# -*- coding: utf-8 -*-
"""Pianificazione automatica: divide le spedizioni geolocalizzate di una filiale in un giorno fra i driver scelti con
HERE Tour Planning v3 (problema asincrono) e scrive il risultato con AI_PIANO_AUTO_Risposta.
La richiesta la crea la pagina "Pianificazione automatica" di Speedy Web (AI_PIANO_AUTO_Richiesta: PIANO_AUTO e
PIANO_AUTO_DRIVER con turno, partenza/ritorno, max pezzi, zone preferite di ogni driver); il workflow GEO-02_HERE_TOUR
dello schedulatore lancia questo script con WF_PARAMETRI {"IdPianoAuto": n}.
Come si imposta il problema:
- le spedizioni allo stesso indirizzo (coordinate uguali) sono una fermata sola: domanda = numero di pezzi, sosta =
  sosta + sostaPezzo per ogni pezzo in piu' (meno fermate = calcolo migliore e meno transazioni HERE);
- zone "ibride": il giro della fermata e' il suo territorio; i giri abituali del driver sono i suoi territori
  preferiti (strict false): li serve per primi ma puo' prendere anche fuori;
- equilibrio: ogni driver porta al massimo la media dei pezzi + tolleranza % (o meno, se ha un suo massimo) e fa
  almeno la media delle fermate - tolleranza % (limits.stops.minCount, funzione sperimentale "minStops" di HERE);
  l'obiettivo "optimizeTourCount maximize" fa lavorare tutti i driver scelti;
- turno: inizio e fine del driver, partenza e ritorno dalla filiale o da casa (UTENTI_GEO);
- posizioni sospette escluse: una consegna molto piu' lontana dalla filiale delle altre (oltre il doppio del 95esimo
  percentile e oltre 30 km in linea d'aria) e' quasi sempre geolocalizzata male (es. "CASELLINA" provincia FC invece
  di Scandicci: 290 km in piu' al driver che la prende); resta non assegnata col motivo, da correggere a mano.
Parametri della pagina (PIANO_AUTO.Parametri): sosta, sostaPezzo, tolleranza, zone, usaTutti, tieniLontane.
Token in Lista Valori HERE/token; sosta di default nella riga "sosta" (60 s).
Uso a mano: here_tour.py --id N [--prova] [--problema file.json]   (--prova: chiama HERE ma non scrive)
"""
import os
import sys
import json
import math
import time
import datetime
import urllib.request
import urllib.parse
import urllib.error

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'poste'))
import speedy  # noqa: E402

URL_ASYNC = 'https://tourplanning.hereapi.com/v3/problems/async'
SOSTA = 60
SOSTA_PEZZO = 20
TOLLERANZA = 15
ATTESA_MAX = 25 * 60          # secondi massimi di attesa della soluzione
MOTIVI = {
    'CAPACITY_CONSTRAINT': "i driver hanno gia' il massimo dei pezzi",
    'SHIFT_TIME_CONSTRAINT': 'non entra nei turni dei driver',
    'TIME_WINDOW_CONSTRAINT': 'non entra nei turni dei driver',
    'DISTANCE_CONSTRAINT': 'troppo lontano',
    'REACHABLE_CONSTRAINT': 'posto non raggiungibile su strada',
    'TERRITORY_CONSTRAINT': 'fuori dalle zone dei driver',
    'SKILL_CONSTRAINT': 'nessun driver adatto',
    'NO_REASON_FOUND': 'non assegnata (motivo non indicato da HERE)',
}


def arg(nome, predefinito=None):
    if nome in sys.argv:
        i = sys.argv.index(nome)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return predefinito


