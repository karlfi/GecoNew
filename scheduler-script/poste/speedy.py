# -*- coding: utf-8 -*-
"""Cose comuni agli script di import lanciati dal motore dello schedulatore (ESEGUIPYTHON).

- La connessione al DB arriva dal motore nella variabile d'ambiente WF_CONNSTRING (la stessa
  del motore, quindi senza password scritte negli script); fuori dal motore si legge
  l'appsettings.json del motore, che sta in ..\\..\\motore rispetto a questa cartella.
- La cartella dei file e' il primo argomento dello step (Argomenti), altrimenti WF_UPLOADS,
  altrimenti C:\\inetpub\\speedyapp\\uploads. I file elaborati finiscono in <cartella>\\acquisiti.
- Con --prova lo script legge i file e dice cosa farebbe, senza scrivere sul DB e senza
  spostare nulla.
- Esce con codice 1 se almeno un file e' andato in errore: per il motore lo step e' ERRORE.
"""
import os
import sys
import json
import math
import shutil
import datetime
import unicodedata
import warnings

import pyodbc

# i file di Poste/iMile non hanno lo stile predefinito: openpyxl lo segnala su stderr a ogni
# apertura e il motore lo mostrerebbe come avviso nel log
warnings.filterwarnings('ignore', message='Workbook contains no default style')

CARTELLA_PREDEFINITA = r'C:\inetpub\speedyapp\uploads'

# i fogli portano intestazioni in ogni alfabeto (iMile: cinese): la stampa non deve mai
# fermare lo script, anche su una console in cp1252
for _flusso in (sys.stdout, sys.stderr):
    try:
        _flusso.reconfigure(encoding='utf-8', errors='replace')
    except (AttributeError, ValueError):
        pass


def argomenti():
    """(cartella, prova): la cartella dei file e se e' solo una prova."""
    prova = '--prova' in sys.argv
    liberi = [a for a in sys.argv[1:] if not a.startswith('--')]
    cartella = liberi[0] if liberi else (os.environ.get('WF_UPLOADS') or CARTELLA_PREDEFINITA)
    if not os.path.isdir(cartella):
        raise SystemExit(f"cartella dei file non trovata: {cartella}")
    print(f"cartella: {cartella}" + ("  [PROVA: nessuna scrittura]" if prova else ""))
    return cartella, prova


def _connstring_dotnet():
    cs = os.environ.get('WF_CONNSTRING')
    if cs:
        return cs
    qui = os.path.dirname(os.path.abspath(__file__))
    for p in (os.path.join(qui, '..', '..', 'motore', 'appsettings.json'),
              r'C:\progetti\scheduler\motore\appsettings.json'):
        if os.path.exists(p):
            return json.load(open(p, encoding='utf-8-sig'))['ConnectionStrings']['DeliveryDB']
    raise SystemExit("connessione al DB non trovata: serve WF_CONNSTRING (dal motore) o l'appsettings.json del motore")


def connessione():
    """pyodbc.Connection verso DeliveryDB, col miglior driver ODBC presente sulla macchina."""
    d = {}
    for parte in _connstring_dotnet().split(';'):
        if '=' in parte:
            k, v = parte.split('=', 1)
            d[k.strip().lower()] = v.strip()
    server = d.get('server') or d.get('data source')
    db = d.get('database') or d.get('initial catalog')
    uid = d.get('user id') or d.get('uid')
    pwd = d.get('password') or d.get('pwd')
    presenti = pyodbc.drivers()
    driver = next((x for x in ('ODBC Driver 18 for SQL Server', 'ODBC Driver 17 for SQL Server',
                               'SQL Server Native Client 11.0', 'SQL Server') if x in presenti), 'SQL Server')
    odbc = f"DRIVER={{{driver}}};SERVER={server};DATABASE={db};UID={uid};PWD={pwd};TrustServerCertificate=yes;MARS_Connection=yes"
    cn = pyodbc.connect(odbc, autocommit=False)
    print(f"DB: {server}/{db} come {uid} (driver {driver})")
    return cn


def file_da_elaborare(cartella, condizione):
    """i file (non cartelle) della cartella il cui nome soddisfa la condizione, in ordine di nome"""
    return sorted(f for f in os.listdir(cartella)
                  if os.path.isfile(os.path.join(cartella, f)) and condizione(f))


def archivia(cartella, nomefile, prova):
    """sposta il file in <cartella>\\acquisiti (un omonimo gia' presente viene sostituito)"""
    dest_dir = os.path.join(cartella, 'acquisiti')
    dest = os.path.join(dest_dir, nomefile)
    if prova:
        print(f"  [prova] sposterei il file in {dest}")
        return
    os.makedirs(dest_dir, exist_ok=True)
    if os.path.exists(dest):
        os.remove(dest)
    shutil.move(os.path.join(cartella, nomefile), dest)
    print(f"  archiviato in {dest}")


def testo(v):
    """una cella del foglio come stringa per il DB: vuoto/NaN -> None, date come testo ISO"""
    if v is None:
        return None
    if isinstance(v, float) and math.isnan(v):
        return None
    if isinstance(v, (datetime.datetime, datetime.date)):
        return v.isoformat(sep=' ')
    s = str(v).strip()
    return None if s in ('', 'nan', 'NaT', 'None') else s


def cap(v):
    """un CAP dal foglio: Excel lo legge come numero e perde lo zero iniziale (00122 -> 122)"""
    if isinstance(v, float) and not math.isnan(v) and v == int(v):
        v = int(v)
    if isinstance(v, int):
        return f"{v:05d}"
    s = testo(v)
    return s.zfill(5) if s and s.isdigit() and len(s) < 5 else s


def senza_accenti(s):
    return ''.join(c for c in unicodedata.normalize('NFKD', str(s)) if not unicodedata.combining(c)).strip().lower()


def colonna(df, nome):
    """la colonna del DataFrame col nome indicato, senza badare a maiuscole, accenti e spazi"""
    voluto = senza_accenti(nome)
    for c in df.columns:
        if senza_accenti(c) == voluto:
            return c
    raise KeyError(f"colonna '{nome}' non trovata nel foglio (colonne: {[str(c) for c in df.columns]})")


def esegui_stored(cn, nome, prova):
    if prova:
        print(f"  [prova] eseguirei EXEC {nome}")
        return
    cur = cn.cursor()
    cur.execute(f"SET NOCOUNT ON; EXEC dbo.{nome}")
    cn.commit()
    print(f"  EXEC {nome} completata")


def esito(errori, elaborati):
    """riepilogo finale e codice di uscita (1 se qualcosa e' andato storto)"""
    print(f"--- fine: {elaborati} file elaborati, {len(errori)} in errore ---")
    for e in errori:
        print(f"ERRORE {e}")
    sys.exit(1 if errori else 0)
