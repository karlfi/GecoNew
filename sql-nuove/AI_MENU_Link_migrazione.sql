-- =============================================================
-- Compila MENU_ELEMENTI.Link per le pagine GIA' migrate nella nuova webapp.
-- Le foglie con Link valorizzato = migrate; con Link NULL = ancora da migrare.
-- Idempotente: si puo' rieseguire (riallinea il Link in base alla Videata).
-- Convenzione Link: rotta interna della SPA nuova.
-- =============================================================

-- Motore interrogazioni (la pagina legge IdQuery/sWhere dal campo Parametri)
UPDATE MENU_ELEMENTI SET Link = '/interrogazioni'
WHERE Videata IN ('RisultatoInterrogazioni', 'Risutatointerrogazioni');

-- Pagine di configurazione generiche
UPDATE MENU_ELEMENTI SET Link = '/config/coperture' WHERE Videata = 'Coperture';
UPDATE MENU_ELEMENTI SET Link = '/config/prodotti'  WHERE Videata = 'Prodotti';
UPDATE MENU_ELEMENTI SET Link = '/config/listini'   WHERE Videata = 'Listini';
UPDATE MENU_ELEMENTI SET Link = '/config/processi'  WHERE Videata = 'Processi';
UPDATE MENU_ELEMENTI SET Link = '/config/gruppi'    WHERE Videata = 'Gruppi';
UPDATE MENU_ELEMENTI SET Link = '/config/aziende'   WHERE Videata = 'Aziende';
UPDATE MENU_ELEMENTI SET Link = '/config/filiali'   WHERE Videata = 'Filiali';
UPDATE MENU_ELEMENTI SET Link = '/config/clienti'   WHERE Videata = 'Clienti';
UPDATE MENU_ELEMENTI SET Link = '/config/tracciati' WHERE Videata = 'FILE TRACCIATO';
UPDATE MENU_ELEMENTI SET Link = '/config/fornitori' WHERE Videata = 'Fornitori';
UPDATE MENU_ELEMENTI SET Link = '/config/lista'     WHERE Videata = 'Lista';
UPDATE MENU_ELEMENTI SET Link = '/config/mittenti'  WHERE Videata = 'Mittenti';
UPDATE MENU_ELEMENTI SET Link = '/config/stati'     WHERE Videata = 'Stati';

-- Editor avanzati
UPDATE MENU_ELEMENTI SET Link = '/interrogazioni-editor' WHERE Videata = 'ModificaInterrogazioni';
UPDATE MENU_ELEMENTI SET Link = '/menu'                  WHERE Videata = 'MenuElementi';
UPDATE MENU_ELEMENTI SET Link = '/utenti'                WHERE Videata = 'Listautenti';

-- Editor workflow / azioni (macchina a stati per processo)
UPDATE MENU_ELEMENTI SET Link = '/workflow' WHERE Videata IN ('Azionenuova', 'Processi Azioni');

-- Consultazione azioni per processo (videata legacy "Azioni (OLD)")
UPDATE MENU_ELEMENTI SET Link = '/azioni' WHERE Videata = 'Azioni';

-- Tracking spedizioni per barcode (voci "Ricerca Barcode" / "Tracking Barcode")
UPDATE MENU_ELEMENTI SET Link = '/tracking' WHERE Videata = 'Ricerca Barcode';

-- Contatori giornalieri di filiale ("Attivita Filiali")
UPDATE MENU_ELEMENTI SET Link = '/attivita-filiali' WHERE Videata = 'Attivitafiliale';

-- Griglia giornaliera driver ("Attivita Dipendenti")
UPDATE MENU_ELEMENTI SET Link = '/attivita-dipendenti' WHERE Videata = 'Inserimento Attivita';

-- Creazione bolle di trasferimento ("DDT - creazione")
UPDATE MENU_ELEMENTI SET Link = '/ddt' WHERE Videata = 'Bollainterna';

-- Esegui Comando (voci di menu con Videata='Eseguicomando', es. Testo Comando Diretto;
-- le azioni pagina# delle interrogazioni la raggiungono senza Link)
UPDATE MENU_ELEMENTI SET Link = '/esegui-comando' WHERE Videata = 'Eseguicomando';

-- Esiti (pagina operativa cardine: ~114 voci di menu, ognuna coi propri Parametri)
UPDATE MENU_ELEMENTI SET Link = '/esiti' WHERE Videata = 'Esiti';

-- Creazione giri su Mappa
UPDATE MENU_ELEMENTI SET Link = '/giri-mappa' WHERE Videata = 'Sped2mappe';

-- Dashboard
UPDATE MENU_ELEMENTI SET Link = '/dashboard' WHERE Videata = 'Dashboard';

-- Export CSV per HR (pagina NUOVA, senza videata legacy): voce in coda al
-- gruppo "Gestione Dipendenti" (IdMenuElemento 1460)
IF NOT EXISTS (SELECT 1 FROM MENU_ELEMENTI WHERE Link = '/export-hr')
  INSERT INTO MENU_ELEMENTI (ParentID, [Text], Link, Sorting)
  VALUES (1460, 'Export CSV per HR', '/export-hr', 30);

-- Carica UNILAV (pagina NUOVA): assunzione da PDF Comunicazione Obbligatoria
IF NOT EXISTS (SELECT 1 FROM MENU_ELEMENTI WHERE Link = '/unilav')
  INSERT INTO MENU_ELEMENTI (ParentID, [Text], Link, Sorting)
  VALUES (1460, 'Carica UNILAV (PDF)', '/unilav', 31);