def chiama(metodo, url, token, corpo=None):
    """-> (json, transazioni dichiarate nell'intestazione Usage). Riprova sugli errori 5xx e di rete."""
    sep = '&' if '?' in url else '?'
    dati = json.dumps(corpo).encode('utf-8') if corpo is not None else None
    req = urllib.request.Request(url + sep + urllib.parse.urlencode({'apiKey': token}), data=dati, method=metodo,
                                 headers={'Content-Type': 'application/json', 'User-Agent': 'SpeedyWeb'})
    for tentativo in (1, 2, 3):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                testo = r.read().decode('utf-8')
                usage = r.headers.get('Usage') or ''
                return (json.loads(testo) if testo else {}), sum(int(x.split(':')[-1]) for x in usage.split(',') if ':' in x and x.split(':')[-1].strip().isdigit())
        except urllib.error.HTTPError as e:
            testo = e.read().decode('utf-8', 'replace')
            if e.code >= 500 and tentativo < 3:
                time.sleep(5 * tentativo)
                continue
            try:
                j = json.loads(testo)
                testo = j.get('cause') or j.get('title') or testo
            except ValueError:
                pass
            raise RuntimeError(f'HERE HTTP {e.code}: {str(testo)[:400]}')
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            if tentativo < 3:
                time.sleep(5 * tentativo)
                continue
            raise RuntimeError(f'HERE non raggiungibile: {e}')


def ora_here(giorno, ora):
    """date + time -> '2026-09-25T08:30:00+02:00' col fuso del server."""
    return datetime.datetime.combine(giorno, ora).astimezone().isoformat()


def ora_locale(s):
    """'2026-09-25T06:30:00Z' -> '2026-09-25T08:30:00' (ora locale senza fuso, per SQL Server)."""
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(str(s).replace('Z', '+00:00')).astimezone().replace(tzinfo=None).isoformat(timespec='seconds')
    except ValueError:
        return str(s)[:19]


def carica(cur, id_piano):
    p = cur.execute("""SELECT p.IdFiliale, p.Data, p.Stato, p.Parametri, f.Latitude, f.Longitude, f.FILIALE
                       FROM dbo.PIANO_AUTO p JOIN dbo.FILIALI f ON f.IDFILIALE = p.IdFiliale WHERE p.IdPianoAuto = ?""", id_piano).fetchone()
    if not p:
        raise RuntimeError(f'piano {id_piano} inesistente')
    if p[4] is None or p[5] is None:
        raise RuntimeError(f'la filiale {p[6]} non ha le coordinate (FILIALI.Latitude/Longitude)')
    driver = cur.execute("""SELECT d.IdDriver, u.Nome, d.Inizio, d.Fine, d.PartenzaCasa, d.RitornoCasa, d.MaxPezzi, d.Giri, g.Lat, g.Lng
                            FROM dbo.PIANO_AUTO_DRIVER d JOIN dbo.UTENTI u ON u.IdUtente = d.IdDriver
                            LEFT JOIN dbo.UTENTI_GEO g ON g.IdUtente = d.IdDriver
                            WHERE d.IdPianoAuto = ? ORDER BY u.Nome""", id_piano).fetchall()
    giorno = p[1]
    sped = cur.execute("""SELECT IdSpedizione, DestinazioneLatitude, DestinazioneLongitude, IdGiro FROM dbo.SPED_ATTIVITA
                          WHERE IdFiliale = ? AND DataCarico >= ? AND DataCarico < ?
                            AND DestinazioneLatitude IS NOT NULL AND DestinazioneLongitude IS NOT NULL""",
                       p[0], giorno, giorno + datetime.timedelta(days=1)).fetchall()
    try:
        par = json.loads(p[3] or '{}')
    except ValueError:
        par = {}
    return {'filiale': p[6], 'giorno': giorno, 'stato': p[2], 'par': par, 'base': {'lat': float(p[4]), 'lng': float(p[5])},
            'driver': driver, 'sped': sped}


def km(a, b):
    """distanza in linea d'aria fra due {'lat','lng'} in km"""
    la1, la2 = math.radians(a['lat']), math.radians(b['lat'])
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(math.radians(b['lng'] - a['lng']) / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(h))


def sospette(dati):
    """le spedizioni con la posizione molto piu' lontana dalla filiale delle altre: {IdSpedizione: km}"""
    dist = {r[0]: km(dati['base'], {'lat': float(r[1]), 'lng': float(r[2])}) for r in dati['sped']}
    if len(dist) < 10:
        return {}
    ordinate = sorted(dist.values())
    p95 = ordinate[int(len(ordinate) * 0.95) - 1]
    soglia = max(30.0, 2 * p95)
    return {k: v for k, v in dist.items() if v > soglia}


