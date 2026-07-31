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

-- Dati storici Speedy (pagina NUOVA): consegne NEXIVE 2019-2020 su mappa,
-- voce nel gruppo "Test - Sviluppo" (IdMenuElemento 1229)
IF NOT EXISTS (SELECT 1 FROM MENU_ELEMENTI WHERE Link = '/storici')
  INSERT INTO MENU_ELEMENTI (ParentID, [Text], Link, Sorting)
  VALUES (1229, 'Dati storici Speedy', '/storici', 10);

-- Nuova Spedizione Parcel Speedy (videata legacy "Nuovaspedizione")
UPDATE MENU_ELEMENTI SET Link = '/sped-nuova' WHERE Videata = 'Nuovaspedizione';

-- Gestione clienti dedicata (sostituisce la config generica /config/clienti)
UPDATE MENU_ELEMENTI SET Link = '/clienti' WHERE Videata = 'Clienti';

-- Accettazione da file (senza e con parametro CodFamiglia; le varianti
-- Mittenti/MMG restano da migrare)
UPDATE MENU_ELEMENTI SET Link = '/accettazione-file'
WHERE Videata IN ('AccettazioneDaFile', 'AccettazioneDaFileFamiglia', 'Accettazione Da File Famiglia');

-- Accettazione da banco (senza/con CodFamiglia, varianti con uffici mittenti,
-- Adexuffici che passa idCliente/idProdotto nei Parametri)
UPDATE MENU_ELEMENTI SET Link = '/accettazione-banco'
WHERE Videata IN ('AccettazioneDaBanco', 'AccettazioneDaBancoFamiglia',
                  'AccettazioneDaBancoMittenti', 'Accettazione Da Banco Mittenti',
                  'Adexuffici');

-- Variante MGG (Ministero GG): il link dedicato preimposta cliente 5318,
-- famiglia P e prodotto PICKUP MG (la videata legacy li fissava nel codice)
UPDATE MENU_ELEMENTI SET Link = '/accettazione-banco-mgg'
WHERE Videata = 'Accettazione Da Banco MGG';

-- VideoCodifica: le varianti famiglia/Adex passano i filtri nei Parametri,
-- la MGG ha il link dedicato che fissa il cliente 5318
UPDATE MENU_ELEMENTI SET Link = '/videocodifica'
WHERE Videata IN ('Videocodifica', 'Videocodificafamiglia', 'Adexvideocodifica');
UPDATE MENU_ELEMENTI SET Link = '/videocodifica-mgg' WHERE Videata = 'Videocodificamgg';

-- Checkin lotti: le varianti MGG/Checkindb passano idCliente nei Parametri
UPDATE MENU_ELEMENTI SET Link = '/checkin'
WHERE Videata IN ('Checkin', 'Checkin Famiglia', 'Checkin MGG', 'Checkindb');

-- Gestione gruppi dedicata (sostituisce la config generica /config/gruppi)
UPDATE MENU_ELEMENTI SET Link = '/gruppi' WHERE Videata = 'Gruppi';

-- Presenze TeamSystem (pagina NUOVA): file mensile per lo studio paghe,
-- voce nel gruppo "Gestione Dipendenti" (IdMenuElemento 1460)
IF NOT EXISTS (SELECT 1 FROM MENU_ELEMENTI WHERE Link = '/presenze-ts')
  INSERT INTO MENU_ELEMENTI (ParentID, [Text], Link, Sorting)
  VALUES (1460, 'Presenze TeamSystem', '/presenze-ts', 32);

-- Scontrini di Fine Gita (14 voci, una per filiale)
UPDATE MENU_ELEMENTI SET Link = '/scontrini-gita' WHERE Videata = 'Scontrini Fine Gita';

-- Spedizioni Interne (trasferimenti di materiale tra filiali, azione 1036)
UPDATE MENU_ELEMENTI SET Link = '/sped-interna' WHERE Videata = 'Spedizioneinterna';

-- Distinta Riepilogativa Giornaliera MGG (la variante Notifiche resta da migrare)
UPDATE MENU_ELEMENTI SET Link = '/distinta-riepilogativa' WHERE Videata = 'Distinta Riepilogativa';

-- Ricerche costruite sulle interrogazioni: Ricerca Multipla (IN su elenco
-- barcode), Trova Distinte (form su query 1012), Ricerca con parametri (&[...])
UPDATE MENU_ELEMENTI SET Link = '/ricerca-multipla'
WHERE Videata IN ('RicercaMultipla', 'Ricerca Multipla');
UPDATE MENU_ELEMENTI SET Link = '/trova-distinte'
WHERE Videata IN ('TrovaDistinte', 'Trova Distinte');
UPDATE MENU_ELEMENTI SET Link = '/ricerca-params' WHERE Videata = 'Ricercaparams';

-- Pagine residue (senza la famiglia Giri, da migrare a parte)
UPDATE MENU_ELEMENTI SET Link = '/lavorato-driver' WHERE Videata = 'Lavoratodriver';
UPDATE MENU_ELEMENTI SET Link = '/profilo' WHERE Videata = 'Profilo';
UPDATE MENU_ELEMENTI SET Link = '/scatole' WHERE Videata = 'Scatola';
UPDATE MENU_ELEMENTI SET Link = '/ceste' WHERE Videata = 'Ceste';
UPDATE MENU_ELEMENTI SET Link = '/dipendenti-filiale' WHERE Videata = 'Dipendenti';
UPDATE MENU_ELEMENTI SET Link = '/punteggi' WHERE Videata = 'Punteggi';
UPDATE MENU_ELEMENTI SET Link = '/pickup' WHERE Videata = 'Pickup';

-- Manutenzioni/Sinistri mezzi: config generica su MEZZI_NOTE / MEZZI_SINISTRI
UPDATE MENU_ELEMENTI SET Link = '/config/manutenzioni' WHERE Videata = 'Manutenzioni';
UPDATE MENU_ELEMENTI SET Link = '/config/sinistri' WHERE Videata = 'Sinistri';

-- Tracciato file (menu di test): stesso editor della config tracciati
UPDATE MENU_ELEMENTI SET Link = '/config/tracciati' WHERE Videata = 'Tracciatofile';

-- Ricerca Barcode Clienti Lite: stesso tracking (il claim idCliente
-- dell'utente limita gia' i risultati alle sue spedizioni)
UPDATE MENU_ELEMENTI SET Link = '/tracking' WHERE Videata = 'Ricerca Barcode Clienti Lite';
