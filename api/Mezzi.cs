using System.Data;
using System.Text.Json;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

// === Scheda mezzo (la "Mezzi24" del legacy) ===
// Testata e dati Info dalla tabella MEZZI (scrittura via AI_MEZZI_Save); le
// linguette leggono MEZZI_KM (km, driver, foto e posizione presi dall'app),
// MEZZI_FOTO (foto del mezzo), COSTI (carburante e altro per targa),
// MEZZI_Rifornimenti e MEZZI_Telepass, MEZZI_SINISTRI e MEZZI_NOTE (che si
// scrivono con le AI_MEZZI_NOTE_Save / AI_MEZZI_SINISTRI_Save gia' esistenti).
// Le foto stanno sul server nella cartella delle immagini dell'app (Palm_images):
// il file si chiama come la colonna "foto", a volte con un suffisso in piu'.
static class Mezzi
{
    public static void Map(WebApplication app, Func<string> connString)
    {
        // elenco per la navigazione: filtri e testo libero (targa, telaio, modello, assegnatario)
        app.MapGet("/api/mezzi", async (string? testo, int? idFiliale, string? tipo, string? stato) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync(@"
                SELECT m.idMezzo, m.targa, m.codTipoMezzo, t.tipoMezzo AS Tipo, m.marca, m.modello, m.telaio, m.dataImmatricolazione, m.dataDismissione,
                       m.DataRevisione, m.DataBollo, m.DataScadenzaNoleggio, m.idFiliale, f.FILIALE AS Filiale, m.IdUtente, u.Nome AS Assegnatario,
                       m.[Proprietà] AS Proprieta, m.Noleggiatore, m.DataFermo, m.Scorta, m.Rottamato,
                       k.km AS UltimiKm, k.data AS DataUltimiKm, ud.Nome AS DriverAttuale
                FROM dbo.MEZZI m
                LEFT JOIN dbo.MEZZI_TIPI t ON t.codTipoMezzo = m.codTipoMezzo
                LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = m.idFiliale
                LEFT JOIN dbo.UTENTI u ON u.IdUtente = m.IdUtente
                OUTER APPLY (SELECT TOP 1 x.km, x.data, x.IdUtente FROM dbo.MEZZI_KM x WHERE x.targa = m.targa ORDER BY x.data DESC, x.IdMezziKM DESC) k
                LEFT JOIN dbo.UTENTI ud ON ud.IdUtente = k.IdUtente
                WHERE (@idFiliale IS NULL OR m.idFiliale = @idFiliale)
                  AND (@tipo IS NULL OR m.codTipoMezzo = @tipo)
                  AND (@stato = 'tutti' OR (@stato = 'dismessi' AND m.dataDismissione IS NOT NULL) OR (ISNULL(@stato, 'attivi') = 'attivi' AND m.dataDismissione IS NULL))
                  AND (@testo IS NULL OR m.targa LIKE @like OR m.telaio LIKE @like OR m.modello LIKE @like OR m.marca LIKE @like OR u.Nome LIKE @like OR ud.Nome LIKE @like)
                ORDER BY m.targa",
                new { testo = Vuoto(testo), idFiliale, tipo = Vuoto(tipo), stato = Vuoto(stato), like = "%" + (testo ?? "").Trim() + "%" }));
        }).RequireAuthorization();

        app.MapGet("/api/mezzi/lookup", async () =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(new
            {
                tipi = (await cn.QueryAsync("SELECT RTRIM(codTipoMezzo) AS Codice, tipoMezzo AS Descrizione FROM dbo.MEZZI_TIPI ORDER BY codTipoMezzo")).ToList(),
                filiali = (await cn.QueryAsync("SELECT IDFILIALE AS IdFiliale, FILIALE AS Filiale FROM dbo.FILIALI WHERE FILIALE IS NOT NULL ORDER BY FILIALE")).ToList(),
                proprieta = new[] { new { valore = 0, testo = "Di proprietà" }, new { valore = 1, testo = "Noleggio" }, new { valore = 2, testo = "Leasing" } },
                noleggiatori = (await cn.QueryAsync<string>("SELECT DISTINCT Noleggiatore FROM dbo.MEZZI WHERE Noleggiatore IS NOT NULL AND Noleggiatore <> '' ORDER BY Noleggiatore")).ToList(),
                fornitori = (await cn.QueryAsync("SELECT ID AS IdFornitore, Fornitore FROM dbo.FORNITORI WHERE Fornitore IS NOT NULL ORDER BY Fornitore")).ToList(),
                aziende = (await cn.QueryAsync("SELECT IdAzienda, Azienda AS RagioneSociale FROM dbo.AZIENDE ORDER BY Azienda")).ToList(),
            });
        }).RequireAuthorization();

        // una scheda: tutta la riga di MEZZI piu' i nomi
        app.MapGet("/api/mezzi/{id:int}", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            var m = (IDictionary<string, object?>?)await cn.QueryFirstOrDefaultAsync(@"
                SELECT m.*, m.[Proprietà] AS Proprieta, t.tipoMezzo AS Tipo, f.FILIALE AS Filiale, u.Nome AS Assegnatario, u.Matricola,
                       k.km AS UltimiKm, k.data AS DataUltimiKm, ud.Nome AS DriverAttuale,
                       (SELECT COUNT(*) FROM dbo.MEZZI_KM x WHERE x.targa = m.targa) AS NumKm,
                       (SELECT COUNT(*) FROM dbo.MEZZI_FOTO x WHERE x.idMezzo = m.idMezzo OR x.targa = m.targa) AS NumFoto,
                       (SELECT COUNT(*) FROM dbo.COSTI x WHERE x.Targa = m.targa AND x.DataCancellazione IS NULL) AS NumCosti,
                       (SELECT COUNT(*) FROM dbo.MEZZI_SINISTRI x WHERE x.idMezzo = m.idMezzo AND x.DataCancellazione IS NULL) AS NumSinistri,
                       (SELECT COUNT(*) FROM dbo.MEZZI_NOTE x WHERE x.IdMezzo = m.idMezzo) AS NumNote
                FROM dbo.MEZZI m
                LEFT JOIN dbo.MEZZI_TIPI t ON t.codTipoMezzo = m.codTipoMezzo
                LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = m.idFiliale
                LEFT JOIN dbo.UTENTI u ON u.IdUtente = m.IdUtente
                OUTER APPLY (SELECT TOP 1 x.km, x.data, x.IdUtente FROM dbo.MEZZI_KM x WHERE x.targa = m.targa ORDER BY x.data DESC, x.IdMezziKM DESC) k
                LEFT JOIN dbo.UTENTI ud ON ud.IdUtente = k.IdUtente
                WHERE m.idMezzo = @id", new { id });
            if (m is null) return Results.NotFound(new { errore = "Mezzo non trovato" });
            m.Remove("Proprietà");
            return Results.Ok(m);
        }).RequireAuthorization();

        // dalla griglia legacy si arriva con la targa
        app.MapGet("/api/mezzi/targa/{targa}", async (string targa) =>
        {
            await using var cn = new SqlConnection(connString());
            var id = await cn.ExecuteScalarAsync<int?>("SELECT idMezzo FROM dbo.MEZZI WHERE targa = @targa", new { targa = targa.Trim().ToUpperInvariant() });
            return id is null ? Results.NotFound(new { errore = $"Nessun mezzo con targa {targa}" }) : Results.Ok(new { idMezzo = id });
        }).RequireAuthorization();

        app.MapPost("/api/mezzi", (JsonElement b) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var p = new DynamicParameters(new
            {
                targa = Str(b, "targa"), codTipoMezzo = Str(b, "codTipoMezzo"), modello = Str(b, "modello"), marca = Str(b, "marca"), telaio = Str(b, "telaio"),
                dataImmatricolazione = Data(b, "dataImmatricolazione"), dataAcquisto = Data(b, "dataAcquisto"), dataDismissione = Data(b, "dataDismissione"),
                DataRevisione = Data(b, "DataRevisione"), idFiliale = Int(b, "idFiliale"), IdUtente = Int(b, "IdUtente"), Telepass = Str(b, "Telepass"),
                TesseraCarb = Str(b, "TesseraCarb"), Proprieta = Int(b, "Proprieta"), ImportoRata = Num(b, "ImportoRata"), Noleggiatore = Str(b, "Noleggiatore"),
                DataContrattoNoleggio = Data(b, "DataContrattoNoleggio"), Contratto = Str(b, "Contratto"), DataScadenzaNoleggio = Data(b, "DataScadenzaNoleggio"),
                ImportoRiscatto = Num(b, "ImportoRiscatto"), Rottamato = Int(b, "Rottamato"), Scorta = Int(b, "Scorta"), DataBollo = Data(b, "DataBollo"),
                IdAzienda = Int(b, "IdAzienda"), DataScadenzaZTL = Data(b, "DataScadenzaZTL"), ComuneZTL = Str(b, "ComuneZTL"), DataFermo = Data(b, "DataFermo"),
                DKV_idveicolo = Str(b, "DKV_idveicolo"), DKV_trasponder = Str(b, "DKV_trasponder"),
            });
            p.Add("@idMezzo", Int(b, "idMezzo"), DbType.Int32, ParameterDirection.InputOutput);
            await cn.ExecuteAsync("dbo.AI_MEZZI_Save", p, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { idMezzo = p.Get<int>("@idMezzo") });
        })).RequireAuthorization();

        // ---- linguette ----
        // km: ogni rilevazione dell'app con driver, filiale, foto e posizione (ultimi due anni, o l'anno chiesto)
        app.MapGet("/api/mezzi/{id:int}/km", async (int id, int? anno, int? top) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync($@"
                SELECT TOP {Math.Clamp(top ?? 2000, 1, 20000)} k.IdMezziKM, k.data AS Data, k.km AS Km, ISNULL(u.Nome, k.utente) AS Driver, f.FILIALE AS Filiale,
                       k.foto AS Foto, k.latitude AS Latitude, k.longitude AS Longitude, k.idpalmraw AS IdPalmRaw,
                       c.KmPrima AS KmOriginale, c.Data AS DataCorrezione, c.Utente AS CorrettoDa, c.Note AS NotaCorrezione
                FROM dbo.MEZZI m
                JOIN dbo.MEZZI_KM k ON k.targa = m.targa
                LEFT JOIN dbo.UTENTI u ON u.IdUtente = k.IdUtente
                LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = k.idfiliale
                OUTER APPLY (SELECT TOP 1 x.KmPrima, x.Data, x.Utente, x.Note FROM dbo.MEZZI_KM_CORREZIONI x WHERE x.IdMezziKM = k.IdMezziKM ORDER BY x.Data, x.IdCorrezione) c
                WHERE m.idMezzo = @id AND (@anno IS NULL OR YEAR(k.data) = @anno)
                ORDER BY k.data DESC, k.IdMezziKM DESC", new { id, anno }));
        }).RequireAuthorization();

        // correzione di una rilevazione km sbagliata (il valore di prima resta in MEZZI_KM_CORREZIONI)
        app.MapPut("/api/mezzi/km/{idKm:int}", (int idKm, JsonElement b, System.Security.Claims.ClaimsPrincipal user) => Prova(async () =>
        {
            var km = Num(b, "km");
            if (km is null || km < 0) return Results.BadRequest(new { errore = "Km non validi" });
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.AI_MEZZI_KM_Correggi", new { IdMezziKM = idKm, Km = km, Utente = user.Identity?.Name, Note = Str(b, "note") }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { idMezziKM = idKm, km });
        })).RequireAuthorization();

        // log delle modifiche alla riga di MEZZI (trigger TR_INSUP_MEZZI -> LOGTabelle)
        app.MapGet("/api/mezzi/{id:int}/modifiche", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await LogTabelle.Modifiche(cn, "MEZZI", id));
        }).RequireAuthorization();

        // gli anni in cui ci sono km, per il filtro
        app.MapGet("/api/mezzi/{id:int}/km/anni", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync(@"
                SELECT YEAR(k.data) AS Anno, COUNT(*) AS Righe, MIN(k.km) AS KmMin, MAX(k.km) AS KmMax
                FROM dbo.MEZZI m JOIN dbo.MEZZI_KM k ON k.targa = m.targa WHERE m.idMezzo = @id
                GROUP BY YEAR(k.data) ORDER BY 1 DESC", new { id }));
        }).RequireAuthorization();

        app.MapGet("/api/mezzi/{id:int}/foto", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync(@"
                SELECT x.IdMezziFOTO, x.TipoFoto, x.data AS Data, x.foto AS Foto, x.latitude AS Latitude, x.longitude AS Longitude, u.Nome AS Utente, f.FILIALE AS Filiale
                FROM dbo.MEZZI m JOIN dbo.MEZZI_FOTO x ON x.idMezzo = m.idMezzo OR x.targa = m.targa
                LEFT JOIN dbo.UTENTI u ON u.IdUtente = x.IdUtente LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = x.idfiliale
                WHERE m.idMezzo = @id ORDER BY x.data DESC", new { id }));
        }).RequireAuthorization();

        app.MapGet("/api/mezzi/{id:int}/costi", async (int id, int? anno) =>
        {
            await using var cn = new SqlConnection(connString());
            var righe = (await cn.QueryAsync(@"
                SELECT TOP 3000 c.IdCosti, c.DataDoc, c.Tipo, c.Quantita, c.PrezzoUnitario, c.Totale, c.TotaleFinale, RTRIM(c.Fornitore) AS Fornitore, RTRIM(c.NDoc) AS NDoc, c.CDC, c.Noleggio, c.Seriale
                FROM dbo.MEZZI m JOIN dbo.COSTI c ON c.Targa = m.targa
                WHERE m.idMezzo = @id AND c.DataCancellazione IS NULL AND (@anno IS NULL OR YEAR(c.DataDoc) = @anno)
                ORDER BY c.DataDoc DESC, c.IdCosti DESC", new { id, anno })).ToList();
            var perAnno = await cn.QueryAsync(@"
                SELECT YEAR(c.DataDoc) AS Anno, COUNT(*) AS Righe, SUM(ISNULL(c.TotaleFinale, c.Totale)) AS Totale
                FROM dbo.MEZZI m JOIN dbo.COSTI c ON c.Targa = m.targa
                WHERE m.idMezzo = @id AND c.DataCancellazione IS NULL GROUP BY YEAR(c.DataDoc) ORDER BY 1 DESC", new { id });
            return Results.Ok(new { righe, perAnno });
        }).RequireAuthorization();

        app.MapGet("/api/mezzi/{id:int}/altri-costi", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(new
            {
                rifornimenti = (await cn.QueryAsync(@"
                    SELECT TOP 1000 r.IdMezziRif, r.Datatransazione, r.Oratransazione, r.Km, r.Matricolaautista, r.[Località] AS Localita, r.Indirizzo,
                           r.Descrizioneprodotto, r.[Quantità] AS Quantita, r.Prezzodierogazione, r.Importo, r.ImportofatturatoIVAinclusa, r.Numerofattura, r.Datafattura
                    FROM dbo.MEZZI m JOIN dbo.MEZZI_Rifornimenti r ON r.Targa = m.targa WHERE m.idMezzo = @id ORDER BY r.Datatransazione DESC", new { id })).ToList(),
                telepass = (await cn.QueryAsync(@"
                    SELECT TOP 1000 t.IdMezziTelepass, t.Data, t.Telepass, t.TipoMov, t.Passaggio, t.Classe, t.Importo, t.CDC
                    FROM dbo.MEZZI m JOIN dbo.MEZZI_Telepass t ON t.Targa = m.targa WHERE m.idMezzo = @id ORDER BY t.Data DESC", new { id })).ToList(),
            });
        }).RequireAuthorization();

        app.MapGet("/api/mezzi/{id:int}/sinistri", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync(@"
                SELECT s.*, u.Nome AS Utente, d.Nome AS Dipendente, fo.Fornitore AS NomeFornitore
                FROM dbo.MEZZI_SINISTRI s
                LEFT JOIN dbo.UTENTI u ON u.IdUtente = s.IdUtente
                LEFT JOIN dbo.UTENTI d ON d.IdUtente = s.IdDipendenteSpeedy
                LEFT JOIN dbo.FORNITORI fo ON fo.ID = s.IdFornitore
                WHERE s.idMezzo = @id AND s.DataCancellazione IS NULL ORDER BY s.data DESC", new { id }));
        }).RequireAuthorization();

        app.MapGet("/api/mezzi/{id:int}/note", async (int id) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync(@"
                SELECT n.*, u.Nome AS NomeUtente, d.Nome AS Dipendente, fo.Fornitore AS NomeFornitore
                FROM dbo.MEZZI_NOTE n
                LEFT JOIN dbo.UTENTI u ON u.IdUtente = n.IdUtente
                LEFT JOIN dbo.UTENTI d ON d.IdUtente = n.IdDipendenteSpeedy
                LEFT JOIN dbo.FORNITORI fo ON fo.ID = n.IdFornitore
                WHERE n.IdMezzo = @id ORDER BY ISNULL(n.data, n.datainserimento) DESC, n.IdMezzoNota DESC", new { id }));
        }).RequireAuthorization();

        // una nota / manutenzione: la stored esistente (tutti i campi)
        app.MapPost("/api/mezzi/{id:int}/note", (int id, JsonElement b, System.Security.Claims.ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var p = new DynamicParameters(new
            {
                IdMezzo = id, IdUtente = Int(b, "IdUtente"), IdDipendenteSpeedy = Int(b, "IdDipendenteSpeedy"), data = DataOra(b, "data"),
                datainserimento = DateTime.Now, note = Str(b, "note"), utente = user.Identity?.Name, DataFine = DataOra(b, "DataFine"),
                IdFornitore = Int(b, "IdFornitore"), Fornitore = Str(b, "Fornitore"), ImportoPreventivo = Num(b, "ImportoPreventivo"), DataFattura = Data(b, "DataFattura"),
                Seriale = Int(b, "Seriale"), DataInizioFermo = Data(b, "DataInizioFermo"), DataFineFermo = Data(b, "DataFineFermo"),
            });
            p.Add("@IdMezzoNota", Int(b, "IdMezzoNota"), DbType.Int32);   // la stored non lo restituisce: nuova se NULL
            await cn.ExecuteAsync("dbo.AI_MEZZI_NOTE_Save", p, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        // dipendenti per l'assegnatario
        app.MapGet("/api/mezzi/dipendenti", async (string? testo) =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await cn.QueryAsync(@"SELECT TOP 30 IdUtente, Nome, Matricola FROM dbo.UTENTI
                WHERE Nome LIKE @like OR Matricola LIKE @like ORDER BY Nome", new { like = "%" + (testo ?? "").Trim() + "%" }));
        }).RequireAuthorization();

        // la foto scattata dall'app: file jpg nella cartella delle immagini (nome della colonna "foto",
        // a volte con un suffisso in coda). La pagina la chiede con il token e la mostra come blob.
        app.MapGet("/api/mezzi/foto/{nome}", async (string nome, IConfiguration cfg) =>
        {
            if (string.IsNullOrWhiteSpace(nome) || nome.IndexOfAny(new[] { '/', '\\', ':', '*', '?', '"', '<', '>', '|' }) >= 0) return Results.BadRequest(new { errore = "Nome file non valido" });
            var radice = cfg["Percorsi:FotoPalmare"];
            if (string.IsNullOrWhiteSpace(radice))
            {
                await using var cn = new SqlConnection(connString());
                radice = await cn.ExecuteScalarAsync<string?>("SELECT Valore FROM dbo.PARAMETRI WHERE Nome = 'PercorsoFotoPalmare'") ?? @"C:\inetpub\speedyapp\Palm_images";
            }
            var file = TrovaFoto(radice, Path.GetFileNameWithoutExtension(nome));
            if (file is null) return Results.NotFound(new { errore = "Foto non trovata sul server" });
            return Results.File(await File.ReadAllBytesAsync(file), "image/jpeg", enableRangeProcessing: false);
        }).RequireAuthorization();
    }

    // nelle sottocartelle di Palm_images: nome.jpg, altrimenti nome*.jpg (suffisso d'ora in coda)
    static readonly string[] Sottocartelle = { "ritiri", "consegne", "relate", "sconosciuti", "" };
    static string? TrovaFoto(string radice, string nome)
    {
        foreach (var sc in Sottocartelle)
        {
            var dir = sc == "" ? radice : Path.Combine(radice, sc);
            if (!Directory.Exists(dir)) continue;
            var esatto = Path.Combine(dir, nome + ".jpg");
            if (File.Exists(esatto)) return esatto;
            try
            {
                var trovato = Directory.EnumerateFiles(dir, nome + "*.jp*g").OrderBy(f => f).FirstOrDefault();
                if (trovato is not null) return trovato;
            }
            catch { /* cartella non leggibile: si prova la prossima */ }
        }
        return null;
    }

    static string? Vuoto(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    static string? Str(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v)
            ? v.ValueKind switch { JsonValueKind.String => Vuoto(v.GetString()), JsonValueKind.Number => v.GetRawText(), _ => null } : null;
    static int? Int(JsonElement b, string nome)
    {
        if (b.ValueKind != JsonValueKind.Object || !b.TryGetProperty(nome, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number) return v.TryGetInt32(out var n) ? n : (int)v.GetDouble();
        if (v.ValueKind == JsonValueKind.True) return 1;
        if (v.ValueKind == JsonValueKind.False) return 0;
        return int.TryParse(v.ValueKind == JsonValueKind.String ? v.GetString() : null, out var m) ? m : null;
    }
    static double? Num(JsonElement b, string nome)
    {
        if (b.ValueKind != JsonValueKind.Object || !b.TryGetProperty(nome, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number) return v.GetDouble();
        return double.TryParse((v.ValueKind == JsonValueKind.String ? v.GetString() : null)?.Replace(',', '.'), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : null;
    }
    static DateTime? Data(JsonElement b, string nome)
    {
        var s = Str(b, nome);
        if (s is null) return null;
        return DateTime.TryParse(s.Length > 10 ? s[..10] : s, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var d) ? d.Date : null;
    }
    static DateTime? DataOra(JsonElement b, string nome)
    {
        var s = Str(b, nome);
        if (s is null) return null;
        return DateTimeOffset.TryParse(s, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeLocal, out var d) ? d.LocalDateTime : null;
    }
    static async Task<IResult> Prova(Func<Task<IResult>> f)
    {
        try { return await f(); }
        catch (SqlException ex) { return Results.BadRequest(new { errore = ex.Message }); }
    }
}
