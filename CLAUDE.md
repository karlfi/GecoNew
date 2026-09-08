# Ge.C.O. New — note per Claude

## Cos'è
Nuova interfaccia web (API .NET 6 in `api/`, frontend Vue 3 + PrimeVue 4 in `web/`, motore
dello schedulatore in `motore/`) sopra un database legacy **DeliveryDB** che non si tocca:
le scritture passano solo dalle stored procedure `AI_*` / `WF_usp_*` (script in `sql-nuove/`),
le letture sono SQL libero negli endpoint. Il menu legacy (`MENU_ELEMENTI.Link`) guida la
navigazione; le pagine si registrano in `web/src/layout/AppShell.vue` e in
`web/src/config/tabelle.js` (`navDaLink` / `navDaVideata`).

## Fork: da dove viene e cosa cambia
- Fork di **Speedy Web** ([karlfi/DeliveryAI](https://github.com/karlfi/DeliveryAI)) al commit
  `e49ae7e` del 2026-09-07, reso indipendente il 2026-09-07. **Nessun merge** fra i due repository:
  storia comune fino a quel commit, poi divergono.
- Il database è un **gemello** di quello di origine, su `serverdb` (SQL Server 2019, login in
  italiano: la nota di `ZZ_configurazione_server.sql` sulla lingua non serve qui): stessa
  struttura, dati diversi. Non dare per scontato che una modifica di schema fatta nell'origine
  esista qui: `sql-nuove/ZZ_verifica_oggetti.sql` elenca gli oggetti attesi che mancano;
  `ZZ_allinea_serverdb_20260908.sql` è l'allineamento dell'8 settembre 2026 (script dal 3 settembre).
  Su serverdb esiste l'utente di sola lettura `claude` (i GRANT degli script lo prevedono).
- Marchio: "Ge.C.O. New" (titolo, testata, login). I default di dominio del progetto di origine
  (URL del report server, mittente delle mail) qui sono **solo** in configurazione:
  `Motore:FastReportUrl`, `Motore:MittentePredefinito`.

## Configurazione (mai nel repository)
- `api/appsettings.json` e `motore/appsettings.json` sono ignorati da git: si parte dai rispettivi
  `appsettings.example.json`. Unica chiave per il DB: `ConnectionStrings:DeliveryDB`.
- SMTP, report server, cartelle dei file e altre impostazioni stanno **nel DB** (`LISTA_VALORI`,
  `PARAMETRI`): leggerle da lì, mai hardcodarle.
- Segreti (password, chiave JWT) non vanno mai in chat, in commit o nei log.

## Portare una pagina da/verso Speedy Web
I due progetti restano separati, ma una pagina fatta in uno si può portare nell'altro
**un commit alla volta**, sfruttando la storia comune:

```bash
# una volta sola, in questo repository
git remote add speedyweb https://github.com/karlfi/DeliveryAI.git
git fetch speedyweb

# trova il commit della pagina (i messaggi iniziano con "TWEB: ...")
git log --oneline speedyweb/main -- web/src/views/NomePaginaView.vue

# portalo qui: -x annota il commit di origine, -n lascia le modifiche da rivedere senza committare
git cherry-pick -x <commit>
```

Nell'altro verso: in Speedy Web `git remote add geconew https://github.com/karlfi/GecoNew.git`
e lo stesso giro. Cosa aspettarsi:
- una pagina è di solito: `web/src/views/XxxView.vue` (+ componenti), un file API (`api/Xxx.cs`
  o un blocco in `api/Program.cs`), uno script `sql-nuove/XXX.sql` (stored, viste, voce di menu)
  e le righe di registrazione in `AppShell.vue`, `tabelle.js`, `Program.cs` (`Xxx.Map(app, ConnString)`);
- i conflitti nascono quasi solo nei file di registrazione: si risolvono a mano tenendo tutte e due le righe;
- **lo script SQL va poi eseguito sul DB di destinazione** (il cherry-pick porta il file, non lo applica),
  e la voce di menu ha ID diversi nei due DB: controllare `MENU_ELEMENTI`;
- il marchio e i default di dominio differiscono: non portare commit che toccano `index.html`,
  `AppShell.vue` (testata), `LoginView.vue`, gli `appsettings.example.json` o i README, salvo volerlo.

## Come si lavora
- Sviluppo: `avvia-dev.cmd` (API su 5180, Vite su 5173 con proxy `/api`).
- Deploy: `deploy/deploy.ps1` verso la cartella del server (l'`appsettings.json` del server non
  viene sovrascritto).
- Prima di un commit: nessun segreto nei file tracciati; `appsettings.json` resta ignorato.