def problema(dati, sosta_default):
    """-> (problema HERE, fermate {jobId: [IdSpedizione]}, id veicolo -> IdDriver, tetto di pezzi, escluse {Id: km})"""
    par = dati['par']
    sosta = int(par.get('sosta') or sosta_default)
    sosta_pezzo = int(par.get('sostaPezzo') if par.get('sostaPezzo') is not None else SOSTA_PEZZO)
    tolleranza = par.get('tolleranza')
    tolleranza = TOLLERANZA if tolleranza is None else float(tolleranza)
    zone = par.get('zone', True) is not False
    usa_tutti = par.get('usaTutti', True) is not False
    escluse = {} if par.get('tieniLontane') else sospette(dati)

    # fermate: coordinate uguali (a 1 m circa) = un indirizzo solo
    fermate = {}
    for ids, lat, lng, giro in dati['sped']:
        if ids in escluse:
            continue
        fermate.setdefault((round(float(lat), 5), round(float(lng), 5)), []).append((ids, giro))
    jobs, per_job = [], {}
    for n, ((lat, lng), pezzi) in enumerate(sorted(fermate.items()), 1):
        jid = f'f{n}'
        per_job[jid] = [x[0] for x in pezzi]
        giri = [x[1] for x in pezzi if x[1] is not None]
        luogo = {'location': {'lat': lat, 'lng': lng}, 'duration': sosta + sosta_pezzo * (len(pezzi) - 1)}
        if zone and giri:
            luogo['territoryIds'] = [f'g{max(set(giri), key=giri.count)}']
        jobs.append({'id': jid, 'tasks': {'deliveries': [{'places': [luogo], 'demand': [len(pezzi)]}]}})

    totale = len(dati['sped']) - len(escluse)
    n_driver = len(dati['driver'])
    tetto = math.ceil(totale / n_driver * (1 + tolleranza / 100)) if tolleranza > 0 else totale
    minimo = math.floor(len(jobs) / n_driver * (1 - tolleranza / 100)) if tolleranza > 0 and usa_tutti and n_driver > 1 else 0
    tipi, per_veicolo = [], {}
    for id_d, nome, inizio, fine, pcasa, rcasa, maxp, giri_json, clat, clng in dati['driver']:
        casa = {'lat': float(clat), 'lng': float(clng)} if clat is not None and clng is not None else None
        start = casa if pcasa and casa else dati['base']
        end = casa if rcasa and casa else dati['base']
        capacita = min(tetto, maxp) if maxp else tetto
        tipo = {
            'id': f'd{id_d}',
            'profile': 'auto',
            'costs': {'fixed': 0, 'distance': 0.0002, 'time': 0.004},
            'shifts': [{'start': {'time': ora_here(dati['giorno'], inizio), 'location': start},
                        'end': {'time': ora_here(dati['giorno'], fine), 'location': end}}],
            'capacity': [capacita],
            'amount': 1,
        }
        try:
            giri = [int(g) for g in json.loads(giri_json or '[]')]
        except (ValueError, TypeError):
            giri = []
        if zone and giri:
            tipo['territories'] = {'strict': False, 'items': [{'id': f'g{g}', 'priority': 1} for g in giri]}
        if minimo > 0:
            tipo['limits'] = {'stops': {'minCount': {'value': min(minimo, capacita)}}}
        tipi.append(tipo)
        per_veicolo[tipo['id']] = id_d
    obiettivi = [{'type': 'minimizeUnassigned'}]
    if usa_tutti:
        obiettivi.append({'type': 'optimizeTourCount', 'action': 'maximize'})
    obiettivi.append({'type': 'minimizeCost'})
    prob = {
        'fleet': {'types': tipi, 'profiles': [{'name': 'auto', 'type': 'car'}]},
        'plan': {'jobs': jobs},
        'objectives': obiettivi,
        'configuration': {'termination': {'maxTime': 300, 'stagnationTime': 60}},
    }
    if minimo > 0:
        prob['configuration']['experimentalFeatures'] = ['minStops']
    return prob, per_job, per_veicolo, tetto, escluse


