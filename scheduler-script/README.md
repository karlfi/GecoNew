# Script dello schedulatore (Ge.C.O. New)

Script Python lanciati dal motore (`motore/`, step **ESEGUIPYTHON**) sul server di Ge.C.O. New: vanno
copiati in `C:\Progetti\scheduler\script` (la `CartellaScript` del motore), con la stessa struttura di
cartelle. Il motore passa agli script `WF_CONNSTRING` (la connessione al DB), `WF_PARAMETRI` (JSON),
`WF_ID_ESECUZIONE`, `WF_ID_WORKFLOW`, `WF_ID_STEP`; quello che stampano finisce nel log dell'esecuzione,
exit code diverso da zero = step in errore.

Nel fork ci sono solo gli script che servono alle pagine portate da Speedy Web (gli import Poste, Knox
e WINDTRE di Speedy Web restano la': sono legati ai suoi file e ai suoi account).

## poste/speedy.py

Modulo comune: `speedy.connessione()` apre DeliveryDB con la stringa di `WF_CONNSTRING` (o, fuori dal
motore, dall'`appsettings.json` del motore in `..\..\motore`) e il miglior driver ODBC presente.

## here/ — ottimizzazione dei percorsi con HERE (pagina Piano della giornata)

`here_sequenza.py` (workflow **GEO-01_HERE**, messo in coda dalla pagina con `WF_PARAMETRI`
`{"IdGeoHereW": n}`): legge la richiesta preparata da `AI_HERE_RichiestaDriver` (`GEO_HereW` testata,
`GEO_HereWReq` punti, `PIANO_DRIVER`), chiama HERE Waypoints Sequencing v8 (`findsequence2`, partenza e
ritorno in filiale o da casa, sosta per consegna, gruppi oltre 100 punti) e HERE Routing v8 per il
tracciato stradale (polilinea flessibile decodificata dallo script), poi scrive con `AI_HERE_Risposta`
`GEO_HereWaypoint`, `SPED_ATTIVITA.Sequenza` e `PALM_ATTIVITA.Sequenza`. Token in Lista Valori, lista
`HERE`, riga `token` (campo Codice); riga facoltativa `sosta` in secondi. A mano:
`python here_sequenza.py [--id n] [--prova]`.

Il workflow si crea dalla pagina Schedulatore: un solo step ESEGUIPYTHON con Parametri
`{"Script": "here\\here_sequenza.py", "TimeoutSecondi": "900"}`, nome **GEO-01_HERE** (la pagina lo
cerca per nome), nessuna pianificazione.

`here_tour.py` (2026-09-25) serve la pagina **Pianificazione automatica** (menu Gestione Giri Filiale): divide tutte
le spedizioni geolocalizzate della filiale nel giorno fra i driver scelti con **HERE Tour Planning v3** (problema
asincrono: invio, attesa dello stato, soluzione). La pagina crea la richiesta con `AI_PIANO_AUTO_Richiesta`
(`PIANO_AUTO`, `PIANO_AUTO_DRIVER`: turno, partenza/ritorno da casa o filiale, max pezzi, zone preferite) e mette in
coda il workflow **GEO-02_HERE_TOUR** con `WF_PARAMETRI` `{"IdPianoAuto": n}`; lo script scrive driver, fermata,
sequenza e arrivo di ogni spedizione con `AI_PIANO_AUTO_Risposta` (`PIANO_AUTO_SPED`). Come imposta il problema:
spedizioni con le stesse coordinate = una fermata (domanda = pezzi); il giro della fermata e' il suo territorio e i
giri abituali del driver sono territori preferiti non esclusivi (zone "ibride"); equilibrio con un tetto di pezzi
(media + tolleranza %) e un minimo di fermate (media - tolleranza %, funzione sperimentale `minStops`); obiettivo
`optimizeTourCount maximize` per far lavorare tutti i driver scelti. Le posizioni sospette (oltre 30 km e oltre il
doppio del 95esimo percentile dalla filiale, quasi sempre geolocalizzate male) restano non assegnate col motivo.
Il calcolo di 300 consegne dura 2-3 minuti; le chiamate asincrone non hanno l'intestazione `Usage`, quindi le
transazioni HERE si stimano (fermate + driver). Tabelle e stored in `sql-nuove/PIANO_AUTO.sql`. Prova a mano:
`here_tour.py --id N --prova [--problema file.json]`. Il workflow **GEO-02_HERE_TOUR** lo crea lo script SQL.
