@echo off
REM ============================================================================
REM Installa Speedy Web (API .NET + frontend, porta unica) come servizio Windows
REM tramite NSSM. Eseguire come Amministratore. Richiede NSSM (https://nssm.cc).
REM
REM Porta: 5180 (definita in appsettings.json -> Urls). NON sovrapporre a TNOT (3001).
REM ============================================================================

set APPDIR=C:\progetti\AI\GecoWeb2
set EXE=%APPDIR%\GecoApi.exe

if not exist "%APPDIR%\logs" mkdir "%APPDIR%\logs"

REM --- API (serve REST + frontend, una sola porta) ---------------------------
nssm install Geco-Api "%EXE%"
nssm set Geco-Api AppDirectory %APPDIR%
nssm set Geco-Api Start SERVICE_AUTO_START
nssm set Geco-Api AppEnvironmentExtra ASPNETCORE_ENVIRONMENT=Production
nssm set Geco-Api AppStdout "%APPDIR%\logs\api.out.log"
nssm set Geco-Api AppStderr "%APPDIR%\logs\api.err.log"
nssm set Geco-Api AppRotateFiles 1

REM IMPORTANTE: account con accesso a SQL (serverdb / DeliveryDB).
REM Se l'app usa autenticazione SQL (login dedicato in appsettings.json) va bene
REM anche LocalSystem; se mai si passasse ad autenticazione Windows integrata,
REM impostare un utente di dominio con accesso al DB:
REM nssm set Geco-Api ObjectName DOMINIO\utente password

nssm start Geco-Api

echo.
echo Fatto. Servizio Geco-Api installato e avviato (porta 5180, da appsettings.json).
