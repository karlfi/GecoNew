using System.Data;
using System.Security.Claims;
using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;

// === Pianificazione automatica (pagina "Pianificazione automatica", menu Gestione Giri Filiale) ===
// Tutte le spedizioni geolocalizzate della filiale (quella del token) in un giorno divise fra i driver scelti con HERE
// Tour Planning: la pagina manda driver e vincoli (turno, partenza/ritorno da casa o filiale, max pezzi, zone preferite =
// giri abituali), AI_PIANO_AUTO_Richiesta crea la versione del piano, il workflow GEO-02_HERE_TOUR (here_tour.py) la
// calcola e scrive driver, fermata, sequenza e arrivo di ogni spedizione in PIANO_AUTO_SPED. La conferma
// (AI_PIANO_AUTO_Conferma) porta la sequenza sulle spedizioni. Tabelle e stored in sql-nuove/PIANO_AUTO.sql.
static class PianoAuto
{
    const string Workflow = "GEO-02_HERE_TOUR";

    class ErrorePiano : Exception { public ErrorePiano(string m) : base(m) { } }

    static int Filiale(ClaimsPrincipal user) =>
        int.TryParse(user.FindFirstValue("idFiliale"), out var f) ? f : throw new ErrorePiano("Filiale non disponibile");

    static DateTime Giorno(string? data) =>
        string.IsNullOrWhiteSpace(data) ? DateTime.Today
        : DateTime.TryParse(data, out var d) ? d.Date : throw new ErrorePiano("Data non valida");

