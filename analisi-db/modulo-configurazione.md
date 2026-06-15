# Modulo 1 — Dashboard + Configurazione: analisi del modello dati esistente

> Ricognizione dell'11/06/2026 su DeliveryDB (serverdb). Sorgenti SQL citati salvati in `analisi-db/sp/`.

## 1. Autenticazione

**Tabella `UTENTI`** (3021 righe, 60 colonne) — è una "god table" che mescola più domini:

| Area | Colonne principali |
|---|---|
| Login | `Utente`, `Pass` (varchar 50), `codAppLogin` (palmare), `tokenAutoLogin`, `tokenRegistrazione`, `LoginErrors`, `DataUltimoAccesso` |
| Profilo | `Nome`, `Email`, `CodiceFiscale`, `Telefono`, `IdRuolo` (singolo), `IdUtentePadre` (gerarchia), `IdFiliale`, `IdCliente`, `DataInizio`/`DataFine` (validità) |
| Certificato di firma (notifiche legali) | 13 colonne `CERT_*` (validità, revoca, sospensione, serial, PIN, tentativi) |
| Driver | `IdMezzo_Default`, `CodPoste`, `CodADER4`, `CodADER`, `Cod_iMile` |
| HR/dotazioni | `Matricola`, `DataNascita`, `Iban`, `Partime`, `GiorniLavorativi`, `OrarioLavoro`, `Livello`, `Mansione`, `NumeroScarpe`, `TagliaAbbigliamento`, indirizzo residenza |
| Firma grafica | `FotoTessera`, `FirmaEstesa`, `FirmaSigla` (path), `flagFirma` |

**Login attuale** — SP `LogInCSO(@CodAppLogIn, @utente, @pwd, @tipo)`:
- `@tipo=0`: verifica esistenza per `codAppLogin` (login palmare)
- `@tipo=1`: **restituisce la `Pass` salvata al chiamante** → il confronto (MD5) avviene nell'applicazione. Da NON replicare.

**Stato password** (statistiche, nessun valore letto): 3021 utenti → **2573 password vuote** (utenti palmare/token o disattivati), **436 MD5** (hex a 32 char, presumibilmente senza salt), **12 corte** (probabile chiaro). Max len 32.

**Audit**: trigger `TR_UP_UTENTI` (after update) scrive il record in XML su `LogTabelle` (18M righe), saltando gli update di solo `DataUltimoAccesso`/`LoginErrors`. Pattern di audit da mantenere nelle SP nuove.

**Proposta per la nuova API**:
1. Nuova SP `NEW_AuthLogin` che verifica la password **server-side** e restituisce il profilo (mai l'hash). L'API emette JWT con claims: IdUtente, IdRuolo, gruppi, IdFiliale, IdCliente.
2. Migrazione progressiva hash: nuova colonna (es. `PassHash2`) con bcrypt/argon2; al primo login riuscito con MD5 si ri-hasha e si azzera `Pass`. Da concordare (aggiunta colonna = estensione, non modifica).
3. Lockout già pronto: `LoginErrors` esiste.

## 2. RBAC (doppio livello, confermato dal codice)

- **`RUOLI`** (12): 1 SuperUser, 10 Resp. Aziendale, 20 Resp. Filiale, 25 Op. Scansione, 30 Op. Filiale, 35 Op. Sportello, 40 Driver, 41 Driver Az. Esterna, 42 Interinale, 50 Cliente Top, 55 Cliente Base, 99 Anonimo. Ruolo singolo su `UTENTI.IdRuolo`.
- **`GRUPPI`** (52) + **`UTENTI_GRUPPI`** (1363) — N:N utente↔gruppo.
- **Menu**: `MENU_ELEMENTI` (580, albero via `ParentID`, foglie → `Videata`+`Parametri`+`NavigateUrl`), visibilità per ruolo (`MENU_ElementiRuoli`) e per gruppo (`MENU_ELEMENTIGRUPPI`).
- **SP `ElencoMenuGruppi(@IdUtente)`** — implementa tutta la logica: base per ruolo (default 99=Anonimo), override additivo per gruppi, propagazione padre/figli, sorting calcolato (`padre*10000+figlio*100`). **Riusabile così com'è** dalla nuova API (`GET /api/me/menu`).
- Restrizioni dati per utente: `UTENTI_PROFILI` (famiglie prodotto `CodFamiglia`), `UTENTI_PROCESSI` (processo + comune `Belfiore`), `UTENTI_FILIALI` (filiali aggiuntive).

## 3. Dashboard

- **`UTENTI_ATTIVITA`** (620k righe): una riga per utente/giorno — presenza (`codPresenza`), `ore`, `KmPercorsi`, `idMezzo`, `Palmare`, `Login`/`Logout`, `target`, `Punteggio` + 20 contatori generici `ParamI01..I20` (significato da mappare con Carlo).
- **Viste DW**: `V_DW_punteggiGiorno` (ultimi 15 gg, somma+media punteggio per filiale/giorno) e `V_DW_punteggiMese`, entrambe su `V_UtentiAttivita2024`; funzione `SetPunteggio`. Le viste `V_UtentiAttivita2024_old` e `_260304` sono versioni parcheggiate.
- La griglia driver della dashboard legacy (DaConsegnare/Consegnati per driver) viene dal mondo SPED_* — da mappare nella fase operativa.

## 4. Interrogazioni (query builder)

- **`INTERROGAZIONI`** (136): `Titolo`, `Descrizione`, SQL spezzato (`SqlSelect/From/Where/Group/Order`), `Alias` (mappa colonna→etichetta), `Visibilita`, `Parametri`, `CanSee`.
- **Nessuna SP le referenzia** → l'app legacy compone ed esegue l'SQL client-side.
- Proposta: endpoint `POST /api/interrogazioni/{id}/run` che esegue **in sola lettura** (connessione SQL dedicata read-only, timeout, niente concatenazione di input utente — parametri tipizzati da `Parametri`).

## 5. `MenuAlias` — da chiarire con Carlo

Tabella **recente** (aggiornata 08/06/2026, 6 righe) con `AliasKey`, `RouteUrl` (`/`, `/RicercaBarcode`, `/Esiti`, `/RisultatoInterrogazioni`, `/Report`), `TargetPage`, `LegacyViewName`, `SearchKeywords`, `IsActive`, `CreatedAt/UpdatedAt`. Sembra il routing di un **prototipo di nuova app** già iniziato. Se sì, il nuovo menu può nascere da qui.

## 6. Bozza superficie API del modulo

```
POST /api/auth/login              → NEW_AuthLogin (SP nuova)
GET  /api/me                      → profilo + ruolo + gruppi
GET  /api/me/menu                 → ElencoMenuGruppi (SP esistente)
GET  /api/dashboard/punteggi      → V_DW_punteggiGiorno / V_DW_punteggiMese
GET  /api/utenti?filtri...        → lettura (vista/query)
POST /api/utenti  PUT /api/utenti/{id} → NEW_UTENTI_Save (SP nuova, con audit su LogTabelle)
GET/POST ruoli, gruppi, menu, interrogazioni → stessa coppia lettura-libera / scrittura-via-SP
```

## Punti aperti

1. Significato dei `ParamI01..I20` di UTENTI_ATTIVITA (serve Carlo).
2. `MenuAlias`: prototipo esistente? Cartella `esistente/` in TWEB contiene già `utenti.sql` e `utenti_attivita.sql`.
3. Strategia migrazione password MD5 → bcrypt (richiede 1 colonna nuova: ok col vincolo "struttura esistente"?).
4. Le 2573 utenze senza password: confermare che non devono poter accedere al web nuovo.
