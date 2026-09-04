# Motore dello schedulatore (GecoMotore)

Servizio Windows che esegue i workflow dello schedulatore di Speedy Web. Legge e
scrive le stesse tabelle `WF_` dell'API (DeliveryDB): le pagine "Schedulatore" e
"Agenda e storico" mostrano in tempo reale quello che fa.

Cosa fa, in ciclo:

- ogni `MaterializzaMinuti` (5) trasforma le pianificazioni attive in occorrenze
  concrete in `WF_Esecuzione` (`WF_usp_Esecuzione_Pianifica`), entro l'orizzonte
  di ogni pianificazione;
- ogni `TickSecondi` (15) pesca le esecuzioni scadute (`WF_usp_Esecuzione_Claim`,
  con lock: piu' motori non si pestano i piedi, i gruppi di concorrenza sono
  rispettati, le pianificazioni sospese aspettano) e le esegue, fino a
  `MaxParallelo` insieme;
- per ogni esecuzione: step radice in ordine, sottopassi ripetuti per ogni record
  delle `ESEGUIQUERY`, log riga per riga in `WF_EsecuzioneLog`, avanzamento e
  stato finale in `WF_Esecuzione`. Tra uno step e l'altro controlla se
  l'esecuzione e' stata annullata dalla pagina.

Mattoncini: ESEGUIQUERY, EXPORTTXT, EXPORTXLS, COPYFILE, COMPRIMIFILE,
ESEGUISHELL, GENERAREPORT (server FastReport), APRIMAIL (SMTP), IMPORTTXT.
Gli altri tipi vengono saltati con un avviso nel log.

## Installazione sul server

Serve solo il runtime .NET 6 (gia' presente dove gira l'API). Non serve IIS.

1. Pubblicare: `dotnet publish motore/GecoMotore.csproj -c Release -o <cartella>`
   (o copiare la cartella gia' pubblicata) in una cartella del server,
   es. `C:\servizi\GecoMotore`.
2. Copiare `appsettings.example.json` in `appsettings.json` e compilare:
   - `ConnectionStrings:DeliveryDB` (stessa dell'API);
   - `Motore:CartellaScript`: la cartella base dei file `.sql` richiamati dagli
     step (`QuerySQL=.\ADEX\x.sql` viene cercato li' dentro);
   - `Motore:FastReportUrl` se diverso dal predefinito;
   - `Motore:SmtpDaListaValori`: `true` per spedire le mail (APRIMAIL) col relay
     configurato in LISTA_VALORI invece del `ServerSMTP` scritto negli step;
   - `Motore:MailSoloA`: in prova, tutte le mail solo a questo indirizzo.
3. Registrare il servizio, **come amministratore**:
   `powershell -ExecutionPolicy Bypass -File installa-servizio.ps1 -Cartella C:\servizi\GecoMotore -Account DOMINIO\utente`
   Lo script chiede la password dell'account.

**Condivisioni di rete.** Un servizio non vede le unita' mappate (`X:\`, `Z:\`)
e non ha credenziali sue: nei workflow i percorsi vanno scritti come UNC
(`\\192.168.0.252\share\...`) e le credenziali della condivisione stanno in
`LISTA_VALORI`, `Lista = SMB_SERVER`, righe `SERVER`, `USER`, `PASS`
(`Valore` = nome, `Codice` = valore, come `SMTP_SERVER`; si compilano dalla
pagina Lista Valori). Il motore apre la sessione SMB all'avvio e la rinfresca
a ogni giro di materializzazione; per altri server: `SMB_SERVER_2`, `SMB_SERVER_3`.
Con le credenziali in tabella il servizio puo' girare come LocalSystem.
Sul server `.176` sta in `C:\progetti\scheduler\motore`, gli script `.sql`
in `C:\progetti\scheduler\script`.

Log: `logs\motore-AAAAMMGG.log` accanto all'exe (o `Motore:CartellaLog`), piu'
il registro eventi di Windows per avvio/arresto.

## In console (sviluppo)

`dotnet run --project motore/GecoMotore.csproj` fa la stessa cosa in finestra,
con `appsettings.json` accanto al progetto. `TickSecondi` basso per provare.

Comandi utili una volta installato:

```
sc query GecoMotore
sc stop GecoMotore
sc start GecoMotore
sc delete GecoMotore
```
