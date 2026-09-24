using System.Data;
using System.Globalization;
using System.Security.Claims;
using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;

// === Giri della filiale (pagina "Giri", ex videata legacy "Creazione giri su Mappa") ===
// Un giro e' un'area (GEO_GIRI.SHAPE, poligono WGS84) con cui GEO_AssegnaGIRI assegna le spedizioni
// del giorno: prima per CAP fisso, poi per comune fisso, poi per punto dentro l'area. Qui ci sono
// l'elenco coi conteggi del giorno, i comuni della filiale coi confini, le spedizioni geolocalizzate
// (V_ElencoGeoSped), la creazione (disegno a mano o unione di comuni), la modifica di un giro
// esistente (campi, confine, chiusura) con lo storico in GEO_GIRI_VARIAZIONI, e l'assegnazione.
// Le scritture passano da AI_GEO_CreaGiro, AI_GEO_CreaGiroDaComuni, AI_GEO_GIRO_Save,
// AI_GEO_GIRO_Comuni e dalla legacy GEO_AssegnaGIRI.
static class Giri
{
    class ErroreGiri : Exception { public ErroreGiri(string m) : base(m) { } }

    static int Filiale(ClaimsPrincipal user) =>
        int.TryParse(user.FindFirstValue("idFiliale"), out var f) ? f : throw new ErroreGiri("Filiale non disponibile");

    public static void Map(WebApplication app, Func<string> connString)
    {
        // centro mappa = coordinate della filiale corrente (fallback Toscana)
        app.MapGet("/api/giri/init", (ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            await using var cn = new SqlConnection(connString());
            var f = await cn.QueryFirstOrDefaultAsync(
                "SELECT Latitude AS lat, Longitude AS lng, FILIALE AS filiale FROM FILIALI WHERE IDFILIALE = @id",
                new { id = idFiliale }) as IDictionary<string, object>;
            double lat = f?["lat"] is double la ? la : 43.84;
            double lng = f?["lng"] is double lo ? lo : 11.1143;
            return Results.Ok(new { lat, lng, filiale = f?["filiale"] as string, idFiliale });
        })).RequireAuthorization();