    public static void Map(WebApplication app, Func<string> connString)
    {
        // tutto quello che serve alla pagina per un giorno: filiale, riepilogo, giri, driver con i vincoli proposti
        // (quelli dell'ultimo calcolo del driver, altrimenti i predefiniti), parametri, piano del giorno
        app.MapGet("/api/pianificazione", (string? data, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            var giorno = Giorno(data);
            await using var cn = Operatore.Connessione(connString());
            var f = await cn.QueryFirstOrDefaultAsync("SELECT FILIALE AS nome, Latitude AS lat, Longitude AS lng FROM FILIALI WHERE IDFILIALE = @id", new { id = idFiliale });
            var riepilogo = await cn.QueryFirstAsync(@"
                SELECT COUNT(*) AS nSped,
                       ISNULL(SUM(CASE WHEN DestinazioneLatitude IS NOT NULL AND DestinazioneLongitude IS NOT NULL THEN 1 ELSE 0 END), 0) AS nGeo,
                       COUNT(DISTINCT CASE WHEN DestinazioneLatitude IS NOT NULL
                             THEN CONCAT(ROUND(DestinazioneLatitude, 5), ',', ROUND(DestinazioneLongitude, 5)) END) AS nFermate
                FROM SPED_ATTIVITA WHERE IdFiliale = @id AND DataCarico >= @dal AND DataCarico < @al",
                new { id = idFiliale, dal = giorno, al = giorno.AddDays(1) });
            var giri = await cn.QueryAsync(@"
                SELECT g.IdGiro AS idGiro, g.Giro AS giro, g.Colore AS colore, g.IdDriverDefault AS idDriverDefault
                FROM GEO_GIRI g WHERE g.IdFiliale = @id AND g.DataFine IS NULL ORDER BY g.Giro", new { id = idFiliale });
            var driver = await cn.QueryAsync(@"
                SELECT u.IdUtente AS idUtente, u.Nome AS nome, geo.Lat AS casaLat, geo.Lng AS casaLng, geo.Indirizzo AS casaIndirizzo,
                       CONVERT(varchar(5), ult.Inizio, 108) AS inizio, CONVERT(varchar(5), ult.Fine, 108) AS fine,
                       ult.PartenzaCasa AS partenzaCasa, ult.RitornoCasa AS ritornoCasa, ult.MaxPezzi AS maxPezzi, ult.Giri AS giriJson,
                       (SELECT STRING_AGG(CAST(g.IdGiro AS varchar(12)), ',') FROM GEO_GIRI g
                        WHERE g.IdFiliale = @id AND g.DataFine IS NULL AND g.IdDriverDefault = u.IdUtente) AS giriAbituali,
                       CASE WHEN ultf.IdDriver IS NOT NULL THEN 1 ELSE 0 END AS nellUltimo
                FROM UTENTI u
                LEFT JOIN UTENTI_GEO geo ON geo.IdUtente = u.IdUtente
                OUTER APPLY (SELECT TOP 1 d.Inizio, d.Fine, d.PartenzaCasa, d.RitornoCasa, d.MaxPezzi, d.Giri
                             FROM PIANO_AUTO_DRIVER d JOIN PIANO_AUTO p ON p.IdPianoAuto = d.IdPianoAuto
                             WHERE d.IdDriver = u.IdUtente AND p.IdFiliale = @id ORDER BY d.IdPianoAutoDriver DESC) ult
                OUTER APPLY (SELECT TOP 1 d.IdDriver FROM PIANO_AUTO_DRIVER d
                             WHERE d.IdDriver = u.IdUtente
                               AND d.IdPianoAuto = (SELECT MAX(IdPianoAuto) FROM PIANO_AUTO WHERE IdFiliale = @id)) ultf
                WHERE ISNULL(u.DataFine, '2079-01-01') > GETDATE()
                  AND ((u.IdRuolo IN (40, 41) AND u.IdFiliale = @id)
                       OR u.IdUtente IN (SELECT IdDriverDefault FROM GEO_GIRI WHERE IdFiliale = @id AND DataFine IS NULL AND IdDriverDefault IS NOT NULL))
                ORDER BY u.Nome", new { id = idFiliale });
            var ultimiParametri = await cn.ExecuteScalarAsync<string?>(
                "SELECT TOP 1 Parametri FROM PIANO_AUTO WHERE IdFiliale = @id ORDER BY IdPianoAuto DESC", new { id = idFiliale });
            var sosta = await cn.ExecuteScalarAsync<string?>("SELECT Codice FROM LISTA_VALORI WHERE Lista = 'HERE' AND Valore = 'sosta'");
            // il piano del giorno: il confermato, altrimenti l'ultimo calcolo
            var idPiano = await cn.ExecuteScalarAsync<int?>(@"
                SELECT TOP 1 IdPianoAuto FROM PIANO_AUTO WHERE IdFiliale = @id AND Data = @data
                ORDER BY CASE WHEN Stato = 'CONFERMATO' THEN 0 ELSE 1 END, IdPianoAuto DESC", new { id = idFiliale, data = giorno });
            return Results.Ok(new
            {
                filiale = new { nome = (string?)f?.nome, lat = (double?)f?.lat, lng = (double?)f?.lng },
                data = giorno.ToString("yyyy-MM-dd"),
                riepilogo, giri, driver,
                parametri = ultimiParametri,
                sostaPredefinita = int.TryParse(sosta, out var s) ? s : 60,
                piano = idPiano is int ip ? await Piano(cn, ip) : null,
            });
        })).RequireAuthorization();

        // le spedizioni geolocalizzate del giorno per la mappa, col risultato del piano se c'e'
        app.MapGet("/api/pianificazione/punti", (string? data, int? idPiano, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            var giorno = Giorno(data);
            await using var cn = Operatore.Connessione(connString());
            var punti = await cn.QueryAsync(@"
                SELECT s.IdSpedizione AS id, s.DestinazioneLatitude AS lat, s.DestinazioneLongitude AS lng, s.IdGiro AS idGiro,
                       s.Barcode AS barcode, s.DestinazioneRagioneSociale AS destinatario,
                       ISNULL(s.DestinazioneIndirizzo, '') + ISNULL(' ' + s.DestinazioneNumeroCivico, '') AS indirizzo,
                       s.DestinazioneCap AS cap, s.DestinazioneLocalita AS localita,
                       p.IdDriver AS idDriver, p.Fermata AS fermata, p.Sequenza AS sequenza,
                       CONVERT(varchar(16), p.Arrivo, 126) AS arrivo, p.Motivo AS motivo, CASE WHEN p.IdSpedizione IS NULL THEN 0 ELSE 1 END AS nelPiano
                FROM SPED_ATTIVITA s
                LEFT JOIN PIANO_AUTO_SPED p ON p.IdPianoAuto = @idPiano AND p.IdSpedizione = s.IdSpedizione
                WHERE s.IdFiliale = @id AND s.DataCarico >= @dal AND s.DataCarico < @al
                  AND s.DestinazioneLatitude IS NOT NULL AND s.DestinazioneLongitude IS NOT NULL",
                new { id = idFiliale, dal = giorno, al = giorno.AddDays(1), idPiano = idPiano ?? 0 });
            return Results.Ok(punti);
        })).RequireAuthorization();

        // nuovo calcolo: { data, parametri: {...}, driver: [{ idDriver, inizio, fine, partenzaCasa, ritornoCasa, maxPezzi, giri, colore }] }
        app.MapPost("/api/pianificazione/calcola", (JsonElement b, ClaimsPrincipal user) => Prova(async () =>
        {
            var idFiliale = Filiale(user);
            var giorno = Giorno(Testo(b, "data"));
            var driver = b.TryGetProperty("driver", out var d) && d.ValueKind == JsonValueKind.Array ? d.GetRawText() : throw new ErrorePiano("Scegli almeno un driver");
            var parametri = b.TryGetProperty("parametri", out var p) && p.ValueKind == JsonValueKind.Object ? p.GetRawText() : null;
            await using var cn = Operatore.Connessione(connString());
            var r = await cn.QueryFirstAsync("dbo.AI_PIANO_AUTO_Richiesta",
                new { IdFiliale = idFiliale, Data = giorno, Parametri = parametri, Driver = driver, Utente = user.Identity?.Name },
                commandType: CommandType.StoredProcedure);
            int id = r.IdPianoAuto;
            var idEsecuzione = await Accoda(cn, user.Identity?.Name, JsonSerializer.Serialize(new { IdPianoAuto = id }));
            await cn.ExecuteAsync("dbo.AI_PIANO_AUTO_Esecuzione", new { IdPianoAuto = id, IdEsecuzione = idEsecuzione }, commandType: CommandType.StoredProcedure);
            return Results.Ok(new { idPiano = id, nSpedizioni = (int)r.NSpedizioni, nSenzaCoordinate = (int)r.NSenzaCoordinate, idEsecuzione });
        })).RequireAuthorization();

        // avanzamento del calcolo: stato del piano e dell'esecuzione dello schedulatore (ultimo messaggio del log)
        app.MapGet("/api/pianificazione/{id:int}/stato", (int id, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = Operatore.Connessione(connString());
            var p = await cn.QueryFirstOrDefaultAsync(@"
                SELECT p.IdFiliale, p.Stato AS stato, p.Errore AS errore, p.IdEsecuzione,
                       DATEDIFF(second, p.DataRichiesta, ISNULL(p.DataRisposta, GETDATE())) AS secondi,
                       s.Nome AS statoEsecuzione, e.Avanzamento AS avanzamento,
                       (SELECT TOP 1 l.Messaggio FROM WF_EsecuzioneLog l WHERE l.IdEsecuzione = p.IdEsecuzione ORDER BY l.IdLog DESC) AS ultimoMessaggio
                FROM PIANO_AUTO p
                LEFT JOIN WF_Esecuzione e ON e.IdEsecuzione = p.IdEsecuzione
                LEFT JOIN WF_StatoEsecuzione s ON s.Codice = e.Stato
                WHERE p.IdPianoAuto = @id", new { id }) ?? throw new ErrorePiano("Piano non trovato");
            if ((int)p.IdFiliale != Filiale(user)) throw new ErrorePiano("Il piano e' di un'altra filiale");
            return Results.Ok(new
            {
                stato = (string)p.stato, errore = (string?)p.errore, secondi = (int?)p.secondi,
                statoEsecuzione = (string?)p.statoEsecuzione, avanzamento = (int?)p.avanzamento, ultimoMessaggio = (string?)p.ultimoMessaggio,
            });
        })).RequireAuthorization();

        app.MapGet("/api/pianificazione/{id:int}", (int id, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = Operatore.Connessione(connString());
            var piano = await Piano(cn, id);
            if (piano.idFiliale != Filiale(user)) throw new ErrorePiano("Il piano e' di un'altra filiale");
            return Results.Ok(piano);
        })).RequireAuthorization();

        app.MapPost("/api/pianificazione/{id:int}/conferma", (int id, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = Operatore.Connessione(connString());
            await DellaFiliale(cn, id, Filiale(user));
            await cn.ExecuteAsync("dbo.AI_PIANO_AUTO_Conferma", new { IdPianoAuto = id, Utente = user.Identity?.Name }, commandType: CommandType.StoredProcedure);
            return Results.Ok(await Piano(cn, id));
        })).RequireAuthorization();

