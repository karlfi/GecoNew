# -*- coding: utf-8 -*-
"""
Genera il file presenze mensile per l'import in TeamSystem (il foglio a record
INTM/DIPE/GG01/GG02/PRES usato dallo studio paghe) a partire dalle presenze
di DeliveryDB (UTENTI_ATTIVITA + UTENTI).

Uso:
    set DELIVERYDB_CS=Driver={ODBC Driver 17 for SQL Server};Server=serverdb;Database=DeliveryDB;UID=...;PWD=...
    python genera_presenze_teamsystem.py --filiale 34 --mese 2026-07 [--azienda-ts 574] [--completa] [--out CARTELLA]

Dipendenti: quelli della filiale con codice fiscale valido (LEN=16) e almeno
una riga di attivita' nel mese; il codice filiale TeamSystem viene da
FILIALI.IdFiliale_HRSpeedy.

Regole di compilazione (dalla legenda dello studio paghe):
- fascia oraria giornaliera dal campo UTENTI.Partime (0 = full time 8h,
  altrimenti 40h * partime% / 6 giorni: 90 -> 6h) -> coppia ORD + RO fissa
  (8h -> 7,73+0,27; 7h -> 6,8+0,2; 6h -> 5,8+0,2; ...);
- giorni PRE/INT: riga ORD + riga RO;
- assenze: sigla ORD senza ore + giustificativo con le ore intere della
  fascia (FER->FE, INF->INF, MAL->ML, MAT->MT); NLV e domeniche -> vuoto;
- PE1..PE4 (permessi a ore): ORD ridotto delle ore di permesso, che si
  sommano alla riga RO ("RO = permesso a ore" in legenda);
- gli straordinari NON sono nel gestionale: vanno aggiunti a mano alle ore
  ORD come da istruzioni dello studio;
- i giorni del mese senza righe in UTENTI_ATTIVITA restano vuoti e vengono
  elencati a fine esecuzione; con --completa vengono riempiti con l'orario
  contrattuale (domeniche escluse), utile se si genera prima di fine mese.

Il file esce in ANSI (cp1252) con separatore ';' e righe CRLF, identico per
struttura al modello compilato dallo studio: 68 campi per riga, blocco per
dipendente con 7 righe PRES.
"""
import argparse
import calendar
import os
import sys
from datetime import date

import pyodbc

MESI = ['gen', 'feb', 'mar', 'apr', 'mag', 'giu', 'lug', 'ago', 'set', 'ott', 'nov', 'dic']
GIORNI = ['Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato', 'Domenica']
NCAMPI = 6 + 31 * 2   # 68 campi per riga, anche nei mesi corti (layout fisso del modello)
NRIGHE_PRES = 7

# fasce orarie della legenda: ore giornaliere -> (ORD, RO)
FASCE = [
    (8.0, 7.73, 0.27),
    (7.0, 6.8, 0.2),
    (6.66, 6.45, 0.21),
    (6.0, 5.8, 0.2),
    (5.0, 4.84, 0.16),
    (4.5, 4.35, 0.15),
    (4.0, 3.87, 0.13),
]

# codPresenza -> sigla del giustificativo TeamSystem (ore = fascia intera)
ASSENZE = {'FER': 'FE', 'INF': 'INF', 'MAL': 'ML', 'MAT': 'MT'}


def fascia_da_partime(partime):
    ore = 8.0 if not partime else 40.0 * float(partime) / 100.0 / 6.0
    return min(FASCE, key=lambda f: abs(f[0] - ore))


def num(v):
    """Numero in formato italiano senza zeri inutili: 7.73 -> '7,73', 6.0 -> '6'."""
    if v is None:
        return ''
    s = f"{v:.2f}".rstrip('0').rstrip('.')
    return s.replace('.', ',')


