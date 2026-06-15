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

-- Editor avanzati
UPDATE MENU_ELEMENTI SET Link = '/interrogazioni-editor' WHERE Videata = 'ModificaInterrogazioni';
UPDATE MENU_ELEMENTI SET Link = '/menu'                  WHERE Videata = 'MenuElementi';
UPDATE MENU_ELEMENTI SET Link = '/utenti'                WHERE Videata = 'Listautenti';

-- Editor workflow / azioni (macchina a stati per processo)
UPDATE MENU_ELEMENTI SET Link = '/workflow' WHERE Videata IN ('Azionenuova', 'Processi Azioni');

-- Dashboard
UPDATE MENU_ELEMENTI SET Link = '/dashboard' WHERE Videata = 'Dashboard';