        app.MapPost("/api/pianificazione/{id:int}/scarta", (int id, ClaimsPrincipal user) => Prova(async () =>
        {
            await using var cn = Operatore.Connessione(connString());
            await DellaFiliale(cn, id, Filiale(user));
            await cn.ExecuteAsync("dbo.AI_PIANO_AUTO_Scarta", new { IdPianoAuto = id, Utente = user.Identity?.Name }, commandType: CommandType.StoredProcedure);
            return Results.Ok(await Piano(cn, id));
        })).RequireAuthorization();

        // il giro di un driver in Excel, nell'ordine di consegna
        app.MapGet("/api/pianificazione/{id:int}/driver/{idDriver:int}/export", async (int id, int idDriver, ClaimsPrincipal user) =>
        {
            await using var cn = Operatore.Connessione(connString());
            try { await DellaFiliale(cn, id, Filiale(user)); }
            catch (ErrorePiano ex) { return Results.BadRequest(new { errore = ex.Message }); }
            var righe = (await cn.QueryAsync(@"
                SELECT p.Sequenza AS sequenza, p.Fermata AS fermata, CONVERT(varchar(5), p.Arrivo, 108) AS arrivo, s.Barcode AS barcode,
                       s.DestinazioneRagioneSociale AS destinatario, ISNULL(s.DestinazioneIndirizzo, '') + ISNULL(' ' + s.DestinazioneNumeroCivico, '') AS indirizzo,
                       s.DestinazioneCap AS cap, s.DestinazioneLocalita AS localita, g.Giro AS giro
                FROM PIANO_AUTO_SPED p JOIN SPED_ATTIVITA s ON s.IdSpedizione = p.IdSpedizione
                LEFT JOIN GEO_GIRI g ON g.IdGiro = s.IdGiro
                WHERE p.IdPianoAuto = @id AND p.IdDriver = @idDriver ORDER BY p.Sequenza", new { id, idDriver })).ToList();
            var nome = (await cn.ExecuteScalarAsync<string?>("SELECT Nome FROM UTENTI WHERE IdUtente = @idDriver", new { idDriver }) ?? "driver").Replace(' ', '_');
            var data = await cn.ExecuteScalarAsync<DateTime>("SELECT Data FROM PIANO_AUTO WHERE IdPianoAuto = @id", new { id });
            return Esporta.Xlsx(righe, "Giro", $"pianificazione_{nome}_{data:yyyyMMdd}", new[] {
                ("Sequenza", "sequenza"), ("Fermata", "fermata"), ("Arrivo stimato", "arrivo"), ("Barcode", "barcode"), ("Destinatario", "destinatario"),
                ("Indirizzo", "indirizzo"), ("CAP", "cap"), ("Località", "localita"), ("Giro", "giro") });
        }).RequireAuthorization();
    }

    // un piano con i driver e i loro risultati
    static async Task<dynamic> Piano(SqlConnection cn, int id)
    {
        var p = await cn.QueryFirstOrDefaultAsync(@"
            SELECT IdPianoAuto AS idPiano, IdFiliale AS idFiliale, CONVERT(varchar(10), Data, 126) AS data, Stato AS stato, Parametri AS parametri,
                   NSpedizioni AS nSpedizioni, NFermate AS nFermate, NAssegnate AS nAssegnate, NNonAssegnate AS nNonAssegnate,
                   DistanzaM AS distanzaM, TempoS AS tempoS, Transazioni AS transazioni, Errore AS errore,
                   CONVERT(varchar(19), DataRichiesta, 126) AS dataRichiesta, CONVERT(varchar(19), DataRisposta, 126) AS dataRisposta,
                   CONVERT(varchar(19), DataConferma, 126) AS dataConferma, Utente AS utente, UtenteConferma AS utenteConferma
            FROM PIANO_AUTO WHERE IdPianoAuto = @id", new { id }) ?? throw new ErrorePiano("Piano non trovato");
        var driver = await cn.QueryAsync(@"
            SELECT d.IdDriver AS idDriver, u.Nome AS nome, CONVERT(varchar(5), d.Inizio, 108) AS inizio, CONVERT(varchar(5), d.Fine, 108) AS fine,
                   d.PartenzaCasa AS partenzaCasa, d.RitornoCasa AS ritornoCasa, d.MaxPezzi AS maxPezzi, d.Giri AS giriJson, d.Colore AS colore,
                   d.NPezzi AS nPezzi, d.NFermate AS nFermate, d.DistanzaM AS distanzaM, d.TempoS AS tempoS,
                   CONVERT(varchar(16), d.OraInizio, 126) AS oraInizio, CONVERT(varchar(16), d.OraFine, 126) AS oraFine
            FROM PIANO_AUTO_DRIVER d JOIN UTENTI u ON u.IdUtente = d.IdDriver
            WHERE d.IdPianoAuto = @id ORDER BY u.Nome", new { id });
        var d = (IDictionary<string, object?>)p;
        d["driver"] = driver;
        return p;
    }

    static async Task DellaFiliale(SqlConnection cn, int id, int idFiliale)
    {
        var fil = await cn.ExecuteScalarAsync<int?>("SELECT IdFiliale FROM PIANO_AUTO WHERE IdPianoAuto = @id", new { id }) ?? throw new ErrorePiano("Piano non trovato");
        if (fil != idFiliale) throw new ErrorePiano("Il piano e' di un'altra filiale");
    }

    static async Task<int> Accoda(SqlConnection cn, string? utente, string? parametri)
    {
        var idWorkflow = await cn.ExecuteScalarAsync<int?>("SELECT IdWorkflow FROM dbo.WF_Workflow WHERE Nome = @nome AND Attivo = 1", new { nome = Workflow })
            ?? throw new ErrorePiano($"Nello schedulatore manca il workflow {Workflow}");
        var p = new DynamicParameters(new
        {
            IdWorkflow = idWorkflow, Origine = "MANUALE", Parametri = parametri, DataOraPrevista = (DateTime?)null,
            GruppoConcorrenza = (string?)null, NomeUtente = utente, IdPianificazione = (int?)null, IdDettaglio = (int?)null,
        });
        p.Add("@IdEsecuzione", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await cn.ExecuteAsync("dbo.WF_usp_Esecuzione_Crea", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@IdEsecuzione");
    }

    static string? Testo(JsonElement b, string nome) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(nome, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static async Task<IResult> Prova(Func<Task<IResult>> f)
    {
        try { return await f(); }
        catch (ErrorePiano ex) { return Results.BadRequest(new { errore = ex.Message }); }
        catch (SqlException ex) { return Results.BadRequest(new { errore = ex.Message }); }
    }
}