        // elenco giri della filiale con driver predefinito, comune fisso, tipo di area e spedizioni
        // del giorno dentro il giro; con tutti=1 anche quelli non attivi (flag "Attivo" della pagina
        // Giri = DataFine vuota: disattivare scrive la data, riattivare la toglie)
        app.MapGet("/api/giri/elenco", (bool? tutti, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            await using var cn = new SqlConnection(connString());
            var g = await cn.QueryAsync(@"
                SELECT g.IdGiro AS idGiro, g.Giro AS giro, g.CAP AS cap, g.Belfiore AS belfiore, c.DENOMINAZIONE AS comune,
                       g.Colore AS colore, g.IdDriverDefault AS idDriverDefault, u.Nome AS driverDefault,
                       CONVERT(varchar(19), g.DataModifica, 126) AS dataModifica, CONVERT(varchar(19), g.DataFine, 126) AS dataFine,
                       CASE WHEN g.DataFine IS NULL THEN 1 ELSE 0 END AS attivo,
                       g.SHAPE.STGeometryType() AS tipoShape, g.SHAPE.STNumPoints() AS nPunti, ISNULL(s.n, 0) AS nSped
                FROM GEO_GIRI g
                LEFT JOIN UTENTI u ON u.IdUtente = g.IdDriverDefault
                OUTER APPLY (SELECT TOP 1 DENOMINAZIONE FROM GEO_COMUNE WHERE BELFIORE = g.Belfiore) c
                LEFT JOIN (SELECT IdGiro, COUNT(*) AS n FROM V_ElencoGeoSped WHERE IdFiliale = @id GROUP BY IdGiro) s ON s.IdGiro = g.IdGiro
                WHERE g.IdFiliale = @id AND (@tutti = 1 OR g.DataFine IS NULL)
                ORDER BY g.Giro",
                new { id = idFiliale, tutti = tutti == true ? 1 : 0 });
            return Results.Ok(g);
        })).RequireAuthorization();

        // tendine e contatori: driver della filiale (ruolo Driver / Driver azienda esterna, piu' quelli
        // gia' predefiniti su un giro anche se di altra filiale), comuni coperti, spedizioni del giorno
        app.MapGet("/api/giri/lookup", (ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            await using var cn = new SqlConnection(connString());
            var driver = await cn.QueryAsync(@"
                SELECT u.IdUtente AS idUtente, u.Nome AS nome, u.IdFiliale AS idFiliale
                FROM UTENTI u
                WHERE ISNULL(u.DataFine, '2079-01-01') > GETDATE()
                  AND ((u.IdRuolo IN (40, 41) AND u.IdFiliale = @id)
                       OR u.IdUtente IN (SELECT IdDriverDefault FROM GEO_GIRI WHERE IdFiliale = @id AND IdDriverDefault IS NOT NULL))
                ORDER BY u.Nome", new { id = idFiliale });
            var comuni = await Comuni(cn, idFiliale);
            var sped = await cn.QueryFirstAsync(@"
                SELECT COUNT(*) AS totale, ISNULL(SUM(CASE WHEN IdGiro IS NULL THEN 1 ELSE 0 END), 0) AS senzaGiro
                FROM V_ElencoGeoSped WHERE IdFiliale = @id", new { id = idFiliale });
            return Results.Ok(new { driver, comuni, spedizioni = sped });
        })).RequireAuthorization();

        // comuni coperti dalla filiale (via GEO_COPERTURE.CAP)
        app.MapGet("/api/giri/comuni", (ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            return Results.Ok(await Comuni(cn, Filiale(user)));
        })).RequireAuthorization();

        // vertici di un comune o di un giro (Geo_GetVertici legacy) -> poligono
        app.MapGet("/api/giri/vertici", (int? idComune, int? idGiro) => Prova(async () =>
        {
            if (idComune is null && idGiro is null) throw new ErroreGiri("Specificare idComune o idGiro");
            await using var cn = new SqlConnection(connString());
            var v = await cn.QueryAsync("dbo.Geo_GetVertici", new { IdComune = idComune, IdGiro = idGiro }, commandType: CommandType.StoredProcedure);
            // Geo_GetVertici restituisce le colonne con casing diverso fra comune e giro: lettura senza distinguere
            static object? Cerca(IDictionary<string, object> r, string nome)
            {
                foreach (var kv in r)
                    if (string.Equals(kv.Key, nome, StringComparison.OrdinalIgnoreCase)) return kv.Value;
                return null;
            }
            return Results.Ok(v.Cast<IDictionary<string, object>>().Select(r => new { lat = Cerca(r, "Latitude"), lng = Cerca(r, "Longitude") }));
        })).RequireAuthorization();

        // spedizioni geolocalizzate da consegnare oggi (V_ElencoGeoSped), filtrabili per giro / CAP;
        // idGiro=0 = quelle senza giro
        app.MapGet("/api/giri/spedizioni", (int? idGiro, string? cap, ClaimsPrincipal user) => Prova(async () =>
        {
            var par = new DynamicParameters();
            par.Add("id", Filiale(user));
            var where = " WHERE idFiliale = @id AND latitude IS NOT NULL";
            if (idGiro is int g && g > 0) { where += " AND IdGiro = @g"; par.Add("g", g); }
            else if (idGiro == 0) where += " AND IdGiro IS NULL";
            if (!string.IsNullOrWhiteSpace(cap) && cap.Length == 5) { where += " AND destinazionecap = @cap"; par.Add("cap", cap); }
            await using var cn = new SqlConnection(connString());
            var s = await cn.QueryAsync($@"
                SELECT idspedizione AS idSpedizione, barcode, latitude AS lat, longitude AS lng,
                       destinazioneindirizzo AS indirizzo, DestinazioneLocalita AS localita,
                       destinazionecap AS cap, giro, IdGiro AS idGiro, colore
                FROM V_ElencoGeoSped{where}", par);
            return Results.Ok(s);
        })).RequireAuthorization();

        // geometria (WKT) di un giro o di un comune: il rendering gestisce anche i MULTIPOLYGON
        app.MapGet("/api/giri/shape", (int? idGiro, int? idComune) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            string? wkt = (idGiro, idComune) switch
            {
                (int g, _) => await cn.ExecuteScalarAsync<string>("SELECT SHAPE.STAsText() FROM GEO_GIRI WHERE IdGiro = @id AND SHAPE IS NOT NULL", new { id = g }),
                (_, int c) => await cn.ExecuteScalarAsync<string>("SELECT SHAPE.STAsText() FROM GEO_COMUNE WHERE IdComune = @id AND SHAPE IS NOT NULL", new { id = c }),
                _ => null
            };
            return Results.Ok(new { wkt });
        })).RequireAuthorization();

        // scheda di un giro: campi, geometria, anello esterno modificabile (solo se e' un poligono
        // semplice: per le aree in piu' parti il confine si rifa' dai comuni) e ultime modifiche
        app.MapGet("/api/giri/{id:int}", (int id, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var g = (IDictionary<string, object?>?)await cn.QueryFirstOrDefaultAsync(@"
                SELECT g.IdGiro AS idGiro, g.IdFiliale AS idFiliale, g.Giro AS giro, g.CAP AS cap, g.Belfiore AS belfiore, g.Colore AS colore,
                       g.IdDriverDefault AS idDriverDefault, CASE WHEN g.DataFine IS NULL THEN 1 ELSE 0 END AS attivo,
                       CONVERT(varchar(19), g.DataModifica, 126) AS dataModifica, CONVERT(varchar(19), g.DataFine, 126) AS dataFine,
                       g.SHAPE.STGeometryType() AS tipoShape, g.SHAPE.STNumGeometries() AS nParti, g.SHAPE.STNumPoints() AS nPunti,
                       g.SHAPE.STAsText() AS wkt,
                       CASE WHEN g.SHAPE.STGeometryType() = 'Polygon' THEN g.SHAPE.STExteriorRing().STAsText() END AS anelloWkt
                FROM GEO_GIRI g WHERE g.IdGiro = @id", new { id });
            if (g is null) return Results.NotFound(new { errore = "Giro non trovato" });
            if (Convert.ToInt32(g["idFiliale"]) != Filiale(user)) return Results.BadRequest(new { errore = "Il giro e' di un'altra filiale" });
            var anello = Anello(g["anelloWkt"] as string);
            g.Remove("anelloWkt");
            g["anello"] = anello;
            g["variazioni"] = await cn.QueryAsync(@"
                SELECT TOP 20 CONVERT(varchar(19), DataOra, 126) AS dataOra, Utente AS utente, Campo AS campo,
                       CASE WHEN Campo = 'SHAPE' THEN NULL ELSE Prima END AS prima,
                       CASE WHEN Campo = 'SHAPE' THEN NULL ELSE Dopo END AS dopo
                FROM GEO_GIRI_VARIAZIONI WHERE IdGiro = @id ORDER BY IdVariazione DESC", new { id });
            return Results.Ok(g);
        })).RequireAuthorization();

        // modifica del giro (campi, chiusura, confine se arrivano i vertici)
        app.MapPut("/api/giri/{id:int}", (int id, JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            string? vertici = null;
            if (b.TryGetProperty("vertici", out var v) && v.ValueKind == JsonValueKind.Array && v.GetArrayLength() > 0)
                vertici = JsonSerializer.Serialize(v.EnumerateArray().Select(p => new { lat = p.GetProperty("lat").GetDouble(), lng = p.GetProperty("lng").GetDouble() }));
            await using var cn = new SqlConnection(connString());
            var r = await cn.QueryFirstOrDefaultAsync("dbo.AI_GEO_GIRO_Save", new
            {
                IdGiro = id, Giro = Testo(b, "giro"), Colore = Testo(b, "colore"), CAP = Testo(b, "cap"), Belfiore = Testo(b, "belfiore"),
                IdDriverDefault = Intero(b, "idDriverDefault"),
                Attivo = !(b.TryGetProperty("attivo", out var a) && a.ValueKind == JsonValueKind.False),
                Vertici = vertici, Utente = user.Identity?.Name,
            }, commandType: CommandType.StoredProcedure);
            if (b.TryGetProperty("attivo", out var att) && att.ValueKind == JsonValueKind.False)
                await ScollegaDaiPiani(cn, id, Filiale(user), user);
            return Results.Ok(r);
        })).RequireAuthorization();

        // flag "Attivo" dall'elenco dei giri: si cambia solo quello (gli altri campi restano come sono).
        // Un giro non attivo non si assegna piu' (le pagine di assegnazione e le stored vedono solo gli
        // attivi) e viene tolto dai piani di oggi e dei giorni dopo, cosi' non resta nel percorso di un
        // driver senza comparire sulla lavagna
        app.MapPut("/api/giri/{id:int}/attivo", (int id, JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var attivo = !(b.TryGetProperty("attivo", out var a) && a.ValueKind == JsonValueKind.False);
            var idFiliale = Filiale(user);
            await using var cn = new SqlConnection(connString());
            var g = await cn.QueryFirstOrDefaultAsync(
                "SELECT Giro, Colore, CAP, Belfiore, IdDriverDefault FROM GEO_GIRI WHERE IdGiro = @id AND IdFiliale = @f",
                new { id, f = idFiliale }) ?? throw new ErroreGiri("Giro non trovato nella filiale");
            await cn.ExecuteAsync("dbo.AI_GEO_GIRO_Save", new
            {
                IdGiro = id, Giro = (string)g.Giro, Colore = (string?)g.Colore, CAP = (string?)g.CAP, Belfiore = (string?)g.Belfiore,
                IdDriverDefault = (int?)g.IdDriverDefault, Attivo = attivo, Vertici = (string?)null, Utente = user.Identity?.Name,
            }, commandType: CommandType.StoredProcedure);
            var tolti = attivo ? 0 : await ScollegaDaiPiani(cn, id, idFiliale, user);
            return Results.Ok(new { idGiro = id, attivo, toltoDaiPiani = tolti });
        })).RequireAuthorization();

        // confine di un giro esistente rifatto come unione dei comuni scelti
        app.MapPost("/api/giri/{id:int}/da-comuni", (int id, JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var ids = b.TryGetProperty("idComuni", out var c) && c.ValueKind == JsonValueKind.Array ? c.EnumerateArray().Select(x => x.GetInt32()).ToList() : new List<int>();
            if (ids.Count == 0) throw new ErroreGiri("Seleziona almeno un comune");
            await using var cn = new SqlConnection(connString());
            await cn.ExecuteAsync("dbo.AI_GEO_GIRO_Comuni", new { IdGiro = id, IdComuni = JsonSerializer.Serialize(ids), Utente = user.Identity?.Name },
                commandType: CommandType.StoredProcedure);
            return Results.Ok(new { ok = true });
        })).RequireAuthorization();

        // nuovo giro come unione delle geometrie dei comuni selezionati
        app.MapPost("/api/giri/da-comuni", (CreaGiroComuniRequest req, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            if (req.IdComuni is null || req.IdComuni.Count == 0) throw new ErroreGiri("Seleziona almeno un comune");
            await using var cn = new SqlConnection(connString());
            var id = await cn.QueryFirstOrDefaultAsync<int?>("dbo.AI_GEO_CreaGiroDaComuni",
                new { Giro = req.Nome, IdFiliale = idFiliale, Colore = req.Colore, IdComuni = JsonSerializer.Serialize(req.IdComuni) },
                commandType: CommandType.StoredProcedure);
            if (id is int g) await Rifinisci(cn, g, req, user);
            return Results.Ok(new { idGiro = id });
        })).RequireAuthorization();

        // nuovo giro con i vertici disegnati (AI_GEO_CreaGiro, atomico)
        app.MapPost("/api/giri", (CreaGiroRequest req, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            if (req.Vertici is null || req.Vertici.Count < 3) throw new ErroreGiri("Servono almeno 3 punti per definire il giro");
            var json = JsonSerializer.Serialize(req.Vertici.Select(v => new { lat = v.Lat, lng = v.Lng }));
            await using var cn = new SqlConnection(connString());
            var id = await cn.QueryFirstOrDefaultAsync<int?>("dbo.AI_GEO_CreaGiro",
                new { Giro = req.Nome, IdFiliale = idFiliale, Colore = req.Colore, Vertici = json }, commandType: CommandType.StoredProcedure);
            if (id is int g) await Rifinisci(cn, g, req, user);
            return Results.Ok(new { idGiro = id });
        })).RequireAuthorization();

        // aggiorna i giri alle spedizioni di oggi (AI_SPED_AssegnaGiri con riassegnazione, per ogni giro
        // scelto o per tutti; stessa regola della legacy GEO_AssegnaGIRI, con lo storico)
        app.MapPost("/api/giri/assegna", (AssegnaGiriRequest req, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            await using var cn = new SqlConnection(connString());
            if (req.IdGiri is { Count: > 0 })
                foreach (var idGiro in req.IdGiri)
                    await cn.ExecuteAsync("dbo.AI_SPED_AssegnaGiri", new { IdFiliale = idFiliale, Data = DateTime.Today, IdGiro = idGiro, Forza = true, Utente = user.Identity?.Name },
                        commandType: CommandType.StoredProcedure);
            else if (req.Tutti == true)
                await cn.ExecuteAsync("dbo.AI_SPED_AssegnaGiri", new { IdFiliale = idFiliale, Data = DateTime.Today, IdGiro = (int?)null, Forza = true, Utente = user.Identity?.Name },
                    commandType: CommandType.StoredProcedure);
            else throw new ErroreGiri("Nessun giro selezionato");
            var sped = await cn.QueryFirstAsync(@"
                SELECT COUNT(*) AS totale, ISNULL(SUM(CASE WHEN IdGiro IS NULL THEN 1 ELSE 0 END), 0) AS senzaGiro
                FROM V_ElencoGeoSped WHERE IdFiliale = @id", new { id = idFiliale });
            return Results.Ok(new { ok = true, spedizioni = sped });
        })).RequireAuthorization();

        // le aree di tutti i giri attivi della filiale in un colpo solo (sfondo della pagina Spedizioni del giorno)
        app.MapGet("/api/giri/shapes", (ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var righe = await cn.QueryAsync(@"
                SELECT IdGiro AS idGiro, Giro AS giro, Colore AS colore, SHAPE.STAsText() AS wkt
                FROM GEO_GIRI WHERE IdFiliale = @id AND DataFine IS NULL AND SHAPE IS NOT NULL ORDER BY Giro", new { id = Filiale(user) });
            return Results.Ok(righe);
        })).RequireAuthorization();
    }

    // giro disattivato: fuori dai piani di oggi e dei giorni dopo (AI_PIANO_Driver senza driver segna
    // "da rifare" il percorso del driver che lo aveva); i giorni passati restano come storico
    static async Task<int> ScollegaDaiPiani(SqlConnection cn, int idGiro, int idFiliale, ClaimsPrincipal user)
    {
        var giorni = (await cn.QueryAsync<DateTime>(@"
            SELECT Data FROM GIRI_PIANO
            WHERE IdGiro = @idGiro AND Data >= CONVERT(date, GETDATE()) AND IdDriver IS NOT NULL",
            new { idGiro })).ToList();
        foreach (var giorno in giorni)
            await cn.ExecuteAsync("dbo.AI_PIANO_Driver",
                new { IdFiliale = idFiliale, Data = giorno, IdGiro = idGiro, IdDriver = (int?)null, Utente = user.Identity?.Name },
                commandType: CommandType.StoredProcedure);
        return giorni.Count;
    }

    // dopo la creazione: driver predefinito, CAP e comune fissi arrivano nella stessa richiesta
    static async Task Rifinisci(SqlConnection cn, int idGiro, CreaGiroBase req, ClaimsPrincipal user)
    {
        if (req.IdDriverDefault is null && string.IsNullOrWhiteSpace(req.Cap) && string.IsNullOrWhiteSpace(req.Belfiore)) return;
        await cn.ExecuteAsync("dbo.AI_GEO_GIRO_Save", new
        {
            IdGiro = idGiro, Giro = req.Nome, Colore = req.Colore, CAP = req.Cap, Belfiore = req.Belfiore,
            IdDriverDefault = req.IdDriverDefault, Attivo = true, Vertici = (string?)null, Utente = user.Identity?.Name,
        }, commandType: CommandType.StoredProcedure);
    }

    static async Task<IEnumerable<dynamic>> Comuni(SqlConnection cn, int idFiliale) =>
        await cn.QueryAsync(@"
            SELECT c.IdComune AS idComune, c.DENOMINAZIONE AS denominazione, c.BELFIORE AS belfiore,
                   MIN(c.CAP) AS cap, MIN(c.SIGLAPROV) AS siglaProv
            FROM GEO_COMUNE c
            JOIN GEO_COPERTURE cop ON cop.CAP = c.CAP
            WHERE cop.IdFilialeDistribuzione = @id
            GROUP BY c.IdComune, c.DENOMINAZIONE, c.BELFIORE
            ORDER BY c.DENOMINAZIONE", new { id = idFiliale });

    // "LINESTRING (lng lat, lng lat, ...)" -> punti {lat, lng} senza il punto di chiusura
    static List<object>? Anello(string? wkt)
    {
        if (string.IsNullOrEmpty(wkt)) return null;
        var a = wkt.IndexOf('('); var z = wkt.LastIndexOf(')');
        if (a < 0 || z <= a) return null;
        var punti = new List<(double lat, double lng)>();
        foreach (var coppia in wkt[(a + 1)..z].Split(','))
        {
            var xy = coppia.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (xy.Length < 2) continue;
            if (double.TryParse(xy[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var lng) &&
                double.TryParse(xy[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var lat))
                punti.Add((lat, lng));
        }
        if (punti.Count > 1 && punti[0] == punti[^1]) punti.RemoveAt(punti.Count - 1);
        return punti.Select(p => (object)new { p.lat, p.lng }).ToList();
    }

    static string? Testo(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static int? Intero(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;

    static async Task<IResult> Prova(Func<Task<IResult>> f)
    {
        try { return await f(); }
        catch (ErroreGiri ex) { return Results.BadRequest(new { errore = ex.Message }); }
        catch (SqlException ex) { return Results.BadRequest(new { errore = ex.Message }); }
    }
}

record VerticeGiro(double Lat, double Lng);
record CreaGiroBase(string Nome, string? Colore, int? IdDriverDefault, string? Cap, string? Belfiore);
record CreaGiroRequest(string Nome, string? Colore, List<VerticeGiro> Vertici, int? IdDriverDefault = null, string? Cap = null, string? Belfiore = null)
    : CreaGiroBase(Nome, Colore, IdDriverDefault, Cap, Belfiore);
record CreaGiroComuniRequest(string Nome, string? Colore, List<int> IdComuni, int? IdDriverDefault = null, string? Cap = null, string? Belfiore = null)
    : CreaGiroBase(Nome, Colore, IdDriverDefault, Cap, Belfiore);
record AssegnaGiriRequest(List<int>? IdGiri, bool? Tutti = null);
