# -*- coding: utf-8 -*-
"""Ottimizza il percorso dei giri del giorno con HERE Waypoints Sequencing (findsequence2).

Le richieste le crea la pagina "Piano della giornata" di Speedy Web (stored AI_HERE_Richiesta):
testata in GEO_HereW, punti in GEO_HereWReq (partenza = IdAttivita 0, ritorno = IdAttivita 999999999,
in mezzo le spedizioni con IdSpedizione), stato RICHIESTA in GIRI_PIANO. Questo script, dal
workflow GEO-01_HERE dello schedulatore, chiama HERE per ogni richiesta, scrive la risposta con
AI_HERE_Risposta (GEO_HereWaypoint: sequenza, tempo e distanza per punto; SPED_ATTIVITA.Sequenza;
GIRI_PIANO FATTA con km e minuti) oppure l'errore (GIRI_PIANO ERRORE).

Quale richiesta: dal motore arriva WF_PARAMETRI {"IdGeoHereW": n}; da riga di comando --id N;
senza niente elabora tutte quelle in attesa (GEO_HereW.DataRisposta nulla e piano RICHIESTA).
HERE accetta fino a 120 destinazioni per chiamata: oltre MAX_DEST i punti vengono divisi in
gruppi vicini (k-means), messi in fila dal piu' vicino alla partenza, e ogni gruppo viene
sequenziato partendo dall'ultimo punto del gruppo precedente. Token in Lista Valori HERE
(riga "token"); sosta per consegna in secondi nella riga "sosta" (default 60).
Uso: here_sequenza.py [--id N] [--prova]   (--prova: chiama HERE ma non scrive)
"""
import os
import sys
import json
import math
import time
import datetime
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'poste'))
import speedy  # noqa: E402

URL = 'https://wps.hereapi.com/v8/findsequence2'
ROUTING = 'https://router.hereapi.com/v8/routes'
MAX_DEST = 100
MAX_VIA = 40        # punti intermedi per chiamata a Routing (il tracciato stradale)
SOSTA = 60
PARTENZA, RITORNO = 0, 999999999

# ---- polilinea flessibile di HERE (https://github.com/heremaps/flexible-polyline) ----
_TAVOLA = [62, -1, -1, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -1, -1, -1, -1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
           10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, -1, -1, -1, -1, 63, -1, 26, 27, 28, 29, 30, 31,
           32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51]


def _valori(testo):
    n, shift = 0, 0
    for ch in testo:
        v = _TAVOLA[ord(ch) - 45]
        n |= (v & 0x1F) << shift
        if v & 0x20:
            shift += 5
        else:
            yield n
            n, shift = 0, 0


def decodifica_polilinea(testo):
    """-> [(lat, lng), ...]"""
    it = _valori(testo)
    versione = next(it)
    if versione != 1:
        raise RuntimeError(f"polilinea versione {versione} non gestita")
    testata = next(it)
    precisione, terza = testata & 15, (testata >> 4) & 7
    fattore = 10 ** precisione
    segno = lambda v: ~(v >> 1) if v & 1 else v >> 1
    lat = lng = 0
    punti = []
    while True:
        try:
            dlat = segno(next(it))
        except StopIteration:
            return punti
        dlng = segno(next(it))
        if terza:
            next(it)
        lat += dlat
        lng += dlng
        punti.append((lat / fattore, lng / fattore))


