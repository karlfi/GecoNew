using System.Data;
using System.Security.Claims;
using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;

// === Piano della giornata (pagina "Piano della giornata") ===
// Per un giorno e una filiale: i giri con le spedizioni caricate, il driver assegnato (GIRI_PIANO, con
// il predefinito del giro) e l'ottimizzazione del percorso con HERE: la pagina chiede (AI_HERE_Richiesta
// crea la testata e i punti in GEO_HereW/GEO_HereWReq) e mette in coda il workflow GEO-01_HERE, lo
// script here_sequenza.py chiama HERE e scrive la risposta; qui si legge il percorso ordinato.
static class Piano
{
    const string WorkflowHere = "GEO-01_HERE";

    class ErrorePiano : Exception { public ErrorePiano(string m) : base(m) { } }

    static int Filiale(ClaimsPrincipal user) =>
        int.TryParse(user.FindFirstValue("idFiliale"), out var f) ? f : throw new ErrorePiano("Filiale non disponibile");

    static DateTime Giorno(string? data) =>
        string.IsNullOrWhiteSpace(data) ? DateTime.Today
        : DateTime.TryParse(data, out var d) ? d.Date : throw new ErrorePiano("Data non valida");

    public static void Map(WebApplication app, Func<string> connString)
    {
        // i giri del giorno: spedizioni (totali, con coordinate, con sequenza), driver, stato dell'ottimizzazione
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
                       p.IdPiano AS idPiano, p.IdDriver AS idDriver, u.Nome AS driver, p.Stato AS stato, p.NPunti AS nPunti, p.NSenzaCoordinate AS nSenzaCoordinate,
                       p.DistanzaM AS distanzaM, p.TempoS AS tempoS, p.Errore AS errore, p.IdGeoHereW AS idGeoHereW,
                       CONVERT(varchar(19), p.DataRichiesta, 126) AS dataRichiesta, CONVERT(varchar(19), p.DataRisposta, 126) AS dataRisposta
                FROM GEO_GIRI g
                LEFT JOIN (SELECT IdGiro, COUNT(*) AS n, SUM(CASE WHEN DestinazioneLatitude IS NOT NULL THEN 1 ELSE 0 END) AS geo,
                                  SUM(CASE WHEN Sequenza IS NOT NULL THEN 1 ELSE 0 END) AS seq
                           FROM SPED_ATTIVITA WHERE IdFiliale = @id AND DataCarico >= @dal AND DataCarico < @al GROUP BY IdGiro) s ON s.IdGiro = g.IdGiro
                LEFT JOIN GIRI_PIANO p ON p.IdGiro = g.IdGiro AND p.Data = @data
                LEFT JOIN UTENTI u ON u.IdUtente = p.IdDriver
                LEFT JOIN UTENTI ud ON ud.IdUtente = g.IdDriverDefault
                WHERE g.IdFiliale = @id AND (g.DataFine IS NULL OR p.IdPiano IS NOT NULL)
                ORDER BY g.Giro", new { id = idFiliale, data = giorno, dal = giorno, al = giorno.AddDays(1) });
            var senzaGiro = await cn.QueryFirstAsync(@"
                SELECT COUNT(*) AS n, SUM(CASE WHEN DestinazioneLatitude IS NOT NULL THEN 1 ELSE 0 END) AS geo
                FROM SPED_ATTIVITA WHERE IdFiliale = @id AND DataCarico >= @dal AND DataCarico < @al AND IdGiro IS NULL",
                new { id = idFiliale, dal = giorno, al = giorno.AddDays(1) });
            var driver = await cn.QueryAsync(@"
                SELECT u.IdUtente AS idUtente, u.Nome AS nome
                FROM UTENTI u
                WHERE ISNULL(u.DataFine, '2079-01-01') > GETDATE()
                  AND ((u.IdRuolo IN (40, 41) AND u.IdFiliale = @id)
                       OR u.IdUtente IN (SELECT IdDriverDefault FROM GEO_GIRI WHERE IdFiliale = @id AND IdDriverDefault IS NOT NULL)
                       OR u.IdUtente IN (SELECT IdDriver FROM GIRI_PIANO WHERE IdFiliale = @id AND Data = @data AND IdDriver IS NOT NULL))
                ORDER BY u.Nome", new { id = idFiliale, data = giorno });
            return Results.Ok(new
            {
                filiale = (string?)f?.filiale, lat = (double?)f?.lat, lng = (double?)f?.lng, data = giorno.ToString("yyyy-MM-dd"),
                giri, senzaGiro = new { n = (int)senzaGiro.n, geo = (int)(senzaGiro.geo ?? 0) }, driver,
            });
        })).RequireAuthorization();

        // driver di un giro per il giorno: { data, idGiro, idDriver | null }
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

        // ottimizzazione di un giro: { data, idGiro } -> richiesta HERE + esecuzione del workflow in coda
        app.MapPost("/api/piano/ottimizza", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            var giorno = Giorno(Testo(b, "data"));
            var idGiro = Intero(b, "idGiro") ?? throw new ErrorePiano("Giro mancante");
            await using var cn = new SqlConnection(connString());
            var r = await cn.QueryFirstAsync("dbo.AI_HERE_Richiesta",
                new { IdFiliale = idFiliale, Data = giorno, IdGiro = idGiro, IdUtente = IdUtente(user), Utente = user.Identity?.Name }, commandType: CommandType.StoredProcedure);
            var idEsecuzione = await Accoda(cn, user.Identity?.Name, JsonSerializer.Serialize(new { IdGeoHereW = (int)r.IdGeoHereW }));
            return Results.Ok(new { idPiano = (int)r.IdPiano, idGeoHereW = (int)r.IdGeoHereW, nPunti = (int)r.NPunti, nSenzaCoordinate = (int)r.NSenzaCoordinate, idEsecuzione });
        })).RequireAuthorization();

        // ottimizzazione di tutti i giri del giorno con spedizioni geolocalizzate: { data, soloDaFare }
        app.MapPost("/api/piano/ottimizza-tutti", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            var giorno = Giorno(Testo(b, "data"));
            var soloDaFare = !(b.TryGetProperty("soloDaFare", out var s) && s.ValueKind == JsonValueKind.False);
            await using var cn = new SqlConnection(connString());
            var giri = await cn.QueryAsync<int>(@"
                SELECT s.IdGiro FROM SPED_ATTIVITA s
                JOIN GEO_GIRI g ON g.IdGiro = s.IdGiro AND g.DataFine IS NULL
                LEFT JOIN GIRI_PIANO p ON p.IdGiro = s.IdGiro AND p.Data = @data
                WHERE s.IdFiliale = @id AND s.DataCarico >= @dal AND s.DataCarico < @al AND s.DestinazioneLatitude IS NOT NULL
                  AND (@solo = 0 OR ISNULL(p.Stato, '') NOT IN ('FATTA', 'RICHIESTA', 'IN_CORSO'))
                GROUP BY s.IdGiro", new { id = idFiliale, data = giorno, dal = giorno, al = giorno.AddDays(1), solo = soloDaFare ? 1 : 0 });
            var richieste = 0; var saltati = new List<string>();
            foreach (var idGiro in giri)
            {
                try
                {
                    await cn.ExecuteAsync("dbo.AI_HERE_Richiesta", new { IdFiliale = idFiliale, Data = giorno, IdGiro = idGiro, IdUtente = IdUtente(user), Utente = user.Identity?.Name }, commandType: CommandType.StoredProcedure);
                    richieste++;
                }
                catch (SqlException ex) { saltati.Add($"giro {idGiro}: {ex.Message}"); }
            }
            int? idEsecuzione = richieste > 0 ? await Accoda(cn, user.Identity?.Name, null) : null;
            return Results.Ok(new { richieste, saltati, idEsecuzione });
        })).RequireAuthorization();

        // il percorso di un piano: i punti nell'ordine di HERE (o, senza ottimizzazione, le spedizioni del giro)
        app.MapGet("/api/piano/{id:int}/percorso", (int id, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var p = await PianoDi(cn, id, Filiale(user));
            var punti = await Percorso(cn, p);
            return Results.Ok(new
            {
                piano = new { idPiano = (int)p.IdPiano, idGiro = (int)p.IdGiro, giro = (string)p.Giro, colore = (string?)p.Colore, data = ((DateTime)p.Data).ToString("yyyy-MM-dd"),
                              stato = (string?)p.Stato, distanzaM = (int?)p.DistanzaM, tempoS = (int?)p.TempoS, driver = (string?)p.Driver, errore = (string?)p.Errore },
                filiale = new { lat = (double?)p.FLat, lng = (double?)p.FLng, nome = (string?)p.Filiale },
                punti,
            });
        })).RequireAuthorization();

        // il percorso in Excel, nell'ordine di consegna
        app.MapGet("/api/piano/{id:int}/export", async (int id, ClaimsPrincipal user) =>
        {
            await using var cn = new SqlConnection(connString());
            var p = await PianoDi(cn, id, Filiale(user));
            var punti = await Percorso(cn, p);
            return Esporta.Xlsx(punti, "Percorso", $"percorso_{((string)p.Giro).Replace(' ', '_')}_{((DateTime)p.Data):yyyyMMdd}", new[] {
                ("Sequenza", "sequenza"), ("Barcode", "barcode"), ("Destinatario", "destinatario"), ("Indirizzo", "indirizzo"), ("CAP", "cap"), ("Località", "localita"),
                ("Arrivo stimato", "arrivo"), ("Km dal punto prima", "km"), ("Minuti dal punto prima", "minuti"), ("Km progressivi", "kmProgressivi") });
        }).RequireAuthorization();

        // lo storico di un piano (driver e ottimizzazioni)
        app.MapGet("/api/piano/{id:int}/storico", (int id) => Prova(async () =>
        {
            await using var cn = new SqlConnection(connString());
            var righe = await cn.QueryAsync(@"
                SELECT CONVERT(varchar(19), v.DataOra, 126) AS dataOra, v.Utente AS utente, v.Campo AS campo,
                       CASE WHEN v.Campo = 'Driver' THEN ISNULL(up.Nome, v.Prima) ELSE v.Prima END AS prima,
                       CASE WHEN v.Campo = 'Driver' THEN ISNULL(ud.Nome, v.Dopo) ELSE v.Dopo END AS dopo
                FROM GIRI_PIANO_VARIAZIONI v
                LEFT JOIN UTENTI up ON v.Campo = 'Driver' AND TRY_CAST(v.Prima AS int) = up.IdUtente
                LEFT JOIN UTENTI ud ON v.Campo = 'Driver' AND TRY_CAST(v.Dopo AS int) = ud.IdUtente
                WHERE v.IdPiano = @id ORDER BY v.IdVariazione DESC", new { id });
            return Results.Ok(righe);
        })).RequireAuthorization();
    }

    static async Task<dynamic> PianoDi(SqlConnection cn, int id, int idFiliale)
    {
        var p = await cn.QueryFirstOrDefaultAsync(@"
            SELECT p.IdPiano, p.Data, p.IdFiliale, p.IdGiro, g.Giro, g.Colore, p.Stato, p.DistanzaM, p.TempoS, p.IdGeoHereW, p.Errore, u.Nome AS Driver,
                   f.FILIALE AS Filiale, f.Latitude AS FLat, f.Longitude AS FLng
            FROM GIRI_PIANO p JOIN GEO_GIRI g ON g.IdGiro = p.IdGiro
            LEFT JOIN UTENTI u ON u.IdUtente = p.IdDriver
            LEFT JOIN FILIALI f ON f.IDFILIALE = p.IdFiliale
            WHERE p.IdPiano = @id", new { id }) ?? throw new ErrorePiano("Piano non trovato");
        if ((int)p.IdFiliale != idFiliale) throw new ErrorePiano("Il piano e' di un'altra filiale");
        return p;
    }

    // i punti del percorso: con l'ottimizzazione fatta, nell'ordine di HERE con tempi e distanze; altrimenti le spedizioni
    // del giro con coordinate, senza ordine. km/minuti dal punto precedente, km progressivi (soste escluse dai tempi)
    static async Task<List<dynamic>> Percorso(SqlConnection cn, dynamic p)
    {
        IEnumerable<dynamic> righe;
        if (p.IdGeoHereW is int idHere && (string?)p.Stato == "FATTA")
            righe = await cn.QueryAsync(@"
                SELECT w.Sequenza AS seq, r.IdSpedizione AS idSpedizione, r.IdAttivita AS idAttivita, r.Latitude AS lat, r.Longitude AS lng,
                       CASE WHEN s.IdSpedizione IS NULL THEN r.Indirizzo ELSE ISNULL(s.DestinazioneIndirizzo, '') + ISNULL(' ' + s.DestinazioneNumeroCivico, '') END AS indirizzo,
                       w.TempoViaggio AS tempo, w.Distanza AS distanza, CONVERT(varchar(19), w.DataArrivo, 126) AS arrivo,
                       s.Barcode AS barcode, s.DestinazioneRagioneSociale AS destinatario, s.DestinazioneCap AS cap, s.DestinazioneLocalita AS localita
                FROM GEO_HereWReq r
                JOIN GEO_HereWaypoint w ON w.IdHereReq = CAST(r.IdGeoHereW AS varchar(50)) AND w.IdApi = r.IdGeoHereReq
                LEFT JOIN SPED_ATTIVITA s ON s.IdSpedizione = r.IdSpedizione
                WHERE r.IdGeoHereW = @id ORDER BY w.Sequenza", new { id = idHere });
        else
        {
            DateTime giorno = p.Data;
            righe = await cn.QueryAsync(@"
                SELECT CAST(NULL AS int) AS seq, s.IdSpedizione AS idSpedizione, CAST(NULL AS int) AS idAttivita, s.DestinazioneLatitude AS lat, s.DestinazioneLongitude AS lng,
                       ISNULL(s.DestinazioneIndirizzo, '') + ISNULL(' ' + s.DestinazioneNumeroCivico, '') AS indirizzo,
                       CAST(NULL AS int) AS tempo, CAST(NULL AS int) AS distanza, CAST(NULL AS varchar(19)) AS arrivo,
                       s.Barcode AS barcode, s.DestinazioneRagioneSociale AS destinatario, s.DestinazioneCap AS cap, s.DestinazioneLocalita AS localita
                FROM SPED_ATTIVITA s
                WHERE s.IdFiliale = @idFiliale AND s.IdGiro = @idGiro AND s.DataCarico >= @dal AND s.DataCarico < @al AND s.DestinazioneLatitude IS NOT NULL
                ORDER BY s.Sequenza, s.DestinazioneCap, s.DestinazioneIndirizzo", new { idFiliale = (int)p.IdFiliale, idGiro = (int)p.IdGiro, dal = giorno, al = giorno.AddDays(1) });
        }
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

    static async Task<IResult> Prova(Func<Task<IResult>> f)
    {
        try { return await f(); }
        catch (ErrorePiano ex) { return Results.BadRequest(new { errore = ex.Message }); }
        catch (SqlException ex) { return Results.BadRequest(new { errore = ex.Message }); }
    }
}
