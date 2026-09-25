# Ge.C.O. New — nuova interfaccia

> **Fork** di *Speedy Web* ([karlfi/DeliveryAI](https://github.com/karlfi/DeliveryAI), commit `e49ae7e` del 2026-09-07),
> reso indipendente il 2026-09-07: stesso codice, **database gemello su un altro server**
> (`serverdb` / `DeliveryDB`). Nessun merge previsto fra i due repository: le pagine
> si portano da uno all'altro a mano, un commit alla volta (vedi `CLAUDE.md`, "Portare una pagina").
>
> Configurazione: `api/appsettings.json` e `motore/appsettings.json` (non tracciati; partire dagli
> `appsettings.example.json`). Verifica degli oggetti DB: `sql-nuove/ZZ_verifica_oggetti.sql`.

Riscrittura delle **interfacce** del gestionale legacy Ge.C.O. Web (Instant Developer / ASP.NET)
sul **database esistente, lasciato intatto**. Non è un nuovo gestionale: è una nuova UI —
**Ge.C.O. New** — che parla con lo stesso DB.

---

## Idee di fondo (i vincoli che spiegano tutto il resto)

1. **Il DB non si tocca.** Niente migrazioni, niente code-first. La struttura è quella legacy
   (`serverdb` / `DeliveryDB`, SQL Server 2019).
2. **Le scritture passano SOLO da stored procedure** con prefisso `AI_`. Le **letture** invece
   sono SQL libero dentro gli endpoint. Questo separa la logica dati dall'interfaccia.
3. **L'URL non cambia mai.** La navigazione è interna (uno stack in memoria), come il legacy:
   la barra degli indirizzi resta sempre su `/`.
4. **Motore generico invece di pagine copiate.** Le pagine di configurazione non sono scritte
   a mano una per una: un solo motore legge le colonne da `sys.columns` e costruisce griglia e
   form da sé.
5. **Il menu legacy è la sorgente di verità della navigazione**, esteso dal campo `Link`
   (aggiunto in `MENU_ELEMENTI`) che mappa ogni voce → pagina nuova.

---

## Struttura del repository

```
TWEB/
├── api/          backend  .NET 6   (porta 5180)   "chi parla col DB"
├── web/          frontend Vue 3    (porta 5173)   "chi disegna le pagine"
├── sql-nuove/    stored procedure AI_             "le uniche scritture ammesse"
└── analisi-db/   ricognizione del DB legacy (CSV, SP originali, note)
```

---

## Avvio in sviluppo

Servono due terminali.

```powershell
# Terminale 1 — backend
cd C:\progetti\AI\TWEB\api
dotnet run                       # -> http://localhost:5180

# Terminale 2 — frontend
cd C:\progetti\AI\TWEB\web
npm install                      # solo la prima volta
npm run dev                      # -> http://localhost:5173
```

Apri **http://localhost:5173** e accedi con un utente Ge.C.O. che abbia la password web (gli
utenti solo-palmare, senza password, non possono entrare). In sviluppo il frontend fa da proxy
`/api` -> `5180`, quindi niente problemi di CORS.

**Accesso di sviluppo (prove automatiche).** Con `"DevLogin": { "Utente": "<login>" }` in
`api/appsettings.Development.json` (non va in git ne' nelle release) la pagina di login in `npm run dev` entra da
sola con quell'utente, senza password: serve alle prove fatte da Claude nel browser integrato o con Playwright.
L'endpoint `POST /api/auth/dev-login` risponde solo in ambiente Development, con la chiave valorizzata e a chiamate
dalla macchina stessa; altrimenti 404. Attenzione: il database resta quello di `appsettings.Development.json` /
`appsettings.json`, cioe' produzione, e le prove che scrivono si decidono ogni volta.

> **Se `dotnet build/run` dice "file locked":** c'è un `GecoApi.exe` ancora vivo.
> `Stop-Process -Name GecoApi` e ripeti.

### Prerequisito sul DB

Le scritture funzionano solo se le stored procedure `AI_` esistono sul database. Esegui una
volta lo script unico idempotente:

```
sql-nuove/00_crea_tutto.sql
```

Contiene tutte le SP `AI_`, la migrazione del campo `Link` e i `GRANT`. È rieseguibile
(usa `CREATE OR ALTER`).

---

## Il backend — `api/`

Tutto il backend è **un solo file**: [`api/Program.cs`](api/Program.cs) (~800 righe, minimal API).
Nessun controller separato: ogni endpoint è un `app.MapGet/MapPost`. È piccolo e si legge tutto.

| Blocco | Ruolo |
|---|---|
| Setup JWT + CORS | autenticazione a token, origini ammesse |
| Helper | `ConnString`, `EmettiToken`, `LoadColonne` (introspezione colonne), `JsonToClr` |
| **Login** | chiama `AI_AuthLogin`, mette ruolo/gruppi/filiale/azienda nei claim del token |
| **Filiali / cambio filiale** | tendina in alto a destra; riemette il token con la filiale scelta |
| **Dashboard** | grafici filiale + aggregato azienda + confronto filiali |
| **Interrogazioni** | compone l'SQL dal catalogo `INTERROGAZIONI` e lo esegue |
| **Config generico** | `/schema`, lettura paginata, salvataggio via `AI_<Tabella>_Save` |
| **Workflow** | macchina a stati per processo |
| **Utenti** | lista, dettaglio, lookup, 4 collezioni N:N, salvataggio |

**Punto chiave — l'allowlist.** Il dizionario `ConfigTabelle` (chiave -> tabella reale, es.
`coperture` -> `GEO_COPERTURE`) è la barriera del motore generico: le pagine di configurazione
possono toccare **solo** le tabelle elencate lì.

**Variabili globali nelle interrogazioni.** Nell'SQL del catalogo, i segnaposto `@[IdFiliale]`,
`@[IdUtente]`, `@[IdAzienda]`, ecc. sono sostituiti server-side dai **claim del token** — mai da
input del client.

I segreti (connection string, chiave JWT) stanno in `api/appsettings.json`, **escluso da git**.
C'è `api/appsettings.example.json` come modello.

---

## Il frontend — `web/`

Vue 3 + Vite + PrimeVue (tema Aura). Mappa dei file:

```
web/src/
├── main.js              bootstrap (Pinia, router, PrimeVue, Vue Flow)
├── api.js               axios: aggiunge il token a ogni chiamata, 401 -> login
├── router/              router minimale: SOLO /login e /  (il resto è interno)
│
├── layout/AppShell.vue  ★ il cuore: topbar + menu laterale + area pagina
│
├── stores/
│   ├── auth.js          token, utente, menu, filiali (persistiti in localStorage)
│   └── nav.js           ★ navigazione a stack (drill-down / indietro), SENZA URL
│
├── config/tabelle.js    mappa Link/Videata -> quale pagina aprire
├── lib/
│   ├── menuTree.js       costruisce l'albero a 2 livelli dal menu piatto
│   ├── parametri.js      parsing dei Parametri menu (IdQuery=N | sWhere=...)
│   └── layout.js         auto-layout del grafo workflow (dagre)
│
├── components/EChart.vue wrapper ECharts (import dinamico, ~1MB lazy)
└── views/                una pagina per ogni "tipo" di nav
    ├── LoginView.vue
    ├── DashboardView.vue            (tipo: dashboard)
    ├── RisultatoInterrogazioni.vue  (tipo: interrogazioni)
    ├── ConfigTable.vue              (tipo: config — il motore generico)
    ├── UtentiView.vue               (tipo: utenti)
    ├── WorkflowView.vue             (tipo: workflow)
    ├── InterrogazioniEditor.vue     (tipo: interrogazioni-editor)
    ├── MenuEditor.vue               (tipo: menu-editor)
    └── PlaceholderView.vue          (tutto il resto = "da migrare")
```

### Come funziona la navigazione (il pezzo meno ovvio)

[`AppShell.vue`](web/src/layout/AppShell.vue) è l'unico componente sempre montato. Al centro **non**
c'è `<router-view>` ma un blocco di `v-if`: in base a `nav.corrente.tipo` monta la view giusta.

Quando clicchi una voce di menu, `naviga(voce)`:

1. guarda prima il campo **`Link`** — `navDaLink()` in [`config/tabelle.js`](web/src/config/tabelle.js)
   traduce `/config/prodotti`, `/utenti`, `/workflow`, … in un oggetto `{ tipo, … }`;
2. se `Link` è vuoto, ripiega sul vecchio routing per `Videata`;
3. l'oggetto finisce nello store [`nav.js`](web/src/stores/nav.js) (`apriDaMenu`) e `AppShell` reagisce.

L'URL resta sempre `/`. Nel menu: **pallino verde** = `Link` valorizzato (pagina migrata);
**voce smorzata** = ancora da migrare.

---

## Le stored procedure — `sql-nuove/`

Le **uniche scritture ammesse**. Ogni tabella scrivibile ha la sua `AI_<Tabella>_Save` (upsert).
I file singoli sono raccolti nello script unico [`sql-nuove/00_crea_tutto.sql`](sql-nuove/00_crea_tutto.sql).

Convenzione: prefisso `AI_`, sempre `CREATE OR ALTER`, e `GRANT EXECUTE` all'utente applicativo.

---

## Scenari tipici "ci metto le mani"

### A) Aggiungere una pagina di configurazione per una nuova tabella (es. `CLIENTI`)
1. In [`Program.cs`](api/Program.cs), aggiungi una riga all'allowlist: `["clienti"] = "CLIENTI"`.
2. Crea la SP `AI_CLIENTI_Save` (copia il pattern da
   [`AI_PRODOTTI_Save.sql`](sql-nuove/AI_PRODOTTI_Save.sql)) e aggiungila a `00_crea_tutto.sql`.
3. Imposta `Link = /config/clienti` sulla voce di menu (pagina Elenco menu, o sul DB).
4. Fatto: griglia, form, paginazione e ricerca li genera `ConfigTable.vue` leggendo lo schema.
   **Non scrivi frontend.**

### B) Cambiare l'aspetto di una pagina esistente
È tutto nel singolo `.vue` (es. [`DashboardView.vue`](web/src/views/DashboardView.vue)):
`<script setup>` prepara dati e opzioni dei grafici, `<template>` li dispone, `<style scoped>`
è solo di quella pagina. Salvi -> Vite ricarica a caldo.

### C) Cambiare/aggiungere dati che arrivano dal DB
Tocchi l'endpoint in [`Program.cs`](api/Program.cs):
- **letture** -> SQL diretto dentro l'endpoint (come la dashboard);
- **scritture** -> **non** inline: modifichi/crei la SP `AI_` corrispondente. È la regola d'oro.

### D) Mappare una voce di menu a una pagina
Nessun codice: imposti il campo `Link` della voce. Convenzioni (in `config/tabelle.js`):
`/dashboard`, `/utenti`, `/menu`, `/interrogazioni-editor`, `/workflow`,
`/interrogazioni` (+ `Parametri`), `/config/<chiave>`.

---

## Dove guardare quando qualcosa non va

| Sintomo | Dove |
|---|---|
| Login fallisce | la SP `AI_AuthLogin` esiste sul DB? |
| Menu vuoto | `AI_ElencoMenuGruppi` (c'è fallback automatico alla legacy `ElencoMenuGruppi`) |
| Una voce di menu non apre nulla | `Link`/`Videata` della voce + logica `naviga()` in `AppShell.vue` |
| Salvataggio dà errore SQL | arriva dalla SP `AI_`: il messaggio è propagato tale e quale |
| 401 a ripetizione | token scaduto (8h) — `api.js` rimanda al login da solo |

---

## Stack

- **Backend:** ASP.NET Core minimal API (.NET 6), Dapper, Microsoft.Data.SqlClient, JWT Bearer.
- **Frontend:** Vue 3 + Vite, PrimeVue (Aura), Pinia, ECharts, Vue Flow + dagre, ExcelJS (lazy).
- **DB:** SQL Server (`serverdb`), database `DeliveryDB` gemello di quello di origine (+ `geo`, `speedy` se presenti).
- Solo componenti open-source, on-premise.

---

## Note operative ancora aperte

- Upgrade .NET 6 -> 8 (aggiornare `<TargetFramework>` e versioni pacchetti).
- Pulsanti legacy non ancora replicati sulla pagina Utenti: Crea Attività, Stampa Badge,
  Richiedi Foto e Firma.
- Workflow: editor completo dei parametri azione (`Chiedi_*`) agganciato all'arco — endpoint
  pronto, pannello da costruire.
