using System.Data;
using System.Globalization;
using System.Security.Claims;
using System.Text.Json;
using System.Text.RegularExpressions;
using ClosedXML.Excel;
using Dapper;
using Microsoft.Data.SqlClient;

// === Palmari aziendali ===
// Anagrafica dei dispositivi (tabella PALMARI) dal file "Device List" di Knox
// Manage, collegamento alla SIM (per ICCID o numero), alla filiale (dal tag
// Knox quando corrisponde a una filiale sola) e all'uso quotidiano dei driver,
// che l'app registra in UTENTI_ATTIVITA.Palmare con l'Android ID: quello non
// sta nel file Knox e si abbina dalla scheda. Scritture via AI_PALMARI_*.
static class Palmari
{
    public static void Map(WebApplication app, Func<string> connString)
    {
        app.MapGet("/api/palmari", async (string? testo, string? tag, int? idFiliale, string? modello, string? stato, bool? conSim, bool? abbinato) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await Elenco(cn, testo, tag, idFiliale, modello, stato, conSim, abbinato));
        }).RequireAuthorization();

        // lo stesso elenco, con gli stessi filtri, in Excel
        app.MapGet("/api/palmari/export", async (string? testo, string? tag, int? idFiliale, string? modello, string? stato, bool? conSim, bool? abbinato) =>
        {
            await using var cn = new SqlConnection(connString());
            var righe = await Elenco(cn, testo, tag, idFiliale, modello, stato, conSim, abbinato);
            return Esporta.Xlsx(righe, "Palmari", "palmari", new[] {
                ("Filiale", "Filiale"), ("Seriale", "Seriale"), ("Nome device", "NomeDevice"), ("Modello", "Modello"), ("Android", "VersioneOS"), ("Tag Knox", "Tag"), ("Stato", "Stato"),
                ("SIM", "SimNumero"), ("Piano SIM", "SimPiano"), ("Stato SIM", "SimStato"), ("ICCID", "ICCID"), ("IMEI", "Imei"), ("Android ID", "AndroidId"),
                ("Ultimo uso", "UltimoUso"), ("Ultimo driver", "UltimoDriver"), ("Filiale ultimo uso", "UltimaFiliale"), ("Giorni d'uso (30)", "GiorniUso30"),
                ("Posizione (data)", "PosizioneData"), ("Utente Knox", "UtenteMdm"), ("Stato Knox", "StatoMdm"), ("Ultimo contatto Knox", "UltimoContatto"), ("Segnalazione Knox", "Problema"), ("Note", "Note") });
        }).RequireAuthorization();

        // tendine, riepilogo e gli Android ID visti dall'app ma non ancora abbinati a un palmare
        app.MapGet("/api/palmari/lookup", async () =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(new
            {
                stati = new[] { "In uso", "Scorta", "Guasto", "Dismesso" },
                tags = (await cn.QueryAsync<string>("SELECT DISTINCT Tag FROM dbo.PALMARI WHERE Tag IS NOT NULL ORDER BY Tag")).ToList(),
                modelli = (await cn.QueryAsync<string>("SELECT DISTINCT Modello FROM dbo.PALMARI WHERE Modello IS NOT NULL ORDER BY Modello")).ToList(),
                filiali = (await cn.QueryAsync("SELECT IDFILIALE AS IdFiliale, FILIALE AS Filiale FROM dbo.FILIALI WHERE FILIALE IS NOT NULL ORDER BY FILIALE")).ToList(),
                totale = await cn.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.PALMARI"),
                ultimoImport = await cn.ExecuteScalarAsync<DateTime?>("SELECT MAX(DataImport) FROM dbo.PALMARI"),
                // ultimi 90 giorni di attivita' e di eventi dell'app, per abbinare a mano
                androidNonAbbinati = (await cn.QueryAsync(@"
                    SELECT x.AndroidId, MAX(x.Quando) AS UltimoUso, MAX(x.Driver) AS UltimoDriver, MAX(x.Filiale) AS Filiale, MAX(x.Modello) AS Modello, COUNT(*) AS Eventi
                    FROM (
                        SELECT a.Palmare AS AndroidId, CAST(a.data AS DATETIME) AS Quando, u.Nome AS Driver, f.FILIALE AS Filiale, CAST(NULL AS VARCHAR(50)) AS Modello
                        FROM dbo.UTENTI_ATTIVITA a LEFT JOIN dbo.UTENTI u ON u.IdUtente = a.idUtente LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = a.idFiliale
                        WHERE a.Palmare IS NOT NULL AND a.Palmare <> '' AND a.data >= DATEADD(day, -90, GETDATE())
                        UNION ALL
                        SELECT r.imei, r.datainserimento, r.driver, JSON_VALUE(r.datijson, '$.filiale'), JSON_VALUE(r.datijson, '$.phoneModel')
                        FROM dbo.PALM_RAW r WHERE r.imei IS NOT NULL AND r.imei <> '' AND r.datainserimento >= DATEADD(day, -90, GETDATE()) AND ISJSON(r.datijson) = 1
                    ) x
                    WHERE NOT EXISTS (SELECT 1 FROM dbo.PALMARI p WHERE p.AndroidId = x.AndroidId)
                    GROUP BY x.AndroidId ORDER BY MAX(x.Quando) DESC")).ToList(),
            });
        }).RequireAuthorization();

        // un palmare: scheda, SIM, uso quotidiano (ultimi 90 giorni), variazioni
        app.MapGet("/api/palmari/{id:int}", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            var p = (IDictionary<string, object?>?)await cn.QueryFirstOrDefaultAsync("SELECT * FROM dbo.V_Palmari WHERE IdPalmare = @id", new { id });
            if (p is null) return Results.NotFound(new { errore = "Palmare non trovato" });
            p["Sim"] = p["IdSim"] is int idSim ? await cn.QueryFirstOrDefaultAsync("SELECT * FROM dbo.V_Sim WHERE IdSim = @idSim", new { idSim }) : null;
            p["Utilizzo"] = p["AndroidId"] is string aid ? (await cn.QueryAsync(@"
                SELECT a.data AS Data, a.idUtente AS IdUtente, u.Nome AS Driver, f.FILIALE AS Filiale, a.codPresenza AS Presenza, a.Login, a.Logout, a.KmPercorsi
                FROM dbo.UTENTI_ATTIVITA a LEFT JOIN dbo.UTENTI u ON u.IdUtente = a.idUtente LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = a.idFiliale
                WHERE a.Palmare = @aid AND a.data >= DATEADD(day, -90, GETDATE()) ORDER BY a.data DESC", new { aid })).ToList() : new List<dynamic>();
            p["Variazioni"] = (await cn.QueryAsync("SELECT * FROM dbo.PALMARI_VARIAZIONI WHERE IdPalmare = @id ORDER BY DataRegistrazione DESC", new { id })).ToList();
            p["Posizioni"] = (await cn.QueryAsync("SELECT TOP 200 DataOra, Latitudine, Longitudine, Origine, FileOrigine FROM dbo.PALMARI_POSIZIONI WHERE IdPalmare = @id ORDER BY DataOra DESC", new { id })).ToList();
            return Results.Ok(p);
        }).RequireAuthorization();

        app.MapPost("/api/palmari", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var p = new DynamicParameters(new
            {
                Seriale = Str(b, "Seriale"), Imei = Str(b, "Imei"), Imei2 = Str(b, "Imei2"), Mac = Str(b, "Mac"), AndroidId = Str(b, "AndroidId"),
                NomeDevice = Str(b, "NomeDevice"), Alias = Str(b, "Alias"), Modello = Str(b, "Modello"), Produttore = Str(b, "Produttore"),
                Tag = Str(b, "Tag"), NumeroMobile = Str(b, "NumeroMobile"), ICCID = Str(b, "ICCID"), IdSim = Int(b, "IdSim"), IdFiliale = Int(b, "IdFiliale"),
                Stato = Str(b, "Stato"), Note = Str(b, "Note"), Utente = user.Identity?.Name,
            });
            p.Add("@IdPalmare", Int(b, "IdPalmare"), DbType.Int32, ParameterDirection.InputOutput);
            await cn.ExecuteAsync("dbo.AI_PALMARI_Save", p, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { idPalmare = p.Get<int>("@IdPalmare") });
        })).RequireAuthorization();

        app.MapDelete("/api/palmari/{id:int}", (int id) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.AI_PALMARI_Del", new { IdPalmare = id }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        // SIM da agganciare: cerca per numero o ICCID
        app.MapGet("/api/palmari/sim", async (string? testo) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync(@"SELECT TOP 30 IdSim, Numero, ICCID, PianoTariffario, Stato FROM dbo.SIM
                WHERE Numero LIKE @like OR ICCID LIKE @like ORDER BY Numero", new { like = "%" + (testo ?? "").Trim() + "%" }));
        }).RequireAuthorization();

        // import del "Device List" di Knox Manage: { nome, base64 }
        app.MapPost("/api/palmari/import", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var nome = Str(b, "nome") ?? "import.xlsx";
            var bytes = Convert.FromBase64String(Str(b, "base64") ?? "");
            List<Dictionary<string, string>> righe; Dictionary<string, string> colonne;
            try { (righe, colonne) = LeggiExcel(bytes); }
            catch (Exception ex) { return Results.BadRequest(new { errore = "File non leggibile: " + ex.Message }); }
            if (!colonne.ContainsKey("seriale"))
                return Results.BadRequest(new { errore = "Nel foglio manca la colonna del seriale (Serial Number). Colonne trovate: " + string.Join(", ", colonne.Values) });

            await using var cn = new SqlConnection(connString());
            await cn.OpenAsync();
            var filiali = (await cn.QueryAsync("SELECT IDFILIALE AS IdFiliale, FILIALE AS Filiale FROM dbo.FILIALI WHERE FILIALE IS NOT NULL"))
                .Select(f => ((int)f.IdFiliale, (string)f.Filiale)).ToList();
            var alias = await Alias(cn);
            int nuovi = 0, aggiornati = 0, invariati = 0, posizioni = 0; var errori = new List<string>(); var tagSenzaFiliale = new SortedSet<string>();
            var utente = user.Identity?.Name;
            foreach (var (r, i) in righe.Select((r, i) => (r, i)))
            {
                var seriale = (r.GetValueOrDefault("seriale") ?? "").Trim();
                if (seriale == "") continue;
                try
                {
                    var imei = (r.GetValueOrDefault("imei") ?? "").Split(',').Select(x => x.Trim()).Where(x => x != "").ToList();
                    var tag = Vuoto(r.GetValueOrDefault("tag"));
                    var idFiliale = FilialeDalTag(tag, filiali, alias);
                    if (tag is not null && idFiliale is null) tagSenzaFiliale.Add(tag);
                    var p = new DynamicParameters(new
                    {
                        Seriale = seriale, Imei = imei.ElementAtOrDefault(0), Imei2 = imei.ElementAtOrDefault(1), Mac = Vuoto(r.GetValueOrDefault("mac")),
                        NomeDevice = Vuoto(r.GetValueOrDefault("nome")), Alias = Vuoto(r.GetValueOrDefault("alias")), Modello = Vuoto(r.GetValueOrDefault("modello")),
                        Produttore = Vuoto(r.GetValueOrDefault("produttore")), Piattaforma = Vuoto(r.GetValueOrDefault("piattaforma")),
                        VersioneOS = Vuoto(r.GetValueOrDefault("os")), VersioneAgent = Vuoto(r.GetValueOrDefault("agent")), Firmware = Vuoto(r.GetValueOrDefault("firmware")),
                        StatoMdm = Vuoto(r.GetValueOrDefault("statoMdm")), TipoGestione = Vuoto(r.GetValueOrDefault("gestione")), TipoEnrollment = Vuoto(r.GetValueOrDefault("enrollment")),
                        Organizzazione = Vuoto(r.GetValueOrDefault("organizzazione")), Profilo = Vuoto(r.GetValueOrDefault("profilo")), UtenteMdm = Vuoto(r.GetValueOrDefault("utenteMdm")),
                        Tag = tag, NumeroMobile = Numero(r.GetValueOrDefault("numero")), ICCID = Vuoto(r.GetValueOrDefault("iccid")), EID = Vuoto(r.GetValueOrDefault("eid")),
                        Problema = Vuoto(r.GetValueOrDefault("problema")), UltimoComando = Vuoto(r.GetValueOrDefault("comando")),
                        Roaming = r.GetValueOrDefault("roaming") is string ro && ro != "" ? ro.Trim().ToUpperInvariant() is "Y" or "YES" or "SI" or "1" : (bool?)null,
                        UltimoContatto = Vuoto(r.GetValueOrDefault("ultimoContatto")), UltimoAggiornamentoMdm = DataCella(r.GetValueOrDefault("aggiornato")),
                        CodiceKiosk = Vuoto(r.GetValueOrDefault("kiosk")), CodiceUnenroll = Vuoto(r.GetValueOrDefault("unenroll")), CodiceSblocco = Vuoto(r.GetValueOrDefault("sblocco")),
                        Email = Vuoto(r.GetValueOrDefault("email")), Gruppi = Vuoto(r.GetValueOrDefault("gruppi")), ProfiliAssegnati = Vuoto(r.GetValueOrDefault("profiliAssegnati")),
                        IdFiliale = idFiliale, Utente = utente,
                    });
                    p.Add("@IdPalmare", dbType: DbType.Int32, direction: ParameterDirection.Output);
                    p.Add("@Esito", dbType: DbType.String, size: 20, direction: ParameterDirection.Output);
                    await cn.ExecuteAsync("dbo.AI_PALMARI_Import", p, commandType: CommandType.StoredProcedure);
                    switch (p.Get<string>("@Esito")) { case "NUOVO": nuovi++; break; case "AGGIORNATO": aggiornati++; break; default: invariati++; break; }
                    // "Last Location": 40.7292339, 8.5308784 (2026-09-06 21:52:51)
                    var pos = Posizione(r.GetValueOrDefault("posizione"));
                    if (pos is not null)
                    {
                        var q = new DynamicParameters(new { IdPalmare = p.Get<int>("@IdPalmare"), DataOra = pos.Value.quando, Latitudine = pos.Value.lat, Longitudine = pos.Value.lng, Origine = "KNOX", FileOrigine = nome });
                        q.Add("@Nuova", dbType: DbType.Boolean, direction: ParameterDirection.Output);
                        await cn.ExecuteAsync("dbo.AI_PALMARI_POSIZIONE_Save", q, commandType: CommandType.StoredProcedure);
                        if (q.Get<bool>("@Nuova")) posizioni++;
                    }
                }
                catch (Exception ex) { errori.Add($"riga {i + 2} ({seriale}): {ex.Message}"); }
            }
            var senzaSim = await cn.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.PALMARI WHERE IdSim IS NULL AND ICCID IS NOT NULL");
            return Results.Ok(new { file = nome, righe = righe.Count, colonne = colonne.Keys.OrderBy(k => k).ToList(), nuovi, aggiornati, invariati, posizioni, errori,
                                    tagSenzaFiliale = tagSenzaFiliale.ToList(), iccidSenzaSim = senzaSim });
        })).RequireAuthorization();
    }

    // gli alias tag -> filiale scritti in LISTA_VALORI (PALMARI_TAG_FILIALE: Valore = tag, Codice = IDFILIALE)
    static async Task<Dictionary<string, int>> Alias(SqlConnection cn)
    {
        var righe = await cn.QueryAsync("SELECT Valore, Codice FROM dbo.LISTA_VALORI WHERE Lista = 'PALMARI_TAG_FILIALE'");
        var d = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in righe) if (int.TryParse(((string?)r.Codice ?? "").Trim(), out var id)) d[((string)r.Valore).Trim()] = id;
        return d;
    }

    // Il tag Knox e' scritto come il nome della filiale, o quasi: prima gli alias,
    // poi il confronto sui nomi per parole (via i prefissi TOSC/SARD/LINEA/EXT e i
    // trattini): vale se una filiale sola contiene tutte le parole del tag.
    // Con OLBIA vince "SARD - OLBIA" e non "SARD - SDA OLBIA", a meno che il tag non dica SDA.
    static int? FilialeDalTag(string? tag, List<(int id, string nome)> filiali, Dictionary<string, int>? alias = null)
    {
        if (string.IsNullOrWhiteSpace(tag)) return null;
        var t = tag.Trim();
        if (alias is not null && alias.TryGetValue(t, out var daAlias)) return daAlias;
        var parole = Parole(t);
        if (parole.Count == 0) return null;
        var conSda = parole.Contains("SDA");
        var candidate = filiali.Where(f => { var pf = Parole(f.nome); return parole.All(p => pf.Contains(p)); }).ToList();
        candidate = candidate.Where(f => Parole(f.nome).Contains("SDA") == conSda).ToList();
        if (candidate.Count > 1) candidate = candidate.Where(f => !Regex.IsMatch(f.nome, @"^(EXT|LINEA)\b", RegexOptions.IgnoreCase)).ToList();
        if (candidate.Count > 1)   // piu' filiali: quella col nome piu' corto e' la piu' vicina al tag
        {
            var minimo = candidate.Min(f => Parole(f.nome).Count);
            candidate = candidate.Where(f => Parole(f.nome).Count == minimo).ToList();
        }
        return candidate.Count == 1 ? candidate[0].id : null;
    }
    static readonly HashSet<string> Prefissi = new(StringComparer.OrdinalIgnoreCase) { "TOSC", "SARD", "LINEA", "EXT", "DI", "DEL", "DELLA" };
    static HashSet<string> Parole(string s) =>
        new(Regex.Split(s.ToUpperInvariant().Replace("/", " "), @"[^A-Z0-9]+").Where(p => p.Length > 0 && !Prefissi.Contains(p)));

    static readonly (string chiave, string[] nomi)[] Colonne =
    {
        ("statoMdm", new[] { "status", "stato" }), ("ultimoContatto", new[] { "last seen" }), ("nome", new[] { "device name", "nome device", "nome" }),
        ("alias", new[] { "device nickname (alias)", "alias" }), ("problema", new[] { "issue" }), ("imei", new[] { "imei / meid", "imei" }),
        ("seriale", new[] { "serial number", "seriale", "serial" }), ("utenteMdm", new[] { "user name", "utente" }), ("tag", new[] { "device tag", "tag" }),
        ("piattaforma", new[] { "platform" }), ("gestione", new[] { "management type" }), ("numero", new[] { "mobile number", "numero" }),
        ("enrollment", new[] { "enrolled type" }), ("modello", new[] { "model name", "modello", "model" }), ("agent", new[] { "agent version" }),
        ("os", new[] { "os version" }), ("mac", new[] { "mac address", "mac" }), ("firmware", new[] { "firmware version" }), ("produttore", new[] { "manufacturer" }),
        ("roaming", new[] { "roaming" }), ("comando", new[] { "last device command" }), ("organizzazione", new[] { "organization name" }),
        ("profilo", new[] { "profile name & version", "profile" }), ("iccid", new[] { "iccid information", "iccid" }), ("eid", new[] { "eid" }),
        ("aggiornato", new[] { "last updated" }), ("kiosk", new[] { "exit kiosk code" }), ("unenroll", new[] { "unenrollment code" }), ("sblocco", new[] { "unlock code" }),
        ("email", new[] { "email" }), ("gruppi", new[] { "assigned group" }), ("profiliAssegnati", new[] { "assigned profiles" }),
        ("posizione", new[] { "last location", "location" }),   // "Last Location (UTC+02:00)": combacia anche con il fuso in coda
    };

    static readonly Regex RePosizione = new(@"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\((\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2})?)\)");
    static (DateTime quando, decimal lat, decimal lng)? Posizione(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        var m = RePosizione.Match(s);
        if (!m.Success) return null;
        if (!decimal.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var lat)) return null;
        if (!decimal.TryParse(m.Groups[2].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var lng)) return null;
        if (!DateTime.TryParse(m.Groups[3].Value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var quando)) return null;
        if (lat == 0 && lng == 0) return null;
        return (quando, Math.Round(lat, 6), Math.Round(lng, 6));
    }

    static (List<Dictionary<string, string>> righe, Dictionary<string, string> colonne) LeggiExcel(byte[] bytes)
    {
        using var ms = new MemoryStream(bytes);
        using var wb = new XLWorkbook(ms);
        var ws = wb.Worksheets.First();
        var prima = ws.FirstRowUsed() ?? throw new Exception("foglio vuoto");
        var intestazioni = new Dictionary<int, string>();
        foreach (var c in prima.CellsUsed()) intestazioni[c.Address.ColumnNumber] = c.GetString().Trim();
        var colonne = new Dictionary<string, string>();
        foreach (var (chiave, nomi) in Colonne)
            foreach (var n in nomi)
            {
                var trovata = intestazioni.FirstOrDefault(kv => kv.Value.Equals(n, StringComparison.OrdinalIgnoreCase) || kv.Value.StartsWith(n + " (", StringComparison.OrdinalIgnoreCase));
                if (trovata.Value is not null && !colonne.ContainsKey(chiave) && !colonne.ContainsValue(trovata.Value)) { colonne[chiave] = trovata.Value; break; }
            }
        var indice = colonne.ToDictionary(kv => kv.Key, kv => intestazioni.First(x => x.Value == kv.Value).Key);
        var righe = new List<Dictionary<string, string>>();
        foreach (var riga in ws.RowsUsed().Skip(1))
        {
            var r = new Dictionary<string, string>();
            foreach (var (chiave, col) in indice)
            {
                var cella = riga.Cell(col);
                r[chiave] = cella.DataType == XLDataType.DateTime ? cella.GetDateTime().ToString("yyyy-MM-dd")
                          : cella.DataType == XLDataType.Number ? cella.GetDouble().ToString(CultureInfo.InvariantCulture)
                          : cella.GetString().Trim();
            }
            if (r.Values.Any(v => v != "")) righe.Add(r);
        }
        return (righe, colonne);
    }

    // "'+393386270521" -> "3386270521", come sta in SIM.Numero
    static string? Numero(string? s)
    {
        s = Regex.Replace((s ?? "").Trim(), @"[^\d]", "");
        if (s.StartsWith("0039")) s = s[4..]; else if (s.StartsWith("39") && s.Length > 10) s = s[2..];
        return s == "" ? null : s;
    }
    static DateTime? DataCella(string? s)
    {
        s = (s ?? "").Trim();
        if (s == "") return null;
        if (DateTime.TryParseExact(s, new[] { "yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "dd/MM/yyyy", "d/M/yyyy" }, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)) return d.Date;
        if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) && n > 20000 && n < 80000) return DateTime.FromOADate(n).Date;
        return null;
    }
    // l'elenco della pagina (vista V_Palmari) coi filtri: lo usano l'API e l'export
    static async Task<IEnumerable<dynamic>> Elenco(SqlConnection cn, string? testo, string? tag, int? idFiliale, string? modello, string? stato, bool? conSim, bool? abbinato) =>
        await cn.QueryAsync(@"
            SELECT IdPalmare, Seriale, Imei, AndroidId, NomeDevice, Alias, Modello, VersioneOS, VersioneAgent, StatoMdm, UtenteMdm, Tag, Profilo,
                   NumeroMobile, ICCID, IdSim, IdFiliale, Filiale, Problema, UltimoContatto, UltimoAggiornamentoMdm, Stato, Note,
                   SimNumero, SimPiano, SimStato, SimPercResidua, UltimoUso, UltimoDriver, UltimaFiliale, GiorniUso30, UltimoEventoApp, VersioneApp,
                   PosizioneData, PosizioneLat, PosizioneLng, AppLat, AppLng
            FROM dbo.V_Palmari
            WHERE (@tag IS NULL OR Tag = @tag) AND (@idFiliale IS NULL OR IdFiliale = @idFiliale)
              AND (@modello IS NULL OR Modello = @modello) AND (@stato IS NULL OR Stato = @stato)
              AND (@conSim IS NULL OR (@conSim = 1 AND IdSim IS NOT NULL) OR (@conSim = 0 AND IdSim IS NULL))
              AND (@abbinato IS NULL OR (@abbinato = 1 AND AndroidId IS NOT NULL) OR (@abbinato = 0 AND AndroidId IS NULL))
              AND (@testo IS NULL OR Seriale LIKE @like OR Imei LIKE @like OR AndroidId LIKE @like OR NomeDevice LIKE @like OR Alias LIKE @like
                   OR NumeroMobile LIKE @like OR SimNumero LIKE @like OR ICCID LIKE @like OR UtenteMdm LIKE @like OR UltimoDriver LIKE @like OR Note LIKE @like OR Mac LIKE @like)
            ORDER BY Filiale, Seriale",
            new { testo = Vuoto(testo), tag = Vuoto(tag), idFiliale, modello = Vuoto(modello), stato = Vuoto(stato), conSim, abbinato, like = "%" + (testo ?? "").Trim() + "%" });

    static string? Vuoto(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    static string? Str(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v)
            ? v.ValueKind switch { JsonValueKind.String => Vuoto(v.GetString()), JsonValueKind.Number => v.GetRawText(), _ => null } : null;
    static int? Int(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v)
            ? v.ValueKind == JsonValueKind.Number ? v.GetInt32() : int.TryParse(v.ValueKind == JsonValueKind.String ? v.GetString() : null, out var n) ? n : null : null;

    static async Task<IResult> Prova(Func<Task<IResult>> f)
    {
        try { return await f(); }
        catch (SqlException ex) { return Results.BadRequest(new { errore = ex.Message }); }
        catch (FormatException ex) { return Results.BadRequest(new { errore = ex.Message }); }
    }
}
