# Deploy in produzione (Windows Server 2019)

Speedy Web gira sullo **stesso server di TNOT**. L'API .NET serve sia il REST sia
il frontend Vue (build statica) sulla **stessa porta**, quindi **non serve IIS**.

## Porte — niente sovrapposizioni con TNOT

| Servizio | Progetto | Porta | Note |
|---|---|---|---|
| **Geco-Api** | Speedy Web (questo) | **5180** | API + frontend (porta unica) |
| WF-Api | TNOT | 3001 | API + frontend (porta unica) |
| SQL Server | — | 1433 | `serverdb`/`DeliveryDB` (TWEB), `10.1.0.1`/`NotificheDB` (TNOT) |

La porta 5180 è definita in `appsettings.json` (`Urls`). I due progetti usano **DB diversi**
e **porte diverse**: convivono senza conflitti. (La 5173 di Vite è solo per lo sviluppo, non
gira sul server.)

## 1. Prerequisiti sul server
- **NSSM** — https://nssm.cc (per il servizio Windows). Stesso tool di TNOT.
- Accesso di rete a SQL `serverdb` (DeliveryDB).
- **Nessun runtime .NET da installare**: la pubblicazione è *self-contained* (porta con sé il runtime).

## 2. Database
Esegui una volta, come amministratore SQL su `DeliveryDB`:
- `sql-nuove\00_crea_tutto.sql` (tutte le SP `AI_` + migrazione `Link` + GRANT, idempotente).

**Login applicativo (least privilege):** non usare `sa` in produzione. Lo script concede già
i permessi all'utente `claude` (sola lettura + EXECUTE sulle SP `AI_`), che è esattamente il
profilo che serve all'app. Imposta nella connection string un login dedicato con quei permessi
(rinomina `claude` se preferisci un nome più "di servizio"). Se `sa` è stato usato in setup,
**ruota la sua password**.

## 3. Build + copia degli artefatti

### Automatico (consigliato): `deploy\deploy.ps1`
Builda il frontend, pubblica l'API self-contained, mette il frontend in `wwwroot` e copia
sul target preservando l'`appsettings.json` del server:
```powershell
.\deploy\deploy.ps1 -Target \\srv2019\c$\app\GECOWEB       # dal PC di sviluppo
.\deploy\deploy.ps1 -Target C:\app\GECOWEB -RestartService  # sul server stesso
```
(`-SkipBuild` per ricopiare soltanto.)

### Manuale
```powershell
# frontend
cd web; npm ci; npm run build            # -> web\dist\
cd ..
# API self-contained
dotnet publish api\GecoApi.csproj -c Release -r win-x64 --self-contained true -o publish
# frontend dentro wwwroot (porta unica)
robocopy web\dist publish\wwwroot /MIR
```
Copia il contenuto di `publish\` sul server (es. `C:\app\GECOWEB`) **senza sovrascrivere**
l'`appsettings.json` del server.

## 4. Configurazione — `C:\app\GECOWEB\appsettings.json`
NON è in git (contiene i segreti) e NON viene mai copiato dal deploy: crealo a mano sul server
(parti da `api\appsettings.example.json`):
```json
{
  "Urls": "http://*:5180",
  "ConnectionStrings": {
    "DeliveryDB": "Server=serverdb;Database=DeliveryDB;User Id=<login_app>;Password=<...>;Encrypt=False;TrustServerCertificate=True"
  },
  "Jwt": { "Key": "<chiave casuale >= 32 byte>", "Issuer": "GecoApi" },
  "Cors": { "Origins": [ "http://<host-o-ip-del-server>:5180" ] }
}
```
- **`Urls`: `http://*:5180`** — in ascolto su tutte le interfacce (LAN). In locale puoi usare `localhost`.
- **Cors**: con la porta unica il frontend è *same-origin*, quindi CORS di fatto non serve;
  lascia l'origine del server solo se in futuro servissi il frontend da un host diverso.
- Genera la chiave JWT, es.: `[Convert]::ToBase64String((1..48 | % {Get-Random -Max 256}))`.

## 5. Avvio (smoke test manuale)
```powershell
cd C:\app\GECOWEB
.\GecoApi.exe            # apri http://localhost:5180  (sia UI sia /api/ping)
```

## 6. Servizio Windows (riavvio-safe)
Adatta `APPDIR` in `deploy\install-service.bat` e lancialo **come Amministratore**.
Crea il servizio **Geco-Api** (auto-start, log in `logs\`, `ASPNETCORE_ENVIRONMENT=Production`).
Usando autenticazione SQL nella connection string, LocalSystem va bene (non servono share di rete).

## 7. Aggiornamenti successivi
```powershell
.\deploy\deploy.ps1 -Target C:\app\GECOWEB -RestartService
```
L'`appsettings.json` del server resta intatto (escluso da robocopy).
