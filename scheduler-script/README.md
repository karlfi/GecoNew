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
