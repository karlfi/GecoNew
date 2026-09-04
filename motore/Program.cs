using GecoMotore;

// === Motore dello schedulatore di Speedy Web ===
// Servizio Windows (o console, con `dotnet run`): ogni pochi minuti trasforma le
// pianificazioni in occorrenze concrete (WF_usp_Esecuzione_Pianifica), ogni
// pochi secondi pesca quelle scadute (WF_usp_Esecuzione_Claim) ed esegue gli
// step del workflow, scrivendo avanzamento e log su WF_Esecuzione e
// WF_EsecuzioneLog. Stesso DB e stesse stored dell'API: le pagine dello
// schedulatore vedono tutto mentre succede.
//
// Configurazione in appsettings.json accanto all'exe (vedi appsettings.example.json).
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
        // oltre a console/EventLog: un file al giorno nella cartella dei log
        var cartella = ctx.Configuration.GetSection("Motore")["CartellaLog"] ?? Path.Combine(AppContext.BaseDirectory, "logs");
        log.AddProvider(new FileLogProvider(cartella));
    })
    .Build();

await host.RunAsync();
