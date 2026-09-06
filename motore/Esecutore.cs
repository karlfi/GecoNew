using System.Data;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GecoMotore;

// Uno step dell'albero, come sta nel DB, coi sottopassi annidati.
public class Step
{
    public int IdStep; public int? IdStepPadre; public int Ordine;
    public string NomeSezione = ""; public string Tipo = "";
    public bool EsciSuErrore, EseguiPasso = true, Attivo = true;
    public JsonElement Parametri;
    public List<Step> Sottopassi = new();

    // parametro semplice (stringa/numero/bool) come testo; null se manca o e' una struttura
    public string? P(string nome)
    {
        if (Parametri.ValueKind != JsonValueKind.Object) return null;
        foreach (var x in Parametri.EnumerateObject())
            if (string.Equals(x.Name, nome, StringComparison.OrdinalIgnoreCase))
                return x.Value.ValueKind switch
                {
                    JsonValueKind.String => x.Value.GetString(),
                    JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False => x.Value.GetRawText(),
                    _ => null,
                };
        return null;
    }
    public string P(string nome, string predefinito) => P(nome) ?? predefinito;
    public bool Flag(string nome, bool predefinito) => P(nome) is string s ? s.Trim() == "1" || s.Equals("true", StringComparison.OrdinalIgnoreCase) : predefinito;

    // lista di oggetti (campiFissi e simili) come dizionari di testo
    public List<Dictionary<string, string>> Lista(string nome)
    {
        var fuori = new List<Dictionary<string, string>>();
        if (Parametri.ValueKind != JsonValueKind.Object) return fuori;
        foreach (var x in Parametri.EnumerateObject())
            if (string.Equals(x.Name, nome, StringComparison.OrdinalIgnoreCase) && x.Value.ValueKind == JsonValueKind.Array)
                foreach (var el in x.Value.EnumerateArray())
                    if (el.ValueKind == JsonValueKind.Object)
                        fuori.Add(el.EnumerateObject().ToDictionary(k => k.Name, k => k.Value.ValueKind == JsonValueKind.String ? k.Value.GetString() ?? "" : k.Value.GetRawText(), StringComparer.OrdinalIgnoreCase));
        return fuori;
    }
}

// Quello che i mattoncini hanno sotto mano durante l'esecuzione.
public class Contesto
{
    public SqlConnection Cn = null!;
    public Opzioni O = null!;
    public ILogger Log = null!;
    public int IdEsecuzione, IdWorkflow;
    public string? CartellaOutput;
    /// <summary>parametri dell'esecuzione/pianificazione, sostituibili come +[nome]</summary>
    public Dictionary<string, string> Parametri = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>parametri di sistema, sostituibili come @[nome]</summary>
    public Dictionary<string, string> Sistema = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>record corrente quando si e' dentro i sottopassi di una ESEGUIQUERY</summary>
    public IDictionary<string, object?>? Record;
    public DateTime Adesso = DateTime.Now;

    public Contesto ConRecord(IDictionary<string, object?> r) => (Contesto)MemberwiseClone() is var c ? Con(c, r) : this;
    static Contesto Con(Contesto c, IDictionary<string, object?> r) { c.Record = r; return c; }

    // una riga nel log dell'esecuzione (e nel file del servizio)
    public async Task Scrivi(string livello, string messaggio, int? idStep = null, int? numRecord = null)
    {
        await Cn.ExecuteAsync("dbo.WF_usp_EsecuzioneLog_Add",
            new { IdEsecuzione, IdStep = idStep, Livello = livello, Messaggio = messaggio, NumRecord = numRecord },
            commandType: CommandType.StoredProcedure);
        if (livello == "ERRORE") Log.LogError("{m}", messaggio);
        else if (livello == "WARN") Log.LogWarning("{m}", messaggio);
        else Log.LogInformation("{m}", messaggio);
    }

    // sostituzioni nei valori dei parametri (vedi Sostituzioni), con eventuali parametri in piu' dello step
    public string S(string? testo, Dictionary<string, string>? extra = null) => Sostituzioni.Applica(testo, this, extra);
}

// I segnaposto del formato legacy: &[now(fmt)] data di adesso, +[nome] campo del
// record corrente o parametro, @[nome] parametro di sistema.
public static class Sostituzioni
{
    static readonly Regex Now = new(@"&\[now\(([^)]*)\)\]", RegexOptions.IgnoreCase);
    static readonly Regex Piu = new(@"\+\[([^\]]+)\]");
    static readonly Regex Chiocciola = new(@"@\[([^\]]+)\]");

