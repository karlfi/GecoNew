using System.Data;
using System.Security.Claims;
using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;

// === Spedizioni del giorno e giri (pagina "Spedizioni del giorno") ===
// Le spedizioni caricate in un giorno (SPED_ATTIVITA.DataCarico) per la filiale dell'utente, con il
// giro assegnato e il punto di consegna; assegnazione automatica (AI_SPED_AssegnaGiri: CAP fisso >
// comune fisso > area), a mano (AI_SPED_Giro) e spostamento del punto (AI_SPED_Posizione), tutto
// con lo storico in SPED_GEO_VARIAZIONI.
static class SpedGiri
{
    class ErroreSped : Exception { public ErroreSped(string m) : base(m) { } }

    static int Filiale(ClaimsPrincipal user) =>
        int.TryParse(user.FindFirstValue("idFiliale"), out var f) ? f : throw new ErroreSped("Filiale non disponibile");

    static DateTime Giorno(string? data) =>
        string.IsNullOrWhiteSpace(data) ? DateTime.Today
        : DateTime.TryParse(data, out var d) ? d.Date : throw new ErroreSped("Data non valida");

    public static void Map(WebApplication app, Func<string> connString)
    {
        // le spedizioni del giorno con giro e punto, i giri attivi della filiale, se la filiale e' geocodificata
        app.MapGet("/api/sped-giri", (string? data, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            var giorno = Giorno(data);
            await using var cn = Operatore.Connessione(connString());
            var f = await cn.QueryFirstOrDefaultAsync(
                "SELECT FILIALE AS filiale, Latitude AS lat, Longitude AS lng, ISNULL(GeoNormalizza, 0) AS geo FROM FILIALI WHERE IDFILIALE = @id", new { id = idFiliale });
            var sped = await cn.QueryAsync(@"
                SELECT s.IdSpedizione AS idSpedizione, s.Barcode AS barcode, s.IdCliente AS idCliente, c.RagioneSociale AS cliente, p.Prodotto AS prodotto,
                       s.DestinazioneRagioneSociale AS destinatario, s.DestinazioneIndirizzo AS indirizzo, s.DestinazioneNumeroCivico AS civico,
                       s.DestinazioneCap AS cap, s.DestinazioneLocalita AS localita, s.DestinazioneProvinciaCodice AS prov, s.Belfiore AS belfiore,
                       s.DestinazioneLatitude AS lat, s.DestinazioneLongitude AS lng,
                       s.IdGiro AS idGiro, g.Giro AS giro, g.Colore AS colore, s.Sequenza AS sequenza,
                       CONVERT(varchar(19), s.DataCarico, 126) AS dataCarico
                FROM SPED_ATTIVITA s
                LEFT JOIN GEO_GIRI g ON g.IdGiro = s.IdGiro
                LEFT JOIN CLIENTI c ON c.IdCliente = s.IdCliente
                LEFT JOIN PRODOTTI p ON p.IdProdotto = s.IdProdotto
                WHERE s.IdFiliale = @id AND s.DataCarico >= @dal AND s.DataCarico < @al
                ORDER BY g.Giro, s.DestinazioneCap, s.DestinazioneIndirizzo",
                new { id = idFiliale, dal = giorno, al = giorno.AddDays(1) });
            var giri = await cn.QueryAsync(@"
                SELECT IdGiro AS idGiro, Giro AS giro, Colore AS colore, CAP AS cap, Belfiore AS belfiore
                FROM GEO_GIRI WHERE IdFiliale = @id AND DataFine IS NULL ORDER BY Giro", new { id = idFiliale });
            return Results.Ok(new
            {
                filiale = (string?)f?.filiale, lat = (double?)f?.lat, lng = (double?)f?.lng,
                geoAttiva = f is not null && Convert.ToInt32(f.geo) != 0,
                data = giorno.ToString("yyyy-MM-dd"), spedizioni = sped, giri,
            });
        })).RequireAuthorization();

        // assegnazione automatica: { data, idCliente?, idGiro?, forza }
        app.MapPost("/api/sped-giri/assegna-auto", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = Operatore.Connessione(connString());
            var r = await cn.QueryFirstAsync("dbo.AI_SPED_AssegnaGiri", new
            {
                IdFiliale = Filiale(user), Data = Giorno(Testo(b, "data")), IdCliente = Intero(b, "idCliente"), IdGiro = Intero(b, "idGiro"),
                Forza = b.TryGetProperty("forza", out var f) && f.ValueKind == JsonValueKind.True, Utente = user.Identity?.Name,
            }, commandType: CommandType.StoredProcedure);
            return Results.Ok(r);
        })).RequireAuthorization();

        // assegnazione a mano: { idSpedizioni: [..], idGiro: n | null }
        app.MapPost("/api/sped-giri/assegna", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var ids = b.TryGetProperty("idSpedizioni", out var v) && v.ValueKind == JsonValueKind.Array ? v.EnumerateArray().Select(x => x.GetInt32()).ToList() : new List<int>();
            if (ids.Count == 0) throw new ErroreSped("Nessuna spedizione selezionata");
            await using var cn = Operatore.Connessione(connString());
            var cambiate = await cn.ExecuteScalarAsync<int>("dbo.AI_SPED_Giro",
                new { IdFiliale = Filiale(user), IdSpedizioni = JsonSerializer.Serialize(ids), IdGiro = Intero(b, "idGiro"), Utente = user.Identity?.Name },
                commandType: CommandType.StoredProcedure);
            return Results.Ok(new { cambiate });
        })).RequireAuthorization();

        // punto di consegna spostato o messo: { lat, lng, riassegna }
        app.MapPost("/api/sped-giri/{id:int}/posizione", (int id, JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            if (!b.TryGetProperty("lat", out var la) || !b.TryGetProperty("lng", out var lo) || la.ValueKind != JsonValueKind.Number || lo.ValueKind != JsonValueKind.Number)
                throw new ErroreSped("Coordinate mancanti");
            await using var cn = Operatore.Connessione(connString());
            var appartiene = await cn.ExecuteScalarAsync<int?>("SELECT IdFiliale FROM SPED_ATTIVITA WHERE IdSpedizione = @id", new { id });
            if (appartiene != Filiale(user)) throw new ErroreSped("La spedizione non e' della filiale");
            var r = await cn.QueryFirstAsync("dbo.AI_SPED_Posizione", new
            {
                IdSpedizione = id, Lat = la.GetDouble(), Lng = lo.GetDouble(),
                Riassegna = !(b.TryGetProperty("riassegna", out var ri) && ri.ValueKind == JsonValueKind.False), Utente = user.Identity?.Name,
            }, commandType: CommandType.StoredProcedure);
            return Results.Ok(r);
        })).RequireAuthorization();

        // storico di una spedizione (giro e posizione)
        app.MapGet("/api/sped-giri/{id:int}/variazioni", (int id) => Prova(async () =>
        {
            await using var cn = Operatore.Connessione(connString());
            var righe = await cn.QueryAsync(@"
                SELECT CONVERT(varchar(19), v.DataOra, 126) AS dataOra, v.Utente AS utente, v.Origine AS origine, v.Campo AS campo,
                       CASE WHEN v.Campo = 'Giro' THEN ISNULL(gp.Giro, v.Prima) ELSE v.Prima END AS prima,
                       CASE WHEN v.Campo = 'Giro' THEN ISNULL(gd.Giro, v.Dopo) ELSE v.Dopo END AS dopo
                FROM SPED_GEO_VARIAZIONI v
                LEFT JOIN GEO_GIRI gp ON v.Campo = 'Giro' AND TRY_CAST(v.Prima AS int) = gp.IdGiro
                LEFT JOIN GEO_GIRI gd ON v.Campo = 'Giro' AND TRY_CAST(v.Dopo AS int) = gd.IdGiro
                WHERE v.IdSpedizione = @id ORDER BY v.IdVariazione DESC", new { id });
            return Results.Ok(righe);
        })).RequireAuthorization();
    }

    static string? Testo(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static int? Intero(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;

    static async Task<IResult> Prova(Func<Task<IResult>> f)
    {
        try { return await f(); }
        catch (ErroreSped ex) { return Results.BadRequest(new { errore = ex.Message }); }
        catch (SqlException ex) { return Results.BadRequest(new { errore = ex.Message }); }
    }
}