def risolvi(token, prob):
    """problema asincrono: invio, attesa dello stato, soluzione. -> (soluzione, transazioni)"""
    risp, tx = chiama('POST', URL_ASYNC, token, prob)
    href = risp.get('href')
    if not href:
        raise RuntimeError('HERE non ha dato lo stato del calcolo: ' + json.dumps(risp)[:300])
    print(f"  problema inviato ({risp.get('statusId')}), attendo la soluzione...")
    inizio = time.time()
    attesa = 3
    while time.time() - inizio < ATTESA_MAX:
        time.sleep(attesa)
        attesa = min(attesa + 2, 15)
        stato, t = chiama('GET', href, token)
        tx += t
        s = stato.get('status')
        if s == 'success':
            sol, t = chiama('GET', stato['resource']['href'], token)
            print(f'  soluzione pronta in {int(time.time() - inizio)} s')
            return sol, tx + t
        if s == 'failure':
            err = stato.get('error') or {}
            raise RuntimeError('HERE non ha trovato una soluzione: ' + str(err.get('cause') or err.get('title') or stato)[:400])
    raise RuntimeError(f'HERE non ha finito entro {ATTESA_MAX // 60} minuti')


def leggi(sol, per_job, per_veicolo):
    """-> (righe per spedizione, righe per driver, fermate totali, distanza m, tempo s)"""
    sped, driver = [], []
    fermate_tot = dist_tot = tempo_tot = 0
    for tour in sol.get('tours') or []:
        id_d = per_veicolo.get(tour.get('typeId')) or per_veicolo.get(str(tour.get('vehicleId', '')).rsplit('_', 1)[0])
        if id_d is None:
            continue
        seq = fermata = 0
        prima = ultima = None
        for stop in tour.get('stops') or []:
            consegne = [a for a in stop.get('activities') or [] if a.get('type') == 'delivery']
            orari = stop.get('time') or {}
            if prima is None:
                prima = orari.get('departure')
            ultima = orari.get('arrival') or ultima
            if not consegne:
                continue
            fermata += 1
            for a in consegne:
                for ids in per_job.get(a.get('jobId'), []):
                    seq += 1
                    sped.append({'id': ids, 'driver': id_d, 'fermata': fermata, 'seq': seq,
                                 'arrivo': ora_locale((a.get('time') or {}).get('start') or orari.get('arrival'))})
        st = tour.get('statistic') or {}
        driver.append({'idDriver': id_d, 'pezzi': seq, 'fermate': fermata, 'distanza': int(st.get('distance') or 0),
                       'tempo': int(st.get('duration') or 0), 'inizio': ora_locale(prima), 'fine': ora_locale(ultima)})
        fermate_tot += fermata
        dist_tot += int(st.get('distance') or 0)
        tempo_tot += int(st.get('duration') or 0)
    for u in sol.get('unassigned') or []:
        motivi = u.get('reasons') or []
        testo = '; '.join(MOTIVI.get(m.get('code'), m.get('description') or m.get('code') or '') for m in motivi) or MOTIVI['NO_REASON_FOUND']
        for ids in per_job.get(u.get('jobId'), []):
            sped.append({'id': ids, 'driver': None, 'motivo': testo[:300]})
    return sped, driver, fermate_tot, dist_tot, tempo_tot