    /// <summary>"a=1;b=2;" -> {a:1, b:2}</summary>
    public static Dictionary<string, string> ParametriDaStringa(string? s)
    {
        var fuori = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var parte in (s ?? "").Split(';'))
        {
            var i = parte.IndexOf('=');
            if (i > 0) fuori[parte[..i].Trim()] = parte[(i + 1)..].Trim();
        }
        return fuori;
    }

    public static string Applica(string? testo, Contesto ctx, Dictionary<string, string>? extra = null)
    {
        if (string.IsNullOrEmpty(testo)) return testo ?? "";
        var fuori = Now.Replace(testo, m => FormattaAdesso(ctx.Adesso, m.Groups[1].Value));
        fuori = Piu.Replace(fuori, m =>
        {
            var nome = m.Groups[1].Value;
            if (ctx.Record is not null && Cerca(ctx.Record, nome, out var v)) return Segnaposto(v);
            if (extra is not null && extra.TryGetValue(nome, out var e)) return e;
            return ctx.Parametri.TryGetValue(nome, out var p) ? p : m.Value;
        });
        fuori = Chiocciola.Replace(fuori, m => ctx.Sistema.TryGetValue(m.Groups[1].Value, out var v) ? v : m.Value);
        return fuori;
    }

    static bool Cerca(IDictionary<string, object?> r, string nome, out object? v)
    {
        if (r.TryGetValue(nome, out v)) return true;
        foreach (var k in r.Keys) if (string.Equals(k, nome, StringComparison.OrdinalIgnoreCase)) { v = r[k]; return true; }
        v = null; return false;
    }

    // token del legacy: yyyy, yy, mm (mese), dd, hh, ss - i piu' lunghi prima
    static string FormattaAdesso(DateTime d, string fmt) => Regex.Replace(fmt.Trim(), "yyyy|yy|mm|dd|hh|ss", m => m.Value.ToLowerInvariant() switch
    {
        "yyyy" => d.Year.ToString(), "yy" => (d.Year % 100).ToString("00"), "mm" => d.Month.ToString("00"),
        "dd" => d.Day.ToString("00"), "hh" => d.Hour.ToString("00"), _ => d.Second.ToString("00"),
    }, RegexOptions.IgnoreCase);

    // un valore del record dentro un nome file o una query: le date senza
    // separatori (vanno bene sia in SQL Server sia in un nome di file), i numeri col punto
    public static string Segnaposto(object? v) => v switch
    {
        null or DBNull => "",
        DateTime d => d.TimeOfDay == TimeSpan.Zero ? d.ToString("yyyyMMdd") : d.ToString("yyyyMMdd HHmmss"),
        bool b => b ? "1" : "0",
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => v.ToString() ?? "",
    };

    // lo stesso valore in un file di export: date leggibili
    public static string Testo(object? v) => v switch
    {
        null or DBNull => "",
        DateTime d => d.TimeOfDay == TimeSpan.Zero ? d.ToString("dd/MM/yyyy") : d.ToString("dd/MM/yyyy HH:mm:ss"),
        bool b => b ? "1" : "0",
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => v.ToString() ?? "",
    };
}

// Le query degli step: da file (i .sql legacy, ANSI) o scritte direttamente.
public static class Query
{
    static Query() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    public static readonly Encoding Ansi = Encoding.GetEncoding(1252);
    // un percorso si riconosce dalla forma: .\ o ..\ , X:\ , \\server , oppure finisce in .sql
    static readonly Regex SembraPercorso = new(@"^(\.{1,2}[\\/]|[A-Za-z]:[\\/]|\\\\)", RegexOptions.IgnoreCase);
    static readonly Regex Go = new(@"^\s*GO\s*$", RegexOptions.Multiline | RegexOptions.IgnoreCase);

    /// <summary>QuerySQL: un file (".\x.sql" relativo alla cartella script, o assoluto) oppure la query scritta direttamente nello step</summary>
    public static string Carica(string spec, string? cartellaScript)
    {
        spec = (spec ?? "").Trim();
        if (spec == "") throw new Exception("QuerySQL mancante");
        var eFile = !spec.Contains('\n') && (SembraPercorso.IsMatch(spec) || spec.EndsWith(".sql", StringComparison.OrdinalIgnoreCase));
        if (!eFile) return spec;
        var rel = Regex.Replace(spec, @"^\.[\\/]", "");
        var pieno = Path.IsPathRooted(spec) ? spec : Path.Combine(cartellaScript ?? AppContext.BaseDirectory, rel);
        if (!File.Exists(pieno)) throw new FileNotFoundException($"QuerySQL non trovata: {pieno}");
        return Ansi.GetString(File.ReadAllBytes(pieno));
    }

