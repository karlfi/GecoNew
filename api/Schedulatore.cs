using System.Data;
using System.Globalization;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using Cronos;
using Dapper;
using Microsoft.Data.SqlClient;

// === Schedulatore (il Workflow Orchestrator, gia' progetto TNOT) ===
// I "file step" legacy (.stp, simil-INI) diventano workflow con un albero di
// step nelle tabelle WF_: da qui si importano, si ritoccano, si pianificano
// (cron o data singola) e si segue lo storico delle esecuzioni. Le scritture
// passano solo dalle stored WF_usp_*.
// Chi esegue davvero e' il motore, che pesca da WF_Esecuzione le occorrenze
// scadute (Claim): "esegui ora" mette in coda e basta. Le date delle tabelle
// WF_ sono tutte UTC, e l'API le marca come tali perche' il browser le mostri
// nell'ora locale.
static class Schedulatore
{
    public static void Map(WebApplication app, Func<string> connString)
    {
        // ---- lookup ---------------------------------------------------------
        app.MapGet("/api/schedulatore/tipi", async () =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync(
                "SELECT Codice, Descrizione, SupportaSottopassi FROM dbo.WF_TipoStep WHERE Attivo = 1 ORDER BY Codice"));
        }).RequireAuthorization();

        // ---- workflow ---------------------------------------------------------
        // elenco con quanti step, quante pianificazioni vive e com'e' andata l'ultima volta
        app.MapGet("/api/schedulatore/workflow", async () =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(Utc(await cn.QueryAsync(@"
                SELECT w.IdWorkflow, w.Nome, w.Descrizione, w.NStepDichiarati, w.DirectoryOutput, w.Attivo,
                       w.FileOrigine, w.DataCreazione, w.DataModifica,
                       (SELECT COUNT(*) FROM dbo.WF_WorkflowStep s WHERE s.IdWorkflow = w.IdWorkflow) AS NumStep,
                       (SELECT COUNT(*) FROM dbo.WF_PianificazioneMaster m
                         WHERE m.IdWorkflow = w.IdWorkflow AND m.DataCancellazione IS NULL AND m.Attiva = 1 AND m.Sospesa = 0) AS NumPianificazioni,
                       ult.Stato AS UltimoStato, ult.StatoNome AS UltimoStatoNome, ult.InizioUtc AS UltimoInizioUtc, ult.FineUtc AS UltimoFineUtc
                FROM dbo.WF_Workflow w
                OUTER APPLY (SELECT TOP 1 e.Stato, st.Nome AS StatoNome, e.InizioUtc, e.FineUtc
                             FROM dbo.WF_Esecuzione e JOIN dbo.WF_StatoEsecuzione st ON st.Codice = e.Stato
                             WHERE e.IdWorkflow = w.IdWorkflow AND e.Stato <> 0 ORDER BY e.IdEsecuzione DESC) ult
                ORDER BY w.Nome")));
        }).RequireAuthorization();

        // testata + albero degli step (sottopassi annidati), parametri gia' come JSON
        app.MapGet("/api/schedulatore/workflow/{id:int}", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            var testa = (IDictionary<string, object?>?)await cn.QueryFirstOrDefaultAsync(
                "SELECT * FROM dbo.WF_Workflow WHERE IdWorkflow = @id", new { id });
            if (testa is null) return Results.NotFound(new { errore = "Workflow non trovato" });
            Utc(testa);
            testa["VariabiliGlobali"] = JsonOInvariato(testa["VariabiliGlobali"]);
            testa["ParametriExtra"] = JsonOInvariato(testa["ParametriExtra"]);
            var righe = await cn.QueryAsync(@"
                SELECT IdStep, IdStepPadre, Ordine, NomeSezione, Tipo, EsciSuErrore, EseguiPasso, Attivo, Parametri, Livello, Percorso
                FROM dbo.WF_vw_WorkflowStepAlbero WHERE IdWorkflow = @id ORDER BY Percorso", new { id });
            testa["Steps"] = Albero(righe);
            return Results.Ok(testa);
        }).RequireAuthorization();

        // testata scritta dalla pagina: nuovo workflow (vuoto, gli step si aggiungono dopo) o modifica
        app.MapPost("/api/schedulatore/workflow", (JsonElement b) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(new { idWorkflow = await SalvaWorkflow(cn, null, b) });
        })).RequireAuthorization();

        app.MapPut("/api/schedulatore/workflow/{id:int}", (int id, JsonElement b) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            await SalvaWorkflow(cn, id, b);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        app.MapDelete("/api/schedulatore/workflow/{id:int}", (int id) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.WF_usp_Workflow_Delete", new { IdWorkflow = id }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        // ---- step -------------------------------------------------------------
        app.MapPut("/api/schedulatore/step/{id:int}", (int id, JsonElement b) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.WF_usp_Step_UpdateParametri", new
            {
                IdStep = id,
                Parametri = Json(b, "parametri") ?? "{}",
                EsciSuErrore = Bool(b, "esciSuErrore"),
                EseguiPasso = Bool(b, "eseguiPasso"),
                Attivo = Bool(b, "attivo"),
                Tipo = Str(b, "tipo"),
                NomeSezione = Str(b, "nomeSezione"),
            }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        app.MapPost("/api/schedulatore/workflow/{id:int}/step", (int id, JsonElement b) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var p = new DynamicParameters(new
            {
                IdWorkflow = id, IdStepPadre = Int(b, "idStepPadre"),
                Tipo = Str(b, "tipo") ?? "ESEGUIQUERY", NomeSezione = Str(b, "nomeSezione"),
            });
            p.Add("@IdStep", dbType: DbType.Int32, direction: ParameterDirection.Output);
            await cn.ExecuteAsync("dbo.WF_usp_Step_Insert", p, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { idStep = p.Get<int>("@IdStep") });
        })).RequireAuthorization();

        app.MapDelete("/api/schedulatore/step/{id:int}", (int id) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.WF_usp_Step_Delete", new { IdStep = id }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        app.MapPost("/api/schedulatore/step/{id:int}/sposta", (int id, JsonElement b) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.WF_usp_Step_Sposta",
                new { IdStep = id, Direzione = Str(b, "direzione") == "su" ? "su" : "giu" }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        // ---- import dei file .stp ------------------------------------------------
        // body: { file: [{ nome, base64 }], sovrascrivi } - un esito per file
        app.MapPost("/api/schedulatore/import", async (JsonElement b) =>
        {
            var sovrascrivi = Bool(b, "sovrascrivi") ?? true;
            var esiti = new List<object>();
            if (!b.TryGetProperty("file", out var file) || file.ValueKind != JsonValueKind.Array)
                return Results.BadRequest(new { errore = "Nessun file" });
            await using var cn = new SqlConnection(connString());
            foreach (var f in file.EnumerateArray())
            {
                var nomeFile = Str(f, "nome") ?? "senza_nome.stp";
                try
                {
                    var bytes = Convert.FromBase64String(Str(f, "base64") ?? "");
                    var wf = FileStep.Parsa(bytes, nomeFile);
                    var id = await Importa(cn, wf, bytes, sovrascrivi);
                    esiti.Add(new { file = nomeFile, ok = true, idWorkflow = (int?)id, nome = wf.Nome, numStep = wf.Appiattiti().Count, errore = (string?)null });
                }
                catch (Exception ex)
                {
                    esiti.Add(new { file = nomeFile, ok = false, idWorkflow = (int?)null, nome = (string?)null, numStep = 0, errore = ex.Message });
                }
            }
            return Results.Ok(new { esiti });
        }).RequireAuthorization();

        // ---- esecuzioni -----------------------------------------------------------
        // "esegui ora": in coda con la data di adesso, la pesca il motore
        app.MapPost("/api/schedulatore/workflow/{id:int}/esegui", (int id, JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var p = new DynamicParameters(new
            {
                IdWorkflow = id, Origine = "MANUALE", Parametri = Json(b, "parametri"),
                DataOraPrevista = (DateTime?)null, GruppoConcorrenza = (string?)null,
                NomeUtente = user.Identity?.Name, IdPianificazione = (int?)null, IdDettaglio = (int?)null,
            });
            p.Add("@IdEsecuzione", dbType: DbType.Int32, direction: ParameterDirection.Output);
            await cn.ExecuteAsync("dbo.WF_usp_Esecuzione_Crea", p, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { idEsecuzione = p.Get<int>("@IdEsecuzione") });
        })).RequireAuthorization();

        app.MapPost("/api/schedulatore/esecuzione/{id:int}/annulla", (int id, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.WF_usp_Esecuzione_Annulla", new { IdEsecuzione = id, NomeUtente = user.Identity?.Name },
                commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        // storico: le ultime N, filtrabili per workflow e per stato
        app.MapGet("/api/schedulatore/esecuzioni", async (int? idWorkflow, int? stato, int? top) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(Utc(await cn.QueryAsync($@"
                SELECT TOP {Math.Clamp(top ?? 200, 1, 2000)}
                       IdEsecuzione, IdWorkflow, NomeWorkflow, IdPianificazione, IdDettaglio, Stato, StatoNome, Origine,
                       GruppoConcorrenza, DataOraPrevista, InizioUtc, FineUtc, MachineName, NomeUtente, Avanzamento, Esito, DataCreazione
                FROM dbo.WF_vw_Esecuzione
                WHERE (@idWorkflow IS NULL OR IdWorkflow = @idWorkflow) AND (@stato IS NULL OR Stato = @stato)
                ORDER BY IdEsecuzione DESC", new { idWorkflow, stato })));
        }).RequireAuthorization();

        // una esecuzione col suo log: una chiamata sola, la pagina la ripete finche' e' in corso
        app.MapGet("/api/schedulatore/esecuzione/{id:int}", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            var e = (IDictionary<string, object?>?)await cn.QueryFirstOrDefaultAsync(
                "SELECT * FROM dbo.WF_vw_Esecuzione WHERE IdEsecuzione = @id", new { id });
            if (e is null) return Results.NotFound(new { errore = "Esecuzione non trovata" });
            Utc(e);
            e["Parametri"] = JsonOInvariato(e["Parametri"]);
            e["Log"] = Utc(await cn.QueryAsync(@"
                SELECT Sequenza, IdStep, Livello, Messaggio, NumRecord, TimestampUtc
                FROM dbo.WF_EsecuzioneLog WHERE IdEsecuzione = @id ORDER BY Sequenza", new { id })).ToList();
            return Results.Ok(e);
        }).RequireAuthorization();

        // ---- pianificazioni -----------------------------------------------------
        // ogni ricorrenza porta le sue prossime occorrenze, calcolate qui: cosi' si
        // vede subito se un cron fa quel che si voleva
        app.MapGet("/api/schedulatore/workflow/{id:int}/pianificazioni", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            var masters = Utc(await cn.QueryAsync(@"
                SELECT IdPianificazione, IdWorkflow, Descrizione, Parametri, GruppoConcorrenza, Note,
                       OrizzonteGiorni, DataOraFinale, Sospesa, Attiva, DataCreazione, DataModifica
                FROM dbo.WF_PianificazioneMaster
                WHERE IdWorkflow = @id AND DataCancellazione IS NULL ORDER BY IdPianificazione", new { id })).ToList();
            var dettagli = Utc(await cn.QueryAsync(@"
                SELECT d.IdDettaglio, d.IdPianificazione, d.TipoRicorrenza, d.CronExpr, d.DataOraSingola, d.Priorita, d.Attiva,
                       m.DataOraFinale
                FROM dbo.WF_PianificazioneDettaglio d
                JOIN dbo.WF_PianificazioneMaster m ON m.IdPianificazione = d.IdPianificazione
                WHERE m.IdWorkflow = @id AND m.DataCancellazione IS NULL ORDER BY d.IdDettaglio", new { id })).ToList();
            foreach (var d in dettagli) d["Prossime"] = Prossime(d, 3, DateTime.UtcNow.AddYears(2));
            foreach (var m in masters)
            {
                m["Parametri"] = JsonOInvariato(m["Parametri"]);
                m["Dettagli"] = dettagli.Where(d => Equals(d["IdPianificazione"], m["IdPianificazione"])).ToList();
            }
            return Results.Ok(masters);
        }).RequireAuthorization();

        app.MapPost("/api/schedulatore/workflow/{id:int}/pianificazioni", (int id, JsonElement b) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(new { idPianificazione = await SalvaPianificazione(cn, null, id, b) });
        })).RequireAuthorization();

        app.MapPut("/api/schedulatore/pianificazione/{id:int}", (int id, JsonElement b) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var idWorkflow = Int(b, "idWorkflow")
                ?? await cn.ExecuteScalarAsync<int>("SELECT IdWorkflow FROM dbo.WF_PianificazioneMaster WHERE IdPianificazione = @id", new { id });
            await SalvaPianificazione(cn, id, idWorkflow, b);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        app.MapDelete("/api/schedulatore/pianificazione/{id:int}", (int id) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.WF_usp_Pianificazione_Elimina", new { IdPianificazione = id }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        app.MapPost("/api/schedulatore/pianificazione/{id:int}/dettagli", (int id, JsonElement b) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(new { idDettaglio = await SalvaDettaglio(cn, null, id, b) });
        })).RequireAuthorization();

        app.MapPut("/api/schedulatore/dettaglio/{id:int}", (int id, JsonElement b) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var idPian = await cn.ExecuteScalarAsync<int>("SELECT IdPianificazione FROM dbo.WF_PianificazioneDettaglio WHERE IdDettaglio = @id", new { id });
            await SalvaDettaglio(cn, id, idPian, b);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        app.MapDelete("/api/schedulatore/dettaglio/{id:int}", (int id) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.WF_usp_Dettaglio_Elimina", new { IdDettaglio = id }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        // prova di un'espressione cron: valida? e quando scatterebbe
        app.MapGet("/api/schedulatore/cron", (string? expr, int? n) =>
        {
            try
            {
                var cron = Cron(expr ?? "");
                var prossime = cron.GetOccurrences(DateTime.UtcNow, DateTime.UtcNow.AddYears(2), TimeZoneInfo.Local)
                    .Take(Math.Clamp(n ?? 5, 1, 20)).ToList();
                return Results.Ok(new { valida = true, errore = (string?)null, prossime });
            }
            catch (Exception ex)
            {
                return Results.Ok(new { valida = false, errore = ex.Message, prossime = new List<DateTime>() });
            }
        }).RequireAuthorization();

        // cosa scattera' nei prossimi giorni: le ricorrenze calcolate da qui piu'
        // quello che e' gia' in coda (esegui ora, o le occorrenze materializzate dal motore)
        app.MapGet("/api/schedulatore/prossime", async (int? giorni) =>
        {
            var fine = DateTime.UtcNow.AddDays(Math.Clamp(giorni ?? 7, 1, 90));
            await using var cn = new SqlConnection(connString());
            var righe = new List<RigaProssima>();
            var dettagli = Utc(await cn.QueryAsync(@"
                SELECT d.IdDettaglio, d.IdPianificazione, d.TipoRicorrenza, d.CronExpr, d.DataOraSingola, d.Priorita, d.Attiva,
                       m.IdWorkflow, w.Nome AS NomeWorkflow, m.Descrizione, m.Sospesa, m.DataOraFinale, m.GruppoConcorrenza
                FROM dbo.WF_PianificazioneDettaglio d
                JOIN dbo.WF_PianificazioneMaster m ON m.IdPianificazione = d.IdPianificazione
                JOIN dbo.WF_Workflow w ON w.IdWorkflow = m.IdWorkflow
                WHERE d.Attiva = 1 AND m.Attiva = 1 AND m.DataCancellazione IS NULL"));
            foreach (var d in dettagli)
                foreach (var quando in Prossime(d, 200, fine))
                    righe.Add(new RigaProssima(quando, d["TipoRicorrenza"]?.ToString() ?? "", (int)d["IdWorkflow"]!, d["NomeWorkflow"]?.ToString() ?? "",
                        d["IdPianificazione"] as int?, d["Descrizione"]?.ToString(), d["Sospesa"] is true, d["GruppoConcorrenza"]?.ToString(),
                        d["CronExpr"]?.ToString(), null));
            var inCoda = Utc(await cn.QueryAsync(@"
                SELECT IdEsecuzione, IdWorkflow, NomeWorkflow, IdPianificazione, Origine, DataOraPrevista, GruppoConcorrenza, NomeUtente
                FROM dbo.WF_vw_Esecuzione WHERE Stato = 0 ORDER BY DataOraPrevista"));
            foreach (var e in inCoda)
                righe.Add(new RigaProssima((DateTime)e["DataOraPrevista"]!, "CODA", (int)e["IdWorkflow"]!, e["NomeWorkflow"]?.ToString() ?? "",
                    e["IdPianificazione"] as int?, e["Origine"] + (e["NomeUtente"] is null ? "" : " di " + e["NomeUtente"]), false,
                    e["GruppoConcorrenza"]?.ToString(), null, (int)e["IdEsecuzione"]!));
            return Results.Ok(righe.OrderBy(r => r.Quando).Take(500));
        }).RequireAuthorization();
    }

    record RigaProssima(DateTime Quando, string Fonte, int IdWorkflow, string NomeWorkflow, int? IdPianificazione,
        string? Descrizione, bool Sospesa, string? GruppoConcorrenza, string? CronExpr, int? IdEsecuzione);

    // ---- testata del workflow -----------------------------------------------------
    static async Task<int> SalvaWorkflow(SqlConnection cn, int? id, JsonElement b)
    {
        var p = new DynamicParameters(new
        {
            Nome = Str(b, "nome"), Descrizione = Str(b, "descrizione"), DirectoryOutput = Str(b, "directoryOutput"),
            NomeFileLog = Str(b, "nomeFileLog"), NomeFileLogResult = Str(b, "nomeFileLogResult"),
            PausaTraStepMS = Int(b, "pausaTraStepMS"), ApriDirectoryFinale = Bool(b, "apriDirectoryFinale"),
            LoggaInizioOperazione = Bool(b, "loggaInizioOperazione"), VariabiliGlobali = Json(b, "variabiliGlobali"),
            Attivo = Bool(b, "attivo"),
        });
        p.Add("@IdWorkflow", id, DbType.Int32, ParameterDirection.InputOutput);
        await cn.ExecuteAsync("dbo.WF_usp_Workflow_Salva", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@IdWorkflow");
    }

    // ---- pianificazioni: salvataggi -----------------------------------------------
    static async Task<int> SalvaPianificazione(SqlConnection cn, int? id, int idWorkflow, JsonElement b)
    {
        var p = new DynamicParameters(new
        {
            IdWorkflow = idWorkflow, Descrizione = Str(b, "descrizione"), Parametri = Json(b, "parametri"),
            GruppoConcorrenza = Str(b, "gruppoConcorrenza"), Note = Str(b, "note"),
            OrizzonteGiorni = Int(b, "orizzonteGiorni") ?? 30, DataOraFinale = DataUtc(b, "dataOraFinale"),
            Sospesa = Bool(b, "sospesa") ?? false, Attiva = Bool(b, "attiva") ?? true,
        });
        p.Add("@IdPianificazione", id, DbType.Int32, ParameterDirection.InputOutput);
        await cn.ExecuteAsync("dbo.WF_usp_Pianificazione_Salva", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@IdPianificazione");
    }

    static async Task<int> SalvaDettaglio(SqlConnection cn, int? id, int idPianificazione, JsonElement b)
    {
        var tipo = (Str(b, "tipoRicorrenza") ?? "CRON").ToUpperInvariant();
        var cron = tipo == "CRON" ? Str(b, "cronExpr") : null;
        if (tipo == "CRON") Cron(cron ?? "");   // errore chiaro qui, non dal motore tra una settimana
        var p = new DynamicParameters(new
        {
            IdPianificazione = idPianificazione, TipoRicorrenza = tipo, CronExpr = cron,
            DataOraSingola = tipo == "ONESHOT" ? DataUtc(b, "dataOraSingola") : null,
            Priorita = Int(b, "priorita") ?? 0, Attiva = Bool(b, "attiva") ?? true,
        });
        p.Add("@IdDettaglio", id, DbType.Int32, ParameterDirection.InputOutput);
        await cn.ExecuteAsync("dbo.WF_usp_Dettaglio_Salva", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@IdDettaglio");
    }

    // ---- cron ------------------------------------------------------------------------
    // cinque campi (min ora giorno mese sett.) come il motore; sei = coi secondi davanti
    static CronExpression Cron(string expr)
    {
        var campi = expr.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (campi.Length is not (5 or 6)) throw new ArgumentException("Cron: servono 5 campi (min ora giorno mese giorno-settimana), es. \"0 6 * * 1-5\"");
        return CronExpression.Parse(string.Join(' ', campi), campi.Length == 6 ? CronFormat.IncludeSeconds : CronFormat.Standard);
    }

    // le prossime occorrenze di una ricorrenza (riga di WF_PianificazioneDettaglio), in UTC;
    // una pianificazione sospesa le mostra lo stesso (col suo flag), cosi' si vede cosa si sta saltando
    static List<DateTime> Prossime(IDictionary<string, object?> d, int quante, DateTime fineUtc)
    {
        var da = DateTime.UtcNow;
        if (d.TryGetValue("DataOraFinale", out var df) && df is DateTime fin && fin < fineUtc) fineUtc = fin;
        if (fineUtc <= da) return new();
        if (Equals(d["TipoRicorrenza"], "ONESHOT"))
            return d["DataOraSingola"] is DateTime s && s >= da && s <= fineUtc ? new() { s } : new();
        try
        {
            return Cron(d["CronExpr"]?.ToString() ?? "").GetOccurrences(da, fineUtc, TimeZoneInfo.Local).Take(quante).ToList();
        }
        catch { return new(); }   // cron non valido: niente occorrenze, l'errore si vede nella prova del cron
    }

    // ---- import: albero -> TVP -> stored ------------------------------------------------
    static async Task<int> Importa(SqlConnection cn, FileStep.Workflow wf, byte[] bytes, bool sovrascrivi)
    {
        var tvp = new DataTable();
        tvp.Columns.Add("TempId", typeof(int));
        tvp.Columns.Add("ParentTempId", typeof(int));
        tvp.Columns.Add("Ordine", typeof(int));
        tvp.Columns.Add("NomeSezione", typeof(string));
        tvp.Columns.Add("Tipo", typeof(string));
        tvp.Columns.Add("EsciSuErrore", typeof(bool));
        tvp.Columns.Add("EseguiPasso", typeof(bool));
        tvp.Columns.Add("Attivo", typeof(bool));
        tvp.Columns.Add("Parametri", typeof(string));
        foreach (var (s, tempId, padre) in wf.Appiattiti())
            tvp.Rows.Add(tempId, (object?)padre ?? DBNull.Value, s.Ordine, s.NomeSezione, s.Tipo,
                s.EsciSuErrore, s.EseguiPasso, s.Attivo, JsonSerializer.Serialize(s.Parametri, JsonGrezzo));
        var cb = wf.ComandoBase;
        var p = new DynamicParameters(new
        {
            Nome = wf.Nome, NStepDichiarati = cb.NStepDichiarati, DirectoryOutput = cb.DirectoryOutput,
            NomeFileLog = cb.NomeFileLog, NomeFileLogResult = cb.NomeFileLogResult, PausaTraStepMS = cb.PausaTraStepMS,
            ApriDirectoryFinale = cb.ApriDirectoryFinale, LoggaInizioOperazione = cb.LoggaInizioOperazione,
            VariabiliGlobali = JsonSerializer.Serialize(cb.VariabiliGlobali, JsonGrezzo),
            ParametriExtra = JsonSerializer.Serialize(cb.Extra, JsonGrezzo),
            FileOrigine = wf.FileOrigine, HashOrigine = SHA256.HashData(bytes), SovrascriviSeEsiste = sovrascrivi,
        });
        p.Add("@Steps", tvp.AsTableValuedParameter("dbo.WF_udt_StepList"));
        p.Add("@IdWorkflow", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await cn.ExecuteAsync("dbo.WF_usp_Workflow_Import", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@IdWorkflow");
    }

    // ---- attrezzi -------------------------------------------------------------------
    static readonly JsonSerializerOptions JsonGrezzo = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    static async Task<IResult> Prova(Func<Task<IResult>> f)
    {
        try { return await f(); }
        catch (SqlException ex) { return Results.BadRequest(new { errore = ex.Message }); }
        catch (ArgumentException ex) { return Results.BadRequest(new { errore = ex.Message }); }
    }

    // tutte le date delle tabelle WF_ sono UTC: marcate cosi' escono con la "Z"
    static IDictionary<string, object?> Utc(IDictionary<string, object?> r)
    {
        foreach (var k in r.Keys.ToList())
            if (r[k] is DateTime d) r[k] = DateTime.SpecifyKind(d, DateTimeKind.Utc);
        return r;
    }
    static IEnumerable<IDictionary<string, object?>> Utc(IEnumerable<dynamic> righe)
    {
        foreach (var r in righe) yield return Utc((IDictionary<string, object?>)r);
    }

    // colonna JSON -> oggetto (se non e' JSON valido resta testo, per non perdere niente)
    static object? JsonOInvariato(object? v)
    {
        if (v is not string s || string.IsNullOrWhiteSpace(s)) return v;
        try { return JsonDocument.Parse(s).RootElement.Clone(); } catch { return s; }
    }

    // le righe della vista (ordinate per Percorso) diventano radici con i sottopassi annidati
    static List<IDictionary<string, object?>> Albero(IEnumerable<dynamic> righe)
    {
        var nodi = new Dictionary<int, IDictionary<string, object?>>();
        var radici = new List<IDictionary<string, object?>>();
        foreach (var r in righe)
        {
            var n = Utc((IDictionary<string, object?>)r);
            n["Parametri"] = JsonOInvariato(n["Parametri"]);
            n["Sottopassi"] = new List<IDictionary<string, object?>>();
            nodi[(int)n["IdStep"]!] = n;
        }
        foreach (var n in nodi.Values)
        {
            if (n["IdStepPadre"] is int padre && nodi.TryGetValue(padre, out var p))
                ((List<IDictionary<string, object?>>)p["Sottopassi"]!).Add(n);
            else radici.Add(n);
        }
        return radici;
    }

    static string? Str(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    static bool? Bool(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False ? v.GetBoolean() : null;
    static int? Int(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;
    static string? Json(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind is JsonValueKind.Object or JsonValueKind.Array ? v.GetRawText() : null;
    // la pagina manda ISO con l'offset (toISOString); senza offset si intende ora locale del server
    static DateTime? DataUtc(JsonElement b, string nome)
    {
        var s = Str(b, nome);
        if (string.IsNullOrWhiteSpace(s)) return null;
        return DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var d)
            ? d.UtcDateTime : throw new ArgumentException($"Data non valida: {s}");
    }
}

// === Parser dei "file step" legacy (.stp, simil-INI) ===
// Porta fedele del parser TypeScript di TNOT: il valore puo' contenere '=' (si
// spezza solo sul primo), le chiavi non fanno distinzione di maiuscole, le
// sezioni [StepN_SottopassoM] / [StepN_CampoM] ecc. tornano un albero, i valori
// restano stringhe grezze. [StepNO3] e' il trucco legacy per disabilitare uno
// step senza toglierlo dal file: si conserva con Attivo = 0.
static class FileStep
{
    public class Workflow
    {
        public string Nome = "";
        public string? FileOrigine;
        public Testata ComandoBase = new();
        public List<Step> Steps = new();

        // visita in pre-ordine con id provvisori: e' la forma che vuole la stored
        public List<(Step s, int tempId, int? padre)> Appiattiti()
        {
            var fuori = new List<(Step, int, int?)>();
            var seq = 0;
            void Visita(Step s, int? padre)
            {
                var id = ++seq;
                fuori.Add((s, id, padre));
                foreach (var c in s.Sottopassi) Visita(c, id);
            }
            foreach (var s in Steps) Visita(s, null);
            return fuori;
        }
    }
    public class Testata
    {
        public int? NStepDichiarati;
        public string? DirectoryOutput, NomeFileLog, NomeFileLogResult;
        public int PausaTraStepMS;
        public bool ApriDirectoryFinale, LoggaInizioOperazione = true;
        public List<string> VariabiliGlobali = new();
        public Dictionary<string, string> Extra = new();
    }
    public class Step
    {
        public int Ordine;
        public string NomeSezione = "", Tipo = "";
        public bool Attivo = true, EsciSuErrore, EseguiPasso = true;
        public Dictionary<string, object?> Parametri = new();
        public List<Step> Sottopassi = new();
    }

    class Sezione
    {
        public string Nome = "";
        public List<(string chiave, string valore)> Voci = new();
        public Dictionary<string, string> Mappa = new(StringComparer.OrdinalIgnoreCase);
        public string? this[string chiave] => Mappa.TryGetValue(chiave, out var v) ? v : null;
    }

    static FileStep() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    // i file legacy sono ANSI (Windows-1252): accenti ed euro vanno letti cosi'
    public static Workflow Parsa(byte[] bytes, string nomeFile)
    {
        var testo = Encoding.GetEncoding(1252).GetString(bytes);
        var nome = Regex.Replace(nomeFile, @"\.[^.]+$", "");
        return Parsa(testo, nome, nomeFile);
    }

    public static Workflow Parsa(string testo, string nome, string? fileOrigine)
    {
        var sezioni = Spezza(testo);
        var perNome = new Dictionary<string, Sezione>(StringComparer.OrdinalIgnoreCase);
        foreach (var s in sezioni) perNome[s.Nome] = s;
        if (!perNome.TryGetValue("ComandoBase", out var basee))
            throw new ArgumentException("Sezione [ComandoBase] assente: file step non valido.");

        var mappate = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "nstep", "directoryoutput", "nomefilelog", "nomefilelogresult", "pausatrastepms",
            "apridirectoryfineale", "apridirectoryfinale", "loggainiziooperazione", "variabiliglobali",
        };
        var testata = new Testata
        {
            NStepDichiarati = Intero(basee["NStep"]),
            DirectoryOutput = basee["DirectoryOutput"],
            NomeFileLog = basee["NomeFileLog"],
            NomeFileLogResult = basee["NomeFileLogResult"],
            PausaTraStepMS = Intero(basee["PausaTraStepMS"]) ?? 0,
            // nel manuale la chiave e' scritta "ApriDirectoryFineale" (refuso legacy)
            ApriDirectoryFinale = Booleano(basee["ApriDirectoryFineale"] ?? basee["ApriDirectoryFinale"], false),
            LoggaInizioOperazione = Booleano(basee["LoggaInizioOperazione"], true),
            VariabiliGlobali = (basee["VariabiliGlobali"] ?? "").Split(',').Select(x => x.Trim()).Where(x => x != "").ToList(),
        };
        foreach (var (k, v) in basee.Voci) if (!mappate.Contains(k)) testata.Extra[k] = v;

        // radici: [StepN] attivi e [StepNON] disabilitati, in ordine di numero
        var radici = sezioni
            .Select(s => (s, m: Regex.Match(s.Nome, @"^Step(NO)?(\d+)$", RegexOptions.IgnoreCase)))
            .Where(x => x.m.Success)
            .Select(x => (x.s, indice: int.Parse(x.m.Groups[2].Value), attivo: !x.m.Groups[1].Success))
            .OrderBy(x => x.indice);

        return new Workflow
        {
            Nome = nome, FileOrigine = fileOrigine, ComandoBase = testata,
            Steps = radici.Select(r => CostruisciStep(r.s.Nome, perNome, r.indice, r.attivo)).ToList(),
        };
    }

    static readonly Regex RigaSezione = new(@"^\s*\[(.+?)\]\s*$");

    static List<Sezione> Spezza(string contenuto)
    {
        var sezioni = new List<Sezione>();
        Sezione? corrente = null;
        var testo = contenuto.TrimStart('﻿').Replace("\r\n", "\n").Replace('\r', '\n');
        foreach (var grezza in testo.Split('\n'))
        {
            var riga = grezza.Trim();
            if (riga == "") continue;
            // commenti: INI (';' '#') e stile SQL ('--'), usati nei file veri
            if (riga.StartsWith(';') || riga.StartsWith('#') || riga.StartsWith("--")) continue;
            var m = RigaSezione.Match(riga);
            if (m.Success)
            {
                corrente = new Sezione { Nome = m.Groups[1].Value.Trim() };
                sezioni.Add(corrente);
                continue;
            }
            var uguale = riga.IndexOf('=');
            if (uguale < 0 || corrente is null) continue;     // riga fuori sintassi, o prima di ogni sezione
            var chiave = riga[..uguale].Trim();
            var valore = riga[(uguale + 1)..].Trim();
            corrente.Voci.Add((chiave, valore));
            corrente.Mappa[chiave] = valore;
        }
        return sezioni;
    }

    static readonly HashSet<string> ChiaviUniversali = new(StringComparer.OrdinalIgnoreCase) { "tipo", "escisuerrore", "eseguipasso" };
    // sotto-sezioni: i sottopassi sono step veri; le altre sono strutture che finiscono nel JSON
    static readonly Dictionary<string, string> Sottosezioni = new(StringComparer.OrdinalIgnoreCase)
    {
        ["sottopasso"] = "sottopassi", ["campo"] = "campiFissi", ["primariga"] = "primaRiga",
        ["campilookup"] = "campiLookup", ["campicombo"] = "campiCombo",
    };

    // figlia diretta di `padre`: padre + "_" + Tipo + numero, senza altri "_"
    static (string genere, int indice)? Figlia(string padre, string nome)
    {
        if (!nome.StartsWith(padre + "_", StringComparison.OrdinalIgnoreCase)) return null;
        var coda = nome[(padre.Length + 1)..];
        if (coda.Contains('_')) return null;
        var m = Regex.Match(coda, @"^([A-Za-z]+?)(\d+)$");
        if (!m.Success || !Sottosezioni.ContainsKey(m.Groups[1].Value)) return null;
        return (m.Groups[1].Value.ToLowerInvariant(), int.Parse(m.Groups[2].Value));
    }

    static Step CostruisciStep(string nomeSezione, Dictionary<string, Sezione> perNome, int ordine, bool attivo)
    {
        if (!perNome.TryGetValue(nomeSezione, out var s)) throw new ArgumentException($"Sezione mancante: [{nomeSezione}]");
        var step = new Step
        {
            Ordine = ordine, NomeSezione = s.Nome, Attivo = attivo,
            Tipo = (s["Tipo"] ?? "").ToUpperInvariant(),
            EsciSuErrore = Booleano(s["EsciSuErrore"], false),
            EseguiPasso = Booleano(s["EseguiPasso"], true),
        };
        foreach (var (k, v) in s.Voci) if (!ChiaviUniversali.Contains(k)) step.Parametri[k] = v;   // grezzo, per fedelta'

        var figlie = perNome.Values.Select(x => (sez: x, f: Figlia(nomeSezione, x.Nome))).Where(x => x.f is not null)
            .GroupBy(x => x.f!.Value.genere).ToDictionary(g => g.Key, g => g.OrderBy(x => x.f!.Value.indice).ToList());
        foreach (var genere in new[] { "campo", "primariga", "campilookup", "campicombo" })
            if (figlie.TryGetValue(genere, out var voci))
                step.Parametri[Sottosezioni[genere]] = voci.Select(x =>
                {
                    var o = new Dictionary<string, object?> { ["ordine"] = x.f!.Value.indice };
                    foreach (var (k, v) in x.sez.Voci) o[k] = v;
                    return o;
                }).ToList();
        if (figlie.TryGetValue("sottopasso", out var sotto))
            foreach (var x in sotto) step.Sottopassi.Add(CostruisciStep(x.sez.Nome, perNome, x.f!.Value.indice, true));
        return step;
    }

    static bool Booleano(string? v, bool predefinito)
    {
        if (string.IsNullOrEmpty(v)) return predefinito;
        v = v.Trim();
        return v == "1" || Regex.IsMatch(v, @"^(true|si|sì|yes)$", RegexOptions.IgnoreCase);
    }
    static int? Intero(string? v) => int.TryParse(v?.Trim(), out var n) ? n : null;
}