def tracciato(token, tappe):
    """Il tracciato stradale che passa per le tappe (lat, lng) nell'ordine, a spezzoni di MAX_VIA punti intermedi.
    -> [[lat, lng], ...] arrotondati; None se Routing non risponde (il percorso resta valido lo stesso)."""
    coords = []
    i = 0
    while i < len(tappe) - 1:
        tratto = tappe[i:i + MAX_VIA + 2]
        params = [('transportMode', 'car'), ('origin', f"{tratto[0][0]},{tratto[0][1]}"), ('destination', f"{tratto[-1][0]},{tratto[-1][1]}"),
                  ('return', 'polyline'), ('apiKey', token)]
        params += [('via', f"{v[0]},{v[1]}") for v in tratto[1:-1]]
        req = urllib.request.Request(ROUTING + '?' + urllib.parse.urlencode(params), headers={'User-Agent': 'SpeedyWeb'})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                js = json.loads(r.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            print(f"  tracciato: Routing HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:200]}")
            return None
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            print(f"  tracciato: Routing non raggiungibile: {e}")
            return None
        rotte = js.get('routes') or []
        if not rotte:
            print("  tracciato: Routing senza percorso:", json.dumps(js)[:200])
            return None
        for sez in rotte[0].get('sections') or []:
            if sez.get('polyline'):
                coords.extend(decodifica_polilinea(sez['polyline']))
        i += len(tratto) - 1
    # tolgo i punti doppi consecutivi e arrotondo
    out = []
    for lat, lng in coords:
        p = [round(lat, 5), round(lng, 5)]
        if not out or out[-1] != p:
            out.append(p)
    return out


def arg(nome, predefinito=None):
    if nome in sys.argv:
        i = sys.argv.index(nome)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return predefinito


# ---- HERE ----
def partenza_iso(giorno):
    """Ora di partenza per HERE (obbligatoria con le soste): le 7:00 del giorno del piano, o adesso se e' passato."""
    ora_locale = datetime.datetime.now().astimezone()
    dep = datetime.datetime.combine(giorno, datetime.time(7, 0)).replace(tzinfo=ora_locale.tzinfo)
    if dep < ora_locale:
        dep = ora_locale.replace(microsecond=0)
    return dep.isoformat()


def chiama_here(token, sosta, start, destinazioni, end, partenza):
    """Una chiamata a findsequence2: start/end = (lat, lng), destinazioni = [(id, lat, lng)]. Torna il JSON."""
    params = {'apiKey': token, 'mode': 'fastest;car;traffic:disabled', 'improveFor': 'time', 'departure': partenza,
              'start': f"start;{start[0]},{start[1]}"}
    for i, (idr, lat, lng) in enumerate(destinazioni, 1):
        params[f'destination{i}'] = f"{idr};{lat},{lng};st:{sosta}"
    if end:
        params['end'] = f"end;{end[0]},{end[1]}"
    req = urllib.request.Request(URL + '?' + urllib.parse.urlencode(params), headers={'User-Agent': 'SpeedyWeb'})
    for tentativo in (1, 2, 3):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            testo = e.read().decode('utf-8', 'replace')
            if e.code >= 500 and tentativo < 3:
                time.sleep(5 * tentativo)
                continue
            raise RuntimeError(f"HERE HTTP {e.code}: {testo[:300]}")
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            if tentativo < 3:
                time.sleep(5 * tentativo)
                continue
            raise RuntimeError(f"HERE non raggiungibile: {e}")


def senza_fuso(s):
    """'2026-09-24T07:12:00+02:00' -> '2026-09-24T07:12:00' (SQL Server datetime non vuole il fuso)."""
    if not s:
        return None
    s = str(s)
    return s[:19] if len(s) >= 19 else s


def leggi_risposta(js):
    """-> (punti in ordine [{id, seq, tempo, distanza, arrivo, partenza}], distanza totale m, tempo totale s)."""
    if js.get('errors'):
        raise RuntimeError('HERE: ' + '; '.join(str(e) for e in js['errors'])[:300])
    ris = (js.get('results') or [None])[0]
    if not ris or not ris.get('waypoints'):
        raise RuntimeError('HERE: risposta senza percorso: ' + json.dumps(js)[:300])
    verso = {ic.get('toWaypoint'): ic for ic in ris.get('interconnections') or []}
    punti = []
    for w in sorted(ris['waypoints'], key=lambda x: x.get('sequence', 0)):
        ic = verso.get(w.get('id'), {})
        punti.append({'id': str(w.get('id')), 'seq': int(w.get('sequence', 0)), 'tempo': int(ic.get('time') or 0),
                      'distanza': int(ic.get('distance') or 0), 'arrivo': senza_fuso(w.get('estimatedArrival')),
                      'partenza': senza_fuso(w.get('estimatedDeparture'))})
    return punti, int(ris.get('distance') or 0), int(ris.get('time') or 0)


# ---- gruppi per le richieste grandi ----
def gruppi(dest, k):
    """k-means semplice su (lat, lng*cos lat): -> lista di liste di destinazioni."""
    if k <= 1:
        return [dest]
    kx = math.cos(math.radians(dest[0][1]))
    pts = [(d[1], d[2] * kx) for d in dest]
    centri = [pts[int(i * (len(pts) - 1) / max(k - 1, 1))] for i in range(k)]
    for _ in range(30):
        ass = [min(range(k), key=lambda c: (p[0] - centri[c][0]) ** 2 + (p[1] - centri[c][1]) ** 2) for p in pts]
        nuovi = []
        for c in range(k):
            mem = [pts[i] for i in range(len(pts)) if ass[i] == c]
            nuovi.append((sum(p[0] for p in mem) / len(mem), sum(p[1] for p in mem) / len(mem)) if mem else centri[c])
        if nuovi == centri:
            break
        centri = nuovi
    out = [[dest[i] for i in range(len(dest)) if ass[i] == c] for c in range(k)]
    return [g for g in out if g]


def ordina_gruppi(gr, start):
    """dal piu' vicino alla partenza, poi sempre il gruppo piu' vicino all'ultimo centro."""
    def centro(g):
        return (sum(d[1] for d in g) / len(g), sum(d[2] for d in g) / len(g))
    resto = list(gr)
    pos = start
    ordine = []
    while resto:
        g = min(resto, key=lambda x: (centro(x)[0] - pos[0]) ** 2 + (centro(x)[1] - pos[1]) ** 2)
        ordine.append(g)
        resto.remove(g)
        pos = centro(g)
    return ordine


def ottimizza(token, sosta, start, dest, end, partenza):
    """Sequenza completa: [(idReq, tempo, distanza, arrivo, partenza)] nell'ordine, esclusi partenza e ritorno; totali."""
    if len(dest) <= MAX_DEST:
        gr = [dest]
    else:
        gr = ordina_gruppi(gruppi(dest, math.ceil(len(dest) / MAX_DEST)), start)
    ordine, dist_tot, tempo_tot = [], 0, 0
    pos = start
    for i, g in enumerate(gr):
        ultimo = i == len(gr) - 1
        js = chiama_here(token, sosta, pos, [(d[0], d[1], d[2]) for d in g], end if ultimo else None, partenza)
        punti, dist, tempo = leggi_risposta(js)
        per_id = {d[0]: d for d in g}
        for p in punti:
            if p['id'] in ('start', 'end'):
                continue
            try:
                idr = int(p['id'])
            except ValueError:
                raise RuntimeError(f"HERE ha restituito un id inatteso: {p['id']}")
            ordine.append((idr, p['tempo'], p['distanza'], p['arrivo'], p['partenza']))
            d = per_id.get(idr)
            if d:
                pos = (d[1], d[2])
        # il tratto di ritorno (dall'ultimo punto alla filiale) e' nell'interconnessione verso 'end'
        fine = next((p for p in punti if p['id'] == 'end'), None)
        dist_tot += dist
        tempo_tot += tempo
        if ultimo:
            return ordine, dist_tot, tempo_tot, (fine['tempo'], fine['distanza'], fine['arrivo']) if fine else (0, 0, None)
    return ordine, dist_tot, tempo_tot, (0, 0, None)


def elabora(cn, cur, token, sosta, id_here, prova):
    righe = cur.execute("SELECT IdGeoHereReq, IdSpedizione, IdAttivita, Latitude, Longitude FROM dbo.GEO_HereWReq WHERE IdGeoHereW = ? ORDER BY IdGeoHereReq", id_here).fetchall()
    start = next((r for r in righe if r[2] == PARTENZA), None)
    end = next((r for r in righe if r[2] == RITORNO), None)
    dest = [(r[0], r[3], r[4]) for r in righe if r[2] not in (PARTENZA, RITORNO) and r[3] is not None and r[4] is not None]
    if not start or not dest:
        raise RuntimeError(f"richiesta {id_here}: manca la partenza o non ci sono punti")
    giorno = cur.execute("SELECT TOP 1 Data FROM dbo.PIANO_DRIVER WHERE IdGeoHereW = ? UNION ALL SELECT TOP 1 Data FROM dbo.GIRI_PIANO WHERE IdGeoHereW = ?", id_here, id_here).fetchone()
    partenza = partenza_iso(giorno[0] if giorno else datetime.date.today())
    print(f"richiesta {id_here}: {len(dest)} punti" + (f" in {math.ceil(len(dest) / MAX_DEST)} gruppi" if len(dest) > MAX_DEST else "") + f", partenza {partenza}")
    ordine, dist, tempo, ritorno = ottimizza(token, sosta, (start[3], start[4]), dest, (end[3], end[4]) if end else None, partenza)
    waypoints = [{'idReq': start[0], 'seq': 0, 'tempo': 0, 'distanza': 0, 'arrivo': None, 'partenza': None}]
    for i, (idr, t, d, arr, part) in enumerate(ordine, 1):
        waypoints.append({'idReq': idr, 'seq': i, 'tempo': t, 'distanza': d, 'arrivo': arr, 'partenza': part})
    if end:
        waypoints.append({'idReq': end[0], 'seq': len(ordine) + 1, 'tempo': ritorno[0], 'distanza': ritorno[1], 'arrivo': ritorno[2], 'partenza': None})
    print(f"  percorso: {dist / 1000:.1f} km, {tempo // 60} min con le soste, {len(ordine)} consegne")
    # il tracciato stradale nell'ordine trovato (partenza, consegne, ritorno)
    per_id = {r[0]: (r[3], r[4]) for r in righe}
    tappe = [(start[3], start[4])] + [per_id[idr] for idr, *_ in ordine if idr in per_id] + ([(end[3], end[4])] if end else [])
    linea = tracciato(token, tappe)
    print(f"  tracciato stradale: {len(linea)} punti" if linea else "  tracciato stradale: non disponibile")
    if prova:
        print("  [PROVA] non scrivo:", [w['idReq'] for w in waypoints][:12], '...')
        return
    cur.execute("EXEC dbo.AI_HERE_Risposta @IdGeoHereW=?, @Waypoints=?, @DistanzaM=?, @TempoS=?, @Polilinea=?",
                id_here, json.dumps(waypoints), dist, tempo, json.dumps(linea) if linea else None)
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
        raise SystemExit("in LISTA_VALORI (lista HERE) manca la riga token")
    sosta = int(cfg.get('sosta') or SOSTA)
    ids = []
    if arg('--id'):
        ids = [int(arg('--id'))]
    else:
        try:
            par = json.loads(os.environ.get('WF_PARAMETRI') or '{}')
            if par.get('IdGeoHereW'):
                ids = [int(par['IdGeoHereW'])]
        except (ValueError, TypeError):
            pass
    if not ids:
        ids = [r[0] for r in cur.execute("""
            SELECT w.IdGeoHereW FROM dbo.GEO_HereW w
            WHERE w.DataRisposta IS NULL
              AND (EXISTS (SELECT 1 FROM dbo.PIANO_DRIVER p WHERE p.IdGeoHereW = w.IdGeoHereW AND p.Stato = 'RICHIESTA')
                   OR EXISTS (SELECT 1 FROM dbo.GIRI_PIANO p WHERE p.IdGeoHereW = w.IdGeoHereW AND p.Stato = 'RICHIESTA'))
            ORDER BY w.IdGeoHereW""").fetchall()]
    print(f"HERE Waypoints Sequencing: {len(ids)} richieste da elaborare" + ("  [PROVA]" if prova else ""))
    ok, errori = 0, 0
    for id_here in ids:
        try:
            if not prova:
                cur.execute("EXEC dbo.AI_HERE_InCorso @IdGeoHereW=?", id_here)
                cn.commit()
            elabora(cn, cur, token, sosta, id_here, prova)
            ok += 1
        except Exception as ex:
            errori += 1
            print(f"  ERRORE richiesta {id_here}: {str(ex)[:300]}")
            if not prova:
                try:
                    cur.execute("EXEC dbo.AI_HERE_Risposta @IdGeoHereW=?, @Errore=?", id_here, str(ex)[:500])
                    while cur.nextset():
                        pass
                    cn.commit()
                except Exception as ex2:
                    print(f"  errore nel registrare l'errore: {ex2}")
    print(f"--- fine: {len(ids)} richieste | ok {ok} | errori {errori}")
    return 1 if errori and not ok else 0


if __name__ == '__main__':
    sys.exit(main())
