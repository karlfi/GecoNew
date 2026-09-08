<#
.SYNOPSIS
  Build + deploy di Ge.C.O. New (API .NET + frontend Vue) su una destinazione
  (locale o UNC). Gemello di TNOT\deploy\deploy.ps1, adattato a .NET.

.DESCRIPTION
  1. Builda il frontend (web\dist\) e pubblica l'API (.NET self-contained win-x64).
  2. Copia il frontend dentro publish\wwwroot\ (porta unica: l'API serve la SPA).
  3. Copia gli artefatti sul -Target preservando l'appsettings.json del server.

  Eseguibile dal PC di sviluppo (Target = UNC, es. \\srv2019\c$\app\GECOWEB)
  oppure direttamente sul server (Target = C:\app\GECOWEB).

  NB: porta 5180 (vedi appsettings.json sul server) -> NON sovrapposta a TNOT (3001).

.PARAMETER Target
  Cartella di destinazione (locale o UNC). Viene creata se non esiste.

.PARAMETER SkipBuild
  Salta build frontend + publish (usa publish\ gia' presente).

.PARAMETER RestartService
  Dopo il deploy riavvia il servizio Windows Geco-Api (solo se gira in locale).

.EXAMPLE
  .\deploy\deploy.ps1 -Target \\srv2019\c$\app\GECOWEB
  .\deploy\deploy.ps1 -Target C:\app\GECOWEB -RestartService

.NOTES
  L'appsettings.json (segreti + binding porta) e' SPECIFICO del server: non viene
  mai copiato ne' cancellato (robocopy /XF). Crealo a mano sul server la prima volta.
#>
param(
  [Parameter(Mandatory = $true)][string]$Target,
  [switch]$SkipBuild,
  [switch]$RestartService,
  [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'

# Radice del progetto = cartella che contiene 'deploy'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$Publish = Join-Path $Root 'publish'
Write-Host "Progetto: $Root"     -ForegroundColor Cyan
Write-Host "Target:   $Target"   -ForegroundColor Cyan
Write-Host "Runtime:  $Runtime (self-contained: nessun runtime .NET da installare sul server)" -ForegroundColor Cyan

function Assert-LastExit($what) {
  if ($LASTEXITCODE -ne 0) { throw "$what fallito (exit $LASTEXITCODE)" }
}

function Copy-Mirror($src, $dst, [string[]]$excludeFiles) {
  # /XF protegge i file esclusi sia dalla copia sia dalla cancellazione (/MIR purge).
  $args = @($src, $dst, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
  if ($excludeFiles) { $args += '/XF'; $args += $excludeFiles }
  robocopy @args | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy '$src' -> '$dst' errore ($LASTEXITCODE)" }
  $global:LASTEXITCODE = 0
}

# --- 1. Build -----------------------------------------------------------------
if (-not $SkipBuild) {
  Write-Host "`n== Build frontend (web) ==" -ForegroundColor Green
  Push-Location web
  try {
    npm ci;          Assert-LastExit 'npm ci (web)'
    npm run build;   Assert-LastExit 'npm run build (web)'
  } finally { Pop-Location }

  Write-Host "`n== Publish API (.NET, self-contained $Runtime) ==" -ForegroundColor Green
  if (Test-Path $Publish) { Remove-Item -Recurse -Force $Publish }
  dotnet publish api\GecoApi.csproj -c Release -r $Runtime --self-contained true -o $Publish
  Assert-LastExit 'dotnet publish'

  Write-Host "`n== Copia frontend in publish\wwwroot (porta unica) ==" -ForegroundColor Green
  Copy-Mirror "$Root\web\dist" "$Publish\wwwroot"
}

# verifica artefatti
if (-not (Test-Path "$Publish\GecoApi.exe"))       { throw "Manca publish\GecoApi.exe (publish API?)" }
if (-not (Test-Path "$Publish\wwwroot\index.html")) { throw "Manca publish\wwwroot\index.html (build frontend?)" }

# --- 2. Copia sul target ------------------------------------------------------
Write-Host "`n== Copia su $Target ==" -ForegroundColor Green
New-Item -ItemType Directory -Force -Path $Target | Out-Null
# appsettings.json (segreti + porta) e appsettings.Development.json restano quelli del server.
Copy-Mirror $Publish $Target @('appsettings.json', 'appsettings.Development.json')

# Promemoria appsettings.json (non lo copiamo mai: e' specifico del server)
if (-not (Test-Path "$Target\appsettings.json")) {
  Write-Host "ATTENZIONE: $Target\appsettings.json non esiste: crealo (vedi api\appsettings.example.json)." -ForegroundColor Yellow
  Write-Host "            Ricordati Urls = http://*:5180 e la connection string di produzione." -ForegroundColor Yellow
}

# --- 3. Riavvio servizio (opzionale, solo locale) ----------------------------
if ($RestartService) {
  Write-Host "`n== Riavvio servizio Geco-Api ==" -ForegroundColor Green
  if (Get-Service Geco-Api -ErrorAction SilentlyContinue) {
    Restart-Service Geco-Api
    Write-Host "Geco-Api riavviato." -ForegroundColor Green
  } else {
    Write-Host "Servizio Geco-Api non trovato (installa con deploy\install-service.bat)." -ForegroundColor Yellow
  }
}

Write-Host "`nDeploy completato." -ForegroundColor Cyan
