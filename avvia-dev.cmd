@echo off
REM ============================================================================
REM Avvia Speedy Web in SVILUPPO: apre due finestre, una per l'API .NET (5180)
REM e una per il frontend Vite (5173), poi apre il browser su localhost:5173.
REM Doppio click su questo file, oppure da terminale: avvia-dev.cmd
REM Per fermare tutto: chiudere le due finestre (o Ctrl+C in ciascuna).
REM ============================================================================

cd /d "%~dp0"

REM se una delle porte e' gia' occupata, probabilmente girano gia'
netstat -ano | findstr /r ":5180 .*LISTENING" >nul && echo API gia' in ascolto sulla 5180, non la riavvio. || start "GecoApi (5180)" cmd /k dotnet run --project api\GecoApi.csproj
netstat -ano | findstr /r ":5173 .*LISTENING" >nul && echo Vite gia' in ascolto sulla 5173, non lo riavvio. || start "Vite (5173)" cmd /k npm run dev --prefix web

REM attende qualche secondo che i server salgano, poi apre il browser
timeout /t 8 /nobreak >nul
start http://localhost:5173