def riga(campi):
    out = [''] * NCAMPI
    for i, v in campi.items():
        out[i] = v
    return ';'.join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--filiale', type=int, required=True, help='IdFiliale di DeliveryDB (es. 34 = Elba)')
    ap.add_argument('--mese', required=True, help='mese nel formato AAAA-MM (es. 2026-07)')
    ap.add_argument('--azienda-ts', type=int, default=574, help='codice azienda in TeamSystem (default 574)')
    ap.add_argument('--completa', action='store_true',
                    help='riempie i giorni feriali senza dati con l\'orario contrattuale')
    ap.add_argument('--ore', action='append', default=[], metavar='MATRICOLA=ORE',
                    help='forza le ore giornaliere di un dipendente (es. 336=10 per '
                         'includere lo straordinario stabile); il ROL resta quello della fascia')
    ap.add_argument('--out', default='.', help='cartella di destinazione')
    args = ap.parse_args()

    override_ore = {}
    for o in args.ore:
        matricola, _, ore = o.partition('=')
        override_ore[matricola.strip()] = float(ore.replace(',', '.'))

    cs = os.environ.get('DELIVERYDB_CS')
    if not cs:
        sys.exit('Impostare la variabile d\'ambiente DELIVERYDB_CS con la connection string ODBC')

    anno, mese = map(int, args.mese.split('-'))
    ngiorni = calendar.monthrange(anno, mese)[1]
    label = f"{MESI[mese - 1]}-{anno % 100:02d}"
    dal, al = date(anno, mese, 1), date(anno + (mese == 12), mese % 12 + 1, 1)

    cn = pyodbc.connect(cs)
    cur = cn.cursor()

    cur.execute("SELECT FILIALE, IdFiliale_HRSpeedy FROM FILIALI WHERE IDFILIALE = ?", args.filiale)
    fil = cur.fetchone()
    if not fil:
        sys.exit(f"Filiale {args.filiale} inesistente")
    if fil.IdFiliale_HRSpeedy is None:
        sys.exit(f"La filiale '{fil.FILIALE}' non ha IdFiliale_HRSpeedy: impostarlo in FILIALI")
    filiale_ts = str(fil.IdFiliale_HRSpeedy)

    cur.execute("""
        SELECT u.IdUtente, u.Matricola, u.Nome, u.Partime,
               ua.data, ua.codPresenza
        FROM UTENTI_ATTIVITA ua
        INNER JOIN UTENTI u ON u.IdUtente = ua.idUtente
        WHERE u.idFiliale = ? AND ua.data >= ? AND ua.data < ?
          AND LEN(u.CodiceFiscale) = 16
        ORDER BY u.IdUtente, ua.data""", args.filiale, dal, al)

    dipendenti = {}   # IdUtente -> {matricola, nome, partime, giorni: {n: codPresenza}}
    for r in cur.fetchall():
        d = dipendenti.setdefault(r.IdUtente, {
            'matricola': (r.Matricola or '').strip(),
            'nome': (r.Nome or '').strip().upper(),
            'partime': r.Partime,
            'giorni': {}
        })
        d['giorni'][r.data.day] = (r.codPresenza or '').strip()
    cn.close()

    if not dipendenti:
        sys.exit('Nessun dipendente con presenze nel mese per questa filiale')

    def chiave(d):
        try:
            return (0, int(d['matricola']))
        except ValueError:
            return (1, 0)

    testata_giorni = {}
    testata_sigle = {}
    for g in range(1, ngiorni + 1):
        testata_giorni[6 + (g - 1) * 2] = f"{g} - {GIORNI[date(anno, mese, g).weekday()]}"
        testata_sigle[6 + (g - 1) * 2] = 'Sigla'
        testata_sigle[6 + (g - 1) * 2 + 1] = 'Ore'

    righe_file = [
        riga({0: 'INTM', 1: 'Mese', 2: 'Azienda', 3: 'Filiale', 4: 'Matricola',
              6: 'Codice Azienda:', 8: str(args.azienda_ts), 10: 'Mese Presenze:', 12: label}),
        riga({}),
    ]
    avvisi = []

    for nd, d in enumerate(sorted(dipendenti.values(), key=chiave)):
        tot, ord_h, rol = fascia_da_partime(d['partime'])
        if d['matricola'] in override_ore:
            tot = override_ore[d['matricola']]
            ord_h = tot - rol      # il ROL resta la quota della fascia contrattuale
        vuoti = []
        # per ogni giorno la lista di coppie (sigla, ore) da distribuire sulle righe PRES
        coppie = {}
        for g in range(1, ngiorni + 1):
            wd = date(anno, mese, g).weekday()
            cod = d['giorni'].get(g)
            if cod is None:
                if wd != 6:
                    vuoti.append(g)
                    if args.completa:
                        coppie[g] = [('ORD', num(ord_h)), ('RO', num(rol))]
                continue
            if cod in ('PRE', 'INT'):
                coppie[g] = [('ORD', num(ord_h)), ('RO', num(rol))]
            elif cod == 'NLV':
                pass
            elif cod in ASSENZE:
                coppie[g] = [('ORD', ''), (ASSENZE[cod], num(tot))]
            elif cod.startswith('PE') and cod[2:].isdigit():
                n = int(cod[2:])
                coppie[g] = [('ORD', num(ord_h - n)), ('RO', num(rol + n))]
            elif cod in ('C05', 'C10'):
                coppie[g] = [('ORD', ''), ('CIG', num(tot))]
                avvisi.append(f"{d['matricola']} {d['nome']}: giorno {g} in cassa integrazione ({cod}): "
                              "verificare la sigla con lo studio paghe")
            else:
                avvisi.append(f"{d['matricola']} {d['nome']}: giorno {g} con codice '{cod}' non gestito, lasciato vuoto")

        if vuoti:
            stato = 'riempiti con l\'orario contrattuale' if args.completa else 'lasciati vuoti'
            avvisi.append(f"{d['matricola']} {d['nome']}: giorni senza dati ({stato}): "
                          + ', '.join(map(str, vuoti)))

        righe_file.append(riga({0: 'DIPE', 6: 'Matricola:', 8: d['matricola'],
                                10: 'Nominativo:', 12: d['nome']}))
        righe_file.append(riga({0: 'GG01', **testata_giorni}))
        righe_file.append(riga({0: 'GG02', **testata_sigle}))
        base = {0: 'PRES', 1: label, 2: str(args.azienda_ts), 3: filiale_ts, 4: d['matricola']}
        for slot in range(NRIGHE_PRES):
            campi = dict(base)
            for g, elenco in coppie.items():
                if slot < len(elenco):
                    sigla, ore = elenco[slot]
                    campi[6 + (g - 1) * 2] = sigla
                    campi[6 + (g - 1) * 2 + 1] = ore
            righe_file.append(riga(campi))
        if nd < len(dipendenti) - 1:
            righe_file.append(riga({}))

    nome_file = f"Presenze_TS_Fil{filiale_ts}_{label}.csv"
    percorso = os.path.join(args.out, nome_file)
    with open(percorso, 'w', encoding='cp1252', newline='') as f:
        f.write('\r\n'.join(righe_file) + '\r\n')

    print(f"Scritto {percorso} — {len(dipendenti)} dipendenti, filiale TS {filiale_ts}, azienda {args.azienda_ts}")
    for a in avvisi:
        print('AVVISO:', a)


if __name__ == '__main__':
    main()
