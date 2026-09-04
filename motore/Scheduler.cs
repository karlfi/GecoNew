using System.Data;
using Cronos;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GecoMotore;

// Il giro del motore: materializza le pianificazioni, pesca le esecuzioni
// scadute (una stored con lock: piu' motori non si pestano i piedi) e le fa
// partire in parallelo fino al tetto. Le date in WF_ sono tutte UTC.
public class Scheduler : BackgroundService
{
    readonly Opzioni o;
    readonly ILogger<Scheduler> log;
    readonly ILoggerFactory logFactory;
    int inCorso;
    DateTime ultimaMaterializzazione = DateTime.MinValue;

    public Scheduler(Opzioni o, ILogger<Scheduler> log, ILoggerFactory logFactory)
    {
        this.o = o; this.log = log; this.logFactory = logFactory;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        log.LogInformation("Motore avviato su {m}: tick {t} s, materializza ogni {mm} min, max {p} in parallelo, script in {s}",
            o.Macchina, o.TickSecondi, o.MaterializzaMinuti, o.MaxParallelo, o.CartellaScript ?? "(cartella dell'exe)");
        await Prova(RecuperaInterrotte, "recupero delle esecuzioni interrotte");

        while (!ct.IsCancellationRequested)
        {
            if ((DateTime.UtcNow - ultimaMaterializzazione).TotalMinutes >= o.MaterializzaMinuti)
            {
                ultimaMaterializzazione = DateTime.UtcNow;
                await Prova(Materializza, "materializzazione delle pianificazioni");
            }
            await Prova(PescaEdEsegui, "pesca delle esecuzioni");
            try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, o.TickSecondi)), ct); }
            catch (OperationCanceledException) { }
        }

        // in chiusura: le esecuzioni in corso finiscono, entro il tetto
        var attesa = DateTime.UtcNow.AddSeconds(o.AttesaChiusuraSecondi);
        while (Volatile.Read(ref inCorso) > 0 && DateTime.UtcNow < attesa)
        {
            log.LogInformation("Chiusura: aspetto {n} esecuzioni in corso", inCorso);
            await Task.Delay(2000);
        }
        if (inCorso > 0) log.LogWarning("Chiusura con {n} esecuzioni ancora in corso: al riavvio risulteranno interrotte", inCorso);
        log.LogInformation("Motore fermato");
    }

    async Task Prova(Func<Task> f, string cosa)
    {
        try { await f(); }
        catch (Exception ex) { log.LogError(ex, "Errore nella {cosa}", cosa); }
    }

    SqlConnection Connessione() => new(o.ConnString);

    // Rimaste IN_ESECUZIONE da un arresto brusco di QUESTA macchina: nessuno le
    // finira' mai, meglio dirlo chiaro nello storico.
    async Task RecuperaInterrotte()
    {
        await using var cn = Connessione();
        var ferme = (await cn.QueryAsync<int>(
            "SELECT IdEsecuzione FROM dbo.WF_Esecuzione WHERE Stato = 1 AND MachineName = @m", new { m = o.Macchina })).ToList();
        foreach (var id in ferme)
        {
            await cn.ExecuteAsync("dbo.WF_usp_EsecuzioneLog_Add", new { IdEsecuzione = id, IdStep = (int?)null, Livello = "ERRORE",
                Messaggio = "Esecuzione interrotta: il motore e' stato riavviato mentre era in corso", NumRecord = (int?)null },
                commandType: CommandType.StoredProcedure);
            await cn.ExecuteAsync("dbo.WF_usp_Esecuzione_Termina", new { IdEsecuzione = id, Stato = 3, Esito = "Interrotta dal riavvio del motore" },
                commandType: CommandType.StoredProcedure);
            log.LogWarning("Esecuzione #{id} rimasta in corso da prima del riavvio: segnata come ERRORE", id);
        }
    }

    // Ogni ricorrenza attiva genera le occorrenze future entro il suo orizzonte
    // (la stored salta quelle gia' presenti). Una pianificazione sospesa viene
    // materializzata lo stesso: e' il Claim a non pescarla finche' e' sospesa.
    async Task Materializza()
    {
        await using var cn = Connessione();
        var piani = await cn.QueryAsync(@"
            SELECT m.IdPianificazione, m.IdWorkflow, m.GruppoConcorrenza, m.Parametri, m.OrizzonteGiorni, m.DataOraFinale,
                   d.IdDettaglio, d.TipoRicorrenza, d.CronExpr, d.DataOraSingola, d.Parametri AS ParametriDet
            FROM dbo.WF_PianificazioneMaster m
            JOIN dbo.WF_PianificazioneDettaglio d ON d.IdPianificazione = m.IdPianificazione
            WHERE m.Attiva = 1 AND m.DataCancellazione IS NULL AND d.Attiva = 1");
        var adesso = DateTime.UtcNow;
        var create = 0;
        foreach (var r in piani)
        {
            var orizzonte = adesso.AddDays((int?)r.OrizzonteGiorni ?? 30);
            var limite = r.DataOraFinale is DateTime fine && Utc(fine) < orizzonte ? Utc(fine) : orizzonte;
            string? parametri = (string?)r.ParametriDet ?? (string?)r.Parametri;
            var occorrenze = new List<DateTime>();
            if ((string)r.TipoRicorrenza == "ONESHOT")
            {
                if (r.DataOraSingola is DateTime s && Utc(s) > adesso && Utc(s) <= limite) occorrenze.Add(Utc(s));
            }
            else if (!string.IsNullOrWhiteSpace((string?)r.CronExpr))
            {
                try { occorrenze.AddRange(Cron((string)r.CronExpr).GetOccurrences(adesso, limite, TimeZoneInfo.Local).Take(1000)); }
                catch (Exception ex)
                {
                    log.LogWarning("Cron non valido \"{c}\" (pianificazione {p}): {e}", (string)r.CronExpr, (int)r.IdPianificazione, ex.Message);
                    continue;
                }
            }
            foreach (var quando in occorrenze)
            {
                await cn.ExecuteAsync("dbo.WF_usp_Esecuzione_Pianifica", new
                {
                    IdPianificazione = (int)r.IdPianificazione, IdDettaglio = (int)r.IdDettaglio, IdWorkflow = (int)r.IdWorkflow,
                    DataOraPrevista = quando, GruppoConcorrenza = (string?)r.GruppoConcorrenza, Parametri = parametri,
                }, commandType: CommandType.StoredProcedure);
                create++;
            }
        }
        log.LogInformation("Materializzazione: {n} ricorrenze, {o} occorrenze passate alla stored", piani.Count(), create);
    }

    // Pesca finche' c'e' posto: ogni esecuzione parte su un suo task.
    async Task PescaEdEsegui()
    {
        while (Volatile.Read(ref inCorso) < o.MaxParallelo)
        {
            await using var cn = Connessione();
            var riga = await cn.QueryFirstOrDefaultAsync("dbo.WF_usp_Esecuzione_Claim", new { MachineName = o.Macchina },
                commandType: CommandType.StoredProcedure);
            if (riga is null) break;
            int idEsecuzione = riga.IdEsecuzione, idWorkflow = riga.IdWorkflow;
            string? parametri = riga.Parametri;
            Interlocked.Increment(ref inCorso);
            log.LogInformation("Esecuzione #{e} (workflow {w}) presa in carico", idEsecuzione, idWorkflow);
            _ = Task.Run(async () =>
            {
                try { await Esecutore.Esegui(o, logFactory.CreateLogger("Esecuzione." + idEsecuzione), idEsecuzione, idWorkflow, parametri); }
                catch (Exception ex) { log.LogError(ex, "Esecuzione #{e}: errore non gestito", idEsecuzione); }
                finally { Interlocked.Decrement(ref inCorso); }
            });
        }
    }

    static DateTime Utc(DateTime d) => DateTime.SpecifyKind(d, DateTimeKind.Utc);

    // cinque campi (min ora giorno mese sett.), sei se ci sono i secondi davanti: come l'API
    public static CronExpression Cron(string expr)
    {
        var campi = expr.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (campi.Length is not (5 or 6)) throw new ArgumentException("servono 5 campi (min ora giorno mese giorno-settimana)");
        return CronExpression.Parse(string.Join(' ', campi), campi.Length == 6 ? CronFormat.IncludeSeconds : CronFormat.Standard);
    }
}
