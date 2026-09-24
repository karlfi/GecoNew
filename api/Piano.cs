using System.Data;
using System.Globalization;
using System.Security.Claims;
using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;

// === Piano della giornata (pagina "Piano della giornata") ===
// Per un giorno e una filiale: i giri con le spedizioni caricate, il driver che li fa (GIRI_PIANO.IdDriver),
// e per ogni driver il percorso ottimizzato con HERE su tutte le consegne dei suoi giri (PIANO_DRIVER:
// partenza e ritorno da casa o dalla filiale, richiesta in GEO_HereW/GEO_HereWReq, risposta scritta dallo
// script here_sequenza.py del workflow GEO-01_HERE con la polilinea stradale). La casa del driver sta in
// UTENTI_GEO, geocodificata qui con HERE quando la si imposta.
static class Piano
{
    const string WorkflowHere = "GEO-01_HERE";
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(30) };

    class ErrorePiano : Exception { public ErrorePiano(string m) : base(m) { } }

    static int Filiale(ClaimsPrincipal user) =>
        int.TryParse(user.FindFirstValue("idFiliale"), out var f) ? f : throw new ErrorePiano("Filiale non disponibile");

    static DateTime Giorno(string? data) =>
        string.IsNullOrWhiteSpace(data) ? DateTime.Today
        : DateTime.TryParse(data, out var d) ? d.Date : throw new ErrorePiano("Data non valida");

    public static void Map(WebApplication app, Func<string> connString)
    {
        // i giri del giorno (spedizioni, driver) e i driver della filiale (opzioni, casa, percorso)
        app.MapGet("/api/piano", (string? data, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            var giorno = Giorno(data);
            await using var cn = new SqlConnection(connString());
            var f = await cn.QueryFirstOrDefaultAsync("SELECT FILIALE AS filiale, Latitude AS lat, Longitude AS lng FROM FILIALI WHERE IDFILIALE = @id", new { id = idFiliale });
            var giri = await cn.QueryAsync(@"
                SELECT g.IdGiro AS idGiro, g.Giro AS giro, g.Colore AS colore, g.IdDriverDefault AS idDriverDefault, ud.Nome AS driverDefault,
                       CASE WHEN g.DataFine IS NULL THEN 1 ELSE 0 END AS attivo,
                       ISNULL(s.n, 0) AS nSped, ISNULL(s.geo, 0) AS nGeo, ISNULL(s.seq, 0) AS nSequenza,
                       p.IdPiano AS idPiano, p.IdDriver AS idDriver, u.Nome AS driver
                FROM GEO_GIRI g
                LEFT JOIN (SELECT IdGiro, COUNT(*) AS n, SUM(CASE WHEN DestinazioneLatitude IS NOT NULL THEN 1 ELSE 0 END) AS geo,
                                  SUM(CASE WHEN Sequenza IS NOT NULL THEN 1 ELSE 0 END) AS seq
                           FROM SPED_ATTIVITA WHERE IdFiliale = @id AND DataCarico >= @dal AND DataCarico < @al GROUP BY IdGiro) s ON s.IdGiro = g.IdGiro
                LEFT JOIN GIRI_PIANO p ON p.IdGiro = g.IdGiro AND p.Data = @data
                LEFT JOIN UTENTI u ON u.IdUtente = p.IdDriver
                LEFT JOIN UTENTI ud ON ud.IdUtente = g.IdDriverDefault
                -- solo i giri attivi; nei giorni passati anche quelli poi disattivati che erano nel piano (storico)
                WHERE g.IdFiliale = @id AND (g.DataFine IS NULL OR (p.IdPiano IS NOT NULL AND @data < CONVERT(date, GETDATE())))
                ORDER BY g.Giro", new { id = idFiliale, data = giorno, dal = giorno, al = giorno.AddDays(1) });
            var driver = await cn.QueryAsync(@"
                SELECT u.IdUtente AS idUtente, u.Nome AS nome,
                       pd.IdPianoDriver AS idPianoDriver, ISNULL(pd.PartenzaCasa, 0) AS partenzaCasa, ISNULL(pd.RitornoCasa, 0) AS ritornoCasa,
                       pd.Stato AS stato, ISNULL(pd.DaRifare, 0) AS daRifare, pd.NPunti AS nPunti, pd.NSenzaCoordinate AS nSenzaCoordinate,
                       pd.DistanzaM AS distanzaM, pd.TempoS AS tempoS, pd.Errore AS errore, CONVERT(varchar(19), pd.DataRisposta, 126) AS dataRisposta,
                       CASE WHEN pd.Polilinea IS NULL THEN 0 ELSE 1 END AS conPolilinea,
                       geo.Indirizzo AS casaIndirizzo, geo.Lat AS casaLat, geo.Lng AS casaLng,
                       NULLIF(LTRIM(RTRIM(ISNULL(u.IndirizzoRes, '') + ISNULL(', ' + u.CapRes, '') + ISNULL(' ' + u.ComuneRes, '') + ISNULL(' ' + u.ProvRes, ''))), '') AS residenza
                FROM UTENTI u
                LEFT JOIN PIANO_DRIVER pd ON pd.IdDriver = u.IdUtente AND pd.Data = @data
                LEFT JOIN UTENTI_GEO geo ON geo.IdUtente = u.IdUtente
                WHERE ISNULL(u.DataFine, '2079-01-01') > GETDATE()
                  AND ((u.IdRuolo IN (40, 41) AND u.IdFiliale = @id)
                       OR u.IdUtente IN (SELECT IdDriverDefault FROM GEO_GIRI WHERE IdFiliale = @id AND IdDriverDefault IS NOT NULL)
                       OR u.IdUtente IN (SELECT IdDriver FROM GIRI_PIANO WHERE IdFiliale = @id AND Data = @data AND IdDriver IS NOT NULL))
                ORDER BY u.Nome", new { id = idFiliale, data = giorno });
            var senzaGiro = await cn.QueryFirstAsync(@"
                SELECT COUNT(*) AS n, ISNULL(SUM(CASE WHEN DestinazioneLatitude IS NOT NULL THEN 1 ELSE 0 END), 0) AS geo
                FROM SPED_ATTIVITA WHERE IdFiliale = @id AND DataCarico >= @dal AND DataCarico < @al AND IdGiro IS NULL",
                new { id = idFiliale, dal = giorno, al = giorno.AddDays(1) });
            return Results.Ok(new
            {
                filiale = (string?)f?.filiale, lat = (double?)f?.lat, lng = (double?)f?.lng, data = giorno.ToString("yyyy-MM-dd"),
                giri, driver, senzaGiro = new { n = (int)senzaGiro.n, geo = (int)senzaGiro.geo },
            });
        })).RequireAuthorization();

        // giro -> driver: { data, idGiro, idDriver | null }
        app.MapPost("/api/piano/driver", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var r = await cn.QueryFirstAsync("dbo.AI_PIANO_Driver",
                new { IdFiliale = Filiale(user), Data = Giorno(Testo(b, "data")), IdGiro = Intero(b, "idGiro") ?? throw new ErrorePiano("Giro mancante"), IdDriver = Intero(b, "idDriver"), Utente = user.Identity?.Name },
                commandType: CommandType.StoredProcedure);
            return Results.Ok(r);
        })).RequireAuthorization();

        // driver predefiniti sui giri del giorno ancora senza driver: { data }
        app.MapPost("/api/piano/driver-predefiniti", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var n = await cn.ExecuteScalarAsync<int>("dbo.AI_PIANO_DriverPredefiniti",
                new { IdFiliale = Filiale(user), Data = Giorno(Testo(b, "data")), Utente = user.Identity?.Name }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { assegnati = n });
        })).RequireAuthorization();

        // partenza/ritorno da casa o dalla filiale: { data, idDriver, partenzaCasa, ritornoCasa }
        app.MapPost("/api/piano/driver/opzioni", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var r = await cn.QueryFirstAsync("dbo.AI_PIANO_DriverOpzioni", new
            {
                IdFiliale = Filiale(user), Data = Giorno(Testo(b, "data")), IdDriver = Intero(b, "idDriver") ?? throw new ErrorePiano("Driver mancante"),
                PartenzaCasa = Vero(b, "partenzaCasa"), RitornoCasa = Vero(b, "ritornoCasa"), Utente = user.Identity?.Name,
            }, commandType: CommandType.StoredProcedure);
            return Results.Ok(r);
        })).RequireAuthorization();

        // casa del driver: { indirizzo } -> geocodifica HERE e salva in UTENTI_GEO
        app.MapPost("/api/piano/driver/{idUtente:int}/casa", (int idUtente, JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var indirizzo = (Testo(b, "indirizzo") ?? "").Trim();
            if (indirizzo.Length < 5) throw new ErrorePiano("Indirizzo mancante");
            await using var cn = new SqlConnection(connString());
            var token = await cn.ExecuteScalarAsync<string?>("SELECT Codice FROM dbo.LISTA_VALORI WHERE Lista = 'HERE' AND Valore = 'token'");
            if (string.IsNullOrWhiteSpace(token)) throw new ErrorePiano("In Lista Valori (lista HERE) manca la riga token");
            var (lat, lng, trovato) = await Geocodifica(token.Trim(), indirizzo);
            await cn.ExecuteAsync("dbo.AI_UTENTI_GEO_Save", new { IdUtente = idUtente, Indirizzo = indirizzo, Lat = lat, Lng = lng, Origine = "HERE", Utente = user.Identity?.Name },
                commandType: CommandType.StoredProcedure);
            return Results.Ok(new { indirizzo, lat, lng, trovato });
        })).RequireAuthorization();

        // ottimizzazione del percorso di un driver: { data, idDriver } -> richiesta HERE + workflow in coda
        app.MapPost("/api/piano/ottimizza", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            await using var cn = new SqlConnection(connString());
            var r = await cn.QueryFirstAsync("dbo.AI_HERE_RichiestaDriver",
                new { IdFiliale = idFiliale, Data = Giorno(Testo(b, "data")), IdDriver = Intero(b, "idDriver") ?? throw new ErrorePiano("Driver mancante"), IdUtente = IdUtente(user), Utente = user.Identity?.Name },
                commandType: CommandType.StoredProcedure);
            var idEsecuzione = await Accoda(cn, user.Identity?.Name, JsonSerializer.Serialize(new { IdGeoHereW = (int)r.IdGeoHereW }));
            return Results.Ok(new { idPianoDriver = (int)r.IdPianoDriver, idGeoHereW = (int)r.IdGeoHereW, nPunti = (int)r.NPunti, nSenzaCoordinate = (int)r.NSenzaCoordinate, idEsecuzione });
        })).RequireAuthorization();

        // tutti i driver con consegne geolocalizzate: { data, soloDaFare }
        app.MapPost("/api/piano/ottimizza-tutti", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            var giorno = Giorno(Testo(b, "data"));
            var soloDaFare = !(b.TryGetProperty("soloDaFare", out var s) && s.ValueKind == JsonValueKind.False);
            await using var cn = new SqlConnection(connString());
            var driver = await cn.QueryAsync<int>(@"
                SELECT p.IdDriver FROM GIRI_PIANO p
                JOIN SPED_ATTIVITA s ON s.IdGiro = p.IdGiro AND s.IdFiliale = @id AND s.DataCarico >= @dal AND s.DataCarico < @al AND s.DestinazioneLatitude IS NOT NULL
                LEFT JOIN PIANO_DRIVER pd ON pd.IdDriver = p.IdDriver AND pd.Data = @data
                WHERE p.Data = @data AND p.IdDriver IS NOT NULL
                  AND (@solo = 0 OR ISNULL(pd.Stato, '') NOT IN ('RICHIESTA', 'IN_CORSO') AND (ISNULL(pd.Stato, '') <> 'FATTA' OR pd.DaRifare = 1))
                GROUP BY p.IdDriver", new { id = idFiliale, data = giorno, dal = giorno, al = giorno.AddDays(1), solo = soloDaFare ? 1 : 0 });
            var richieste = 0; var saltati = new List<string>();
            foreach (var idDriver in driver)
            {
                try
                {
                    await cn.ExecuteAsync("dbo.AI_HERE_RichiestaDriver", new { IdFiliale = idFiliale, Data = giorno, IdDriver = idDriver, IdUtente = IdUtente(user), Utente = user.Identity?.Name }, commandType: CommandType.StoredProcedure);
                    richieste++;
                }
                catch (SqlException ex) { saltati.Add(ex.Message); }
            }
            int? idEsecuzione = richieste > 0 ? await Accoda(cn, user.Identity?.Name, null) : null;
            return Results.Ok(new { richieste, saltati, idEsecuzione });
        })).RequireAuthorization();

        // punti "sciolti" (senza giro o in giri non assegnati) presi con il rettangolo: vanno nel giro del driver piu' vicino
        app.MapPost("/api/piano/punti", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            var giorno = Giorno(Testo(b, "data"));
            var idDriver = Intero(b, "idDriver") ?? throw new ErrorePiano("Driver mancante");
            var ids = b.TryGetProperty("idSpedizioni", out var v) && v.ValueKind == JsonValueKind.Array ? v.EnumerateArray().Select(x => x.GetInt32()).ToList() : new List<int>();
            if (ids.Count == 0) throw new ErrorePiano("Nessuna spedizione nel rettangolo");
            await using var cn = new SqlConnection(connString());
            var giri = (await cn.QueryAsync(@"
                SELECT g.IdGiro AS idGiro, g.Giro AS giro, g.SHAPE.STCentroid().STY AS lat, g.SHAPE.STCentroid().STX AS lng
                FROM GIRI_PIANO p JOIN GEO_GIRI g ON g.IdGiro = p.IdGiro
                WHERE p.Data = @data AND p.IdDriver = @idDriver AND p.IdFiliale = @id", new { id = idFiliale, data = giorno, idDriver })).ToList();
            if (giri.Count == 0) throw new ErrorePiano("Il driver non ha ancora un giro: assegnagli prima un'area, poi i punti sciolti");
            var centro = await cn.QueryFirstAsync("SELECT AVG(DestinazioneLatitude) AS lat, AVG(DestinazioneLongitude) AS lng FROM SPED_ATTIVITA WHERE IdSpedizione IN @ids", new { ids });
            double clat = (double?)centro.lat ?? 0, clng = (double?)centro.lng ?? 0;
            var giro = giri.OrderBy(g => g.lat is null ? double.MaxValue : Math.Pow((double)g.lat - clat, 2) + Math.Pow((double)g.lng - clng, 2)).First();
            var cambiate = await cn.ExecuteScalarAsync<int>("dbo.AI_SPED_Giro",
                new { IdFiliale = idFiliale, IdSpedizioni = JsonSerializer.Serialize(ids), IdGiro = (int)giro.idGiro, Utente = user.Identity?.Name }, commandType: CommandType.StoredProcedure);
            await cn.ExecuteAsync("UPDATE PIANO_DRIVER SET DaRifare = 1 WHERE Data = @data AND IdDriver = @idDriver AND Stato = 'FATTA'", new { data = giorno, idDriver });
            return Results.Ok(new { cambiate, giro = (string)giro.giro });
        })).RequireAuthorization();

        // il percorso di un driver: tappe nell'ordine di HERE (o le consegne senza ordine), partenza, ritorno, polilinea
        app.MapGet("/api/piano/driver/{id:int}/percorso", (int id, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var p = await PianoDriverDi(cn, id, Filiale(user));
            List<IDictionary<string, object?>> punti = (await Percorso(cn, (object)p)).Cast<IDictionary<string, object?>>().ToList();
            var partenza = punti.FirstOrDefault(x => (string?)x["tipo"] == "partenza");
            var ritorno = punti.FirstOrDefault(x => (string?)x["tipo"] == "ritorno");
            List<double[]>? polilinea = null;
            if (p.Polilinea is string pl && pl.Length > 2)
                try { polilinea = JsonSerializer.Deserialize<List<double[]>>(pl); } catch { polilinea = null; }
            return Results.Ok(new
            {
                piano = new { idPianoDriver = (int)p.IdPianoDriver, idDriver = (int)p.IdDriver, driver = (string?)p.Driver, data = ((DateTime)p.Data).ToString("yyyy-MM-dd"),
                              stato = (string?)p.Stato, daRifare = (bool)p.DaRifare, distanzaM = (int?)p.DistanzaM, tempoS = (int?)p.TempoS, errore = (string?)p.Errore,
                              partenzaCasa = (bool)p.PartenzaCasa, ritornoCasa = (bool)p.RitornoCasa, filiale = (string?)p.Filiale,
                              giri = ((string?)p.Giri ?? "").Split(" | ", StringSplitOptions.RemoveEmptyEntries) },
                partenza, ritorno, punti = punti.Where(x => (string?)x["tipo"] == "consegna").ToList(), polilinea,
            });
        })).RequireAuthorization();

        // il percorso in Excel, nell'ordine di consegna
        app.MapGet("/api/piano/driver/{id:int}/export", async (int id, ClaimsPrincipal user) =>
        {
            await using var cn = new SqlConnection(connString());
            var p = await PianoDriverDi(cn, id, Filiale(user));
            List<dynamic> punti = await Percorso(cn, (object)p);
            var nome = ((string?)p.Driver ?? "driver").Replace(' ', '_');
            return Esporta.Xlsx(punti, "Percorso", $"percorso_{nome}_{((DateTime)p.Data):yyyyMMdd}", new[] {
                ("Sequenza", "sequenza"), ("Giro", "giro"), ("Barcode", "barcode"), ("Destinatario", "destinatario"), ("Indirizzo", "indirizzo"), ("CAP", "cap"), ("Località", "localita"),
                ("Arrivo stimato", "arrivo"), ("Km dal punto prima", "km"), ("Minuti dal punto prima", "minuti"), ("Km progressivi", "kmProgressivi") });
        }).RequireAuthorization();

        // storico di un driver nel giorno (giri presi e tolti, opzioni, ottimizzazioni)
        app.MapGet("/api/piano/driver/{id:int}/storico", (int id) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var righe = await cn.QueryAsync(@"
                SELECT CONVERT(varchar(19), DataOra, 126) AS dataOra, Utente AS utente, Campo AS campo, Prima AS prima, Dopo AS dopo
                FROM PIANO_DRIVER_VARIAZIONI WHERE IdPianoDriver = @id ORDER BY IdVariazione DESC", new { id });
            return Results.Ok(righe);
        })).RequireAuthorization();
    }

    static async Task<dynamic> PianoDriverDi(SqlConnection cn, int id, int idFiliale)
    {
        var p = await cn.QueryFirstOrDefaultAsync(@"
            SELECT p.IdPianoDriver, p.Data, p.IdFiliale, p.IdDriver, u.Nome AS Driver, p.PartenzaCasa, p.RitornoCasa, p.Stato, p.DaRifare, p.DistanzaM, p.TempoS,
                   p.IdGeoHereW, p.Errore, p.Polilinea, f.FILIALE AS Filiale, f.Latitude AS FLat, f.Longitude AS FLng, geo.Lat AS CLat, geo.Lng AS CLng, geo.Indirizzo AS Casa,
                   (SELECT STRING_AGG(g.Giro, ' | ') FROM GIRI_PIANO gp JOIN GEO_GIRI g ON g.IdGiro = gp.IdGiro WHERE gp.Data = p.Data AND gp.IdDriver = p.IdDriver) AS Giri
            FROM PIANO_DRIVER p
            LEFT JOIN UTENTI u ON u.IdUtente = p.IdDriver
            LEFT JOIN FILIALI f ON f.IDFILIALE = p.IdFiliale
            LEFT JOIN UTENTI_GEO geo ON geo.IdUtente = p.IdDriver
            WHERE p.IdPianoDriver = @id", new { id }) ?? throw new ErrorePiano("Piano non trovato");
        if ((int)p.IdFiliale != idFiliale) throw new ErrorePiano("Il piano e' di un'altra filiale");
        return p;
    }

    // le tappe: con l'ottimizzazione fatta nell'ordine di HERE con tempi e distanze (partenza e ritorno compresi);
    // altrimenti le consegne dei giri del driver senza ordine. km/minuti dal punto precedente, km progressivi.
    static async Task<List<dynamic>> Percorso(SqlConnection cn, dynamic p)
    {
        IEnumerable<dynamic> righe;
        DateTime giorno = p.Data;
        if (p.IdGeoHereW is int idHere && (string?)p.Stato == "FATTA")
            righe = await cn.QueryAsync(@"
                SELECT w.Sequenza AS seq, r.IdSpedizione AS idSpedizione, r.IdAttivita AS idAttivita, r.Latitude AS lat, r.Longitude AS lng,
                       CASE WHEN s.IdSpedizione IS NULL THEN r.Indirizzo ELSE ISNULL(s.DestinazioneIndirizzo, '') + ISNULL(' ' + s.DestinazioneNumeroCivico, '') END AS indirizzo,
                       w.TempoViaggio AS tempo, w.Distanza AS distanza, CONVERT(varchar(19), w.DataArrivo, 126) AS arrivo,
                       s.Barcode AS barcode, s.DestinazioneRagioneSociale AS destinatario, s.DestinazioneCap AS cap, s.DestinazioneLocalita AS localita, g.Giro AS giro
                FROM GEO_HereWReq r
                JOIN GEO_HereWaypoint w ON w.IdHereReq = CAST(r.IdGeoHereW AS varchar(50)) AND w.IdApi = r.IdGeoHereReq
                LEFT JOIN SPED_ATTIVITA s ON s.IdSpedizione = r.IdSpedizione
                LEFT JOIN GEO_GIRI g ON g.IdGiro = s.IdGiro
                WHERE r.IdGeoHereW = @id ORDER BY w.Sequenza", new { id = idHere });
        else
            righe = await cn.QueryAsync(@"
                SELECT CAST(NULL AS int) AS seq, s.IdSpedizione AS idSpedizione, CAST(NULL AS int) AS idAttivita, s.DestinazioneLatitude AS lat, s.DestinazioneLongitude AS lng,
                       ISNULL(s.DestinazioneIndirizzo, '') + ISNULL(' ' + s.DestinazioneNumeroCivico, '') AS indirizzo,
                       CAST(NULL AS int) AS tempo, CAST(NULL AS int) AS distanza, CAST(NULL AS varchar(19)) AS arrivo,
                       s.Barcode AS barcode, s.DestinazioneRagioneSociale AS destinatario, s.DestinazioneCap AS cap, s.DestinazioneLocalita AS localita, g.Giro AS giro
                FROM SPED_ATTIVITA s JOIN GEO_GIRI g ON g.IdGiro = s.IdGiro
                WHERE s.IdFiliale = @idFiliale AND s.DataCarico >= @dal AND s.DataCarico < @al AND s.DestinazioneLatitude IS NOT NULL
                  AND s.IdGiro IN (SELECT IdGiro FROM GIRI_PIANO WHERE Data = @data AND IdDriver = @idDriver)
                ORDER BY g.Giro, s.Sequenza, s.DestinazioneCap, s.DestinazioneIndirizzo",
                new { idFiliale = (int)p.IdFiliale, idDriver = (int)p.IdDriver, data = giorno, dal = giorno, al = giorno.AddDays(1) });
        var lista = new List<dynamic>();
        var progressivi = 0.0; var consegna = 0;
        foreach (IDictionary<string, object?> r in righe)
        {
            var idAtt = r["idAttivita"] as int?;
            var tipo = idAtt == 0 ? "partenza" : idAtt == 999999999 ? "ritorno" : "consegna";
            var distanza = r["distanza"] as int?;
            progressivi += (distanza ?? 0) / 1000.0;
            r["tipo"] = tipo;
            r["sequenza"] = tipo == "consegna" && r["seq"] is not null ? ++consegna : null;
            r["km"] = distanza is null ? null : Math.Round(distanza.Value / 1000.0, 1);
            r["minuti"] = r["tempo"] is int t ? Math.Round(t / 60.0, 1) : null;
            r["kmProgressivi"] = distanza is null ? null : Math.Round(progressivi, 1);
            lista.Add(r);
        }
        return lista;
    }

    // HERE Geocoding: indirizzo -> (lat, lng, etichetta trovata)
    static async Task<(double lat, double lng, string trovato)> Geocodifica(string token, string indirizzo)
    {
        var url = "https://geocode.search.hereapi.com/v1/geocode?q=" + Uri.EscapeDataString(indirizzo) + "&in=countryCode:ITA&lang=it&apiKey=" + Uri.EscapeDataString(token);
        using var risp = await http.GetAsync(url);
        var testo = await risp.Content.ReadAsStringAsync();
        if (!risp.IsSuccessStatusCode) throw new ErrorePiano($"HERE Geocoding: HTTP {(int)risp.StatusCode}");
        using var doc = JsonDocument.Parse(testo);
        var items = doc.RootElement.TryGetProperty("items", out var it) ? it : default;
        if (items.ValueKind != JsonValueKind.Array || items.GetArrayLength() == 0) throw new ErrorePiano("HERE non trova questo indirizzo: prova con via, numero, CAP e comune");
        var primo = items[0];
        var pos = primo.GetProperty("position");
        var etichetta = primo.TryGetProperty("address", out var a) && a.TryGetProperty("label", out var l) ? l.GetString() ?? indirizzo : indirizzo;
        return (pos.GetProperty("lat").GetDouble(), pos.GetProperty("lng").GetDouble(), etichetta);
    }

    static async Task<int> Accoda(SqlConnection cn, string? utente, string? parametri)
    {
        var idWorkflow = await cn.ExecuteScalarAsync<int?>("SELECT IdWorkflow FROM dbo.WF_Workflow WHERE Nome = @nome AND Attivo = 1", new { nome = WorkflowHere })
            ?? throw new ErrorePiano($"Nello schedulatore manca il workflow {WorkflowHere}");
        var p = new DynamicParameters(new
        {
            IdWorkflow = idWorkflow, Origine = "MANUALE", Parametri = parametri, DataOraPrevista = (DateTime?)null,
            GruppoConcorrenza = (string?)null, NomeUtente = utente, IdPianificazione = (int?)null, IdDettaglio = (int?)null,
        });
        p.Add("@IdEsecuzione", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await cn.ExecuteAsync("dbo.WF_usp_Esecuzione_Crea", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@IdEsecuzione");
    }

    static int? IdUtente(ClaimsPrincipal user) =>
        int.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var id) ? id : null;

    static string? Testo(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static int? Intero(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;

    static bool Vero(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind == JsonValueKind.True;

    static async Task<IResult> Prova(Func<Task<IResult>> f)
    {
        try { return await f(); }
        catch (ErrorePiano ex) { return Results.BadRequest(new { errore = ex.Message }); }
        catch (SqlException ex) { return Results.BadRequest(new { errore = ex.Message }); }
        catch (HttpRequestException ex) { return Results.BadRequest(new { errore = "HERE non raggiungibile: " + ex.Message }); }
        catch (TaskCanceledException) { return Results.BadRequest(new { errore = "HERE non risponde (timeout)" }); }
    }
}