    /// <summary>esegue (anche piu' batch separati da GO); torna le righe dell'ultimo recordset e le righe toccate</summary>
    public static async Task<(List<IDictionary<string, object?>> righe, int interessate, bool conRecordset)> Esegui(Contesto ctx, string sql)
    {
        List<IDictionary<string, object?>> righe = new();
        var interessate = 0; var conRecordset = false;
        foreach (var batch in Go.Split(sql).Where(b => !string.IsNullOrWhiteSpace(b)))
        {
            await using var cmd = new SqlCommand(batch, ctx.Cn) { CommandTimeout = ctx.O.TimeoutQuerySecondi };
            await using var rd = await cmd.ExecuteReaderAsync();
            do
            {
                if (rd.FieldCount > 0)
                {
                    var nomi = Enumerable.Range(0, rd.FieldCount).Select(rd.GetName).ToArray();
                    var lette = new List<IDictionary<string, object?>>();
                    while (await rd.ReadAsync())
                    {
                        var r = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                        for (var i = 0; i < nomi.Length; i++) r[nomi[i]] = rd.IsDBNull(i) ? null : rd.GetValue(i);
                        lette.Add(r);
                    }
                    righe = lette; conRecordset = true;
                }
            } while (await rd.NextResultAsync());
            if (rd.RecordsAffected > 0) interessate += rd.RecordsAffected;
        }
        return (righe, interessate, conRecordset);
    }
}

