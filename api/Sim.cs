using System.Data;
using System.Globalization;
using System.Security.Claims;
using System.Text.Json;
using System.Text.RegularExpressions;
using ClosedXML.Excel;
using Dapper;
using Microsoft.Data.SqlClient;

// === SIM aziendali ===
// Anagrafica delle SIM (tabella SIM), storico dei cambi di piano/stato
// (SIM_VARIAZIONI) e rilevazioni periodiche di consumi e credito dal portale
// Wind (SIM_RILEVAZIONI). Le scritture passano da AI_SIM_*.
// L'import legge gli Excel dell'operatore riconoscendo le colonne dal nome:
// l'elenco SIM (ProdottoSim, NumeroSim, Stato, DataInizio, ICCID, PianoTariffario)
// e la "consistenza" (SERVICE ID, Piano (Wind), Stato SIM, credito, GB, Rilevato il),
// anche insieme nello stesso foglio.
static class Sim
{
    public static void Map(WebApplication app, Func<string> connString)
    {
        // elenco (vista V_Sim), con i filtri della pagina
        app.MapGet("/api/sim", async (string? testo, string? stato, int? idFiliale, string? piano) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync(@"
                SELECT * FROM dbo.V_Sim
                WHERE (@stato IS NULL OR Stato = @stato)
                  AND (@idFiliale IS NULL OR IdFiliale = @idFiliale)
                  AND (@piano IS NULL OR PianoTariffario = @piano)
                  AND (@testo IS NULL OR Numero LIKE @like OR ICCID LIKE @like OR Dipendente LIKE @like
                       OR AssegnataA LIKE @like OR Palmare LIKE @like OR SerialePalmare LIKE @like OR Note LIKE @like)
                ORDER BY Numero",
                new { testo = Vuoto(testo), stato = Vuoto(stato), idFiliale, piano = Vuoto(piano), like = "%" + (testo ?? "").Trim() + "%" }));
        }).RequireAuthorization();

        // tendine: stati e piani presenti, filiali, riepilogo
        app.MapGet("/api/sim/lookup", async () =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(new
            {
                stati = new[] { "Attiva", "Sospesa", "Cessata" },
                statiPresenti = (await cn.QueryAsync<string>("SELECT DISTINCT Stato FROM dbo.SIM ORDER BY Stato")).ToList(),
                piani = (await cn.QueryAsync<string>("SELECT DISTINCT PianoTariffario FROM dbo.SIM WHERE PianoTariffario IS NOT NULL ORDER BY PianoTariffario")).ToList(),
                prodotti = (await cn.QueryAsync<string>("SELECT DISTINCT Prodotto FROM dbo.SIM WHERE Prodotto IS NOT NULL ORDER BY Prodotto")).ToList(),
                filiali = (await cn.QueryAsync("SELECT IDFILIALE AS IdFiliale, FILIALE AS Filiale FROM dbo.FILIALI WHERE FILIALE IS NOT NULL ORDER BY FILIALE")).ToList(),
                totale = await cn.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.SIM"),
                ultimaRilevazione = await cn.ExecuteScalarAsync<DateTime?>("SELECT MAX(DataRilevazione) FROM dbo.SIM_RILEVAZIONI"),
            });
        }).RequireAuthorization();

        // dipendenti per l'assegnazione: cerca per nome o matricola
        app.MapGet("/api/sim/dipendenti", async (string? testo) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync(@"
                SELECT TOP 30 IdUtente, Nome, Matricola FROM dbo.UTENTI
                WHERE Nome LIKE @like OR Matricola LIKE @like ORDER BY Nome", new { like = "%" + (testo ?? "").Trim() + "%" }));
        }).RequireAuthorization();

        // una SIM: anagrafica, variazioni e ultime rilevazioni
        app.MapGet("/api/sim/{id:int}", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            var s = (IDictionary<string, object?>?)await cn.QueryFirstOrDefaultAsync("SELECT * FROM dbo.V_Sim WHERE IdSim = @id", new { id });
            if (s is null) return Results.NotFound(new { errore = "SIM non trovata" });
            s["Variazioni"] = (await cn.QueryAsync("SELECT * FROM dbo.SIM_VARIAZIONI WHERE IdSim = @id ORDER BY Data DESC, IdVariazione DESC", new { id })).ToList();
            s["Rilevazioni"] = (await cn.QueryAsync("SELECT TOP 36 * FROM dbo.SIM_RILEVAZIONI WHERE IdSim = @id ORDER BY DataRilevazione DESC", new { id })).ToList();
            return Results.Ok(s);
        }).RequireAuthorization();

        // salvataggio dalla scheda (nuova o modifica)
        app.MapPost("/api/sim", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var p = new DynamicParameters(new
            {
                Numero = Str(b, "Numero"), ICCID = Str(b, "ICCID"), Operatore = Str(b, "Operatore"), Prodotto = Str(b, "Prodotto"),
                Stato = Str(b, "Stato"), DataAttivazione = Data(b, "DataAttivazione"), DataCessazione = Data(b, "DataCessazione"),
                PianoTariffario = Str(b, "PianoTariffario"), IdFiliale = Int(b, "IdFiliale"), IdUtente = Int(b, "IdUtente"),
                AssegnataA = Str(b, "AssegnataA"), Palmare = Str(b, "Palmare"), SerialePalmare = Str(b, "SerialePalmare"),
                Note = Str(b, "Note"), Utente = user.Identity?.Name, NotaVariazione = Str(b, "NotaVariazione"),
            });
            p.Add("@IdSim", Int(b, "IdSim"), DbType.Int32, ParameterDirection.InputOutput);
            await cn.ExecuteAsync("dbo.AI_SIM_Save", p, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { idSim = p.Get<int>("@IdSim") });
        })).RequireAuthorization();

        app.MapDelete("/api/sim/{id:int}", (int id) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.AI_SIM_Del", new { IdSim = id }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        // import di un Excel dell'operatore: { nome, base64 }
        app.MapPost("/api/sim/import", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var nome = Str(b, "nome") ?? "import.xlsx";
            var bytes = Convert.FromBase64String(Str(b, "base64") ?? "");
            List<Dictionary<string, string>> righe;
            Dictionary<string, string> colonne;
            try { (righe, colonne) = LeggiExcel(bytes); }
            catch (Exception ex) { return Results.BadRequest(new { errore = "File non leggibile: " + ex.Message }); }
            if (!colonne.ContainsKey("numero"))
                return Results.BadRequest(new { errore = "Nel foglio manca la colonna del numero (NumeroSim, SERVICE ID o Numero). Colonne trovate: " + string.Join(", ", righe.Count > 0 ? righe[0].Keys : Array.Empty<string>()) });
            var conAnagrafica = colonne.ContainsKey("piano") || colonne.ContainsKey("iccid") || colonne.ContainsKey("prodotto") || colonne.ContainsKey("stato");
            var conRilevazione = colonne.ContainsKey("rilevato") && (colonne.ContainsKey("gbResidui") || colonne.ContainsKey("credito") || colonne.ContainsKey("gbConsumati"));

            int nuove = 0, aggiornate = 0, invariate = 0, rilevazioni = 0;
            var errori = new List<string>();
            var utente = user.Identity?.Name;
            await using var cn = new SqlConnection(connString());
            await cn.OpenAsync();
            foreach (var (r, i) in righe.Select((r, i) => (r, i)))
            {
                var numero = Numero(r.GetValueOrDefault("numero"));
                if (numero == "") continue;
                try
                {
                    var rilevato = DataCella(r.GetValueOrDefault("rilevato"));
                    var p = new DynamicParameters(new
                    {
                        Numero = numero, ICCID = Vuoto(r.GetValueOrDefault("iccid")), Prodotto = Vuoto(r.GetValueOrDefault("prodotto")),
                        Stato = StatoNormale(r.GetValueOrDefault("stato")), DataAttivazione = DataCella(r.GetValueOrDefault("dataInizio")),
                        PianoTariffario = Vuoto(r.GetValueOrDefault("piano")), DataVariazione = rilevato, FileOrigine = nome, Utente = utente,
                    });
                    p.Add("@IdSim", dbType: DbType.Int32, direction: ParameterDirection.Output);
                    p.Add("@Esito", dbType: DbType.String, size: 20, direction: ParameterDirection.Output);
                    await cn.ExecuteAsync("dbo.AI_SIM_Import", p, commandType: CommandType.StoredProcedure);
                    var idSim = p.Get<int>("@IdSim");
                    switch (p.Get<string>("@Esito")) { case "NUOVA": nuove++; break; case "AGGIORNATA": aggiornate++; break; default: invariate++; break; }

                    if (conRilevazione && rilevato is DateTime dr)
                    {
                        await cn.ExecuteAsync("dbo.AI_SIM_RILEVAZIONE_Save", new
                        {
                            IdSim = idSim, DataRilevazione = dr, PianoTariffario = Vuoto(r.GetValueOrDefault("piano")),
                            Stato = Vuoto(r.GetValueOrDefault("stato")), CreditoResiduo = Decimale(r.GetValueOrDefault("credito")),
                            GbSoglia = Decimale(r.GetValueOrDefault("gbSoglia")), GbConsumati = Decimale(r.GetValueOrDefault("gbConsumati")),
                            GbResidui = Decimale(r.GetValueOrDefault("gbResidui")), PercResidua = Decimale(r.GetValueOrDefault("perc")),
                            PeriodoSoglia = Vuoto(r.GetValueOrDefault("periodo")), FileOrigine = nome,
                        }, commandType: CommandType.StoredProcedure);
                        rilevazioni++;
                    }
                }
                catch (Exception ex) { errori.Add($"riga {i + 2} ({numero}): {ex.Message}"); }
            }
            return Results.Ok(new
            {
                file = nome, righe = righe.Count, anagrafica = conAnagrafica, rilevazione = conRilevazione,
                colonne = colonne.Keys.OrderBy(k => k).ToList(), nuove, aggiornate, invariate, rilevazioni, errori,
            });
        })).RequireAuthorization();
    }

    // ---- lettura dell'Excel: prima riga = intestazioni, riconosciute dal nome ----
    static readonly (string chiave, string[] nomi)[] Colonne =
    {
        ("numero", new[] { "numerosim", "service id", "numero", "msisdn", "numero sim" }),
        ("iccid", new[] { "iccid" }),
        ("prodotto", new[] { "prodottosim", "nome del prodotto", "prodotto" }),
        ("stato", new[] { "stato sim", "stato" }),
        ("dataInizio", new[] { "datainizio", "data inizio", "data attivazione", "dataattivazione" }),
        ("piano", new[] { "piano (wind)", "pianotariffario", "piano tariffario", "piano" }),
        ("credito", new[] { "credito residuo (wind)", "credito residuo", "credito" }),
        ("gbSoglia", new[] { "gb soglia", "soglia dati", "soglia" }),
        ("gbConsumati", new[] { "gb consumati", "consumati" }),
        ("gbResidui", new[] { "gb residui (wind)", "gb residui", "residui" }),
        ("perc", new[] { "% residua (wind)", "% residua", "perc residua" }),
        ("periodo", new[] { "periodo soglia (wind)", "periodo soglia", "periodo" }),
        ("rilevato", new[] { "rilevato il (wind)", "rilevato il", "data rilevazione", "rilevato" }),
    };

    static (List<Dictionary<string, string>> righe, Dictionary<string, string> colonne) LeggiExcel(byte[] bytes)
    {
        using var ms = new MemoryStream(bytes);
        using var wb = new XLWorkbook(ms);
        var ws = wb.Worksheets.First();
        var prima = ws.FirstRowUsed() ?? throw new Exception("foglio vuoto");
        var intestazioni = new Dictionary<int, string>();
        foreach (var c in prima.CellsUsed()) intestazioni[c.Address.ColumnNumber] = c.GetString().Trim();
        // nome dell'intestazione -> chiave logica (la prima che combacia vince: "piano (wind)" prima di "piano")
        var colonne = new Dictionary<string, string>();
        foreach (var (chiave, nomi) in Colonne)
            foreach (var n in nomi)
            {
                var trovata = intestazioni.FirstOrDefault(kv => kv.Value.Equals(n, StringComparison.OrdinalIgnoreCase));
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

    // ---- attrezzi ----
    static string Numero(string? s)
    {
        s = (s ?? "").Trim();
        if (s.Contains('E') && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d)) s = d.ToString("F0", CultureInfo.InvariantCulture);
        if (s.EndsWith(".0")) s = s[..^2];
        return Regex.Replace(s, @"\s|\+", "");
    }
    static string? StatoNormale(string? s)
    {
        var v = (s ?? "").Trim().ToLowerInvariant();
        if (v == "") return null;
        if (v.StartsWith("att") || v.StartsWith("act")) return "Attiva";
        if (v.StartsWith("sosp") || v.StartsWith("susp")) return "Sospesa";
        if (v.StartsWith("cess") || v.StartsWith("deact") || v.StartsWith("disatt") || v.StartsWith("ceas")) return "Cessata";
        return s!.Trim();
    }
    static DateTime? DataCella(string? s)
    {
        s = (s ?? "").Trim();
        if (s == "") return null;
        if (DateTime.TryParseExact(s, new[] { "yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "dd/MM/yyyy", "d/M/yyyy", "dd/MM/yyyy HH:mm:ss" }, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)) return d.Date;
        if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) && n > 20000 && n < 80000) return DateTime.FromOADate(n).Date;
        return null;
    }
    static decimal? Decimale(string? s)
    {
        s = Regex.Replace((s ?? "").Trim(), @"[^\d,.\-]", "");   // via euro, spazi, simboli
        if (s == "") return null;
        if (s.Contains(',') && !s.Contains('.')) s = s.Replace(',', '.');
        else if (s.Contains(',') && s.Contains('.')) s = s.Replace(".", "").Replace(',', '.');
        return decimal.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? Math.Round(d, 3) : null;
    }
    static string? Vuoto(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    static string? Str(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v)
            ? v.ValueKind switch { JsonValueKind.String => Vuoto(v.GetString()), JsonValueKind.Number => v.GetRawText(), _ => null } : null;
    static int? Int(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v)
            ? v.ValueKind == JsonValueKind.Number ? v.GetInt32() : int.TryParse(v.ValueKind == JsonValueKind.String ? v.GetString() : null, out var n) ? n : null : null;
    static DateTime? Data(JsonElement b, string nome) => DataCella(Str(b, nome)?[..Math.Min(10, Str(b, nome)!.Length)]);

    static async Task<IResult> Prova(Func<Task<IResult>> f)
    {
        try { return await f(); }
        catch (SqlException ex) { return Results.BadRequest(new { errore = ex.Message }); }
        catch (FormatException ex) { return Results.BadRequest(new { errore = ex.Message }); }
    }
}
