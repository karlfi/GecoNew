using System.Collections.Concurrent;

namespace GecoMotore;

// Sezione "Motore" di appsettings.json, piu' la stringa di connessione.
public class Opzioni
{
    public string ConnString { get; set; } = "";
    /// <summary>ogni quanti secondi si pescano le esecuzioni scadute</summary>
    public int TickSecondi { get; set; } = 15;
    /// <summary>ogni quanti minuti le pianificazioni diventano occorrenze in WF_Esecuzione</summary>
    public int MaterializzaMinuti { get; set; } = 5;
    /// <summary>quante esecuzioni insieme al massimo</summary>
    public int MaxParallelo { get; set; } = 5;
    /// <summary>una ONESHOT scaduta da meno di questi minuti viene eseguita lo stesso</summary>
    public int TolleranzaOneshotMinuti { get; set; } = 15;
    /// <summary>cartella base delle QuerySQL relative degli step (es. .\ADEX\x.sql)</summary>
    public string? CartellaScript { get; set; }
    /// <summary>nome registrato in WF_Esecuzione.MachineName (default: nome macchina)</summary>
    public string? NomeMacchina { get; set; }
    /// <summary>server FastReport per GENERAREPORT: GET url?report=..&format=PDF&..</summary>
    public string FastReportUrl { get; set; } = "";
    /// <summary>timeout delle query degli step (i flussi legacy possono essere lunghi)</summary>
    public int TimeoutQuerySecondi { get; set; } = 3600;
    /// <summary>interprete per gli step ESEGUIPYTHON (percorso di python.exe, o "python" se e' nel PATH)</summary>
    public string Python { get; set; } = "python";
    /// <summary>cartella dei file di log (default: logs accanto all'exe)</summary>
    public string? CartellaLog { get; set; }
    /// <summary>allo stop, quanto aspettare le esecuzioni in corso prima di lasciarle</summary>
    public int AttesaChiusuraSecondi { get; set; } = 120;
    /// <summary>APRIMAIL: se lo step non ha ServerSMTP, usa il relay di LISTA_VALORI (SMTP_SERVER); lo step, se lo definisce, vince</summary>
    public bool SmtpDaListaValori { get; set; } = true;
    /// <summary>prove: tutte le mail vanno solo a questo indirizzo, coi destinatari veri nel testo</summary>
    public string? MailSoloA { get; set; }
    /// <summary>APRIMAIL: mittente quando lo step non ne ha uno e Lista Valori non da' uno USER</summary>
    public string MittentePredefinito { get; set; } = "";

    public string Macchina => string.IsNullOrWhiteSpace(NomeMacchina) ? Environment.MachineName : NomeMacchina;
}

// Un file di log al giorno, righe semplici: quello che serve per capire cosa ha
// fatto il servizio quando nessuno guardava la console.
public class FileLogProvider : ILoggerProvider
{
    readonly string cartella;
    readonly object serratura = new();
    readonly ConcurrentDictionary<string, ILogger> logger = new();
    public FileLogProvider(string cartella) { this.cartella = cartella; Directory.CreateDirectory(cartella); }
    public ILogger CreateLogger(string categoria) => logger.GetOrAdd(categoria, c => new FileLogger(this, c.Split('.').Last()));
    public void Dispose() { }

    internal void Scrivi(string riga)
    {
        lock (serratura)
        {
            try { File.AppendAllText(Path.Combine(cartella, $"motore-{DateTime.Now:yyyyMMdd}.log"), riga + Environment.NewLine); }
            catch { /* il log su file non deve mai fermare il motore */ }
        }
    }

    class FileLogger : ILogger
    {
        readonly FileLogProvider p; readonly string categoria;
        public FileLogger(FileLogProvider p, string categoria) { this.p = p; this.categoria = categoria; }
        IDisposable ILogger.BeginScope<TState>(TState state) => Nulla.Istanza;
        sealed class Nulla : IDisposable { public static readonly Nulla Istanza = new(); public void Dispose() { } }
        public bool IsEnabled(LogLevel l) => l >= LogLevel.Information;
        public void Log<TState>(LogLevel l, EventId id, TState state, Exception? ex, Func<TState, Exception?, string> f)
        {
            if (!IsEnabled(l)) return;
            var livello = l switch { LogLevel.Warning => "WARN", LogLevel.Error or LogLevel.Critical => "ERR ", _ => "INFO" };
            p.Scrivi($"{DateTime.Now:HH:mm:ss} {livello} {categoria}: {f(state, ex)}{(ex is null ? "" : " | " + ex.GetType().Name + ": " + ex.Message)}");
        }
    }
}
