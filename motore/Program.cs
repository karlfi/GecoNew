using GecoMotore;

// === Motore dello schedulatore di Ge.C.O. New ===
// Servizio Windows (o console, con `dotnet run`): ogni pochi minuti trasforma le
// pianificazioni in occorrenze concrete (WF_usp_Esecuzione_Pianifica), ogni
// pochi secondi pesca quelle scadute (WF_usp_Esecuzione_Claim) ed esegue gli
// step del workflow, scrivendo avanzamento e log su WF_Esecuzione e
// WF_EsecuzioneLog. Stesso DB e stesse stored dell'API: le pagine dello
// schedulatore vedono tutto mentre succede.
//
// Configurazione in appsettings.json accanto all'exe (vedi appsettings.example.json).
//
// Un'eccezione all'avvio (configurazione, DI, registrazione del servizio) finirebbe
// solo nel registro eventi di Windows: la scriviamo anche in logs\avvio-errore.txt
// accanto all'exe, dove si trova subito (2026-09-17: il servizio su un server nuovo
// cadeva in silenzio con errore 1053).
AppDomain.CurrentDomain.UnhandledException += (_, e) => ScriviErroreAvvio(e.ExceptionObject);

try
{
    await Avvia(args);
}
catch (Exception ex)
{
    ScriviErroreAvvio(ex);
    throw;
}

static void ScriviErroreAvvio(object? errore)
{
    try
    {
        var cartella = Path.Combine(AppContext.BaseDirectory, "logs");
        Directory.CreateDirectory(cartella);
        File.AppendAllText(Path.Combine(cartella, "avvio-errore.txt"),
            $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {errore}{Environment.NewLine}{Environment.NewLine}");
    }
    catch { /* se non si puo' scrivere, resta il registro eventi */ }
}

static async Task Avvia(string[] args)
{
var host = Host.CreateDefaultBuilder(args)
    .UseWindowsService(o => o.ServiceName = "GecoMotore")
    .UseContentRoot(AppContext.BaseDirectory)
    .ConfigureServices((ctx, servizi) =>
    {
        var o = ctx.Configuration.GetSection("Motore").Get<Opzioni>() ?? new Opzioni();
        o.ConnString = ctx.Configuration.GetConnectionString("DeliveryDB")
            ?? throw new InvalidOperationException("ConnectionStrings:DeliveryDB mancante in appsettings.json");
        servizi.AddSingleton(o);
        servizi.AddHostedService<Scheduler>();
        // allo stop il servizio aspetta le esecuzioni in corso (fino a questo tetto)
        servizi.Configure<HostOptions>(h => h.ShutdownTimeout = TimeSpan.FromSeconds(o.AttesaChiusuraSecondi + 10));
    })
    .ConfigureLogging((ctx, log) =>
    {
        // oltre a console/EventLog: un file al giorno nella cartella dei log.
        // "CartellaLog": null nel JSON arriva qui come stringa vuota, non come null:
        // vuoto = cartella predefinita (era un crash all'avvio con l'esempio copiato pari pari)
        var cartella = ctx.Configuration.GetSection("Motore")["CartellaLog"];
        if (string.IsNullOrWhiteSpace(cartella)) cartella = Path.Combine(AppContext.BaseDirectory, "logs");
        log.AddProvider(new FileLogProvider(cartella));
    })
    .Build();

await host.RunAsync();
}