// Esegue un workflow: step radice in ordine, sottopassi per ogni record delle
// ESEGUIQUERY, avanzamento e log su WF_Esecuzione. Stesso comportamento del
// motore TypeScript di TNOT, piu' il controllo dell'annullamento tra uno step e l'altro.
public static class Esecutore
{
    public static async Task Esegui(Opzioni o, ILogger log, int idEsecuzione, int idWorkflow, string? parametriJson)
    {
        await using var cn = new SqlConnection(o.ConnString);
        await cn.OpenAsync();
        await cn.ExecuteAsync("dbo.WF_usp_Esecuzione_Inizia", new { IdEsecuzione = idEsecuzione, MachineName = o.Macchina }, commandType: CommandType.StoredProcedure);

        var ctx = new Contesto { Cn = cn, O = o, Log = log, IdEsecuzione = idEsecuzione, IdWorkflow = idWorkflow, Parametri = ParametriDaJson(parametriJson) };
        try
        {
            var testa = await cn.QueryFirstOrDefaultAsync("SELECT * FROM dbo.WF_Workflow WHERE IdWorkflow = @id", new { id = idWorkflow })
                ?? throw new Exception($"Workflow {idWorkflow} inesistente");
            ctx.CartellaOutput = (string?)testa.DirectoryOutput;
            var radici = Albero(await cn.QueryAsync(@"
                SELECT IdStep, IdStepPadre, Ordine, NomeSezione, Tipo, EsciSuErrore, EseguiPasso, Attivo, Parametri
                FROM dbo.WF_vw_WorkflowStepAlbero WHERE IdWorkflow = @id ORDER BY Percorso", new { id = idWorkflow }));

            await ctx.Scrivi("INFO", $"Avvio workflow \"{testa.Nome}\" ({radici.Count} step radice) su {o.Macchina}");
            var pausa = (int?)testa.PausaTraStepMS ?? 0;

            for (var i = 0; i < radici.Count; i++)
            {
                if (await Annullata(cn, idEsecuzione))
                {
                    await ctx.Scrivi("WARN", "Esecuzione annullata: mi fermo qui");
                    return;
                }
                if (pausa > 0) await Task.Delay(pausa);
                var step = radici[i];
                try { await EseguiStep(ctx, step); }
                catch (Exception ex)
                {
                    await ctx.Scrivi("ERRORE", $"Step {step.NomeSezione}: {ex.Message}", step.IdStep);
                    if (step.EsciSuErrore) throw;
                }
                await cn.ExecuteAsync("dbo.WF_usp_Esecuzione_Avanzamento",
                    new { IdEsecuzione = idEsecuzione, Avanzamento = (int)Math.Round((i + 1) * 100.0 / radici.Count) }, commandType: CommandType.StoredProcedure);
            }
            await cn.ExecuteAsync("dbo.WF_usp_Esecuzione_Termina", new { IdEsecuzione = idEsecuzione, Stato = 2, Esito = "OK" }, commandType: CommandType.StoredProcedure);
            await ctx.Scrivi("INFO", "Workflow completato");
        }
        catch (Exception ex)
        {
            await ctx.Scrivi("ERRORE", $"Workflow interrotto: {ex.Message}");
            await cn.ExecuteAsync("dbo.WF_usp_Esecuzione_Termina", new { IdEsecuzione = idEsecuzione, Stato = 3, Esito = ex.Message }, commandType: CommandType.StoredProcedure);
        }
    }

    static async Task<bool> Annullata(SqlConnection cn, int idEsecuzione) =>
        await cn.ExecuteScalarAsync<int?>("SELECT Stato FROM dbo.WF_Esecuzione WHERE IdEsecuzione = @id", new { id = idEsecuzione }) == 4;

    // uno step: salto se disattivo, poi il mattoncino del suo tipo; i sottopassi
    // li chiama il mattoncino (ESEGUIQUERY) per ogni record
    public static async Task EseguiStep(Contesto ctx, Step step)
    {
        if (!step.Attivo || !step.EseguiPasso)
        {
            await ctx.Scrivi("INFO", $"Salto {step.NomeSezione} (disattivo)", step.IdStep);
            return;
        }
        await ctx.Scrivi("INFO", $"Step {step.NomeSezione} [{step.Tipo}]", step.IdStep);

        async Task Figli(IDictionary<string, object?> record)
        {
            var c = ctx.ConRecord(record);
            foreach (var f in step.Sottopassi)
            {
                try { await EseguiStep(c, f); }
                catch (Exception ex)
                {
                    await c.Scrivi("ERRORE", $"Sottopasso {f.NomeSezione}: {ex.Message}", f.IdStep);
                    if (f.EsciSuErrore) throw;
                }
            }
        }

        switch (step.Tipo.ToUpperInvariant())
        {
            case "ESEGUIQUERY": await Mattoncini.EseguiQuery(ctx, step, Figli); break;
            case "EXPORTTXT": await Mattoncini.ExportTxt(ctx, step); break;
            case "EXPORTXLS": await Mattoncini.ExportXls(ctx, step); break;
            case "COPYFILE": await Mattoncini.CopyFile(ctx, step); break;
            case "COMPRIMIFILE": await Mattoncini.ComprimiFile(ctx, step); break;
            case "ESEGUISHELL": await Mattoncini.EseguiShell(ctx, step); break;
            case "ESEGUIPYTHON": await Mattoncini.EseguiPython(ctx, step); break;
            case "GENERAREPORT": await Mattoncini.GeneraReport(ctx, step); break;
            case "APRIMAIL": await Mattoncini.ApriMail(ctx, step); break;
            case "IMPORTTXT": await Mattoncini.ImportTxt(ctx, step); break;
            default: await ctx.Scrivi("WARN", $"Tipo {step.Tipo} non gestito dal motore: step saltato", step.IdStep); break;
        }
    }

    static Dictionary<string, string> ParametriDaJson(string? json)
    {
        var fuori = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrWhiteSpace(json)) return fuori;
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind == JsonValueKind.Object)
                foreach (var p in doc.RootElement.EnumerateObject())
                    fuori[p.Name] = p.Value.ValueKind == JsonValueKind.String ? p.Value.GetString() ?? "" : p.Value.GetRawText();
        }
        catch { /* parametri non JSON: come se non ci fossero */ }
        return fuori;
    }

    static List<Step> Albero(IEnumerable<dynamic> righe)
    {
        var nodi = new Dictionary<int, Step>(); var radici = new List<Step>();
        foreach (var r in righe)
        {
            var s = new Step
            {
                IdStep = r.IdStep, IdStepPadre = r.IdStepPadre, Ordine = r.Ordine, NomeSezione = r.NomeSezione, Tipo = r.Tipo,
                EsciSuErrore = r.EsciSuErrore, EseguiPasso = r.EseguiPasso, Attivo = r.Attivo,
            };
            try { s.Parametri = JsonDocument.Parse((string?)r.Parametri ?? "{}").RootElement.Clone(); }
            catch { s.Parametri = JsonDocument.Parse("{}").RootElement.Clone(); }
            nodi[s.IdStep] = s;
        }
        foreach (var s in nodi.Values)   // la vista e' gia' in ordine di Percorso: i figli restano in ordine
        {
            if (s.IdStepPadre is int p && nodi.TryGetValue(p, out var padre)) padre.Sottopassi.Add(s);
            else radici.Add(s);
        }
        return radici;
    }
}
