# Registra (o aggiorna) il servizio Windows del motore dello schedulatore.
# Da eseguire come amministratore sul server, dopo aver pubblicato in -Cartella
# e compilato appsettings.json.
#   .\installa-servizio.ps1 -Cartella C:\servizi\GecoMotore -Account DOMINIO\utente
# Senza -Account il servizio gira come LocalSystem (che NON vede le share di rete).
param(
    [Parameter(Mandatory = $true)] [string] $Cartella,
    [string] $Account,
    [string] $Nome = "GecoMotore"
)

$exe = Join-Path $Cartella "GecoMotore.exe"
if (-not (Test-Path $exe)) { throw "Non trovo $exe: pubblica prima il progetto in $Cartella" }
if (-not (Test-Path (Join-Path $Cartella "appsettings.json"))) { throw "Manca appsettings.json in $Cartella (parti da appsettings.example.json)" }

$esiste = Get-Service -Name $Nome -ErrorAction SilentlyContinue
if ($esiste) {
    Write-Host "Servizio $Nome gia' presente: lo fermo e lo aggiorno"
    if ($esiste.Status -ne 'Stopped') { Stop-Service -Name $Nome -Force; (Get-Service $Nome).WaitForStatus('Stopped', '00:03:00') }
    sc.exe delete $Nome | Out-Null
    Start-Sleep -Seconds 2
}

$argomenti = @("create", $Nome, "binPath= `"$exe`"", "start= auto", "DisplayName= `"Speedy Web - Motore schedulatore`"")
if ($Account) {
    $cred = Get-Credential -UserName $Account -Message "Password dell'account del servizio $Account"
    $argomenti += "obj= $Account"
    $argomenti += "password= $($cred.GetNetworkCredential().Password)"
}
sc.exe @argomenti | Out-Null
sc.exe description $Nome "Esegue i workflow pianificati dello schedulatore di Speedy Web (tabelle WF_ su DeliveryDB)" | Out-Null
# riparte da solo se cade: dopo 1 e 5 minuti, poi ogni 10
sc.exe failure $Nome reset= 86400 actions= restart/60000/restart/300000/restart/600000 | Out-Null

Start-Service -Name $Nome
Start-Sleep -Seconds 3
Get-Service -Name $Nome | Format-Table Name, Status, StartType -AutoSize
Write-Host "Log in $(Join-Path $Cartella 'logs')"