def elabora(cn, cur, token, sosta, id_piano, prova):
    dati = carica(cur, id_piano)
    if not dati['driver']:
        raise RuntimeError('il piano non ha driver')
    if not dati['sped']:
        raise RuntimeError('nessuna spedizione geolocalizzata per la filiale in quel giorno')
    prob, per_job, per_veicolo, tetto, escluse = problema(dati, sosta)
    print(f"piano {id_piano}: {dati['filiale']} {dati['giorno']}, {len(dati['sped']) - len(escluse)} pezzi in {len(per_job)} fermate, "
          f"{len(dati['driver'])} driver, max {tetto} pezzi a testa" + (f", {len(escluse)} con la posizione sospetta escluse" if escluse else ''))
    if arg('--problema'):
        with open(arg('--problema'), 'w', encoding='utf-8') as f:
            json.dump(prob, f, indent=1)
    if not prova:
        cur.execute("EXEC dbo.AI_PIANO_AUTO_InCorso @IdPianoAuto=?, @IdEsecuzione=?", id_piano,
                    int(os.environ['WF_ID_ESECUZIONE']) if os.environ.get('WF_ID_ESECUZIONE', '').isdigit() else None)
        cn.commit()
    sol, tx = risolvi(token, prob)
    # le chiamate asincrone non hanno l'intestazione Usage: si stima come HERE conta (fermate + veicoli)
    tx = tx or len(prob['plan']['jobs']) + len(prob['fleet']['types'])
    sped, driver, fermate, dist, tempo = leggi(sol, per_job, per_veicolo)
    sped += [{'id': ids, 'driver': None, 'motivo': f"posizione sospetta: {k:.0f} km dalla filiale, da controllare"} for ids, k in escluse.items()]
    non = sum(1 for s in sped if s['driver'] is None)
    print(f"  {len(sped) - non} pezzi assegnati, {non} non assegnati, {fermate} fermate, {dist / 1000:.1f} km, {tempo // 3600} h {tempo % 3600 // 60} min, {tx} transazioni HERE")
    for d in driver:
        print(f"    driver {d['idDriver']}: {d['pezzi']} pezzi, {d['fermate']} fermate, {d['distanza'] / 1000:.1f} km, fine {d['fine']}")
    if prova:
        print('  [PROVA] non scrivo')
        return
    cur.execute("EXEC dbo.AI_PIANO_AUTO_Risposta @IdPianoAuto=?, @Driver=?, @Spedizioni=?, @NFermate=?, @DistanzaM=?, @TempoS=?, @Transazioni=?",
                id_piano, json.dumps(driver), json.dumps(sped), fermate, dist, tempo, tx)
    while cur.nextset():
        pass
    cn.commit()


def main():
    prova = '--prova' in sys.argv
    cn = speedy.connessione()
    cur = cn.cursor()
    cfg = {r[0].strip().lower(): (r[1] or '').strip() for r in cur.execute("SELECT Valore, Codice FROM dbo.LISTA_VALORI WHERE Lista = 'HERE'")}
    token = cfg.get('token')
    if not token:
        raise SystemExit('in LISTA_VALORI (lista HERE) manca la riga token')
    sosta = int(cfg.get('sosta') or SOSTA)
    id_piano = int(arg('--id')) if arg('--id') else None
    if id_piano is None:
        try:
            id_piano = int(json.loads(os.environ.get('WF_PARAMETRI') or '{}').get('IdPianoAuto') or 0) or None
        except (ValueError, TypeError, AttributeError):
            id_piano = None
    if id_piano is None:
        r = cur.execute("SELECT TOP 1 IdPianoAuto FROM dbo.PIANO_AUTO WHERE Stato = 'RICHIESTA' ORDER BY IdPianoAuto").fetchone()
        id_piano = r[0] if r else None
    if id_piano is None:
        print('nessuna pianificazione in attesa')
        return 0
    print('HERE Tour Planning' + ('  [PROVA]' if prova else ''))
    try:
        elabora(cn, cur, token, sosta, id_piano, prova)
        return 0
    except Exception as ex:
        print(f'  ERRORE piano {id_piano}: {str(ex)[:500]}')
        if not prova:
            try:
                cn.rollback()
                cur.execute("EXEC dbo.AI_PIANO_AUTO_Risposta @IdPianoAuto=?, @Errore=?", id_piano, str(ex)[:1000])
                cn.commit()
            except Exception as ex2:
                print(f"  errore nel registrare l'errore: {ex2}")
        return 1


if __name__ == '__main__':
    sys.exit(main())
