# Ge.C.O. Web — riprogettazione (TWEB)

Nuova interfaccia per Ge.C.O. Web. Il DB resta quello esistente (`serverdb` → DeliveryDB);
tutte le **scritture** passano da stored procedure con prefisso **`AI_`**.

## Struttura

| Cartella | Contenuto |
|---|---|
| `api/` | Backend ASP.NET Core minimal API (GecoApi) — porta **5180** |
| `web/` | Frontend Vue 3 + Vite + PrimeVue — porta dev **5173** (proxy `/api` → 5180) |
| `sql-nuove/` | Stored procedure nuove da creare sul DB (prefisso `AI_`) |
| `analisi-db/` | Inventario del DB esistente (CSV da marcare) + sorgenti SP legacy + analisi moduli |

## Avvio in sviluppo

```powershell
# terminale 1 — API
cd api
dotnet run

# terminale 2 — frontend
cd web
npm run dev
```

Poi apri http://localhost:5173 e accedi con un utente di GeCO (con password web).

## Endpoint attuali

| Endpoint | Fonte dati | Note |
|---|---|---|
| `POST /api/auth/login` | SP `AI_AuthLogin` | verifica server-side, emette JWT (8h) con ruolo+gruppi |
| `GET /api/me` | claims del token | identità corrente |
| `GET /api/me/menu` | SP `ElencoMenuGruppi` | IdUtente preso dal token; il frontend monta l'albero |
| `GET /api/ping` | — | health check |

## Permessi DB per l'utente dell'API

L'utente SQL dell'API deve avere `db_datareader` + EXECUTE sulle SP usate
(le scritture interne alle SP funzionano per ownership chaining):

```sql
GRANT EXECUTE ON dbo.AI_AuthLogin TO claude;       -- fatto
GRANT EXECUTE ON dbo.ElencoMenuGruppi TO claude;   -- serve per /api/me/menu
```

In produzione: creare un login applicativo dedicato (es. `ai_app`) con gli stessi permessi
e spostare connection string + chiave JWT fuori da `appsettings.json` (variabili d'ambiente).

## Da fare

- [ ] `GRANT EXECUTE ON dbo.ElencoMenuGruppi TO claude;`
- [ ] Upgrade a .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`, poi `<TargetFramework>net8.0</TargetFramework>` e versioni pacchetti 8.x)
- [ ] Dashboard reale (V_DW_punteggiGiorno / V_DW_punteggiMese)
- [ ] CRUD configurazione (utenti, ruoli, gruppi, menu) con SP `AI_*`
- [ ] Esecuzione Interrogazioni (read-only)
- [ ] Migrazione password MD5 → bcrypt (rehash al primo login)
