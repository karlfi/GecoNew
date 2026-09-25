using System.Data;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using Dapper;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Data.SqlClient;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

var jwtKey = builder.Configuration["Jwt:Key"]
    ?? throw new InvalidOperationException("Jwt:Key mancante in appsettings");
var jwtIssuer = builder.Configuration["Jwt:Issuer"] ?? "GecoApi";
var signingKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtKey));

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o =>
    {
        o.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = jwtIssuer,
            ValidateAudience = false,
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = signingKey,
            ClockSkew = TimeSpan.FromMinutes(1)
        };
    });
builder.Services.AddAuthorization();

builder.Services.AddCors(o => o.AddDefaultPolicy(p => p
    .WithOrigins(builder.Configuration.GetSection("Cors:Origins").Get<string[]>()
        ?? new[] { "http://localhost:5173" })
    .AllowAnyHeader()
    .AllowAnyMethod()));

var app = builder.Build();

// Frontend servito dalla stessa API (porta unica, niente IIS): in produzione il
// contenuto di web/dist viene copiato in wwwroot. In sviluppo wwwroot e' vuoto e
// il frontend gira su Vite (5173) che fa da proxy su /api -> qui.
app.UseDefaultFiles();
app.UseStaticFiles();

app.UseCors();
app.UseAuthentication();
app.UseAuthorization();
// chi fa la richiesta, per l'Operatore dello storico delle modifiche (Operatore.cs)
app.Use(async (ctx, next) => { Operatore.DaRichiesta(ctx.User); await next(); });

string ConnString() => app.Configuration.GetConnectionString("DeliveryDB")
    ?? throw new InvalidOperationException("Connection string DeliveryDB mancante");

string EmettiToken(IEnumerable<Claim> claims) => new JwtSecurityTokenHandler().WriteToken(
    new JwtSecurityToken(
        issuer: jwtIssuer,
        claims: claims,
        expires: DateTime.UtcNow.AddHours(8),
        signingCredentials: new SigningCredentials(signingKey, SecurityAlgorithms.HmacSha256)));

async Task<IDictionary<string, object>?> InfoFiliale(SqlConnection cn, int? idFiliale)
{
    if (idFiliale is null) return null;
    return await cn.QueryFirstOrDefaultAsync(
        "SELECT FILIALE AS nome, Indirizzo AS indirizzo, Comune AS comune FROM FILIALI WHERE IDFILIALE = @id",
        new { id = idFiliale }) as IDictionary<string, object>;
}

// === Configurazione generica: tabelle modificabili dal motore unico ===
// Allowlist key->tabella reale: solo queste tabelle sono raggiungibili dagli endpoint /api/config.
var ConfigTabelle = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
{
    ["coperture"] = "GEO_COPERTURE",
    ["prodotti"] = "PRODOTTI",
    ["listini"] = "FATT_LISTINI",
    ["processi"] = "PROCESSI",
    ["gruppi"] = "GRUPPI",
    ["aziende"] = "AZIENDE",
    ["filiali"] = "FILIALI",
    ["clienti"] = "CLIENTI",
    ["tracciati"] = "FILE_TRACCIATO",
    ["fornitori"] = "FORNITORI",
    ["lista"] = "LISTA_VALORI",
    ["mittenti"] = "MITTENTI",
    ["stati"] = "SPED_STATI",
    ["interrogazioni"] = "INTERROGAZIONI",
    ["menu"] = "MENU_ELEMENTI",
    ["manutenzioni"] = "MEZZI_NOTE",
    ["sinistri"] = "MEZZI_SINISTRI"
};

bool TipoBinario(string t) => t is "image" or "varbinary" or "binary" or "timestamp"
    or "rowversion" or "geography" or "geometry" or "hierarchyid" or "sql_variant";
bool TipoTesto(string t) => t is "char" or "varchar" or "nchar" or "nvarchar" or "text" or "ntext";

async Task<List<ColMeta>> LoadColonne(SqlConnection cn, string tabella)
{
    // I CAST sono necessari: ColMeta e' un record posizionale e Dapper pretende che i tipi
    // letti combacino col costruttore. sys.columns.max_length e' smallint (->int) e il flag
    // PK e' un'espressione int (->bit/bool). Senza cast la materializzazione fallisce.
    var rows = await cn.QueryAsync<ColMeta>(@"
        SELECT c.name AS Col, ty.name AS Tipo, CAST(c.max_length AS int) AS MaxLen,
               c.is_nullable AS Nullable, c.is_identity AS Identita,
               CAST(CASE WHEN pk.column_id IS NOT NULL THEN 1 ELSE 0 END AS bit) AS Pk
        FROM sys.columns c
        JOIN sys.types ty ON ty.user_type_id = c.user_type_id
        LEFT JOIN (
            SELECT ic.column_id FROM sys.indexes i
            JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID(@t)
        ) pk ON pk.column_id = c.column_id
        WHERE c.object_id = OBJECT_ID(@t)
        ORDER BY c.column_id", new { t = tabella });
    return rows.ToList();
}

object? JsonToClr(JsonElement e) => e.ValueKind switch
{
    JsonValueKind.Null => null,
    JsonValueKind.True => true,
    JsonValueKind.False => false,
    JsonValueKind.Number => e.TryGetInt64(out var l) ? l : e.GetDouble(),
    JsonValueKind.String => e.GetString() is { Length: 0 } ? null : e.GetString(),
    _ => e.ToString()
};

// Province soppresse nel 2016: le tabelle dei comuni portano ancora le sigle
// vecchie, ma i dipendenti vanno registrati con la provincia di oggi.
static string ProvinciaAttuale(string? p) => (p ?? "").Trim().ToUpperInvariant() switch
{
    "OT" => "SS",   // Olbia-Tempio    -> Sassari
    "OG" => "NU",   // Ogliastra       -> Nuoro
    "VS" => "SU",   // Medio Campidano -> Sud Sardegna
    "CI" => "SU",   // Carbonia-Iglesias -> Sud Sardegna
    var x => x
};

// Le date arrivano dal browser come "2026-06-16". La sessione SQL gira in
// italiano (serve alle stored legacy, che le date se le costruiscono in quel
// formato) e in quella lingua la forma corta su datetime/smalldatetime viene
// letta come giorno-mese: o va in errore (giorno > 12) o scambia i due numeri
// in silenzio. Sapendo dal catalogo che la colonna e' una data, qui la stringa
// diventa una data vera, che ambigua non e'.
static object? ValorePerColonna(object? v, string? tipoSql)
{
    if (v is not string s || s.Length == 0) return v;
    if ((tipoSql ?? "").ToLowerInvariant() is not
        ("date" or "datetime" or "datetime2" or "smalldatetime" or "datetimeoffset")) return v;
    var it = System.Globalization.CultureInfo.GetCultureInfo("it-IT");
    if (DateTime.TryParse(s, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.None, out var d)
        || DateTime.TryParse(s, it, System.Globalization.DateTimeStyles.None, out d)) return d;
    return v;
}

app.MapGet("/api/ping", () => Results.Ok(new { ok = true, ora = DateTime.Now }));

// Login: verifica via SP AI_AuthLogin, emette il JWT
app.MapPost("/api/auth/login", async (LoginRequest req) =>
{
    if (string.IsNullOrWhiteSpace(req.Utente) || string.IsNullOrWhiteSpace(req.Password))
        return Results.BadRequest(new { errore = "Utente e password sono obbligatori" });

    await using var cn = Operatore.Connessione(ConnString());
    using var multi = await cn.QueryMultipleAsync(
        "dbo.AI_AuthLogin",
        new { Utente = req.Utente, Pwd = req.Password },
        commandType: CommandType.StoredProcedure);

    var prima = await multi.ReadFirstAsync();
    int esito = (int)prima.Esito;

    if (esito != 0)
    {
        // 1 = credenziali non valide, 3 = utente solo-palmare: stesso messaggio generico
        var messaggio = esito == 2
            ? "Utente bloccato per troppi tentativi: contattare l'amministratore"
            : "Credenziali non valide";
        return Results.Json(new { errore = messaggio }, statusCode: StatusCodes.Status401Unauthorized);
    }

    var gruppi = (await multi.ReadAsync()).Select(g => (string)g.Gruppo).ToList();

    // variabile globale @[IdAzienda]: azienda della filiale dell'utente
    int? idAzienda = null;
    if ((int?)prima.IdFiliale is int idFil)
        idAzienda = await cn.ExecuteScalarAsync<int?>(
            "SELECT IdAzienda FROM FILIALI WHERE IDFILIALE = @idFil", new { idFil });

    var claims = new List<Claim>
    {
        new(ClaimTypes.NameIdentifier, ((int)prima.IdUtente).ToString()),
        new(ClaimTypes.Name, (string)prima.Utente),
        new("nome", (string?)prima.Nome ?? ""),
        new(ClaimTypes.Role, (string?)prima.Ruolo ?? ""),
        new("idRuolo", ((int?)prima.IdRuolo)?.ToString() ?? ""),
        new("idFiliale", ((int?)prima.IdFiliale)?.ToString() ?? ""),
        new("idCliente", ((int?)prima.IdCliente)?.ToString() ?? ""),
        new("idAzienda", idAzienda?.ToString() ?? "")
    };
    claims.AddRange(gruppi.Select(g => new Claim("gruppo", g)));

    return Results.Ok(new
    {
        token = EmettiToken(claims),
        utente = new
        {
            idUtente = (int)prima.IdUtente,
            utente = (string)prima.Utente,
            nome = (string?)prima.Nome,
            email = (string?)prima.Email,
            ruolo = (string?)prima.Ruolo,
            idRuolo = (int?)prima.IdRuolo,
            idFiliale = (int?)prima.IdFiliale,
            idCliente = (int?)prima.IdCliente,
            idAzienda,
            filiale = await InfoFiliale(cn, (int?)prima.IdFiliale),
            gruppi
        }
    });
});

// Filiali tra cui l'utente puo' scegliere (SP legacy ElencoFiliali, tipo 3)
app.MapGet("/api/me/filiali", async (ClaimsPrincipal user) =>
{
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var filiali = (await cn.QueryAsync(
                "dbo.ElencoFiliali",
                new { IdUtente = idUtente },
                commandType: CommandType.StoredProcedure))
            .Cast<IDictionary<string, object>>()
            .Select(f => new
            {
                idFiliale = Convert.ToInt32(f["idfiliale"]),
                filiale = f["filiale"] as string
            });
        return Results.Ok(filiali);
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = $"Errore DB: {ex.Message}" },
            statusCode: StatusCodes.Status500InternalServerError);
    }
}).RequireAuthorization();

// Cambio filiale: verifica che sia tra quelle ammesse e riemette il token
// con idFiliale/idAzienda aggiornati (le variabili globali seguono il token)
app.MapPost("/api/me/filiale", async (CambiaFilialeRequest req, ClaimsPrincipal user) =>
{
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var ammesse = (await cn.QueryAsync(
                "dbo.ElencoFiliali",
                new { IdUtente = idUtente },
                commandType: CommandType.StoredProcedure))
            .Cast<IDictionary<string, object>>();
        if (!ammesse.Any(f => Convert.ToInt32(f["idfiliale"]) == req.IdFiliale))
            return Results.BadRequest(new { errore = "Filiale non consentita per questo utente" });

        var idAzienda = await cn.ExecuteScalarAsync<int?>(
            "SELECT IdAzienda FROM FILIALI WHERE IDFILIALE = @id", new { id = req.IdFiliale });
        var filiale = await InfoFiliale(cn, req.IdFiliale);

        var scartati = new[] { "idFiliale", "idAzienda", "exp", "iss", "aud", "iat", "nbf", "jti" };
        var claims = user.Claims.Where(c => !scartati.Contains(c.Type)).ToList();
        claims.Add(new Claim("idFiliale", req.IdFiliale.ToString()));
        claims.Add(new Claim("idAzienda", idAzienda?.ToString() ?? ""));

        return Results.Ok(new
        {
            token = EmettiToken(claims),
            idFiliale = req.IdFiliale,
            idAzienda,
            filiale
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = $"Errore DB: {ex.Message}" },
            statusCode: StatusCodes.Status500InternalServerError);
    }
}).RequireAuthorization();

// Identità corrente (dal token)
app.MapGet("/api/me", (ClaimsPrincipal user) => Results.Ok(new
{
    idUtente = user.FindFirstValue(ClaimTypes.NameIdentifier),
    utente = user.Identity?.Name,
    nome = user.FindFirstValue("nome"),
    ruolo = user.FindFirstValue(ClaimTypes.Role),
    idFiliale = user.FindFirstValue("idFiliale"),
    gruppi = user.FindAll("gruppo").Select(c => c.Value)
})).RequireAuthorization();

// Dati per i grafici della dashboard, filtrati sulla filiale corrente (dal token)
app.MapGet("/api/dashboard/punteggi", async (ClaimsPrincipal user) =>
{
    var idFilStr = user.FindFirstValue("idFiliale");
    if (!int.TryParse(idFilStr, out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile nel profilo" });

    try
    {
        await using var cn = Operatore.Connessione(ConnString());

        // Stessa logica delle viste legacy V_DW_punteggiMese / V_DW_punteggiGiorno (giornata = riga driver/giorno
        // con punteggio > 0, media = punteggio / giornate), piu' i PEZZI: la somma di tutto cio' che il driver ha
        // lavorato (parcel di ogni cliente, raccomandate, M1, M2, AG, bancario), cioe' gli stessi conteggi che
        // entrano nel punteggio. Medie: pezzi per giornata di driver e, in azienda, pezzi per filiale.
        const string PEZZI = @"(ISNULL(Parcel_Poste,0)+ISNULL(Parcel_Hermes,0)+ISNULL(Parcel_InPost,0)+ISNULL(Parcel_iMile,0)+ISNULL(Parcel_Folletto,0)+ISNULL(Parcel_Altri,0)+ISNULL(Parcel_Speedy,0)+ISNULL(SDA_Bancario,0)+ISNULL(Parcel_Gofo,0)
                                +ISNULL(RAC140_AvvSco,0)+ISNULL(RAC140_Cons,0)+ISNULL(M1_Cons,0)+ISNULL(M1_Ass,0)+ISNULL(M1_Sco,0)+ISNULL(M2_Cons,0)+ISNULL(AG,0)+ISNULL(M2_Ass,0)+ISNULL(M2_Sco,0))";
        const string MESE = "RIGHT(CONVERT(varchar(4), Anno), 2) + '-' + RIGHT('00' + CONVERT(varchar(3), Mese), 2)";

        var mese = await cn.QueryAsync($@"
            SELECT {MESE} AS mese, SUM(Punteggio) AS punteggio,
                   SUM(CASE WHEN Punteggio > 0 THEN 1 ELSE 0 END) AS giornate,
                   CONVERT(int, SUM(Punteggio) / NULLIF(SUM(CASE WHEN Punteggio > 0 THEN 1 ELSE 0 END), 0)) AS media,
                   SUM({PEZZI}) AS pezzi, COUNT(DISTINCT Driver) AS driver,
                   CONVERT(int, ROUND(1.0 * SUM({PEZZI}) / NULLIF(SUM(CASE WHEN Punteggio > 0 THEN 1 ELSE 0 END), 0), 0)) AS pezziGiornata
            FROM V_UtentiAttivita2024
            WHERE IDFILIALE = @id AND Data >= DATEADD(month, -10, GETDATE())
            GROUP BY Anno, Mese ORDER BY Anno, Mese", new { id = idFiliale }, commandTimeout: 120);

        var giorno = await cn.QueryAsync($@"
            SELECT CONVERT(varchar(10), Data, 23) AS data, SUM(Punteggio) AS punteggio, COUNT(*) AS giornate,
                   CONVERT(int, SUM(Punteggio) / COUNT(*)) AS media,
                   SUM({PEZZI}) AS pezzi, CONVERT(int, ROUND(1.0 * SUM({PEZZI}) / COUNT(*), 0)) AS pezziGiornata
            FROM V_UtentiAttivita2024
            WHERE IDFILIALE = @id AND Punteggio > 0 AND Data >= DATEADD(day, -15, GETDATE())
            GROUP BY Data ORDER BY Data", new { id = idFiliale }, commandTimeout: 120);

        // azienda della filiale corrente
        var idAzienda = await cn.ExecuteScalarAsync<int?>(
            "SELECT IdAzienda FROM FILIALI WHERE IDFILIALE = @id", new { id = idFiliale });
        var aziendaNome = await cn.ExecuteScalarAsync<string>(
            "SELECT Azienda FROM AZIENDE WHERE IdAzienda = @a", new { a = idAzienda });

        // aggregato AZIENDA: somma punteggi, pezzi e giornate su tutte le filiali attive; media pesata =
        // somma punteggi / somma giornate (NON media delle medie); pezzi per filiale = pezzi / filiali con attivita'
        var meseAzienda = await cn.QueryAsync($@"
            SELECT {MESE} AS mese, SUM(v.Punteggio) AS punteggio,
                   SUM(CASE WHEN v.Punteggio > 0 THEN 1 ELSE 0 END) AS giornate,
                   CONVERT(int, SUM(v.Punteggio) / NULLIF(SUM(CASE WHEN v.Punteggio > 0 THEN 1 ELSE 0 END), 0)) AS media,
                   SUM({PEZZI}) AS pezzi, COUNT(DISTINCT v.IDFILIALE) AS filiali, COUNT(DISTINCT v.Driver) AS driver,
                   CONVERT(int, ROUND(1.0 * SUM({PEZZI}) / NULLIF(SUM(CASE WHEN v.Punteggio > 0 THEN 1 ELSE 0 END), 0), 0)) AS pezziGiornata,
                   CONVERT(int, ROUND(1.0 * SUM({PEZZI}) / NULLIF(COUNT(DISTINCT v.IDFILIALE), 0), 0)) AS pezziFiliale
            FROM V_UtentiAttivita2024 v
            JOIN FILIALI f ON f.IDFILIALE = v.IDFILIALE
            WHERE f.IdAzienda = @a AND f.DataChiusura IS NULL AND v.Data >= DATEADD(month, -10, GETDATE())
            GROUP BY v.Anno, v.Mese ORDER BY v.Anno, v.Mese", new { a = idAzienda }, commandTimeout: 120);

        var giornoAzienda = await cn.QueryAsync($@"
            SELECT CONVERT(varchar(10), v.Data, 23) AS data, SUM(v.Punteggio) AS punteggio, COUNT(*) AS giornate,
                   CONVERT(int, SUM(v.Punteggio) / COUNT(*)) AS media,
                   SUM({PEZZI}) AS pezzi, COUNT(DISTINCT v.IDFILIALE) AS filiali,
                   CONVERT(int, ROUND(1.0 * SUM({PEZZI}) / COUNT(*), 0)) AS pezziGiornata,
                   CONVERT(int, ROUND(1.0 * SUM({PEZZI}) / NULLIF(COUNT(DISTINCT v.IDFILIALE), 0), 0)) AS pezziFiliale
            FROM V_UtentiAttivita2024 v
            JOIN FILIALI f ON f.IDFILIALE = v.IDFILIALE
            WHERE f.IdAzienda = @a AND f.DataChiusura IS NULL AND v.Punteggio > 0 AND v.Data >= DATEADD(day, -15, GETDATE())
            GROUP BY v.Data ORDER BY v.Data", new { a = idAzienda }, commandTimeout: 120);

        // confronto filiali attive dell'azienda sull'ultimo mese disponibile
        var meseLabel = await cn.ExecuteScalarAsync<string>($"SELECT MAX({MESE}) FROM V_UtentiAttivita2024 WHERE Data >= DATEADD(month, -10, GETDATE())");
        var confrontoFiliali = await cn.QueryAsync($@"
            SELECT v.IDFILIALE AS idFiliale, f.FILIALE AS filiale, SUM(v.Punteggio) AS punteggio,
                   CONVERT(int, SUM(v.Punteggio) / NULLIF(SUM(CASE WHEN v.Punteggio > 0 THEN 1 ELSE 0 END), 0)) AS media,
                   SUM(CASE WHEN v.Punteggio > 0 THEN 1 ELSE 0 END) AS giornate,
                   SUM({PEZZI}) AS pezzi, COUNT(DISTINCT v.Driver) AS driver,
                   CONVERT(int, ROUND(1.0 * SUM({PEZZI}) / NULLIF(SUM(CASE WHEN v.Punteggio > 0 THEN 1 ELSE 0 END), 0), 0)) AS pezziGiornata
            FROM V_UtentiAttivita2024 v
            JOIN FILIALI f ON f.IDFILIALE = v.IDFILIALE
            WHERE f.IdAzienda = @a AND f.DataChiusura IS NULL AND {MESE} = @mese
            GROUP BY v.IDFILIALE, f.FILIALE
            ORDER BY SUM(v.Punteggio) DESC", new { a = idAzienda, mese = meseLabel }, commandTimeout: 120);

        return Results.Ok(new
        {
            idFiliale, mese, giorno,
            idAzienda, aziendaNome, meseLabel,
            meseAzienda, giornoAzienda, confrontoFiliali
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = $"Errore DB: {ex.Message}" },
            statusCode: StatusCodes.Status500InternalServerError);
    }
}).RequireAuthorization();

// Menu dell'utente: l'IdUtente arriva dal token, non dal client
app.MapGet("/api/me/menu", async (ClaimsPrincipal user) =>
{
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);

    try
    {
        await using var cn = Operatore.Connessione(ConnString());
        IEnumerable<dynamic> voci;
        try
        {
            // versione nuova: restituisce anche il campo Link
            voci = await cn.QueryAsync("dbo.AI_ElencoMenuGruppi",
                new { IdUtente = idUtente }, commandType: CommandType.StoredProcedure);
        }
        catch (SqlException) // AI_ElencoMenuGruppi non ancora creata: uso la legacy (senza Link)
        {
            voci = await cn.QueryAsync("dbo.ElencoMenuGruppi",
                new { IdUtente = idUtente }, commandType: CommandType.StoredProcedure);
        }
        return Results.Ok(voci.Cast<IDictionary<string, object>>());
    }
    catch (SqlException ex)
    {
        return Results.Json(
            new { errore = $"Errore DB nel caricamento del menu: {ex.Message}" },
            statusCode: StatusCodes.Status500InternalServerError);
    }
}).RequireAuthorization();

// Traccia l'apertura di una pagina dal menu, sulla stessa LOG_CALL che scrive
// tweb (stored legacy LOG_AddCall): cosi' le due applicazioni finiscono nello
// stesso registro e si continuano a leggere insieme.
// Origine: "0" e' tweb, "1" e' questa webapp. L'utente lo prende dal token,
// non dal client, e un errore qui non deve mai fermare la navigazione.
app.MapPost("/api/log/videata", async (LogVideataRequest req, ClaimsPrincipal user) =>
{
    var videata = (req.Videata ?? "").Trim();
    if (videata.Length == 0) return Results.NoContent();
    try
    {
        await using var cn = Operatore.Connessione(ConnString());
        await cn.ExecuteAsync("dbo.LOG_AddCall", new
        {
            Videata = Tronca(videata, 500),                 // lunghezze della tabella
            Parametri = Tronca(req.Parametri, 5000),
            IdUtente = int.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var id) ? id : (int?)null,
            Origine = "1"
        }, commandType: CommandType.StoredProcedure);
    }
    catch (SqlException)
    {
        // il log non e' il lavoro dell'utente: se non si scrive, pazienza
    }
    return Results.NoContent();
}).RequireAuthorization();

static string? Tronca(string? v, int max) =>
    string.IsNullOrEmpty(v) ? v : v.Length <= max ? v : v[..max];

// Esegue un'interrogazione del catalogo INTERROGAZIONI componendo l'SQL come il legacy:
// SqlSelect + SqlFrom + SqlWhere + sWhere extra (dal menu o dal tasto destro) + SqlGroup + SqlOrder.
// Le parti sono unite con newline (gli sWhere possono contenere commenti --).
// Le variabili globali @[Nome] sono risolte dai claims del token, MAI da input del client.
app.MapPost("/api/interrogazioni/esegui", async (EseguiInterrogazioneRequest req, ClaimsPrincipal user) =>
{
    await using var cn = Operatore.Connessione(ConnString());

    var q = (await cn.QueryFirstOrDefaultAsync(
        "SELECT Titolo, Descrizione, SqlSelect, SqlFrom, SqlWhere, SqlGroup, SqlOrder FROM INTERROGAZIONI WHERE IdQuery = @id",
        new { id = req.IdQuery })) as IDictionary<string, object>;

    if (q is null)
        return Results.NotFound(new { errore = $"Interrogazione {req.IdQuery} non trovata" });

    string Parte(string nome) => q.TryGetValue(nome, out var v) ? v as string ?? "" : "";

    var sql = string.Join("\r\n", new[]
    {
        Parte("SqlSelect"), Parte("SqlFrom"), Parte("SqlWhere"),
        req.SWhere ?? "", Parte("SqlGroup"), Parte("SqlOrder")
    }.Where(p => !string.IsNullOrWhiteSpace(p)));

    var globali = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
    {
        ["IdUtente"] = user.FindFirstValue(ClaimTypes.NameIdentifier),
        ["IdFiliale"] = user.FindFirstValue("idFiliale"),
        ["IdCliente"] = user.FindFirstValue("idCliente"),
        ["IdAzienda"] = user.FindFirstValue("idAzienda"),
        ["IdRuolo"] = user.FindFirstValue("idRuolo"),
        ["CodRuolo"] = user.FindFirstValue("idRuolo")
    };
    var nonRisolte = new List<string>();
    sql = System.Text.RegularExpressions.Regex.Replace(sql, @"@\[(\w+)\]", m =>
    {
        var nome = m.Groups[1].Value;
        if (globali.TryGetValue(nome, out var val) && !string.IsNullOrEmpty(val)) return val;
        nonRisolte.Add(nome);
        return m.Value;
    });
    if (nonRisolte.Count > 0)
        return Results.BadRequest(new
        {
            errore = $"Variabili globali non risolte: {string.Join(", ", nonRisolte.Distinct())}"
        });

    // parametri &[Nome] / &[D_Nome] / &[Nome{select lookup}] delle query "Ricerca
    // con parametri": sostituiti coi valori del form (apici raddoppiati); un
    // placeholder senza valore diventa stringa vuota (like '%%' = tutto)
    if (System.Text.RegularExpressions.Regex.IsMatch(sql, @"&\[") || req.Valori is not null)
    {
        sql = System.Text.RegularExpressions.Regex.Replace(sql, @"&\[([^\]{}]+)(?:\{[^{}]*\})?\]", m =>
        {
            var nome = m.Groups[1].Value;
            var val = req.Valori != null && req.Valori.TryGetValue(nome, out var v) ? v ?? "" : "";
            return val.Replace("'", "''");
        });
        // le date del form arrivano in formato italiano (le query usano lo stile
        // 103 o CONVERT senza stile): la sessione va messa in dmy
        sql = "SET DATEFORMAT dmy;\r\n" + sql;
    }

    try
    {
        if (cn.State != ConnectionState.Open) await cn.OpenAsync();
        await using var cmd = new SqlCommand(sql, cn) { CommandTimeout = 90 };
        await using var rd = await cmd.ExecuteReaderAsync();

        var colonne = Enumerable.Range(0, rd.FieldCount).Select(rd.GetName).ToArray();
        var righe = new List<object?[]>();
        while (await rd.ReadAsync())
        {
            var r = new object?[rd.FieldCount];
            for (var i = 0; i < rd.FieldCount; i++)
                r[i] = rd.IsDBNull(i) ? null : rd.GetValue(i);
            righe.Add(r);
        }

        return Results.Ok(new
        {
            idQuery = req.IdQuery,
            titolo = Parte("Titolo"),
            descrizione = Parte("Descrizione"),
            colonne,
            righe
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = $"Errore SQL: {ex.Message}" },
            statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Fatturazioni a consuntivo per tipo (ANCI, ALIA): report Excel e mail di
// prefattura, vedi Fatturazione.cs
Fatturazione.Map(app, ConnString);
Schedulatore.Map(app, ConnString);
Sim.Map(app, ConnString);
Palmari.Map(app, ConnString);
Giri.Map(app, ConnString);
SpedGiri.Map(app, ConnString);
Piano.Map(app, ConnString);
PianoAuto.Map(app, ConnString);
Mezzi.Map(app, ConnString);

// Stato di archiviazione del dipendente, modificabile dalla griglia "Elenco
// Dipendenti" (interrogazione 1093). I valori ammessi li controlla la SP.
app.MapPost("/api/hr/utente-stato", async (UtenteStatoRequest req) =>
{
    if (req.IdUtente <= 0)
        return Results.BadRequest(new { errore = "Utente non indicato" });
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var r = await cn.QueryFirstOrDefaultAsync("dbo.AI_UTENTI_Stato_Save",
            new { req.IdUtente, req.Stato },
            commandType: CommandType.StoredProcedure) as IDictionary<string, object>;
        return Results.Ok(new { idUtente = req.IdUtente, stato = r?["Stato"] });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Metadati per le pagine di ricerca legacy costruite sulle interrogazioni:
// - colonnaBarcode: campo su cui la "Ricerca Multipla" applica l'IN sull'elenco
//   incollato (alias qualificato tipo sa.Barcode, o Barcode secco per select *)
// - parametri: segnaposto &[Nome] / &[D_Data] / &[Nome{select v,l from...}] della
//   "Ricerca con parametri", con le opzioni delle lookup gia' risolte
app.MapGet("/api/interrogazioni/{id:int}/ricerca-info", async (int id, ClaimsPrincipal user) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var q = (await cn.QueryFirstOrDefaultAsync(
        "SELECT Titolo, Descrizione, SqlSelect, SqlFrom, SqlWhere, SqlGroup, SqlOrder FROM INTERROGAZIONI WHERE IdQuery = @id",
        new { id })) as IDictionary<string, object>;
    if (q is null)
        return Results.NotFound(new { errore = $"Interrogazione {id} non trovata" });

    string Parte(string nome) => q.TryGetValue(nome, out var v) ? v as string ?? "" : "";
    var testo = string.Join("\r\n", new[]
    {
        Parte("SqlSelect"), Parte("SqlFrom"), Parte("SqlWhere"), Parte("SqlGroup"), Parte("SqlOrder")
    });

    var mCol = System.Text.RegularExpressions.Regex.Match(
        Parte("SqlSelect"), @"(?i)(\w+\.\w*barcode\w*)\s*(?:as|,|$)");
    var colonnaBarcode = mCol.Success ? mCol.Groups[1].Value : "Barcode";

    var globali = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
    {
        ["IdUtente"] = user.FindFirstValue(ClaimTypes.NameIdentifier),
        ["IdFiliale"] = user.FindFirstValue("idFiliale"),
        ["IdCliente"] = user.FindFirstValue("idCliente"),
        ["IdAzienda"] = user.FindFirstValue("idAzienda"),
        ["IdRuolo"] = user.FindFirstValue("idRuolo")
    };

    var parametri = new List<object>();
    var visti = new HashSet<string>();
    foreach (System.Text.RegularExpressions.Match m in
             System.Text.RegularExpressions.Regex.Matches(testo, @"&\[([^\]{}]+)(?:\{([^{}]*)\})?\]"))
    {
        var nome = m.Groups[1].Value;
        if (!visti.Add(nome)) continue;
        var lookupSql = m.Groups[2].Success ? m.Groups[2].Value : null;
        var tipo = nome.StartsWith("D_", StringComparison.OrdinalIgnoreCase) ? "data"
                 : lookupSql is not null ? "lookup" : "testo";
        var etichetta = tipo == "data" ? nome[2..] : nome;

        List<object>? opzioni = null;
        if (lookupSql is not null)
        {
            var sqlLookup = System.Text.RegularExpressions.Regex.Replace(lookupSql, @"@\[(\w+)\]",
                x => globali.TryGetValue(x.Groups[1].Value, out var val) && !string.IsNullOrEmpty(val) ? val : "0");
            try
            {
                opzioni = (await cn.QueryAsync(sqlLookup, commandTimeout: 60))
                    .Cast<IDictionary<string, object>>()
                    .Select(r =>
                    {
                        var vals = r.Values.ToList();
                        return (object)new
                        {
                            valore = Convert.ToString(vals[0]),
                            etichetta = Convert.ToString(vals.Count > 1 ? vals[1] : vals[0])
                        };
                    }).ToList();
            }
            catch (SqlException)
            {
                opzioni = new List<object>();   // lookup rotta: campo comunque editabile a testo
                tipo = "testo";
            }
        }
        parametri.Add(new { nome, etichetta, tipo, opzioni });
    }

    return Results.Ok(new
    {
        idQuery = id,
        titolo = Parte("Titolo"),
        descrizione = Parte("Descrizione"),
        colonnaBarcode,
        parametri
    });
}).RequireAuthorization();

// Proxy dei report FastReport: il report server (PARAMETRI.ReportServer) NON e'
// raggiungibile dai client, quindi il PDF lo scarica l'API e lo gira al browser.
// src = valore delle colonne REPORT# delle interrogazioni: "<nome>.fr3|par1=v1|par2=v2"
var httpReport = new HttpClient { Timeout = TimeSpan.FromSeconds(90) };
string? reportServerCache = null;

// Alcune stored legacy (RicercaBarcode, Tracking) restituiscono il link al PDF
// gia' come URL completo del report server. Aperto cosi' dal browser non
// funziona: il report server risponde solo dalla rete del server, non dai PC in
// filiale. Qui l'URL viene riscritto sul proxy /api/report, che scarica il PDF
// lato server; il link diretto non arriva mai al client.
static string? LinkReportViaProxy(string? link)
{
    if (string.IsNullOrWhiteSpace(link)) return link;
    var m = System.Text.RegularExpressions.Regex.Match(link,
        @"^https?://[^/]+/result\?(?<query>.+)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    if (!m.Success) return link;   // non e' un report: link a mappe, foto, ecc.

    string? report = null;
    var parametri = new List<string>();
    foreach (var pezzo in m.Groups["query"].Value.Split('&', StringSplitOptions.RemoveEmptyEntries))
    {
        var i = pezzo.IndexOf('=');
        if (i <= 0) continue;
        var chiave = pezzo[..i];
        var valore = pezzo[(i + 1)..];
        if (chiave.Equals("report", StringComparison.OrdinalIgnoreCase)) report = valore;
        else if (chiave.Equals("format", StringComparison.OrdinalIgnoreCase)) continue; // lo mette il proxy
        else if (System.Text.RegularExpressions.Regex.IsMatch($"{chiave}={valore}", @"^\w+=[^&#|]*$"))
            parametri.Add($"{chiave}={valore}");
    }
    if (report is null) return link;
    var src = string.Join("|", new[] { report }.Concat(parametri));
    return "/api/report?src=" + Uri.EscapeDataString(src);
}

app.MapGet("/api/report", async (string? src) =>
{
    if (string.IsNullOrWhiteSpace(src))
        return Results.BadRequest(new { errore = "Parametro src mancante" });

    var parti = src.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    var report = parti[0];
    // validazione stretta: niente path/URL nel nome report, parametri solo chiave=valore
    if (!System.Text.RegularExpressions.Regex.IsMatch(report, @"^[\w\-.]+\.fr3$"))
        return Results.BadRequest(new { errore = $"Nome report non valido: '{report}'" });
    var query = parti.Skip(1).ToList();
    if (query.Any(p => !System.Text.RegularExpressions.Regex.IsMatch(p, @"^\w+=[^&#|]*$")))
        return Results.BadRequest(new { errore = "Parametri report non validi" });

    if (reportServerCache is null)
    {
        await using var cn = Operatore.Connessione(ConnString());
        reportServerCache = await cn.ExecuteScalarAsync<string>(
            "SELECT Valore FROM PARAMETRI WHERE Nome = 'ReportServer'");
        if (string.IsNullOrWhiteSpace(reportServerCache))
            return Results.Json(new { errore = "ReportServer non configurato in PARAMETRI" },
                statusCode: StatusCodes.Status500InternalServerError);
    }

    var url = $"{reportServerCache}{report}&format=PDF"
        + (query.Count > 0 ? "&" + string.Join("&", query) : "");
    try
    {
        var pdf = await httpReport.GetByteArrayAsync(url);
        return Results.File(pdf, "application/pdf");
    }
    catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
    {
        return Results.Json(new { errore = $"Report server non raggiungibile: {ex.Message}" },
            statusCode: StatusCodes.Status502BadGateway);
    }
}).RequireAuthorization();

// Schema di una tabella di configurazione: tutte le colonne con metadati per il form
app.MapGet("/api/config/{key}/schema", async (string key) =>
{
    if (!ConfigTabelle.TryGetValue(key, out var tabella))
        return Results.NotFound(new { errore = $"Tabella di configurazione '{key}' non gestita" });

    await using var cn = Operatore.Connessione(ConnString());
    var cols = await LoadColonne(cn, tabella);
    var pk = cols.FirstOrDefault(c => c.Pk)?.Col ?? cols[0].Col;

    return Results.Ok(new
    {
        key,
        tabella,
        pk,
        colonne = cols.Select(c => new
        {
            nome = c.Col,
            tipo = c.Tipo,
            lunghezza = TipoTesto(c.Tipo) && c.MaxLen > 0 ? c.MaxLen : (int?)null,
            obbligatorio = !c.Nullable && !c.Identita,
            pk = c.Pk,
            identita = c.Identita,
            binario = TipoBinario(c.Tipo),
            testo = TipoTesto(c.Tipo),
            numero = c.Tipo is "int" or "bigint" or "smallint" or "tinyint" or "float"
                or "decimal" or "numeric" or "money" or "real",
            data = c.Tipo is "date" or "datetime" or "datetime2" or "smalldatetime" or "datetimeoffset",
            readonly_ = c.Identita
        })
    });
}).RequireAuthorization();

// Lettura paginata (lato server) di una tabella di configurazione
app.MapGet("/api/config/{key}", async (string key, HttpRequest req, ClaimsPrincipal user) =>
{
    if (!ConfigTabelle.TryGetValue(key, out var tabella))
        return Results.NotFound(new { errore = $"Tabella di configurazione '{key}' non gestita" });

    await using var cn = Operatore.Connessione(ConnString());
    var cols = await LoadColonne(cn, tabella);
    var pk = cols.FirstOrDefault(c => c.Pk)?.Col ?? cols[0].Col;
    var leggibili = cols.Where(c => !TipoBinario(c.Tipo)).Select(c => c.Col).ToList();

    int page = int.TryParse(req.Query["page"], out var p) ? Math.Max(0, p) : 0;
    int size = int.TryParse(req.Query["size"], out var s) ? Math.Clamp(s, 1, 500) : 50;
    string? sortReq = req.Query["sort"];
    var sort = cols.Any(c => c.Col.Equals(sortReq, StringComparison.OrdinalIgnoreCase)) ? sortReq! : pk;
    var dir = (string?)req.Query["dir"] == "desc" ? "DESC" : "ASC";
    string? q = req.Query["q"];

    var par = new DynamicParameters();
    var condizioni = new List<string>();
    if (!string.IsNullOrWhiteSpace(q))
    {
        var testo = cols.Where(c => TipoTesto(c.Tipo)).Select(c => $"[{c.Col}] LIKE @q").ToList();
        if (testo.Count > 0) { condizioni.Add("(" + string.Join(" OR ", testo) + ")"); par.Add("q", $"%{q}%"); }
    }
    // le Filiali si vedono solo per l'azienda su cui si e' collegati
    // (il claim idAzienda segue il cambio filiale in testata)
    if (tabella == "FILIALI" && int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda) && idAzienda > 0)
    {
        condizioni.Add("[IdAzienda] = @idAzienda");
        par.Add("idAzienda", idAzienda);
    }
    var where = condizioni.Count > 0 ? " WHERE " + string.Join(" AND ", condizioni) : "";
    par.Add("off", page * size);
    par.Add("size", size);

    var selectList = string.Join(",", leggibili.Select(c => $"[{c}]"));
    var total = await cn.ExecuteScalarAsync<int>($"SELECT COUNT(*) FROM [{tabella}]{where}", par);
    var righe = await cn.QueryAsync(
        $"SELECT {selectList} FROM [{tabella}]{where} ORDER BY [{sort}] {dir} OFFSET @off ROWS FETCH NEXT @size ROWS ONLY",
        par);

    return Results.Ok(new { total, rows = righe.Cast<IDictionary<string, object>>() });
}).RequireAuthorization();

// Salvataggio (insert o update) tramite la SP AI_<Tabella>_Save
app.MapPost("/api/config/{key}", async (string key, JsonElement body) =>
{
    if (!ConfigTabelle.TryGetValue(key, out var tabella))
        return Results.NotFound(new { errore = $"Tabella di configurazione '{key}' non gestita" });

    await using var cn = Operatore.Connessione(ConnString());
    var cols = await LoadColonne(cn, tabella);
    var validi = cols.Where(c => !TipoBinario(c.Tipo))
        .ToDictionary(c => c.Col, StringComparer.OrdinalIgnoreCase);

    // Si passano solo i parametri che la stored dichiara davvero. Quando alla
    // tabella si aggiunge una colonna e la stored non viene rifatta, senza
    // questo filtro il salvataggio muore con "troppi argomenti specificati"
    // (e' successo su FILIALI): meglio salvare il resto e dire quale colonna
    // e' rimasta fuori, che non salvare niente.
    var sp = $"dbo.AI_{tabella}_Save";
    var accettati = (await cn.QueryAsync<string>(
        "SELECT REPLACE(name, '@', '') FROM sys.parameters WHERE object_id = OBJECT_ID(@sp)", new { sp }))
        .ToHashSet(StringComparer.OrdinalIgnoreCase);

    var par = new DynamicParameters();
    var ignorati = new List<string>();
    foreach (var prop in body.EnumerateObject())
        if (validi.ContainsKey(prop.Name))
        {
            // TrimEnd: alcune colonne legacy hanno spazi finali nel nome (es. MITTENTI."CODICE_FISCALE ");
            // un nome di parametro SQL non puo' contenere spazi, quindi lo si normalizza. No-op per tutte le altre.
            var nome = prop.Name.TrimEnd();
            if (accettati.Count > 0 && !accettati.Contains(nome)) { ignorati.Add(nome); continue; }
            par.Add(nome, ValorePerColonna(JsonToClr(prop.Value), validi[prop.Name].Tipo));
        }

    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<int?>(
            sp, par, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id, ignorati });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Albero completo del menu (per l'editor: tutte le righe, senza paginazione)
app.MapGet("/api/menu/all", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT IdMenuElemento, ParentID, Text, Descrizione, Videata, Link, Parametri,
               NavigateUrl, Sorting, ToolTip, Disabled, Icon, Popup, CodFamiglia
        FROM MENU_ELEMENTI ORDER BY ISNULL(ParentID,0), ISNULL(Sorting, IdMenuElemento)");
    return Results.Ok(righe.Cast<IDictionary<string, object>>());
}).RequireAuthorization();

// Cancella una voce di menu (AI_MENU_Del): le radici solo se senza foglie;
// la stored elimina anche i permessi di visibilita' collegati
app.MapDelete("/api/menu/{id:int}", async (int id) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var r = (await cn.QueryFirstAsync("dbo.AI_MENU_Del", new { IdMenuElemento = id },
        commandType: CommandType.StoredProcedure)) as IDictionary<string, object>;
    if (r!.TryGetValue("Errore", out var err) && err is string msg)
        return Results.BadRequest(new { errore = msg });
    return Results.Ok(new { ok = true });
}).RequireAuthorization();

// Duplica una voce di menu (AI_MENU_Duplica): testo "copia N", stessi permessi;
// per le radici, a richiesta, anche tutte le foglie
app.MapPost("/api/menu/duplica", async (MenuDuplicaRequest req) =>
{
    if (req.IdMenuElemento <= 0) return Results.BadRequest(new { errore = "Voce di menu mancante" });
    await using var cn = Operatore.Connessione(ConnString());
    var r = (await cn.QueryFirstAsync("dbo.AI_MENU_Duplica",
        new { req.IdMenuElemento, ConFoglie = req.ConFoglie ? 1 : 0 },
        commandType: CommandType.StoredProcedure)) as IDictionary<string, object>;
    if (r!.TryGetValue("Errore", out var err) && err is string msg)
        return Results.BadRequest(new { errore = msg });
    return Results.Ok(new { id = r["Id"], testo = r["Testo"], foglie = r["Foglie"] });
}).RequireAuthorization();

// === Gruppi (radici di menu collegate + utenti relazionati) ===

// Elenco gruppi con i conteggi delle relazioni
app.MapGet("/api/gruppi", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var gruppi = await cn.QueryAsync(@"
        SELECT g.IdGruppo, g.Gruppo,
               (SELECT COUNT(*) FROM MENU_ELEMENTIGRUPPI mg WHERE mg.IdGruppo = g.IdGruppo) AS nMenu,
               (SELECT COUNT(*) FROM UTENTI_GRUPPI ug WHERE ug.IdGruppo = g.IdGruppo) AS nUtenti
        FROM GRUPPI g ORDER BY g.Gruppo");
    return Results.Ok(gruppi);
}).RequireAuthorization();

// Dettaglio: radici di menu collegate, utenti relazionati, radici ancora collegabili
app.MapGet("/api/gruppi/{id:int}", async (int id) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var gruppo = await cn.QueryFirstOrDefaultAsync(
        "SELECT IdGruppo, Gruppo FROM GRUPPI WHERE IdGruppo = @id", new { id });
    if (gruppo is null) return Results.NotFound(new { errore = "Gruppo inesistente" });
    var menu = await cn.QueryAsync(@"
        SELECT mg.IdMenuElementiGruppi AS id, mg.IdMenu AS idMenu, me.Text AS testo
        FROM MENU_ELEMENTIGRUPPI mg
        LEFT JOIN MENU_ELEMENTI me ON me.IdMenuElemento = mg.IdMenu
        WHERE mg.IdGruppo = @id ORDER BY me.Text", new { id });
    var utenti = await cn.QueryAsync(@"
        SELECT ug.IdUtenteGruppo AS id, ug.IdUtente AS idUtente, u.Utente AS utente, u.Nome AS nome,
               CAST(CASE WHEN u.DataFine IS NULL OR u.DataFine >= CONVERT(date, GETDATE())
                         THEN 1 ELSE 0 END AS bit) AS attivo
        FROM UTENTI_GRUPPI ug
        LEFT JOIN UTENTI u ON u.IdUtente = ug.IdUtente
        WHERE ug.IdGruppo = @id ORDER BY u.Utente", new { id });
    var radiciDisponibili = await cn.QueryAsync(@"
        SELECT me.IdMenuElemento AS idMenu, me.Text AS testo
        FROM MENU_ELEMENTI me
        WHERE ISNULL(me.ParentID, 0) = 0
          AND NOT EXISTS (SELECT 1 FROM MENU_ELEMENTIGRUPPI mg
                          WHERE mg.IdGruppo = @id AND mg.IdMenu = me.IdMenuElemento)
        ORDER BY me.Text", new { id });
    return Results.Ok(new { gruppo, menu, utenti, radiciDisponibili });
}).RequireAuthorization();

// Relazioni del gruppo: stesse SP AI_ usate dalla pagina Utenti per i gruppi
app.MapPost("/api/gruppi/{id:int}/menu", (int id, GruppoMenuReq r) =>
    EseguiRelazione("dbo.AI_MENU_ELEMENTIGRUPPI_Add", new { IdGruppo = id, r.IdMenu })).RequireAuthorization();
app.MapDelete("/api/gruppi/menu/{relId:int}", (int relId) =>
    EseguiRelazione("dbo.AI_MENU_ELEMENTIGRUPPI_Del", new { IdMenuElementiGruppi = relId })).RequireAuthorization();
app.MapPost("/api/gruppi/{id:int}/utenti", (int id, GruppoUtenteReq r) =>
    EseguiRelazione("dbo.AI_UTENTI_GRUPPI_Add", new { r.IdUtente, IdGruppo = id })).RequireAuthorization();
app.MapDelete("/api/gruppi/utenti/{relId:int}", (int relId) =>
    EseguiRelazione("dbo.AI_UTENTI_GRUPPI_Del", new { IdUtenteGruppo = relId })).RequireAuthorization();

// === Workflow / Azioni: macchina a stati per processo ===

// Elenco processi (per la tendina iniziale)
app.MapGet("/api/workflow/processi", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var p = await cn.QueryAsync(
        "SELECT IdProcesso AS idProcesso, Processo AS processo, GiorniSLA AS giorniSLA, CodFamiglia AS codFamiglia FROM PROCESSI ORDER BY Processo");
    return Results.Ok(p);
}).RequireAuthorization();

// Grafo di un processo: nodi (stati), archi (transizioni), azioni (per il filtro)
app.MapGet("/api/workflow/{idProcesso:int}", async (int idProcesso) =>
{
    await using var cn = Operatore.Connessione(ConnString());

    var archi = await cn.QueryAsync(@"
        SELECT w.IdWorkflow AS idWorkflow, w.IdAzione AS idAzione, a.Azione AS azione,
               w.Stato_Inizio AS statoInizio, w.Stato_Fine AS statoFine, w.GiorniSLA AS giorniSLA
        FROM SPED_WORKFLOW w
        JOIN SPED_AZIONI a ON a.IdAzione = w.IdAzione
        WHERE w.IdAzione IN (SELECT IdAzione FROM PROCESSI_AZIONI WHERE IdProcesso = @id)
        ORDER BY a.Azione", new { id = idProcesso });

    var nodi = await cn.QueryAsync(@"
        ;WITH az AS (SELECT IdAzione FROM PROCESSI_AZIONI WHERE IdProcesso = @id),
        st AS (
            SELECT Stato_Inizio AS stato FROM SPED_WORKFLOW WHERE IdAzione IN (SELECT IdAzione FROM az)
            UNION
            SELECT Stato_Fine FROM SPED_WORKFLOW WHERE IdAzione IN (SELECT IdAzione FROM az)
        )
        SELECT s.STATO AS stato, s.Descrizione AS descrizione, s.CodGruppoStati AS gruppo,
               s.Bloccante AS bloccante
        FROM st JOIN SPED_STATI s ON s.STATO = st.stato
        WHERE st.stato IS NOT NULL", new { id = idProcesso });

    var azioni = await cn.QueryAsync(@"
        SELECT DISTINCT a.IdAzione AS idAzione, a.Azione AS azione
        FROM PROCESSI_AZIONI pa JOIN SPED_AZIONI a ON a.IdAzione = pa.IdAzione
        WHERE pa.IdProcesso = @id ORDER BY a.Azione", new { id = idProcesso });

    return Results.Ok(new { idProcesso, nodi, archi, azioni });
}).RequireAuthorization();

// Tutti gli stati (per le tendine inizio/fine quando si crea una transizione)
app.MapGet("/api/workflow/stati", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var s = await cn.QueryAsync(
        "SELECT STATO AS stato, Descrizione AS descrizione FROM SPED_STATI ORDER BY STATO");
    return Results.Ok(s);
}).RequireAuthorization();

// Dettaglio completo di un'azione (tutti i parametri Chiedi_* ecc.)
app.MapGet("/api/workflow/azione/{idAzione:int}", async (int idAzione) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var a = await cn.QueryFirstOrDefaultAsync(
        "SELECT * FROM SPED_AZIONI WHERE IdAzione = @id", new { id = idAzione });
    return a is null ? Results.NotFound() : Results.Ok(a);
}).RequireAuthorization();

// Salvataggio transizione (arco) via SP
app.MapPost("/api/workflow/transizione", async (JsonElement body) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var par = new DynamicParameters();
    foreach (var prop in body.EnumerateObject()) par.Add(prop.Name, JsonToClr(prop.Value));
    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<int?>(
            "dbo.AI_SPED_WORKFLOW_Save", par, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Salvataggio parametri azione via SP
app.MapPost("/api/workflow/azione", async (JsonElement body) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var par = new DynamicParameters();
    foreach (var prop in body.EnumerateObject()) par.Add(prop.Name, JsonToClr(prop.Value));
    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<int?>(
            "dbo.AI_SPED_AZIONI_Save", par, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// === Azioni (OLD): consultazione azioni per processo, come la videata legacy ===

// Tutte le azioni del processo, con TUTTE le colonne di SPED_AZIONI
app.MapGet("/api/azioni/processo/{idProcesso:int}", async (int idProcesso) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT a.*
        FROM SPED_AZIONI a
        WHERE a.IdAzione IN (SELECT IdAzione FROM PROCESSI_AZIONI WHERE IdProcesso = @id)
        ORDER BY a.CodFamigliaAzione, a.Ordine", new { id = idProcesso });
    return Results.Ok(righe.Cast<IDictionary<string, object>>());
}).RequireAuthorization();

// Workflow dell'azione, con gli stati decodificati da SPED_STATI
app.MapGet("/api/azioni/{idAzione:int}/workflow", async (int idAzione) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT w.IdWorkflow AS idWorkflow,
               w.Stato_Inizio AS statoInizio, si.Descrizione AS descInizio,
               w.Stato_Fine AS statoFine, sf.Descrizione AS descFine,
               w.GiorniSLA AS giorniSLA
        FROM SPED_WORKFLOW w
        LEFT JOIN SPED_STATI si ON si.STATO = w.Stato_Inizio
        LEFT JOIN SPED_STATI sf ON sf.STATO = w.Stato_Fine
        WHERE w.IdAzione = @id
        ORDER BY w.Stato_Inizio, w.Stato_Fine", new { id = idAzione });
    return Results.Ok(righe);
}).RequireAuthorization();

// Processi collegati all'azione (PROCESSI_AZIONI), con l'evento palmare
// decodificato dalla vista PALM_TIPOEVENTO
app.MapGet("/api/azioni/{idAzione:int}/processi", async (int idAzione) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT pa.IdProcessoAzione AS idProcessoAzione,
               pa.IdProcesso AS idProcesso, p.Processo AS processo,
               pa.tipoEventoCodice AS tipoEventoCodice, te.Evento AS evento
        FROM PROCESSI_AZIONI pa
        LEFT JOIN PROCESSI p ON p.IdProcesso = pa.IdProcesso
        LEFT JOIN PALM_TIPOEVENTO te ON te.tipoEventoCodice = pa.tipoEventoCodice
        WHERE pa.IdAzione = @id
        ORDER BY p.Processo", new { id = idAzione });
    return Results.Ok(righe);
}).RequireAuthorization();

// Lookup della pagina Azioni: famiglie azione (FK), tipi evento palmare, stati
app.MapGet("/api/azioni/lookups", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var famiglie = await cn.QueryAsync(
        "SELECT CodFamigliaAzione AS codFamigliaAzione, FamigliaAzione AS famigliaAzione FROM SIST_FAMIGLIAAZIONI ORDER BY CodFamigliaAzione");
    var tipiEventi = await cn.QueryAsync(
        "SELECT tipoEventoCodice, Evento AS evento FROM PALM_TIPOEVENTO ORDER BY tipoEventoCodice");
    var stati = await cn.QueryAsync(
        "SELECT STATO AS stato, Descrizione AS descrizione FROM SPED_STATI ORDER BY STATO");
    return Results.Ok(new { famiglie, tipiEventi, stati });
}).RequireAuthorization();

// Salvataggio azione (insert/update) via SP AI_Azioni_SaveAzione.
// In insert @IdProcesso (opzionale) collega subito l'azione al processo.
app.MapPost("/api/azioni/azione", async (JsonElement body) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var colonne = await LoadColonne(cn, "SPED_AZIONI");
    var tipi = colonne.ToDictionary(c => c.Col, c => c.Tipo, StringComparer.OrdinalIgnoreCase);
    var validi = colonne.Select(c => c.Col)
        .Concat(new[] { "IdProcesso" })
        .ToHashSet(StringComparer.OrdinalIgnoreCase);

    var par = new DynamicParameters();
    foreach (var prop in body.EnumerateObject())
        if (validi.Contains(prop.Name))
            par.Add(prop.Name, ValorePerColonna(JsonToClr(prop.Value),
                                                tipi.TryGetValue(prop.Name, out var t) ? t : null));

    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<int?>(
            "dbo.AI_Azioni_SaveAzione", par, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Salvataggio transizione di workflow via SP AI_Azioni_SaveWorkflow
app.MapPost("/api/azioni/workflow", async (SalvaWorkflowRequest req) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<int?>(
            "dbo.AI_Azioni_SaveWorkflow",
            new { req.IdWorkflow, req.IdAzione, req.Stato_Inizio, req.Stato_Fine, req.GiorniSLA },
            commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Salvataggio collegamento processo-azione via SP AI_Azioni_SaveProcessoAzione
app.MapPost("/api/azioni/processo-azione", async (SalvaProcessoAzioneRequest req) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<int?>(
            "dbo.AI_Azioni_SaveProcessoAzione",
            new { req.IdProcessoAzione, req.IdProcesso, req.IdAzione, tipoEventoCodice = req.TipoEventoCodice },
            commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// === Tracking Barcode: SP legacy Tracking (testata) + RicercaBarcode (movimenti) ===
// @IdCliente arriva dal token: gli utenti-cliente vedono solo le proprie spedizioni.
app.MapGet("/api/tracking", async (string? barcode, ClaimsPrincipal user) =>
{
    if (string.IsNullOrWhiteSpace(barcode))
        return Results.BadRequest(new { errore = "Barcode obbligatorio" });

    int? idCliente = int.TryParse(user.FindFirstValue("idCliente"), out var cli) ? cli : null;

    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var dest = (await cn.QueryFirstOrDefaultAsync(
            "dbo.Tracking", new { barcode, IdCliente = idCliente },
            commandType: CommandType.StoredProcedure)) as IDictionary<string, object>;

        if (dest is null)
            return Results.NotFound(new { errore = $"Barcode '{barcode}' non trovato" });

        dest.Remove("FileLogo"); // percorso locale del server legacy, inutile per la SPA

        // Movimenti: Link e' l'URL del report/PDF gia' composto dalla SP; MapIco ('pdf'/'url')
        // distingue il tipo. La colonna Ico (html <img> legacy) non serve.
        var movimenti = (await cn.QueryAsync(
                "dbo.RicercaBarcode", new { Barcode = barcode, IdCliente = idCliente },
                commandType: CommandType.StoredProcedure))
            .Cast<IDictionary<string, object>>()
            .Select(m => new
            {
                data = m.TryGetValue("Data", out var d) ? d : null,
                elemento = m.TryGetValue("Elemento", out var e) ? e as string : null,
                valore = m.TryGetValue("Valore", out var v) ? v as string : null,
                link = LinkReportViaProxy(m.TryGetValue("Link", out var l) ? l as string : null),
                tipo = m.TryGetValue("MapIco", out var t) ? t as string : null
            });

        return Results.Ok(new { destinatario = dest, movimenti });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = $"Errore DB: {ex.Message}" },
            statusCode: StatusCodes.Status500InternalServerError);
    }
}).RequireAuthorization();

// === Attivita Filiali: contatori giornalieri per corriere (FILIALI_ATTIVITA) ===
// La filiale e' SEMPRE quella del token: niente IdFiliale dal client.

app.MapGet("/api/attivita-filiali", async (ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile nel profilo" });

    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT idAttivita, CONVERT(varchar(10), data, 23) AS data,
               ParamI01, ParamI02, ParamI03, ParamI04, ParamI05, ParamI06,
               ParamI07, ParamI08, ParamI09, ParamI10, ParamI11, ParamI12,
               ParamI13, ParamI14, ParamI15, ParamI16, ParamI17, ParamI18
        FROM FILIALI_ATTIVITA
        WHERE idFiliale = @idFiliale
        ORDER BY data DESC", new { idFiliale });
    return Results.Ok(righe);
}).RequireAuthorization();

app.MapPost("/api/attivita-filiali", async (SalvaAttivitaFilialeRequest req, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile nel profilo" });

    await using var cn = Operatore.Connessione(ConnString());
    var par = new DynamicParameters(new { IdAttivita = req.IdAttivita, IdFiliale = idFiliale, Data = req.Data });
    for (var i = 0; i < 18; i++)
        par.Add($"ParamI{i + 1:00}", req.Contatori is { } c && c.Length > i ? c[i] : (short)0);

    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<long?>(
            "dbo.AI_AttivitaFiliali_Save", par, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// === Attivita Dipendenti: griglia giornaliera per driver (UTENTI_ATTIVITA) ===
// Righe della filiale del token per il giorno scelto. Solo update (via SP):
// le righe le crea il gestionale, Login/Logout/mezzo/km arrivano dal palmare.

app.MapGet("/api/attivita-dipendenti", async (string? data, int? idFiliale, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var filialeToken))
        return Results.BadRequest(new { errore = "Filiale non disponibile nel profilo" });
    if (!DateTime.TryParse(data, out var giorno))
        return Results.BadRequest(new { errore = "Data non valida" });

    await using var cn = Operatore.Connessione(ConnString());

    // filiale richiesta diversa da quella corrente: deve essere tra quelle
    // consentite all'utente (SP legacy ElencoFiliali = diritti per utente)
    if (idFiliale is int fil && fil != filialeToken)
    {
        var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
        var ammesse = (await cn.QueryAsync("dbo.ElencoFiliali",
                new { IdUtente = idUtente }, commandType: CommandType.StoredProcedure))
            .Cast<IDictionary<string, object>>();
        if (!ammesse.Any(f => Convert.ToInt32(f["idfiliale"]) == fil))
            return Results.BadRequest(new { errore = "Filiale non consentita per questo utente" });
    }
    var idFilialeSel = idFiliale ?? filialeToken;
    var righe = await cn.QueryAsync(@"
        SELECT ua.idAttivita, ua.idUtente, u.Nome AS nome, u.CodPoste AS codPoste,
               ua.codPresenza, ua.idFiliale, m.targa, ua.KmPercorsi,
               CONVERT(varchar(5), ua.Login, 108) AS login,
               CONVERT(varchar(5), ua.Logout, 108) AS logout,
               ua.Note, ua.Partime, ua.Palmare,
               ua.ParamI03, ua.ParamI04, ua.ParamI05, ua.ParamI06, ua.ParamI07,
               ua.ParamI08, ua.ParamI09, ua.ParamI10, ua.ParamI11, ua.ParamI12,
               ua.ParamI13, ua.ParamI14, ua.ParamI15, ua.ParamI16, ua.ParamI17,
               ua.ParamI18, ua.ParamI19, ua.ParamI20,
               ua.ParamB03, ua.ParamB04, ua.ParamB10, ua.ParamB11
        FROM UTENTI_ATTIVITA ua
        JOIN UTENTI u ON u.IdUtente = ua.idUtente
        LEFT JOIN MEZZI m ON m.idMezzo = ua.idMezzo
        WHERE ua.idFiliale = @idFiliale AND ua.data = @giorno
        ORDER BY u.Nome", new { idFiliale = idFilialeSel, giorno });

    var presenze = await cn.QueryAsync(@"
        SELECT codPresenza, presenza FROM UTENTI_TIPOPRESENZE
        WHERE ISNULL(annullato, 0) = 0 ORDER BY presenza");

    // la pagina blocca le modifiche oltre 15 giorni (stessa regola della SP)
    var modificabile = (DateTime.Today - giorno.Date).TotalDays <= 15;

    return Results.Ok(new { righe, presenze, modificabile });
}).RequireAuthorization();

app.MapPost("/api/attivita-dipendenti", async (JsonElement body) =>
{
    // parametri della SP: IdAttivita, IdFiliale, CodPresenza, Note, Partime + contatori
    var validi = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    { "IdAttivita", "IdFiliale", "CodPresenza", "Note",
      "ParamB03", "ParamB04", "ParamB10", "ParamB11" };
    for (var i = 3; i <= 20; i++) validi.Add($"ParamI{i:00}");

    var par = new DynamicParameters();
    foreach (var prop in body.EnumerateObject())
        if (validi.Contains(prop.Name)) par.Add(prop.Name, JsonToClr(prop.Value));

    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<long?>(
            "dbo.AI_AttivitaDipendenti_Save", par, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// === DDT - creazione (videata legacy Bollainterna): bolle di trasferimento tra filiali ===

// Tendine del form, con le stesse SP legacy della videata InDe
app.MapGet("/api/ddt/lookups", async (ClaimsPrincipal user) =>
{
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile nel profilo" });

    await using var cn = Operatore.Connessione(ConnString());
    var mittenti = await cn.QueryAsync("dbo.ElencoFiliali",
        new { idtipo = 11, IdFiliale = idFiliale, IdUtente = idUtente }, commandType: CommandType.StoredProcedure);
    var destinazioni = await cn.QueryAsync("dbo.ElencoFiliali",
        new { idtipo = 10, IdFiliale = idFiliale, IdUtente = idUtente }, commandType: CommandType.StoredProcedure);
    var driver = await cn.QueryAsync("dbo.ElencoDriver",
        new { Tipo = 10, IdFiliale = idFiliale }, commandType: CommandType.StoredProcedure);
    var mezzi = await cn.QueryAsync("dbo.ElencoMezzi",
        new { tipo = 10, Idfiliale = idFiliale }, commandType: CommandType.StoredProcedure);
    var motrici = await cn.QueryAsync("dbo.ElencoListaValori",
        new { Lista = "Motrici" }, commandType: CommandType.StoredProcedure);
    var driverMotrici = await cn.QueryAsync("dbo.ElencoListaValori",
        new { Lista = "driver_motrici" }, commandType: CommandType.StoredProcedure);

    return Results.Ok(new { mittenti, destinazioni, driver, mezzi, motrici, driverMotrici });
}).RequireAuthorization();

// Creazione bolla: SP legacy SPED_BOLLA (crea SPED_ATTIVITA 'BOL#' + PALM_ATTIVITA,
// genera il barcode 61xxxxxxxxx). Restituisce IdSpedizione e Barcode per la stampa.
app.MapPost("/api/ddt", async (CreaDdtRequest req, ClaimsPrincipal user) =>
{
    if (req.IdFilialeMittente <= 0 || req.IdFilialeDestinazione <= 0)
        return Results.BadRequest(new { errore = "Filiale mittente e destinazione sono obbligatorie" });
    if (req.IdFilialeMittente == req.IdFilialeDestinazione)
        return Results.BadRequest(new { errore = "Mittente e destinazione devono essere filiali diverse" });

    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var r = await cn.QueryFirstOrDefaultAsync("dbo.SPED_BOLLA", new
        {
            IdUtente = idUtente,
            req.IdFilialeDestinazione,
            req.IdFilialeMittente,
            NotaConsegna = req.NotaConsegna ?? "",
            req.IdDriver,
            req.Driver,
            req.IdMezzo,
            req.Targa,
            req.Sigillo1,
            req.Sigillo2,
            req.Sigillo3
        }, commandType: CommandType.StoredProcedure) as IDictionary<string, object>;

        if (r is null || !r.TryGetValue("IdSpedizione", out var idSped))
            return Results.Json(new { errore = "SPED_BOLLA non ha restituito la spedizione" },
                statusCode: StatusCodes.Status500InternalServerError);

        return Results.Ok(new { idSpedizione = idSped, barcode = r.TryGetValue("Barcode", out var bc) ? bc : null });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// === Spedizioni Interne (videata legacy Spedizioneinterna) ===
// Trasferimenti di materiale tra filiali (resi, palmari, cancelleria...): la SP
// legacy SPED_INTERNA crea la SPED_ATTIVITA marcata nota2='SPI#' (barcode
// 6xxxxxxxxxxx, mittente = utente c/o filiale) + la riga palmare. La lettera di
// vettura e' il report DELIVERY_SpedInterna.fr3|IdSpedizione=N via /api/report.

// Filiali di destinazione: stessa lookup del DDT (ElencoFiliali tipo 10).
app.MapGet("/api/spedinterna/lookups", async (ClaimsPrincipal user) =>
{
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile nel profilo" });
    await using var cn = Operatore.Connessione(ConnString());
    var destinazioni = await cn.QueryAsync("dbo.ElencoFiliali",
        new { idtipo = 10, IdFiliale = idFiliale, IdUtente = idUtente }, commandType: CommandType.StoredProcedure);
    return Results.Ok(new { destinazioni });
}).RequireAuthorization();

app.MapPost("/api/spedinterna", async (SpedInternaRequest req, ClaimsPrincipal user) =>
{
    if (req.IdFilialeDestinazione <= 0)
        return Results.BadRequest(new { errore = "La filiale di destinazione è obbligatoria" });
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);

    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var r = await cn.QueryFirstOrDefaultAsync("dbo.SPED_INTERNA", new
        {
            IdUtente = idUtente,
            req.IdFilialeDestinazione,
            NotaConsegna = req.NotaConsegna ?? ""
        }, commandType: CommandType.StoredProcedure) as IDictionary<string, object>;

        if (r is null || !r.TryGetValue("IdSpedizione", out var idSped))
            return Results.Json(new { errore = "SPED_INTERNA non ha restituito la spedizione" },
                statusCode: StatusCodes.Status500InternalServerError);
        return Results.Ok(new { idSpedizione = idSped, barcode = r.TryGetValue("Barcode", out var bc) ? bc : null });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Spedizioni interne recenti della filiale (inviate e ricevute), per ristampa
// della lettera di vettura e controllo dello stato.
app.MapGet("/api/spedinterna/elenco", async (string? dal, string? al, bool? tutte, ClaimsPrincipal user) =>
{
    var idFiliale = int.TryParse(user.FindFirstValue("idFiliale"), out var f) ? f : 0;
    var dDal = DateTime.TryParse(dal, out var d1) ? d1.Date : DateTime.Today.AddDays(-15);
    var dAl = (DateTime.TryParse(al, out var d2) ? d2.Date : DateTime.Today).AddDays(1);

    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT sa.IdSpedizione AS idSpedizione, sa.Barcode AS barcode,
               CONVERT(varchar(16), sa.DataInserimento, 120) AS inserita,
               sa.IdFiliale AS idFilialeMittente, forig.FILIALE AS filialeMittente,
               sa.IdFilialeDestinazione AS idFilialeDestinazione, sa.DestinazioneRagioneSociale AS filialeDestinazione,
               u.Nome AS utente, sa.ContattoDestDescrizione AS nota,
               sa.Stato AS stato, st.Descrizione AS statoDescrizione,
               CONVERT(varchar(16), sa.DataStato, 120) AS dataStato
        FROM SPED_ATTIVITA sa (nolock)
        LEFT JOIN FILIALI forig (nolock) ON forig.IDFILIALE = sa.IdFiliale
        LEFT JOIN UTENTI u (nolock) ON u.IdUtente = sa.IdUtente
        LEFT JOIN SPED_STATI st (nolock) ON st.Stato = sa.Stato
        WHERE sa.nota2 = 'SPI#'
          AND sa.DataInserimento >= @dal AND sa.DataInserimento < @al
          AND (@tutte = 1 OR sa.IdFiliale = @idFiliale OR sa.IdFilialeDestinazione = @idFiliale)
        ORDER BY sa.IdSpedizione DESC",
        new { dal = dDal, al = dAl, tutte = tutte == true ? 1 : 0, idFiliale },
        commandTimeout: 90);
    return Results.Ok(righe);
}).RequireAuthorization();

// === Distinta Riepilogativa Giornaliera (videata legacy "Distinta Riepilogativa") ===
// Modello ministeriale per gli uffici speditori MGG (procure/tribunali, cliente
// 5318): elenca le distinte che contengono spedizioni del cliente e ne stampa il
// riepilogo (MG_DistRiepGiornaliera.fr3|IdDistinta=N) con tariffe e area timbro.
app.MapGet("/api/distintariepilogativa/elenco", async (string? dal, string? al, bool? tutte, int? idCliente, ClaimsPrincipal user) =>
{
    var idFiliale = int.TryParse(user.FindFirstValue("idFiliale"), out var f) ? f : 0;
    var dDal = DateTime.TryParse(dal, out var d1) ? d1.Date : DateTime.Today.AddDays(-7);
    var dAl = (DateTime.TryParse(al, out var d2) ? d2.Date : DateTime.Today).AddDays(1);

    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT d.IdDistinta AS idDistinta, d.Barcode AS barcode,
               CONVERT(varchar(16), d.Data, 120) AS data,
               az.Azione AS azione, d.IdFiliale AS idFiliale, fl.FILIALE AS filiale,
               COUNT(*) AS atti, COUNT(DISTINCT sa.IdMittente) AS uffici
        FROM SPED_DISTINTE d (nolock)
        INNER JOIN SPED_SPED2DISTINTE sd (nolock) ON sd.IdDistinta = d.IdDistinta
        INNER JOIN SPED_ATTIVITA sa (nolock) ON sa.IdSpedizione = sd.IdSpedizione
        LEFT JOIN SPED_AZIONI az (nolock) ON az.IdAzione = d.IdAzione
        LEFT JOIN FILIALI fl (nolock) ON fl.IDFILIALE = d.IdFiliale
        WHERE sa.IdCliente = @idCliente
          AND d.Data >= @dal AND d.Data < @al
          AND (@tutte = 1 OR d.IdFiliale = @idFiliale)
        GROUP BY d.IdDistinta, d.Barcode, CONVERT(varchar(16), d.Data, 120),
                 az.Azione, d.IdFiliale, fl.FILIALE
        ORDER BY d.IdDistinta DESC",
        new { dal = dDal, al = dAl, tutte = tutte == true ? 1 : 0, idFiliale, idCliente = idCliente ?? 5318 },
        commandTimeout: 90);
    return Results.Ok(righe);
}).RequireAuthorization();

// === Esegui Comando (videata legacy Eseguicomando) ===

// Comando "0": esegue l'SQL definito nel menu/azione, con i segnaposto :data e
// :valore sostituiti (quotati server-side) come il legacy. L'SQL arriva dalle
// definizioni di MENU_ELEMENTI/INTERROGAZIONI, non e' composto dal client.
app.MapPost("/api/comando/sql", async (ComandoSqlRequest req) =>
{
    if (string.IsNullOrWhiteSpace(req.Sql))
        return Results.BadRequest(new { errore = "Comando SQL mancante" });

    var sql = req.Sql;
    if (sql.Contains(":data", StringComparison.OrdinalIgnoreCase))
    {
        if (!DateTime.TryParse(req.Data, out var data))
            return Results.BadRequest(new { errore = "Data non valida" });
        sql = System.Text.RegularExpressions.Regex.Replace(
            sql, ":data", $"'{data:yyyyMMdd}'", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    }
    sql = System.Text.RegularExpressions.Regex.Replace(
        sql, ":valore", $"'{(req.Valore ?? "").Replace("'", "''")}'",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    try
    {
        await using var cn = Operatore.Connessione(ConnString());
        await cn.OpenAsync();
        await using var cmd = new SqlCommand(sql, cn) { CommandTimeout = 90 };
        await using var rd = await cmd.ExecuteReaderAsync();

        string messaggio = "";
        string? report = null, reportParametri = null;
        if (await rd.ReadAsync())
        {
            messaggio = rd.IsDBNull(0) ? "" : Convert.ToString(rd.GetValue(0)) ?? "";
            // convenzione legacy: se la terza colonna si chiama WebReport, il comando
            // chiede di aprire un report (colonna Parametri = query string del report)
            if (rd.FieldCount >= 3 && rd.GetName(2).Equals("WebReport", StringComparison.OrdinalIgnoreCase))
            {
                report = rd.IsDBNull(2) ? null : rd.GetString(2);
                var iPar = Enumerable.Range(0, rd.FieldCount)
                    .FirstOrDefault(i => rd.GetName(i).Equals("Parametri", StringComparison.OrdinalIgnoreCase), -1);
                if (iPar >= 0 && !rd.IsDBNull(iPar)) reportParametri = Convert.ToString(rd.GetValue(iPar));
            }
        }
        if (string.IsNullOrWhiteSpace(messaggio)) messaggio = "Eseguito!";
        return Results.Ok(new { messaggio, report, reportParametri });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = $"Errore SQL: {ex.Message}" },
            statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Comandi 1043 (svincolo) / 1044 (reso al mittente): VerificaBarcode su ogni
// barcode, poi InserimentoEsiti; il report della distinta torna al client e
// la mail viene accodata con EMAIL_CREA (come il legacy).
app.MapPost("/api/comando/esiti", async (ComandoEsitiRequest req, ClaimsPrincipal user) =>
{
    if (req.IdAzione is not (1043 or 1044))
        return Results.BadRequest(new { errore = $"Comando {req.IdAzione} non gestito" });
    var barcodes = (req.Barcodes ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    if (barcodes.Length == 0)
        return Results.BadRequest(new { errore = "Nessun barcode indicato" });

    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        foreach (var bc in barcodes)
        {
            var v = await cn.QueryFirstOrDefaultAsync(
                "dbo.VerificaBarcode", new { barcode = bc, Idazione = req.IdAzione },
                commandType: CommandType.StoredProcedure) as IDictionary<string, object>;
            var esito = v is not null && v.TryGetValue("Result", out var rs) ? Convert.ToString(rs) : null;
            if (esito != "1")
                return Results.BadRequest(new { errore = $"Problemi!!! {bc}: {esito ?? "barcode non valido"}" });
        }

        var elenco = string.Join(",", barcodes).Replace(" ", "");
        var r = await cn.QueryFirstOrDefaultAsync("dbo.InserimentoEsiti", new
        {
            IdAzione = req.IdAzione,
            IdUtente = idUtente,
            ElencoBarcode = elenco,
            Data = DateTime.Now
        }, commandType: CommandType.StoredProcedure) as IDictionary<string, object>;

        string? report = null, reportParametri = null;
        if (r is not null && r.TryGetValue("WebReport", out var wr) && wr is string s && !string.IsNullOrWhiteSpace(s))
        {
            report = s;
            if (r.TryGetValue("BarcodeDistinta", out var bd))
                reportParametri = $"Iddistinta={bd}";
        }

        await cn.ExecuteAsync("dbo.EMAIL_CREA",
            new { Barcode = elenco, Motivo = req.IdAzione.ToString(), Body = req.Nota ?? "" },
            commandType: CommandType.StoredProcedure);

        return Results.Ok(new { messaggio = "Operazione eseguita correttamente", report, reportParametri });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = $"Riscontrata anomalia in esecuzione stored: {ex.Message}" },
            statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// === Esiti (videata legacy "Esiti"): esecuzione azioni su barcode ===
// La pagina piu' configurabile: processo -> azione -> (campi dinamici) -> scan
// barcode con verifica asincrona -> conferma via InserimentoEsiti + report.

// flag legacy -1 = vero
bool FlagAz(IDictionary<string, object> a, string col) =>
    a.TryGetValue(col, out var v) && v != null && Convert.ToInt32(v) == -1;
// le opzioni di una combo dagli elenchi legacy, sempre come {value, label}: le stored
// restituiscono le colonne con maiuscole a caso (ElencoQualifiche da' "idqualifica"
// e "qualifica") e la combo a video le cercava col nome esatto, restando vuota
IEnumerable<object> OpzioniCombo(IEnumerable<dynamic> righe, string colValore, string colEtichetta) =>
    righe.Cast<IDictionary<string, object>>().Select(r =>
    {
        object? Cerca(string col) => r.FirstOrDefault(kv => string.Equals(kv.Key, col, StringComparison.OrdinalIgnoreCase)).Value;
        return new { value = Cerca(colValore), label = Cerca(colEtichetta)?.ToString() ?? "" };
    }).ToList();
object? Val(IDictionary<string, object> d, string k) => d.TryGetValue(k, out var v) ? v : null;

async Task<IDictionary<string, object>?> CaricaAzione(SqlConnection cn, int idAzione) =>
    await cn.QueryFirstOrDefaultAsync(@"
        SELECT IdAzione, Azione, MaxAtti, Chiedi_Citta, Chiedi_Operatore, Chiedi_Filiale,
               Chiedi_Resi, Chiedi_FilialeGiac, Chiedi_Terzi, Chiedi_Scatola,
               Param1_Tipo, Param1_Desc
        FROM SPED_AZIONI WHERE IdAzione = @id", new { id = idAzione }) as IDictionary<string, object>;

// Combo processi (ElencoProcessi @CodFamiglia; niente @IdUtente: la SP ha un
// bug con gli utenti multi-profilo)
app.MapGet("/api/esiti/processi", async (string? codFamiglia) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var p = await cn.QueryAsync("dbo.ElencoProcessi",
        new { CodFamiglia = string.IsNullOrEmpty(codFamiglia) ? null : codFamiglia },
        commandType: CommandType.StoredProcedure);
    return Results.Ok(p.Cast<IDictionary<string, object>>()
        .Select(x => new { idProcesso = x["IdProcesso"], processo = x["Processo"] }));
}).RequireAuthorization();

// Combo azioni del processo (ElencoAzioni)
app.MapGet("/api/esiti/azioni", async (int idProcesso, string? codFamigliaAzione) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var a = await cn.QueryAsync("dbo.ElencoAzioni",
        new { IdProcesso = idProcesso, CodFamigliaAzione = string.IsNullOrEmpty(codFamigliaAzione) ? null : codFamigliaAzione },
        commandType: CommandType.StoredProcedure);
    return Results.Ok(a.Cast<IDictionary<string, object>>()
        .Select(x => new { idAzione = x["IdAzione"], azione = x["Azione"] }));
}).RequireAuthorization();

// Config dell'azione scelta: flag + i due campi dinamici Comune/Operatore con
// etichetta, tipo e opzioni (replica PopolaComboComuneOperatore + OnDynamicProperties)
app.MapGet("/api/esiti/azione/{idAzione:int}", async (int idAzione, int idProcesso, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile nel profilo" });

    await using var cn = Operatore.Connessione(ConnString());
    var az = await CaricaAzione(cn, idAzione);
    if (az is null) return Results.NotFound(new { errore = $"Azione {idAzione} inesistente" });

    bool bComune = FlagAz(az, "Chiedi_Citta"), bOperatore = FlagAz(az, "Chiedi_Operatore"),
         bFiliale = FlagAz(az, "Chiedi_Filiale"), bStatiResi = FlagAz(az, "Chiedi_Resi"),
         bFilialeGiac = FlagAz(az, "Chiedi_FilialeGiac"), bTerzi = FlagAz(az, "Chiedi_Terzi");
    int iScatola = az.TryGetValue("Chiedi_Scatola", out var sc) && sc != null ? Convert.ToInt32(sc) : 0;
    string param1Tipo = az.TryGetValue("Param1_Tipo", out var pt) ? pt as string ?? "" : "";
    string param1Desc = az.TryGetValue("Param1_Desc", out var pd) ? pd as string ?? "" : "";
    int maxAtti = az.TryGetValue("MaxAtti", out var ma) && ma != null ? Convert.ToInt32(ma) : 0;

    object? campoComune = null, campoOperatore = null;

    // campo "Comune" (primo campo dinamico) — un solo motivo attivo per azione
    if (bStatiResi)
    {
        var opt = OpzioniCombo(await cn.QueryAsync("dbo.ElencoStatiResi", new { IdAzione = idAzione, IdProcesso = idProcesso }, commandType: CommandType.StoredProcedure), "IdStatoReso", "StatoReso");
        campoComune = new { tipo = "combo", label = "Tipologia Reso", valueKey = "value", labelKey = "label", options = opt };
    }
    else if (bComune)
    {
        var opt = (await cn.QueryAsync("dbo.ElencoComuni", new { IdAzione = idAzione, IdProcesso = idProcesso, IdFiliale = idFiliale }, commandType: CommandType.StoredProcedure))
            .Cast<IDictionary<string, object>>()
            .Select(c => new { value = c["BELFIORE"], label = $"{c["DENOMINAZIONE"]} ({Val(c, "SIGLAPROV")})" });
        campoComune = new { tipo = "combo", label = "Comune", valueKey = "value", labelKey = "label", options = opt };
    }
    else if (bFiliale)
    {
        var opt = OpzioniCombo(await cn.QueryAsync("dbo.ElencoFiliali", new { IdAzione = idAzione, IdProcesso = idProcesso, IdFiliale = idFiliale }, commandType: CommandType.StoredProcedure), "IdFiliale", "Filiale");
        campoComune = new { tipo = "combo", label = "Filiale Dest.", valueKey = "value", labelKey = "label", options = opt };
    }
    else if (bFilialeGiac)
    {
        var opt = OpzioniCombo(await cn.QueryAsync("dbo.ElencoFiliali", new { IdAzione = idAzione, IdProcesso = idProcesso, IdFiliale = idFiliale }, commandType: CommandType.StoredProcedure), "IdFiliale", "Filiale");
        campoComune = new { tipo = "combo", label = "Filiale Giac.", valueKey = "value", labelKey = "label", options = opt };
    }
    else if (bTerzi)
    {
        campoComune = new { tipo = "text", label = "Nome del Terzo", valueKey = "", labelKey = "", options = Array.Empty<object>() };
    }
    else if (iScatola > 0)
    {
        var opt = OpzioniCombo(await cn.QueryAsync("dbo.ElencoScatoleAperte", new { IdFiliale = idFiliale, IdTipoScatola = iScatola }, commandType: CommandType.StoredProcedure), "Barcode", "Barcode");
        campoComune = new { tipo = "combo", label = "Scatola", valueKey = "value", labelKey = "label", options = opt };
    }
    else if (!string.IsNullOrEmpty(param1Tipo))
    {
        campoComune = new { tipo = param1Tipo.Equals("Data", StringComparison.OrdinalIgnoreCase) ? "date" : "text", label = string.IsNullOrEmpty(param1Desc) ? "Parametro" : param1Desc, valueKey = "", labelKey = "", options = Array.Empty<object>() };
    }

    // campo "Operatore" (secondo campo dinamico)
    if (bTerzi)
    {
        // ElencoQualifiche: portiere e vicino hanno una sola qualifica, terzi tutte le altre
        var opt = OpzioniCombo(await cn.QueryAsync("dbo.ElencoQualifiche", new { IdAzione = idAzione, IdProcesso = idProcesso }, commandType: CommandType.StoredProcedure), "IdQualifica", "Qualifica");
        campoOperatore = new { tipo = "combo", label = "Qualifica", valueKey = "value", labelKey = "label", options = opt };
    }
    else if (bOperatore)
    {
        var opt = OpzioniCombo(await cn.QueryAsync("dbo.ElencoOperatori", new { IdAzione = idAzione, IdProcesso = idProcesso, IdFiliale = idFiliale, IdRuolo = 40 }, commandType: CommandType.StoredProcedure), "IdUtente", "Nome");
        campoOperatore = new { tipo = "combo", label = "Postino", valueKey = "value", labelKey = "label", options = opt };
    }

    return Results.Ok(new
    {
        idAzione, azione = az["Azione"], maxAtti,
        flags = new { bComune, bOperatore, bFiliale, bStatiResi, bFilialeGiac, bTerzi, iScatola, param1Tipo },
        campoComune, campoOperatore
    });
}).RequireAuthorization();

// Verifica asincrona di un barcode (VerificaBarcode). Result: 1 ok, 0 warning,
// -1 errore bloccante, -2 rimuovere dalla lista.
app.MapPost("/api/esiti/verifica", async (EsitiVerificaRequest req, ClaimsPrincipal user) =>
{
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile" });

    await using var cn = Operatore.Connessione(ConnString());
    var az = await CaricaAzione(cn, req.IdAzione);
    if (az is null) return Results.BadRequest(new { errore = "Azione inesistente" });

    var par = new DynamicParameters();
    par.Add("barcode", req.Barcode);
    par.Add("IdAzione", req.IdAzione);
    par.Add("IdProcesso", req.IdProcesso);
    par.Add("idFiliale", idFiliale);
    par.Add("IdUtente", idUtente);
    par.Add("Belfiore", req.Comune);
    par.Add("Attributo", req.Attributo);
    if (FlagAz(az, "Chiedi_FilialeGiac")) par.Add("IdFilialeGiac", req.Comune);
    if (FlagAz(az, "Chiedi_Operatore")) par.Add("IdMesso", req.Operatore);
    if (DateTime.TryParse(req.Data, out var d)) par.Add("Data2", d.ToString("yyyyMMdd"));

    try
    {
        var r = await cn.QueryFirstOrDefaultAsync("dbo.VerificaBarcode", par, commandType: CommandType.StoredProcedure) as IDictionary<string, object>;
        if (r is null) return Results.Ok(new { result = "-1", message = "Nessuna risposta dalla verifica" });
        return Results.Ok(new
        {
            barcode = Val(r, "Barcode"),
            result = Convert.ToString(Val(r, "Result")),
            message = Val(r, "Message") as string,
            info = Val(r, "Info") as string,
            stato = Val(r, "Stato") as string,
            idSpedizione = Val(r, "IdSpedizione"),
            nota = Val(r, "Nota") as string,
            listaBarcode = Val(r, "ListaBarcode") as string
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Conferma: InserimentoEsiti con i parametri condizionati dai flag dell'azione;
// restituisce iddistinta + webreport per la stampa.
app.MapPost("/api/esiti/conferma", async (EsitiConfermaRequest req, ClaimsPrincipal user) =>
{
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile" });
    if (string.IsNullOrWhiteSpace(req.ElencoBarcode))
        return Results.BadRequest(new { errore = "Nessun barcode da confermare" });

    await using var cn = Operatore.Connessione(ConnString());
    var az = await CaricaAzione(cn, req.IdAzione);
    if (az is null) return Results.BadRequest(new { errore = "Azione inesistente" });

    var par = new DynamicParameters();
    par.Add("IdAzione", req.IdAzione);
    par.Add("IdFiliale", idFiliale);
    par.Add("IdUtente", idUtente);
    par.Add("ElencoBarcode", req.ElencoBarcode);
    par.Add("ElencoParametri1", req.ElencoParametri1);
    if (DateTime.TryParse(req.Data, out var d)) par.Add("Data", d);
    if (FlagAz(az, "Chiedi_Resi")) par.Add("ElencoNote", req.ElencoParametri1);
    if (FlagAz(az, "Chiedi_Citta")) par.Add("Belfiore", req.Comune);
    if (FlagAz(az, "Chiedi_Operatore")) par.Add("IdPostino", req.Operatore);
    if (FlagAz(az, "Chiedi_Filiale")) par.Add("IdFilialeDestinazione", req.Comune);
    if (FlagAz(az, "Chiedi_FilialeGiac")) par.Add("IdFilialeGiacenza", req.Comune);
    var iScatola = az.TryGetValue("Chiedi_Scatola", out var sc) && sc != null ? Convert.ToInt32(sc) : 0;
    if (iScatola > 0) par.Add("Scatola", req.Comune);

    try
    {
        var r = await cn.QueryFirstOrDefaultAsync("dbo.InserimentoEsiti", par, commandType: CommandType.StoredProcedure) as IDictionary<string, object>;
        var report = r is null ? null : Val(r, "webreport") as string;
        var idDistinta = r is null ? null : Val(r, "iddistinta");
        return Results.Ok(new
        {
            messaggio = "Operazione eseguita correttamente",
            report,
            reportParametri = idDistinta is null ? null : $"IdDistinta={idDistinta}"
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = $"Riscontrata anomalia in esecuzione stored: {ex.Message}" },
            statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// === Utenti: pagina dedicata (la SP AI_UTENTI_Save gestisce la password) ===

// Lista paginata con etichette di ruolo/filiale/cliente (mai la password)
app.MapGet("/api/utenti", async (HttpRequest req) =>
{
    int page = int.TryParse(req.Query["page"], out var p) ? Math.Max(0, p) : 0;
    int size = int.TryParse(req.Query["size"], out var s) ? Math.Clamp(s, 1, 500) : 50;
    string? q = req.Query["q"];
    var ammessiSort = new[] { "Utente", "Nome", "Email", "DataUltimoAccesso", "IdUtente" };
    var sort = ammessiSort.Contains((string?)req.Query["sort"], StringComparer.OrdinalIgnoreCase)
        ? (string)req.Query["sort"]! : "Utente";
    var dir = (string?)req.Query["dir"] == "desc" ? "DESC" : "ASC";

    var par = new DynamicParameters();
    var where = "";
    if (!string.IsNullOrWhiteSpace(q))
    {
        where = " WHERE (u.Utente LIKE @q OR u.Nome LIKE @q OR u.Email LIKE @q OR u.CodiceFiscale LIKE @q)";
        par.Add("q", $"%{q}%");
    }
    par.Add("off", page * size);
    par.Add("size", size);

    await using var cn = Operatore.Connessione(ConnString());
    var total = await cn.ExecuteScalarAsync<int>($"SELECT COUNT(*) FROM UTENTI u{where}", par);
    var rows = await cn.QueryAsync($@"
        SELECT u.IdUtente, u.Utente, u.Nome, u.Email, u.IdRuolo, r.Ruolo,
               u.IdFiliale, f.FILIALE AS Filiale, u.IdCliente, cl.RagioneSociale AS Cliente,
               u.codAppLogin, u.DataUltimoAccesso,
               CAST(CASE WHEN u.DataFine IS NULL OR u.DataFine >= CONVERT(date, GETDATE())
                         THEN 1 ELSE 0 END AS bit) AS Attivo
        FROM UTENTI u
        LEFT JOIN RUOLI r ON r.IdRuolo = u.IdRuolo
        LEFT JOIN FILIALI f ON f.IDFILIALE = u.IdFiliale
        LEFT JOIN CLIENTI cl ON cl.IdCliente = u.IdCliente
        {where}
        ORDER BY u.[{sort}] {dir} OFFSET @off ROWS FETCH NEXT @size ROWS ONLY", par);

    return Results.Ok(new { total, rows = rows.Cast<IDictionary<string, object>>() });
}).RequireAuthorization();

// Dettaglio completo (tutti i campi tranne la password)
app.MapGet("/api/utenti/{id:int}", async (int id) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var cols = (await LoadColonne(cn, "UTENTI")).Where(c => c.Col != "Pass").Select(c => $"[{c.Col}]");
    var u = await cn.QueryFirstOrDefaultAsync(
        $"SELECT {string.Join(",", cols)} FROM UTENTI WHERE IdUtente = @id", new { id });
    return u is null ? Results.NotFound() : Results.Ok(u);
}).RequireAuthorization();

// Lookup per le tendine del form
app.MapGet("/api/utenti/lookups", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var ruoli = await cn.QueryAsync("SELECT IdRuolo AS idRuolo, Ruolo AS ruolo FROM RUOLI ORDER BY Ruolo");
    var filiali = await cn.QueryAsync("SELECT IDFILIALE AS idFiliale, FILIALE AS filiale FROM FILIALI WHERE DataChiusura IS NULL ORDER BY FILIALE");
    var clienti = await cn.QueryAsync("SELECT IdCliente AS idCliente, RagioneSociale AS ragioneSociale FROM CLIENTI ORDER BY RagioneSociale");
    var aziende = await cn.QueryAsync("SELECT IdAzienda AS idAzienda, Azienda AS azienda FROM AZIENDE ORDER BY Azienda");
    var padri = await cn.QueryAsync("SELECT IdUtente AS idUtente, ISNULL(NULLIF(Nome,''), Utente) + ' (' + Utente + ')' AS label FROM UTENTI WHERE DataFine IS NULL OR DataFine >= CONVERT(date, GETDATE()) ORDER BY label");
    var gruppi = await cn.QueryAsync("SELECT IdGruppo AS idGruppo, Gruppo AS gruppo FROM GRUPPI ORDER BY Gruppo");
    var processi = await cn.QueryAsync("SELECT IdProcesso AS idProcesso, Processo AS processo FROM PROCESSI ORDER BY Processo");
    var famiglie = await cn.QueryAsync("SELECT CodFamiglia AS codFamiglia, FamigliaDiProdotto AS famiglia FROM PROD_FAMIGLIE ORDER BY FamigliaDiProdotto");
    return Results.Ok(new { ruoli, filiali, clienti, aziende, padri, gruppi, processi, famiglie });
}).RequireAuthorization();

// Comuni (lookup pesante, caricato a richiesta per il Belfiore dei processi)
app.MapGet("/api/utenti/comuni", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var comuni = await cn.QueryAsync(
        @"SELECT BELFIORE AS belfiore, DENOMINAZIONE + ' (' + ISNULL(SIGLAPROV,'') + ')' AS label
          FROM GEO_Comune WHERE DataFine IS NULL ORDER BY DENOMINAZIONE");
    return Results.Ok(comuni);
}).RequireAuthorization();

// Tutte le associazioni N:N dell'utente
app.MapGet("/api/utenti/{id:int}/relazioni", async (int id) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var gruppi = await cn.QueryAsync(@"
        SELECT ug.IdUtenteGruppo AS id, ug.IdGruppo AS idGruppo, g.Gruppo AS gruppo
        FROM UTENTI_GRUPPI ug JOIN GRUPPI g ON g.IdGruppo = ug.IdGruppo
        WHERE ug.IdUtente = @id ORDER BY g.Gruppo", new { id });
    var profili = await cn.QueryAsync(@"
        SELECT up.IdUtentiProfili AS id, up.CodFamiglia AS codFamiglia, f.FamigliaDiProdotto AS famiglia
        FROM UTENTI_PROFILI up LEFT JOIN PROD_FAMIGLIE f ON f.CodFamiglia = up.CodFamiglia
        WHERE up.IdUtente = @id ORDER BY f.FamigliaDiProdotto", new { id });
    var processi = await cn.QueryAsync(@"
        SELECT pr.IdUtentiProcessi AS id, pr.IdProcesso AS idProcesso, p.Processo AS processo,
               pr.Belfiore AS belfiore, c.DENOMINAZIONE AS comune
        FROM UTENTI_PROCESSI pr LEFT JOIN PROCESSI p ON p.IdProcesso = pr.IdProcesso
        LEFT JOIN GEO_Comune c ON c.BELFIORE = pr.Belfiore
        WHERE pr.IdUtente = @id ORDER BY p.Processo", new { id });
    var filiali = await cn.QueryAsync(@"
        SELECT uf.IdUtenteFiliale AS id, uf.IdFiliale AS idFiliale, f.FILIALE AS filiale
        FROM UTENTI_FILIALI uf JOIN FILIALI f ON f.IDFILIALE = uf.IdFiliale
        WHERE uf.IdUtente = @id ORDER BY f.FILIALE", new { id });
    return Results.Ok(new { gruppi, profili, processi, filiali });
}).RequireAuthorization();

// Add/Del per ciascuna collezione (tramite SP AI_)
async Task<IResult> EseguiRelazione(string sp, object par)
{
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        await cn.ExecuteAsync(sp, par, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { ok = true });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}

app.MapPost("/api/utenti/{id:int}/gruppi", (int id, GruppoReq r) =>
    EseguiRelazione("dbo.AI_UTENTI_GRUPPI_Add", new { IdUtente = id, IdGruppo = r.IdGruppo })).RequireAuthorization();
app.MapDelete("/api/utenti/gruppi/{relId:int}", (int relId) =>
    EseguiRelazione("dbo.AI_UTENTI_GRUPPI_Del", new { IdUtenteGruppo = relId })).RequireAuthorization();

app.MapPost("/api/utenti/{id:int}/profili", (int id, ProfiloReq r) =>
    EseguiRelazione("dbo.AI_UTENTI_PROFILI_Add", new { IdUtente = id, CodFamiglia = r.CodFamiglia })).RequireAuthorization();
app.MapDelete("/api/utenti/profili/{relId:int}", (int relId) =>
    EseguiRelazione("dbo.AI_UTENTI_PROFILI_Del", new { IdUtentiProfili = relId })).RequireAuthorization();

app.MapPost("/api/utenti/{id:int}/processi", (int id, ProcessoReq r) =>
    EseguiRelazione("dbo.AI_UTENTI_PROCESSI_Add", new { IdUtente = id, r.IdProcesso, r.Belfiore })).RequireAuthorization();
app.MapDelete("/api/utenti/processi/{relId:int}", (int relId) =>
    EseguiRelazione("dbo.AI_UTENTI_PROCESSI_Del", new { IdUtentiProcessi = relId })).RequireAuthorization();

app.MapPost("/api/utenti/{id:int}/filiali", (int id, FilialeReq r) =>
    EseguiRelazione("dbo.AI_UTENTI_FILIALI_Add", new { IdUtente = id, IdFiliale = r.IdFiliale })).RequireAuthorization();
app.MapDelete("/api/utenti/filiali/{relId:int}", (int relId) =>
    EseguiRelazione("dbo.AI_UTENTI_FILIALI_Del", new { IdUtenteFiliale = relId })).RequireAuthorization();

// Salvataggio utente via SP (password solo se passata in NuovaPassword)
// Storico delle modifiche a una scheda utente (trigger su UTENTI -> LOGTabelle,
// confronto fra fotografie in LogTabelle.cs). La password non si mostra mai.
app.MapGet("/api/utenti/{id:int}/modifiche", async (int id) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    return Results.Ok(await LogTabelle.Modifiche(cn, "UTENTI", id, new[] { "Pass" }));
}).RequireAuthorization();

app.MapPost("/api/utenti", async (JsonElement body) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var colonne = await LoadColonne(cn, "UTENTI");
    var tipi = colonne.ToDictionary(c => c.Col, c => c.Tipo, StringComparer.OrdinalIgnoreCase);
    var validi = colonne
        .Where(c => !c.Identita && c.Col != "Pass").Select(c => c.Col)
        .Concat(new[] { "IdUtente", "NuovaPassword" })
        .ToHashSet(StringComparer.OrdinalIgnoreCase);

    var par = new DynamicParameters();
    foreach (var prop in body.EnumerateObject())
        if (validi.Contains(prop.Name))
            par.Add(prop.Name, ValorePerColonna(JsonToClr(prop.Value),
                                                tipi.TryGetValue(prop.Name, out var t) ? t : null));

    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<int?>(
            "dbo.AI_UTENTI_Save", par, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// === Export CSV per HR: tracciato TeamSystem IMPDIP_0004_ANAGRAFICA ===
// Dipendenti Speedy (FILIALI.IdAzienda=2) con DataInizio nel mese richiesto,
// inclusi i gia' cessati. Ogni riga = 53 campi nell'ordine del tracciato;
// il client scarica il CSV (separatore ';', vuoto = spazio come da esempio HR).

app.MapGet("/api/hr/anagrafica", async (HttpRequest req) =>
{
    int anno = int.TryParse(req.Query["anno"], out var a) ? a : DateTime.Today.Year;
    int mese = int.TryParse(req.Query["mese"], out var m) ? Math.Clamp(m, 1, 12) : DateTime.Today.Month;
    string azienda = string.IsNullOrWhiteSpace(req.Query["azienda"]) ? "574" : ((string)req.Query["azienda"]!).Trim();

    var dal = new DateTime(anno, mese, 1);
    await using var cn = Operatore.Connessione(ConnString());
    var dip = (await cn.QueryAsync(@"
        SELECT u.IdUtente, u.Nome, u.CodiceFiscale, u.Matricola, u.DataInizio, u.DataFine, u.DataNascita,
               u.IndirizzoRes, u.CapRes, u.ComuneRes, u.ProvRes, u.Email, u.Telefono,
               u.IdFiliale, f.FILIALE AS Filiale, f.IdFiliale_HRSpeedy
        FROM UTENTI u JOIN FILIALI f ON f.IDFILIALE = u.IdFiliale
        WHERE f.IdAzienda = 2 AND u.DataInizio >= @dal AND u.DataInizio < @al
        ORDER BY u.DataInizio, u.Nome", new { dal, al = dal.AddMonths(1) }))
        .Cast<IDictionary<string, object>>().ToList();

    // lookup comuni/nazioni (codici Belfiore) in un colpo solo
    var codici = dip.Select(d => BelfioreDaCf(S(Val(d, "CodiceFiscale")))).Where(c => c != null).ToList();
    var nomiRes = dip.Select(d => S(Val(d, "ComuneRes")).ToUpperInvariant()).Where(n => n != "").Distinct().ToList();
    var comuni = (await cn.QueryAsync(@"
        SELECT codice_belfiore AS Codice, UPPER(denominazione_ita) AS Nome, sigla_provincia AS Prov
        FROM MAP_comuni_nazioni_cf WHERE data_fine_validita IS NULL"))
        .Cast<IDictionary<string, object>>().ToList();
    string ProvFix(string p) => ProvinciaAttuale(p);
    var perCodice = comuni.GroupBy(c => S(Val(c, "Codice"))).ToDictionary(g => g.Key, g => g.First());
    // chiave senza accenti: nel DB gli indirizzi liberi li perdono ("ALA DEI SARDI")
    var perNome = comuni.GroupBy(c => NoAccenti(S(Val(c, "Nome")))).ToDictionary(g => g.Key, g => g.First());

    var righe = new List<object>();
    foreach (var d in dip)
    {
        var segn = new List<string>();
        var cf = S(Val(d, "CodiceFiscale")).ToUpperInvariant();
        var nomeCompleto = S(Val(d, "Nome"));
        var matricola = S(Val(d, "Matricola"));
        if (matricola == "") segn.Add("matricola mancante in UTENTI");
        if (cf.Length != 16) segn.Add("codice fiscale assente o non valido");

        // cognome/nome: lo split viene validato sulle due triplette del CF
        var (cognome, nome, splitOk) = SplitNomeConCf(nomeCompleto, cf);
        if (!splitOk) segn.Add("divisione cognome/nome non verificabile col CF");

        // dal CF: sesso, data di nascita, comune/stato di nascita
        string sesso = "", dataNascita = "", belfN = "", comuneN = "", provN = "", cittadinanza = "";
        if (cf.Length == 16)
        {
            var pcf = ParseCf(cf);
            sesso = pcf.Sesso;
            dataNascita = pcf.DataNascita;
            belfN = pcf.Belfiore;
            if (Val(d, "DataNascita") is DateTime dn) dataNascita = dn.ToString("dd/MM/yyyy");
            if (perCodice.TryGetValue(belfN, out var cN))
            {
                comuneN = S(Val(cN, "Nome"));
                provN = ProvFix(S(Val(cN, "Prov")));
            }
            else segn.Add($"comune di nascita {belfN} non trovato");
            cittadinanza = belfN.StartsWith("Z") ? "" : "0";
            if (belfN.StartsWith("Z")) segn.Add("nato all'estero: cittadinanza da compilare a mano");
        }

        // residenza: campi strutturati se presenti, altrimenti parsing dell'indirizzo libero
        var (via, civico, capRes, comuneRes, provRes) = ParseResidenza(
            S(Val(d, "IndirizzoRes")), S(Val(d, "CapRes")), S(Val(d, "ComuneRes")), S(Val(d, "ProvRes")));
        // altro formato libero frequente: "VIA X,COMUNE" (comune dopo l'ultima virgola)
        if (comuneRes == "" && via.Contains(','))
        {
            var coda = via[(via.LastIndexOf(',') + 1)..].Trim();
            if (perNome.ContainsKey(NoAccenti(coda)))
            {
                comuneRes = coda;
                via = via[..via.LastIndexOf(',')].Trim().TrimEnd(',');
            }
        }
        string belfR = "", provR = "";
        if (comuneRes != "")
        {
            if (perNome.TryGetValue(NoAccenti(comuneRes.ToUpperInvariant()), out var cR))
            {
                belfR = S(Val(cR, "Codice"));
                provR = ProvFix(S(Val(cR, "Prov")));
                comuneRes = S(Val(cR, "Nome")); // denominazione ufficiale (accenti inclusi)
            }
            else segn.Add($"comune di residenza '{comuneRes}' non trovato in tabella comuni");
        }
        else segn.Add("residenza mancante");

        var email = S(Val(d, "Email"));
        if (!email.Contains('@')) email = ""; // nel DB a volte c'e' spazzatura (CF, indirizzi)
        if (email == "") segn.Add("email mancante");
        var cell = new string(S(Val(d, "Telefono")).Where(char.IsDigit).ToArray());
        if (cell.Length < 9) { if (cell != "") segn.Add($"telefono '{S(Val(d, "Telefono"))}' scartato"); cell = ""; }

        var codFiliale = S(Val(d, "IdFiliale_HRSpeedy"));
        if (codFiliale == "") segn.Add($"filiale '{S(Val(d, "Filiale"))}' senza codice HR (FILIALI.IdFiliale_HRSpeedy)");

        // i 53 campi del tracciato, nell'ordine dell'intestazione; vuoto = spazio
        var c53 = Enumerable.Repeat(" ", 53).ToArray();
        string V(string s) => s == "" ? " " : s;
        var completo = via == "" ? "" : " " + via + (civico != "" ? "," + civico : "");
        c53[0] = azienda; c53[1] = V(codFiliale); c53[2] = V(matricola); c53[3] = V(cf);
        c53[5] = V(cognome.ToUpperInvariant()); c53[6] = V(nome.ToUpperInvariant()); c53[7] = V(dataNascita);
        c53[8] = V(sesso); c53[9] = V(belfN); c53[10] = V(comuneN); c53[11] = V(provN);
        c53[12] = V(cittadinanza);
        c53[17] = V(email); c53[20] = V(cell); c53[21] = V(email);
        if (belfR != "")
        {
            var comuneUp = comuneRes.ToUpperInvariant();
            c53[22] = belfR; c53[23] = comuneUp; c53[24] = provR;
            c53[26] = V(via); c53[27] = V(civico); c53[31] = V(capRes); c53[32] = V(completo);
            c53[34] = belfR; c53[35] = belfR;
            // domicilio = residenza (ordine campi: via, frazione, civico)
            c53[36] = belfR; c53[37] = comuneUp; c53[38] = provR;
            c53[40] = V(via); c53[42] = V(civico); c53[45] = V(capRes); c53[46] = V(completo);
        }
        c53[49] = c53[50] = c53[51] = c53[52] = "X";

        righe.Add(new
        {
            idUtente = Val(d, "IdUtente"),
            cognome, nome, cf, matricola,
            filiale = S(Val(d, "Filiale")),
            codFiliale,
            dataInizio = Val(d, "DataInizio") is DateTime di ? di.ToString("dd/MM/yyyy") : "",
            dataFine = Val(d, "DataFine") is DateTime df ? df.ToString("dd/MM/yyyy") : "",
            residenza = belfR == "" ? "" : $"{comuneRes.ToUpperInvariant()} {via}" + (civico != "" ? "," + civico : ""),
            segnalazioni = segn,
            campi = c53
        });
    }

    const string intestazione = "D0001:Codice_azienda;D0002:Codice_filiale;D0003:Codice_matricola;D0005:Codice_fiscale;D0004:Cancella_dati_pagina_ANAGRAFICA;D0006:Cognome;D0007:Nome;D0008:Data_nascita;D0009:Sesso_dipendente;D0010:Codice_comune_di_nascita;D0011:Comune_di_nascita;D0012:Provincia_nascita;D0013:Cittadinanza;D0014:Straniero;D0015:Stato_civile;D0016:Titolo_studio;D0017:E-mail_personale_(flag);D0018:Email;D0019:Password;D0020:Telefono;D0021:Cellulare;D0022:Email_TeamSystem_ID;D0023:RESIDENZA_-_Cod.comune;D0024:RESIDENZA_-_Comune;D0025:RESIDENZA_-_Provincia;D0026:RESIDENZA_-_Tipologia_DUG;D0027:RESIDENZA_-_Indirizzo_DUG;D0028:RESIDENZA_-_Civico_DUG;D0029:RESIDENZA_-_Frazione_DUG;D0031:RESIDENZA_-_Presso_DUG;D0032:RESIDENZA_-_Edificio_DUG;D0030:RESIDENZA_-_CAP;D0033:RESIDENZA_-_Indirizzo_completo;D0034:Data_variazione_residenza;D0035:Comune_addizionale_regionale;D0047:Cod.Comune_residenza_al_1/1;D0036:DOMICILIO_-_Cod._comune;D0037:DOMICILIO_-_Comune;D0038:DOMICILIO_-_Provincia;D0039:DOMICILIO_-_Tipologia_DUG;D0040:DOMICILIO_-_Indirizzo_DUG;D0041:DOMICILIO_-_Frazione_DUG;D0042:DOMICILIO_-_Civico_DUG;D0044:DOMICILIO_-_Presso_DUG;D0045:DOMICILIO_-_Edificio_DUG;D0043:DOMICILIO_-_CAP;D0046:DOMICILIO_-_Indirizzo_completo;D0048:Ex_comune_per_saldo;D0049:Ex_comune_per_acconto;D2503:Assicurazione_IVS;D2504:Assicurazione_DS;D2505:Assicurazione_FG;D2506:Assicurazione_Altre";
    return Results.Ok(new { anno, mese, intestazione, righe });

    static string S(object? v) => v?.ToString()?.Trim() ?? "";

    static string NoAccenti(string s) => s.ToUpperInvariant()
        .Replace("À", "A").Replace("È", "E").Replace("É", "E").Replace("Ì", "I")
        .Replace("Ò", "O").Replace("Ù", "U").Replace("'", "");

    // --- codice fiscale: sesso, data di nascita, Belfiore di nascita ---
    static string? BelfioreDaCf(string cf) => cf.Length == 16 ? cf.Substring(11, 4).ToUpperInvariant() : null;

    static (string Sesso, string DataNascita, string Belfiore) ParseCf(string cf)
    {
        var mesi = "ABCDEHLMPRST";
        int yy = int.TryParse(cf.Substring(6, 2), out var y) ? y : 0;
        int mm = mesi.IndexOf(cf[8]) + 1;
        int gg = int.TryParse(cf.Substring(9, 2), out var g) ? g : 0;
        var sesso = gg > 40 ? "F" : "M";
        if (gg > 40) gg -= 40;
        // pivot: nessun dipendente e' nato dopo l'anno corrente
        int anno = 2000 + yy > DateTime.Today.Year ? 1900 + yy : 2000 + yy;
        var data = (mm >= 1 && gg >= 1 && gg <= 31) ? $"{gg:00}/{mm:00}/{anno}" : "";
        return (sesso, data, cf.Substring(11, 4).ToUpperInvariant());
    }

    // --- split cognome/nome: UTENTI.Nome e' un campo unico "COGNOME NOME"; proviamo
    // ogni punto di divisione e teniamo quello che riproduce le triplette del CF ---
    static (string Cognome, string Nome, bool Ok) SplitNomeConCf(string nomeCompleto, string cf)
    {
        var parole = nomeCompleto.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parole.Length < 2) return (nomeCompleto, "", false);
        if (cf.Length == 16)
        {
            for (int i = 1; i < parole.Length; i++)
            {
                var cg = string.Join(" ", parole[..i]);
                var nm = string.Join(" ", parole[i..]);
                if (TriplaCf(cg, false) == cf[..3] && TriplaCf(nm, true) == cf.Substring(3, 3))
                    return (cg, nm, true);
            }
        }
        // fallback: prima parola = cognome
        return (parole[0], string.Join(" ", parole[1..]), false);
    }

    static string TriplaCf(string s, bool nome)
    {
        var pulito = new string(s.ToUpperInvariant()
            .Replace("À", "A").Replace("È", "E").Replace("É", "E").Replace("Ì", "I")
            .Replace("Ò", "O").Replace("Ù", "U")
            .Where(ch => ch >= 'A' && ch <= 'Z').ToArray());
        var cons = new string(pulito.Where(ch => !"AEIOU".Contains(ch)).ToArray());
        var voc = new string(pulito.Where(ch => "AEIOU".Contains(ch)).ToArray());
        if (nome && cons.Length >= 4) cons = $"{cons[0]}{cons[2]}{cons[3]}";
        return (cons + voc + "XXX")[..3];
    }

    // --- residenza: usa i campi strutturati; se mancano prova a scomporre il testo libero
    // (nel DB capitano blob tipo "VIA LUSSU,25 - 07020 ALA DEI SARDI (SS)") ---
    static (string Via, string Civico, string Cap, string Comune, string Prov) ParseResidenza(
        string indirizzo, string cap, string comune, string prov)
    {
        indirizzo = indirizzo.Replace("Â°", "°"); // mojibake ricorrente nel DB ("NÂ°48")
        if (comune == "" && indirizzo.Contains(" - "))
        {
            var dopo = indirizzo[(indirizzo.LastIndexOf(" - ") + 3)..].Trim();
            indirizzo = indirizzo[..indirizzo.LastIndexOf(" - ")].Trim();
            var mBlob = System.Text.RegularExpressions.Regex.Match(dopo, @"^(?:(\d{5})\s+)?(.+?)\s*(?:\((\w{2})\))?$");
            if (mBlob.Success)
            {
                if (mBlob.Groups[1].Success) cap = mBlob.Groups[1].Value;
                comune = mBlob.Groups[2].Value.Trim();
                if (mBlob.Groups[3].Success) prov = mBlob.Groups[3].Value;
            }
        }
        // sigla provincia: nel DB a volte c'e' il nome per esteso, ma nel tracciato non la usiamo
        // (la provincia esce dalla tabella comuni); civico staccato dal fondo dell'indirizzo
        var via = indirizzo.TrimEnd(',', ' ');
        var civico = "";
        var mCiv = System.Text.RegularExpressions.Regex.Match(via, @"^(.*?)[,\s]+(?:N[°.\s]*)?(\d+\s*[A-Z]?(?:/\w+)?)$",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        if (mCiv.Success && mCiv.Groups[1].Value.Trim().Length >= 4)
        {
            via = mCiv.Groups[1].Value.Trim().TrimEnd(',');
            civico = mCiv.Groups[2].Value.Replace(" ", "").ToUpperInvariant();
        }
        return (via.ToUpperInvariant(), civico, cap, comune, prov);
    }
}).RequireAuthorization();

// === Carica UNILAV: dal testo del PDF (estratto dal client) alla scheda utente ===
// Il PDF "Comunicazione Obbligatoria" ha campi "Etichetta: valore"; il parsing
// affetta il testo sulle etichette note. Il client mostra il confronto e su
// conferma chiama /applica (SP AI_UTENTI_Unilav_Applica, aggiornamento selettivo).
//
// Dalla stessa pagina si caricano tutti e quattro i modelli UNILAV; il tipo si
// riconosce dal tracciato (tipoMovimento) o dalla riga "Modello:" del PDF, e da
// quello dipende la sezione dei dati rapporto e cosa si propone di aggiornare:
//   Inizio (AL)        -> assunzione: anagrafica + rapporto
//   Proroga (PL)       -> nuova scadenza: DataFineContratto e DataFine
//   Trasformazione (TL)-> nuovo contratto/orario/sede; se diventa a tempo
//                         indeterminato le date di fine si svuotano
//   Cessazione (CL)    -> DataFine = data di cessazione
// C'e' poi l'annullamento (tipoComunicazione 04), che non e' un modello a se':
// e' una comunicazione che ne cancella una precedente e porta con se' il
// tracciato di quella annullata. Attenzione: il tipoMovimento resta quello del
// modello annullato (una cessazione annullata dice ancora CL), quindi va letto
// prima il tipo di comunicazione, altrimenti si finisce per riapplicare proprio
// la cessazione che il documento sta cancellando.

app.MapPost("/api/hr/unilav/parse", async (UnilavParseRequest req) =>
{
    var testo = (req.Testo ?? "").Replace("\r", "");
    DateTime? Data(string s) => DateTime.TryParseExact(s, "dd/MM/yyyy", null, System.Globalization.DateTimeStyles.None, out var d) ? d : null;

    // 1) fonte preferita: l'allegato tracciato.json incorporato nel PDF (dati gia' strutturati).
    // Lo estraiamo qui dai byte del PDF: e' uno stream FlateDecode marcato /Type/EmbeddedFile.
    static string? TracciatoDaPdf(byte[] pdf)
    {
        var raw = System.Text.Encoding.Latin1.GetString(pdf);
        int pos = 0;
        while ((pos = raw.IndexOf("/Type/EmbeddedFile", pos, StringComparison.Ordinal)) >= 0)
        {
            var sIdx = raw.IndexOf("stream", pos, StringComparison.Ordinal);
            if (sIdx < 0) break;
            var inizio = sIdx + "stream".Length;
            if (inizio < raw.Length && raw[inizio] == '\r') inizio++;
            if (inizio < raw.Length && raw[inizio] == '\n') inizio++;
            var eIdx = raw.IndexOf("endstream", inizio, StringComparison.Ordinal);
            if (eIdx < 0) break;
            try
            {
                using var ms = new MemoryStream(pdf, inizio, eIdx - inizio);
                ms.Seek(2, SeekOrigin.Begin); // salta l'intestazione zlib
                using var ds = new System.IO.Compression.DeflateStream(ms, System.IO.Compression.CompressionMode.Decompress);
                using var outMs = new MemoryStream();
                ds.CopyTo(outMs);
                var json = System.Text.Encoding.UTF8.GetString(outMs.ToArray()).Trim();
                if (json.StartsWith("{") && json.Contains("lavoratore")) return json;
            }
            catch { /* stream non-zlib o corrotto: si prova il successivo */ }
            pos = eIdx;
        }
        return null;
    }

    var tracciatoJson = req.TracciatoJson;
    if (string.IsNullOrWhiteSpace(tracciatoJson) && !string.IsNullOrWhiteSpace(req.PdfBase64))
    {
        try { tracciatoJson = TracciatoDaPdf(Convert.FromBase64String(req.PdfBase64)); } catch { }
    }

    Dictionary<string, string?>? estratti = null;
    var fonte = "testo del PDF";
    string? belfioreDom = null;
    var tipo = "assunzione";   // assunzione | proroga | trasformazione | cessazione | annullamento
    var annullamento = false;
    if (!string.IsNullOrWhiteSpace(tracciatoJson))
    {
        try
        {
            using var jd = System.Text.Json.JsonDocument.Parse(tracciatoJson);
            var root = jd.RootElement.TryGetProperty("modello", out var mo) ? mo : jd.RootElement;
            string? J(params string[] path)
            {
                var e = root;
                foreach (var p in path)
                    if (e.ValueKind != System.Text.Json.JsonValueKind.Object || !e.TryGetProperty(p, out e)) return null;
                return e.ValueKind switch
                {
                    System.Text.Json.JsonValueKind.String => System.Net.WebUtility.HtmlDecode(e.GetString())?.Trim(),
                    System.Text.Json.JsonValueKind.Number => e.GetRawText(),
                    _ => null
                };
            }
            // i dati del rapporto stanno in una sezione diversa per ogni modello
            annullamento = (J("tipoComunicazione") ?? "") == "04"
                || string.Equals(J("statoComunicazione"), "ANNULLAMENTO", StringComparison.OrdinalIgnoreCase)
                || (J("tipoComunicazioneDescrizione") ?? "").StartsWith("Annullam", StringComparison.OrdinalIgnoreCase);
            tipo = (J("tipoMovimento") ?? "").ToUpperInvariant() switch
            {
                "PL" => "proroga",
                "TL" => "trasformazione",
                "CL" => "cessazione",
                _ => "assunzione"
            };
            var sez = tipo switch
            {
                "proroga" => "proroga",
                "trasformazione" => "trasformazione",
                "cessazione" => "cessazione",
                _ => "inizioRapporto"
            };
            estratti = new()
            {
                ["CodiceFiscale"] = J("lavoratore", "codiceFiscale"),
                ["Cognome"] = J("lavoratore", "cognome"),
                ["Nome"] = J("lavoratore", "nome"),
                ["Sesso"] = J("lavoratore", "sesso"),
                ["ComuneNascita"] = J("lavoratore", "comuneNascitaDescrizione"),
                ["Cittadinanza"] = J("lavoratore", "cittadinanzaDescrizione"),
                ["DataNascita"] = J("lavoratore", "dataNascitaDescrizione"),
                ["SoggiornoTipo"] = J("lavoratore", "lavoratoreExtraUE", "tipoDocumentoDescrizione"),
                ["SoggiornoNumero"] = J("lavoratore", "lavoratoreExtraUE", "numeroDocumento"),
                ["SoggiornoMotivo"] = J("lavoratore", "lavoratoreExtraUE", "motivoPermessoDescrizione"),
                ["SoggiornoScadenza"] = J("lavoratore", "lavoratoreExtraUE", "dataScadenzaPSDescrizione"),
                ["SoggiornoQuestura"] = J("lavoratore", "lavoratoreExtraUE", "questuraDescrizione"),
                ["ComuneDomicilio"] = J("lavoratore", "comuneDescrizione"),
                ["CapDomicilio"] = J("lavoratore", "cap"),
                ["IndirizzoDomicilio"] = J("lavoratore", "indirizzo"),
                ["TitoloStudio"] = J("lavoratore", "livelloIstruzioneDescrizione"),
                ["DataInizioRapporto"] = J(sez, "dataInizioDescrizione"),
                ["DataFineRapporto"] = J(sez, "dataFineDescrizione"),
                ["TipoContratto"] = J(sez, "tipologiaContrattualeDescrizione"),
                ["TipoOrario"] = J(sez, "tipoOrarioDescrizione"),
                ["OreSettimanali"] = J(sez, "oreSettimanaliMedie"),
                ["Qualifica"] = J(sez, "qualificaProfessionaleDescrizione"),
                ["CCNL"] = J(sez, "ccnlDescrizione"),
                ["LivelloInquadramento"] = J(sez, "livelloInquadramentoDescrizione"),
                ["PatInail"] = J(sez, "patINAIL"),
                ["SedeLavoroComune"] = J("datoreLavoro", "comuneSedeLavoroDescrizione"),
                ["UnilavCodice"] = J("codiceComunicazione"),
                ["UnilavData"] = J("dataInvioDescrizione"),
                // campi propri dei modelli diversi dall'assunzione
                ["DataFineProroga"] = J("proroga", "dataFineProrogaDescrizione"),
                ["DataTrasformazione"] = J("trasformazione", "dataTrasformazioneDescrizione"),
                ["CausaTrasformazione"] = J("trasformazione", "codiceTrasformazioneDescrizione"),
                ["DataCessazione"] = J("cessazione", "dataCessazioneDescrizione"),
                ["MotivoCessazione"] = J("cessazione", "codiceCausaDescrizione"),
                // annullamento: la comunicazione cancellata e il perche' (in chiaro nelle note)
                ["CodiceAnnullato"] = J("codiceComunicazionePrecedente"),
                ["Note"] = J("note"),
            };
            belfioreDom = J("lavoratore", "comune"); // Belfiore del comune di domicilio
            fonte = "tracciato.json incorporato";
        }
        catch { estratti = null; }
    }

    // 2) ripiego: testo del PDF affettato sulle etichette note
    if (estratti is null)
    {
    if (testo.Length < 100)
        return Results.Json(new { errore = "Testo del PDF vuoto o troppo corto" }, statusCode: 400);

    // etichette del tracciato UNILAV (case-sensitive: "Nome:" non aggancia "Cognome:")
    var etichette = new[] {
        "Tipo comunicazione:", "Modello:", "Trasmessa il:", "Codice comunicazione:",
        "Codice fiscale:", "Denominazione datore di lavoro:", "Settore:", "Pubblica amministrazione:",
        "Comune sede legale:", "CAP sede legale:", "Indirizzo sede legale:", "Telefono sede legale:",
        "Fax sede legale:", "E-mail sede legale:", "Comune sede di lavoro:", "CAP sede lavoro:",
        "Indirizzo sede di lavoro:", "Telefono sede di lavoro:", "Fax sede di lavoro:", "E-mail sede di lavoro:",
        "Sesso:", "Cognome:", "Nome:", "Comune di nascita:", "Cittadinanza:", "Data di nascita:",
        "Titolo soggiorno:", "Numero titolo soggiorno:", "Motivo titolo soggiorno:", "Scadenza titolo soggiorno:",
        "Questura rilascio titolo:", "Sussistenza sistemazione alloggiativa:", "rimpatrio:",
        "Comune di domicilio:", "CAP domicilio:", "Indirizzo di domicilio:", "Livello di istruzione:",
        "Data inizio rapporto:", "Data fine rapporto:", "Data fine periodo formativo:",
        "Ente previdenziale:", "Codice ente previdenziale:", "PAT INAIL:", "Tipologia contrattuale:",
        "Tipo orario:", "Ore settimali medie:", "Ore settimanali medie:", "Socio lavoratore:",
        "Qualifica professionale:", "Assunzione Obbligatoria:", "Categoria Lavoratore:",
        "Contratto collettivo applicato:", "Livello di inquadramento:", "Retribuzione / Compenso:",
        "Lavoro in agricoltura:", "Giornate lavorative previste:", "Tipo lavorazione:", "Data invio:", "Note:",
        // etichette dei modelli proroga / trasformazione / cessazione
        "Data fine proroga", "Data trasformazione:", "Data cessazione:", "Motivo cessazione:",
        "Codice comunicazione collegata (annullata):",
        "Comune sede di lavoro precedente:", "Indirizzo sede di lavoro precedente:"
    };
    // titoli di sezione: non sono campi ma delimitano i valori che li precedono
    var sezioni = new[] { "Datore di Lavoro", "Lavoratore", "Dati Rapporto", "Dati invio", "Inizio", "Pagina ",
        "Dati Proroga", "Dati Trasformazione", "Dati Cessazione",
        // titoli di sezione dei modelli diversi dall'assunzione: senza questi il
        // valore che li precede (il titolo di studio) se li porta dietro
        "Proroga", "Trasformazione", "Cessazione" };
    // Posizioni di tutte le occorrenze di etichette e titoli di sezione.
    // Nelle colonne strette del PDF le etichette vanno a capo ("Data fine" su una
    // riga e "rapporto:" sulla successiva), quindi si cercano con gli spazi
    // elastici: dove l'etichetta ha uno spazio, il testo puo' avere anche un a
    // capo. La ricerca resta sensibile alle maiuscole, altrimenti "Nome:"
    // aggancerebbe "Cognome:". Si tiene anche la lunghezza trovata, che con l'a
    // capo non e' quella dell'etichetta.
    var occ = new List<(int Pos, int Len, string Lab)>();
    foreach (var lab in etichette.Concat(sezioni))
    {
        var patt = string.Join(@"\s+", lab.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(System.Text.RegularExpressions.Regex.Escape))
            + (lab.EndsWith(" ") ? @"\s+" : "");
        foreach (System.Text.RegularExpressions.Match m in
                 System.Text.RegularExpressions.Regex.Matches(testo, patt))
            occ.Add((m.Index, m.Length, lab));
    }
    occ.Sort((a, b) => a.Pos.CompareTo(b.Pos));
    string Valore(string lab, int daPos = 0)
    {
        var hit = occ.FirstOrDefault(o => o.Lab == lab && o.Pos >= daPos);
        if (hit.Lab is null) return "";
        var inizio = hit.Pos + hit.Len;
        var next = occ.FirstOrDefault(o => o.Pos >= inizio);
        var fine = next.Lab is null ? testo.Length : next.Pos;
        return string.Join(" ", testo[inizio..fine].Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim())).Trim();
    }

    int posLav = testo.IndexOf("Lavoratore", StringComparison.Ordinal);
    if (posLav < 0) posLav = 0;

    estratti = new Dictionary<string, string?>
    {
        ["CodiceFiscale"] = Valore("Codice fiscale:", posLav),
        ["Cognome"] = Valore("Cognome:", posLav),
        ["Nome"] = Valore("Nome:", posLav),
        ["Sesso"] = Valore("Sesso:", posLav),
        ["ComuneNascita"] = Valore("Comune di nascita:", posLav),
        ["Cittadinanza"] = Valore("Cittadinanza:", posLav),
        ["DataNascita"] = Valore("Data di nascita:", posLav),
        ["SoggiornoTipo"] = Valore("Titolo soggiorno:", posLav),
        ["SoggiornoNumero"] = Valore("Numero titolo soggiorno:", posLav),
        ["SoggiornoMotivo"] = Valore("Motivo titolo soggiorno:", posLav),
        ["SoggiornoScadenza"] = Valore("Scadenza titolo soggiorno:", posLav),
        ["SoggiornoQuestura"] = Valore("Questura rilascio titolo:", posLav),
        ["ComuneDomicilio"] = Valore("Comune di domicilio:", posLav),
        ["CapDomicilio"] = Valore("CAP domicilio:", posLav),
        ["IndirizzoDomicilio"] = Valore("Indirizzo di domicilio:", posLav),
        ["TitoloStudio"] = Valore("Livello di istruzione:", posLav),
        ["DataInizioRapporto"] = Valore("Data inizio rapporto:"),
        ["DataFineRapporto"] = Valore("Data fine rapporto:"),
        ["TipoContratto"] = Valore("Tipologia contrattuale:"),
        ["TipoOrario"] = Valore("Tipo orario:"),
        ["OreSettimanali"] = Valore("Ore settimali medie:") is { Length: > 0 } os ? os : Valore("Ore settimanali medie:"),
        ["Qualifica"] = Valore("Qualifica professionale:"),
        ["CCNL"] = Valore("Contratto collettivo applicato:"),
        ["LivelloInquadramento"] = Valore("Livello di inquadramento:"),
        ["PatInail"] = Valore("PAT INAIL:"),
        ["SedeLavoroComune"] = Valore("Comune sede di lavoro:"),
        ["UnilavCodice"] = Valore("Codice comunicazione:"),
        ["UnilavData"] = Valore("Trasmessa il:"),
        ["DataFineProroga"] = Valore("Data fine proroga"),
        ["DataTrasformazione"] = Valore("Data trasformazione:"),
        ["DataCessazione"] = Valore("Data cessazione:"),
        ["MotivoCessazione"] = Valore("Motivo cessazione:"),
        ["CodiceAnnullato"] = Valore("Codice comunicazione collegata (annullata):"),
        ["Note"] = Valore("Note:"),
        // la causa e' spezzata su due righe dalla tabella del PDF ("Causa ... trasformazione: ...")
        ["CausaTrasformazione"] = System.Text.RegularExpressions.Regex.Match(
            testo.Replace('\n', ' '), @"TRASFORMAZIONE\s+DA\s+.{3,60}?\s+A\s+TEMPO\s+\w+",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase).Value,
    };
    // il modello e' scritto in testata: "Comunicazioni Obbligatorie/Cessazione"
    // il valore sta sulla stessa riga dell'etichetta o su quella dopo
    string Testata(string etichetta) => System.Text.RegularExpressions.Regex.Match(
        testo, "^" + System.Text.RegularExpressions.Regex.Escape(etichetta) + @"[ \t]*\n?(.*)$",
        System.Text.RegularExpressions.RegexOptions.Multiline).Groups[1].Value.Trim().ToUpperInvariant();
    var modello = Testata("Modello:");
    annullamento = Testata("Tipo comunicazione:").Contains("ANNULLAM");
    tipo = modello.Contains("PROROGA") ? "proroga"
        : modello.Contains("TRASFORMAZIONE") ? "trasformazione"
        : modello.Contains("CESSAZIONE") ? "cessazione"
        : "assunzione";
    }

    var cf = (estratti["CodiceFiscale"] ?? "").Trim().ToUpperInvariant();
    var cognome = estratti["Cognome"] ?? "";
    var nome = estratti["Nome"] ?? "";
    // "LAVORO A TEMPO DETERMINATO" -> "TEMPO DETERMINATO" (formato usato in tabella)
    estratti["TipoContratto"] = System.Text.RegularExpressions.Regex.Replace(
        estratti["TipoContratto"] ?? "", @"^LAVORO A\s+", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    var avvisi = new List<string>();
    if (cf.Length != 16) avvisi.Add("Codice fiscale del lavoratore non trovato nel PDF");

    // normalizzazioni verso i formati usati in tabella
    string livello = estratti["LivelloInquadramento"] ?? "";
    var mLiv = System.Text.RegularExpressions.Regex.Match(livello.ToUpperInvariant(), @"^(\d+)\s*(SENIOR|JUNIOR)?");
    if (mLiv.Success)
        livello = mLiv.Groups[1].Value + (mLiv.Groups[2].Value == "SENIOR" ? "S" : mLiv.Groups[2].Value == "JUNIOR" ? "J" : "");
    var qual = (estratti["Qualifica"] ?? "").ToUpperInvariant();
    // la qualifica del PDF e' quella ISTAT ("Addetti allo smistamento e al recapito
    // della posta"); in scheda la mansione e' un dato interno, spesso con la zona
    // ("FI Bagno a Ripoli - DRIVER"). Quindi si mappa sulle mansioni note, e la
    // descrizione ISTAT si propone solo per riempire una mansione ancora vuota.
    string? mansione = qual.Contains("FACCHIN") ? "FACCHINO"
        : qual.Contains("CONDUCENT") || qual.Contains("AUTIST") || qual.Contains("CORRIER") ? "DRIVER"
        : null;

    // provincia del comune di domicilio: dal Belfiore (se il tracciato lo da') o dal nome
    await using var cn = Operatore.Connessione(ConnString());
    string? provDom = null;
    if (belfioreDom is { Length: > 0 })
        provDom = await cn.ExecuteScalarAsync<string?>(@"
            SELECT TOP 1 sigla_provincia FROM MAP_comuni_nazioni_cf
            WHERE data_fine_validita IS NULL AND codice_belfiore = @b", new { b = belfioreDom });
    if (provDom is null && (estratti["ComuneDomicilio"] ?? "") != "")
        // il confronto ignora gli accenti (COLLATE ..._AI): l'UNILAV scrive
        // "TORTOLI" con l'accento, le nostre tabelle spesso senza
        provDom = await cn.ExecuteScalarAsync<string?>(@"
            SELECT TOP 1 sigla_provincia FROM MAP_comuni_nazioni_cf
            WHERE data_fine_validita IS NULL
              AND UPPER(denominazione_ita) COLLATE Latin1_General_CI_AI = @c",
            new { c = estratti["ComuneDomicilio"]!.ToUpperInvariant() });
    if (provDom is { Length: > 0 }) provDom = ProvinciaAttuale(provDom);

    // scheda utente per CF (preferisce l'account attivo)
    var utenti = (await cn.QueryAsync(@"
        SELECT u.IdUtente, u.Utente, u.Nome, u.Matricola, u.CodiceFiscale,
               CONVERT(varchar(10), u.DataInizio, 120) AS DataInizio, CONVERT(varchar(10), u.DataFine, 120) AS DataFine,
               CONVERT(varchar(10), u.DataNascita, 120) AS DataNascita,
               u.IndirizzoRes, u.CapRes, u.ComuneRes, u.ProvRes, u.Livello, u.Mansione,
               u.Cittadinanza, u.LuogoNascita, u.TitoloStudio, u.TipoContratto,
               CONVERT(varchar(10), u.DataFineContratto, 120) AS DataFineContratto,
               u.OreSettimanali, u.Partime, u.CCNL, u.SoggiornoTipo, u.SoggiornoNumero, u.SoggiornoMotivo,
               CONVERT(varchar(10), u.SoggiornoScadenza, 120) AS SoggiornoScadenza,
               u.SoggiornoQuestura, u.UnilavCodice, u.Stato, u.IdFiliale, f.FILIALE AS Filiale
        FROM UTENTI u LEFT JOIN FILIALI f ON f.IDFILIALE = u.IdFiliale
        WHERE u.CodiceFiscale = @cf
        ORDER BY CASE WHEN u.DataFine IS NULL THEN 0 ELSE 1 END, u.DataInizio DESC", new { cf }))
        .Cast<IDictionary<string, object>>().ToList();
    var u0 = utenti.FirstOrDefault();
    if (u0 is null)
        avvisi.Add("Nessun utente con questo codice fiscale: crealo prima dalla pagina Utenti, poi ricarica il PDF");

    // Riassunzione: con questo CF c'e' gia' una scheda, ma chiusa prima che il
    // nuovo rapporto cominci. Non le si scrive sopra (e' la storia del rapporto
    // precedente, con la sua matricola e le sue giornate): se ne propone una
    // nuova, con l'anagrafica copiata da quella, il contratto dall'UNILAV e la
    // matricola da scrivere. E' successo con CANGIOLU: l'assunzione di agosto
    // era finita sulla scheda di gennaio.
    DateTime? DataIso(string? s) => DateTime.TryParseExact(s ?? "", "yyyy-MM-dd", null,
        System.Globalization.DateTimeStyles.None, out var d) ? d : null;
    var inizioNuovo = Data((estratti["DataInizioRapporto"] ?? "").Trim());
    var riassunzione = tipo == "assunzione" && u0 is not null
        && DataIso(Val(u0, "DataFine")?.ToString()) is DateTime fineVecchia
        && inizioNuovo is DateTime iniz && fineVecchia < iniz;

    // proposte di aggiornamento (campo tabella -> valore dal PDF), solo se diverse
    var proposte = new List<object>();
    void Proponi(string campo, string etichetta, string? nuovo, string? testo = null, object? opzioni = null)
    {
        if (u0 is null || string.IsNullOrWhiteSpace(nuovo)) return;
        var attuale = Val(u0, campo)?.ToString()?.Trim() ?? "";
        var attualeCmp = attuale;
        var nuovoCmp = nuovo.Trim();
        if (campo.StartsWith("Data") || campo == "SoggiornoScadenza")
        {
            // in tabella le date girano come yyyy-MM-dd; dal PDF come dd/MM/yyyy
            if (Data(nuovoCmp) is DateTime dn) nuovoCmp = dn.ToString("yyyy-MM-dd");
        }
        if (campo is "OreSettimanali" or "Partime"
            && decimal.TryParse(attualeCmp.Replace(',', '.'), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var oa)
            && decimal.TryParse(nuovoCmp.Replace(',', '.'), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var on)
            && oa == on) return;
        if (string.Equals(attualeCmp, nuovoCmp, StringComparison.OrdinalIgnoreCase)) return;
        proposte.Add(new { campo, etichetta, attuale, nuovo = nuovoCmp, testo, opzioni, azzera = false });
    }
    // svuotamento di una data gia' in scheda (es. contratto diventato indeterminato):
    // ISNULL(NULL, campo) non potrebbe farlo, quindi la SP ha i flag @Azzera*
    void ProponiAzzeramento(string campo, string etichetta, string motivo)
    {
        if (u0 is null) return;
        var attuale = Val(u0, campo)?.ToString()?.Trim() ?? "";
        if (attuale == "") return;
        proposte.Add(new { campo, etichetta, attuale, nuovo = "", testo = motivo, opzioni = (object?)null, azzera = true });
    }

    Proponi("Nome", "Cognome e nome", (cognome + " " + nome).Trim());
    Proponi("DataNascita", "Data di nascita", estratti["DataNascita"]);
    Proponi("DataInizio", "Inizio rapporto", estratti["DataInizioRapporto"]);
    Proponi("IndirizzoRes", "Indirizzo (domicilio)", estratti["IndirizzoDomicilio"]);
    Proponi("CapRes", "CAP", estratti["CapDomicilio"]);
    Proponi("ComuneRes", "Comune", estratti["ComuneDomicilio"]);
    Proponi("ProvRes", "Provincia", provDom);
    Proponi("Livello", "Livello", livello);
    var mansioneAttuale = u0 is null ? "" : Val(u0, "Mansione")?.ToString()?.Trim() ?? "";
    var qualTroncata = estratti["Qualifica"] is { Length: > 0 } qd ? (qd.Length > 50 ? qd[..50] : qd) : null;
    Proponi("Mansione", "Mansione", mansione ?? (mansioneAttuale == "" ? qualTroncata : null));
    Proponi("Cittadinanza", "Cittadinanza", estratti["Cittadinanza"]);
    Proponi("LuogoNascita", "Luogo di nascita", estratti["ComuneNascita"]);
    Proponi("TitoloStudio", "Titolo di studio", estratti["TitoloStudio"]);
    Proponi("TipoContratto", "Tipologia contrattuale", estratti["TipoContratto"]);
    Proponi("OreSettimanali", "Ore settimanali", estratti["OreSettimanali"]);
    Proponi("CCNL", "CCNL", estratti["CCNL"]);
    Proponi("SoggiornoTipo", "Titolo di soggiorno", estratti["SoggiornoTipo"]);
    Proponi("SoggiornoNumero", "Numero soggiorno", estratti["SoggiornoNumero"]);
    Proponi("SoggiornoMotivo", "Motivo soggiorno", estratti["SoggiornoMotivo"]);
    Proponi("SoggiornoScadenza", "Scadenza soggiorno", estratti["SoggiornoScadenza"]);
    Proponi("SoggiornoQuestura", "Questura", estratti["SoggiornoQuestura"]);
    Proponi("UnilavCodice", "Codice comunicazione", estratti["UnilavCodice"]);

    // --- part time: in scheda e' la percentuale sulle 40 ore settimanali
    // (0 = tempo pieno), il PDF da' il tipo orario e le ore medie ---
    var tipoOrario = (estratti["TipoOrario"] ?? "").ToUpperInvariant();
    if (tipoOrario.Contains("PIENO"))
        Proponi("Partime", "Part time %", "0", "tempo pieno");
    else if (tipoOrario.Contains("PARZIALE")
        && decimal.TryParse((estratti["OreSettimanali"] ?? "").Replace(',', '.'),
            System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var oreSet)
        && oreSet > 0)
    {
        var perc = Math.Round(oreSet / 40m * 100m, 2);
        Proponi("Partime", "Part time %",
            perc.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture), $"{oreSet:0.#} ore su 40");
    }

    // --- sede di lavoro -> filiale: il comune non basta (piu' filiali per comune,
    // e le sedi SDA hanno il comune solo nel nome), quindi si cercano le candidate
    // e si propone solo se l'attuale non e' gia' coerente ---
    var comuneSede = (estratti["SedeLavoroComune"] ?? "").Trim().ToUpperInvariant();
    if (u0 is not null && comuneSede.Length > 2)
    {
        // Confronto senza accenti: l'UNILAV riporta il comune come sta all'anagrafe
        // ("TORTOLI" con l'accento finale), mentre in FILIALI e' scritto piano.
        // Con la collation del database, che gli accenti li distingue, la filiale
        // di Tortoli non si trovava e il caricamento finiva in errore.
        var candidate = (await cn.QueryAsync(@"
            SELECT IDFILIALE, FILIALE FROM FILIALI
            WHERE UPPER(LTRIM(RTRIM(ISNULL(Comune, '')))) COLLATE Latin1_General_CI_AI = @c
               OR UPPER(FILIALE) COLLATE Latin1_General_CI_AI LIKE '%' + @c + '%'
            ORDER BY FILIALE", new { c = comuneSede }))
            .Select(f => new { valore = ((int)f.IDFILIALE).ToString(), etichetta = (string)f.FILIALE })
            .ToList();
        var idFilAttuale = Val(u0, "IdFiliale")?.ToString() ?? "";
        if (candidate.Count == 0)
            avvisi.Add($"Sede di lavoro '{estratti["SedeLavoroComune"]}': nessuna filiale corrispondente, controlla a mano");
        else if (!candidate.Any(c => c.valore == idFilAttuale))
        {
            if (candidate.Count == 1)
                Proponi("IdFiliale", "Filiale (sede di lavoro)", candidate[0].valore, candidate[0].etichetta);
            else
            {
                // ambiguo: la riga esce con la tendina, senza valore preselezionato
                proposte.Add(new
                {
                    campo = "IdFiliale",
                    etichetta = "Filiale (sede di lavoro)",
                    attuale = Val(u0, "Filiale")?.ToString() ?? "",
                    nuovo = "",
                    testo = $"{candidate.Count} filiali a {estratti["SedeLavoroComune"]}: scegli quella giusta",
                    opzioni = candidate,
                    azzera = false
                });
            }
        }
    }

    // --- cosa comporta il modello sulle date del rapporto ---
    string? causale = null;
    // il movimento annullato resta quello scritto nel tracciato: lo si tiene da
    // parte per sapere che cosa disfare, poi il tipo diventa "annullamento"
    var movimentoAnnullato = tipo;
    if (annullamento) tipo = "annullamento";
    switch (tipo)
    {
        case "annullamento":
            // la comunicazione cancellata e' identificata dal suo codice; il motivo
            // sta nelle note, ed e' l'unica spiegazione che il documento porta
            causale = string.Join(" — ", new[]
            {
                estratti["CodiceAnnullato"] is { Length: > 0 } ca ? $"annulla la comunicazione {ca}" : null,
                estratti["Note"]
            }.Where(x => !string.IsNullOrWhiteSpace(x)));

            if (movimentoAnnullato == "cessazione")
            {
                // Il rapporto non si e' chiuso, ma non e' detto che torni "senza
                // fine": un contratto a termine torna alla sua scadenza naturale.
                // La si cerca prima nel documento (la sezione annullata porta la
                // data di fine rapporto quando c'e'), poi nella fine contratto gia'
                // in scheda; se non c'e' nessuna delle due la riga esce vuota e la
                // data la scrive l'operatore, che il documento non la dice.
                var fineOriginale = estratti["DataFineRapporto"] ?? "";
                if (fineOriginale.Trim().Length == 0 && u0 is not null)
                    fineOriginale = Val(u0, "DataFineContratto")?.ToString() ?? "";
                if (Data(fineOriginale.Trim()) is DateTime dfo) fineOriginale = dfo.ToString("yyyy-MM-dd");
                fineOriginale = fineOriginale.Trim();

                if (u0 is not null)
                    proposte.Add(new
                    {
                        campo = "DataFine",
                        etichetta = "Fine rapporto",
                        attuale = Val(u0, "DataFine")?.ToString()?.Trim() ?? "",
                        nuovo = fineOriginale,
                        testo = fineOriginale.Length > 0
                            ? "cessazione annullata: torna la scadenza del contratto"
                            : "cessazione annullata: se il rapporto ha una scadenza, scrivila qui",
                        opzioni = (object?)null,
                        azzera = fineOriginale.Length == 0,
                        editabile = "data"      // la riga esce con la casella della data
                    });

                if (u0 is not null)
                {
                    // lo stato di archiviazione dell'elenco dipendenti segue il rapporto
                    if (string.Equals(Val(u0, "Stato")?.ToString()?.Trim(), "CESSATO", StringComparison.OrdinalIgnoreCase))
                        Proponi("Stato", "Stato", "SI", "rientra in forza");
                    if (string.IsNullOrWhiteSpace(Val(u0, "DataFine")?.ToString()))
                        avvisi.Add("In scheda la data di fine e' gia' vuota: il dipendente risulta gia' attivo");
                }
            }
            else
            {
                // per gli altri modelli non si sa che cosa fosse stato scritto prima:
                // meglio dirlo che indovinare
                avvisi.Add($"Annullamento di una comunicazione di {movimentoAnnullato}: "
                    + "le date del rapporto non vengono toccate, controlla la scheda a mano");
            }
            break;

        case "proroga":
            // la proroga sposta in avanti la scadenza: fine contratto e fine rapporto
            causale = estratti["DataFineProroga"] is { Length: > 0 } dfp ? $"nuova scadenza {dfp}" : null;
            Proponi("DataFineContratto", "Fine contratto (prorogata)", estratti["DataFineProroga"]);
            Proponi("DataFine", "Fine rapporto (prorogata)", estratti["DataFineProroga"]);
            if (string.IsNullOrWhiteSpace(estratti["DataFineProroga"]))
                avvisi.Add("Proroga senza data di fine: controlla il PDF");
            break;

        case "cessazione":
            causale = estratti["MotivoCessazione"];
            Proponi("DataFine", "Fine rapporto (cessazione)", estratti["DataCessazione"]);
            if (string.IsNullOrWhiteSpace(estratti["DataCessazione"]))
                avvisi.Add("Cessazione senza data: controlla il PDF");
            break;

        case "trasformazione":
            causale = estratti["CausaTrasformazione"];
            // il contratto risultante e' quello nella sezione trasformazione: se e'
            // a tempo indeterminato le date di fine non hanno piu' senso
            if ((estratti["TipoContratto"] ?? "").ToUpperInvariant().Contains("INDETERMINATO"))
            {
                ProponiAzzeramento("DataFineContratto", "Fine contratto", "contratto a tempo indeterminato");
                ProponiAzzeramento("DataFine", "Fine rapporto", "contratto a tempo indeterminato");
            }
            else
            {
                Proponi("DataFineContratto", "Fine contratto", estratti["DataFineRapporto"]);
                Proponi("DataFine", "Fine rapporto", estratti["DataFineRapporto"]);
            }
            break;

        default: // assunzione
            if (riassunzione && string.IsNullOrWhiteSpace(estratti["DataFineRapporto"]))
            {
                // contratto nuovo senza scadenza: la scheda nuova non deve ereditare
                // la chiusura di quella vecchia
                ProponiAzzeramento("DataFineContratto", "Fine contratto", "nuovo rapporto senza scadenza");
                ProponiAzzeramento("DataFine", "Fine rapporto", "nuovo rapporto senza scadenza");
            }
            else
            {
                Proponi("DataFineContratto", "Fine prevista contratto", estratti["DataFineRapporto"]);
                Proponi("DataFine", "Fine rapporto", estratti["DataFineRapporto"]);
            }
            break;
    }

    if (riassunzione && u0 is not null)
    {
        // quello che una scheda nuova deve avere di suo: la matricola la da' il
        // personale, il login si tiene quello di prima (in azienda si fa cosi'),
        // il codice palmare segue la convenzione di oggi (le prime 11 lettere del CF)
        proposte.Add(new { campo = "Matricola", etichetta = "Matricola (nuova)", attuale = Val(u0, "Matricola")?.ToString() ?? "",
            nuovo = "", testo = "la assegna il personale", opzioni = (object?)null, azzera = false, editabile = "testo" });
        proposte.Add(new { campo = "Utente", etichetta = "Login", attuale = Val(u0, "Utente")?.ToString() ?? "",
            nuovo = Val(u0, "Utente")?.ToString() ?? "", testo = (string?)null, opzioni = (object?)null, azzera = false, editabile = "testo" });
        proposte.Add(new { campo = "codAppLogin", etichetta = "Codice palmare", attuale = Val(u0, "codAppLogin")?.ToString() ?? "",
            nuovo = cf.Length == 16 ? cf[..11] : "", testo = (string?)null, opzioni = (object?)null, azzera = false, editabile = "testo" });
    }

    var titoloTipo = tipo switch
    {
        "proroga" => "Proroga",
        "trasformazione" => "Trasformazione",
        "cessazione" => "Cessazione",
        "annullamento" => "Annullamento " + movimentoAnnullato,
        _ => "Assunzione"
    };

    return Results.Ok(new
    {
        fonte, tipo, titoloTipo, causale, estratti, utente = u0,
        altriAccount = utenti.Count - (u0 is null ? 0 : 1), proposte, avvisi,
        riassunzione = riassunzione && u0 is not null ? new
        {
            idUtente = Val(u0, "IdUtente"), matricola = Val(u0, "Matricola"),
            dal = Val(u0, "DataInizio"), al = Val(u0, "DataFine")
        } : null
    });
}).RequireAuthorization();

app.MapPost("/api/hr/unilav/applica", async (UnilavApplicaRequest req) =>
{
    if (req.IdUtente <= 0 || req.Valori is null || req.Valori.Count == 0)
        return Results.Json(new { errore = "Nessun campo da applicare" }, statusCode: 400);

    if (req.NuovaScheda)
    {
        // Riassunzione: req.IdUtente e' la scheda del rapporto precedente e resta
        // com'e'. Se ne crea una nuova copiandone l'anagrafica; sopra si applicano
        // i campi scelti a video (date e contratto dall'UNILAV, matricola, login).
        // Quello che appartiene al vecchio rapporto (matricola, chiusura, UNILAV,
        // accessi) non si porta dietro.
        await using var cnN = Operatore.Connessione(ConnString());
        var vecchia = (await cnN.QueryFirstOrDefaultAsync("SELECT * FROM UTENTI WHERE IdUtente = @id",
            new { id = req.IdUtente })) as IDictionary<string, object>;
        if (vecchia is null)
            return Results.Json(new { errore = $"Scheda {req.IdUtente} non trovata" }, statusCode: 404);
        var delVecchioRapporto = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Matricola", "DataFine", "DataFineContratto", "UnilavCodice", "UnilavData",
            "LoginErrors", "DataUltimoAccesso", "tokenAutoLogin", "tokenRegistrazione", "RECHASH", "RECDATA"
        };
        var colonneUtenti = (await LoadColonne(cnN, "UTENTI"))
            .Where(c => !c.Identita && c.Col != "Pass").Select(c => c.Col).ToList();
        var parN = new DynamicParameters();
        parN.Add("IdUtente", null);            // NULL = inserimento
        foreach (var col in colonneUtenti)
        {
            var v = vecchia.TryGetValue(col, out var x) ? x : null;
            if (delVecchioRapporto.Contains(col)) v = null;
            if (col.Equals("Stato", StringComparison.OrdinalIgnoreCase)) v = "SI";
            parN.Add(col, v);
        }
        foreach (var (k, v) in req.Valori)
        {
            var col = colonneUtenti.FirstOrDefault(c => c.Equals(k, StringComparison.OrdinalIgnoreCase));
            if (col is null) continue;
            if (string.IsNullOrWhiteSpace(v)) { parN.Add(col, null); continue; }
            if (col is "DataNascita" or "DataInizio" or "DataFineContratto" or "DataFine" or "SoggiornoScadenza" or "UnilavData")
            {
                if (DateTime.TryParse(v, System.Globalization.CultureInfo.InvariantCulture,
                        System.Globalization.DateTimeStyles.None, out var d)) parN.Add(col, d);
            }
            else if (col is "OreSettimanali" or "Partime")
            {
                if (decimal.TryParse(v.Replace(',', '.'), System.Globalization.NumberStyles.Any,
                        System.Globalization.CultureInfo.InvariantCulture, out var num)) parN.Add(col, num);
            }
            else if (col == "IdFiliale") { if (int.TryParse(v, out var idf)) parN.Add(col, idf); }
            else parN.Add(col, v.Trim());
        }
        try
        {
            var nuovoId = await cnN.QueryFirstOrDefaultAsync<int?>("dbo.AI_UTENTI_Save", parN,
                commandType: CommandType.StoredProcedure);
            // la vecchia, se non lo diceva gia', da oggi risulta cessata anche in elenco
            var statoVecchio = vecchia.TryGetValue("Stato", out var st) ? st?.ToString()?.Trim() : null;
            if (!string.Equals(statoVecchio, "CESSATO", StringComparison.OrdinalIgnoreCase))
                await cnN.ExecuteAsync("dbo.AI_UTENTI_Stato_Save", new { req.IdUtente, Stato = "CESSATO" },
                    commandType: CommandType.StoredProcedure);
            return Results.Ok(new { righe = 1, nuovoIdUtente = nuovoId });
        }
        catch (SqlException ex)
        {
            return Results.Json(new { errore = ex.Message }, statusCode: 400);
        }
    }
    var ammessi = new[] { "Nome", "DataNascita", "DataInizio", "IndirizzoRes", "CapRes", "ComuneRes", "ProvRes",
        "Livello", "Mansione", "Cittadinanza", "LuogoNascita", "TitoloStudio", "TipoContratto", "DataFineContratto",
        "DataFine", "OreSettimanali", "Partime", "IdFiliale", "CCNL", "SoggiornoTipo", "SoggiornoNumero",
        "SoggiornoMotivo", "SoggiornoScadenza", "SoggiornoQuestura", "UnilavCodice", "UnilavData" };
    var par = new DynamicParameters();
    par.Add("IdUtente", req.IdUtente);
    // lo Stato non appartiene al tracciato UNILAV: e' la colonna dell'elenco
    // dipendenti, e ha la sua stored (che ne controlla i valori ammessi). Arriva
    // qui solo con l'annullamento di una cessazione, per rimettere il dipendente
    // in forza insieme alla data di fine.
    string? statoNuovo = null;
    foreach (var (k, v) in req.Valori)
    {
        if (k.Equals("Stato", StringComparison.OrdinalIgnoreCase)) { statoNuovo = v; continue; }
        if (!ammessi.Contains(k, StringComparer.OrdinalIgnoreCase)) continue;
        if (string.IsNullOrWhiteSpace(v))
        {
            // valore vuoto sulle date di fine = svuota il campo (trasformazione a
            // tempo indeterminato); sugli altri campi non si fa nulla
            if (k.Equals("DataFine", StringComparison.OrdinalIgnoreCase)) par.Add("AzzeraDataFine", true);
            else if (k.Equals("DataFineContratto", StringComparison.OrdinalIgnoreCase)) par.Add("AzzeraDataFineContratto", true);
            continue;
        }
        if (k is "DataNascita" or "DataInizio" or "DataFineContratto" or "DataFine" or "SoggiornoScadenza" or "UnilavData")
        {
            if (DateTime.TryParse(v, out var d)) par.Add(k, d);
        }
        else if (k is "OreSettimanali" or "Partime")
        {
            if (decimal.TryParse(v.Replace(',', '.'), System.Globalization.NumberStyles.Any,
                System.Globalization.CultureInfo.InvariantCulture, out var num)) par.Add(k, num);
        }
        else if (k == "IdFiliale")
        {
            if (int.TryParse(v, out var idf)) par.Add(k, idf);
        }
        else par.Add(k, v.Trim());
    }
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var righe = par.ParameterNames.Count() > 1
            ? await cn.QueryFirstAsync<int>("dbo.AI_UTENTI_Unilav_Applica", par, commandType: CommandType.StoredProcedure)
            : 0;
        if (statoNuovo is not null)
        {
            await cn.ExecuteAsync("dbo.AI_UTENTI_Stato_Save",
                new { req.IdUtente, Stato = string.IsNullOrWhiteSpace(statoNuovo) ? null : statoNuovo.Trim() },
                commandType: CommandType.StoredProcedure);
            righe++;
        }
        return Results.Ok(new { righe });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: 400);
    }
}).RequireAuthorization();

// === Nuova spedizione parcel Speedy (SPED_INSERIMENTO via AI_SPED_NuovaParcel) ===

// geocoding Nominatim/OSM: un client condiviso con User-Agent come da policy OSM
var geocodeHttp = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
geocodeHttp.DefaultRequestHeaders.UserAgent.ParseAdd("GecoNew/1.0");

// Clienti attivi dell'azienda con condizioni parcel (famiglia P)
app.MapGet("/api/sped/init", async (ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda))
        return Results.BadRequest(new { errore = "Azienda non disponibile" });
    await using var cn = Operatore.Connessione(ConnString());
    var clienti = await cn.QueryAsync(@"
        SELECT c.IdCliente AS idCliente, c.RagioneSociale AS ragioneSociale
        FROM CLIENTI c
        WHERE c.IdAzienda = @idAzienda AND c.DataFine IS NULL
          AND EXISTS (SELECT 1 FROM CLIENTI_CONDIZIONI cc
                      WHERE cc.IdCliente = c.IdCliente AND cc.CodFamiglia = 'P')
        ORDER BY c.RagioneSociale", new { idAzienda });
    return Results.Ok(clienti);
}).RequireAuthorization();

// Prodotti abilitati, listini validi e mittenti del cliente scelto
app.MapGet("/api/sped/cliente/{idCliente:int}", async (int idCliente) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var prodotti = await cn.QueryAsync(@"
        SELECT p.IdProdotto AS idProdotto, p.Prodotto AS prodotto
        FROM PRODOTTI p
        WHERE p.CodFamiglia = 'P' AND p.DataFineValidita IS NULL
          AND EXISTS (SELECT 1 FROM CLIENTI_CONDIZIONI cc
                      WHERE cc.IdCliente = @idCliente AND cc.CodFamiglia = 'P'
                        AND (cc.IdProdotto IS NULL OR cc.IdProdotto = p.IdProdotto))
        ORDER BY p.Prodotto", new { idCliente });
    var listini = await cn.QueryAsync(@"
        SELECT IdListino AS idListino, CodiceListino AS codiceListino,
               Descrizione AS descrizione, IdProdotto AS idProdotto
        FROM FATT_LISTINI
        WHERE IdCliente = @idCliente
          AND (ValidoDal IS NULL OR ValidoDal <= CAST(GETDATE() AS date))
          AND (ValidoAl IS NULL OR ValidoAl >= CAST(GETDATE() AS date))
        ORDER BY Descrizione", new { idCliente });
    var mittenti = await cn.QueryAsync(@"
        SELECT IdMittente AS idMittente, UFFICIOSPEDITORE AS ragioneSociale,
               INDIRIZZO AS indirizzo, CAP AS cap, COMUNE AS localita, PROV AS provincia,
               email_mittente AS email
        FROM MITTENTI WHERE idCliente = @idCliente ORDER BY UFFICIOSPEDITORE", new { idCliente });
    return Results.Ok(new { prodotti, listini, mittenti });
}).RequireAuthorization();

// Rubrica: nominativi gia' usati dal cliente come punto di ritiro o destinazione.
// NB: i clienti storici hanno milioni di righe in SPED_ATTIVITA -> si raggruppa
// solo sulle ultime 4000 spedizioni (lettura all'indietro sull'indice IdCliente)
app.MapGet("/api/sped/rubrica", async (int idCliente, string tipo, string? q) =>
{
    var pre = tipo == "ritiro" ? "Ritiro" : "Destinazione";
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync($@"
        SELECT TOP 12 s.RagioneSociale AS ragioneSociale, s.Indirizzo AS indirizzo,
               s.NumeroCivico AS numeroCivico, s.Cap AS cap, s.Localita AS localita,
               s.Provincia AS provincia,
               MAX(s.Lat) AS lat, MAX(s.Lng) AS lng, MAX(s.IdSpedizione) AS ult
        FROM (
            SELECT TOP 4000 {pre}RagioneSociale AS RagioneSociale, {pre}Indirizzo AS Indirizzo,
                   {pre}NumeroCivico AS NumeroCivico, {pre}Cap AS Cap, {pre}Localita AS Localita,
                   {pre}ProvinciaCodice AS Provincia, {pre}Latitude AS Lat, {pre}Longitude AS Lng, IdSpedizione
            FROM SPED_ATTIVITA
            WHERE IdCliente = @idCliente
            ORDER BY IdSpedizione DESC
        ) s
        WHERE s.RagioneSociale IS NOT NULL AND s.RagioneSociale <> ''
          AND (@q IS NULL OR s.RagioneSociale LIKE @q + '%')
        GROUP BY s.RagioneSociale, s.Indirizzo, s.NumeroCivico, s.Cap, s.Localita, s.Provincia
        ORDER BY ult DESC",
        new { idCliente, q = string.IsNullOrWhiteSpace(q) ? null : q.Trim() }, commandTimeout: 15);
    return Results.Ok(righe);
}).RequireAuthorization();

// Sigle provincia esistenti (per la compilazione guidata in ordine inverso)
app.MapGet("/api/sped/province", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var province = await cn.QueryAsync<string>(@"
        SELECT DISTINCT SIGLAPROV FROM GEO_COMUNE
        WHERE ISNULL(SIGLAPROV, '') <> '' ORDER BY SIGLAPROV");
    return Results.Ok(province);
}).RequireAuthorization();

// Comuni/CAP/province esistenti (GEO_COMUNE, una riga per CAP), filtrabili per provincia
app.MapGet("/api/sped/comuni", async (string q, string? prov) =>
{
    if (string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2) return Results.Ok(Array.Empty<object>());
    await using var cn = Operatore.Connessione(ConnString());
    var comuni = await cn.QueryAsync(@"
        SELECT DISTINCT TOP 15 DENOMINAZIONE AS comune, CAP AS cap, SIGLAPROV AS provincia
        FROM GEO_COMUNE
        WHERE DENOMINAZIONE LIKE @q + '%' AND CAP IS NOT NULL
          AND (@prov IS NULL OR SIGLAPROV = @prov)
        ORDER BY comune, cap",
        new { q = q.Trim(), prov = string.IsNullOrWhiteSpace(prov) ? null : prov.Trim().ToUpperInvariant() });
    return Results.Ok(comuni);
}).RequireAuthorization();

// Copertura del CAP di destinazione per il prodotto (GetCoperture legacy)
app.MapGet("/api/sped/copertura", async (int idProdotto, string cap) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var r = (await cn.QueryFirstOrDefaultAsync(
        "dbo.GetCoperture", new { Cap = cap, IdProdotto = idProdotto },
        commandType: CommandType.StoredProcedure)) as IDictionary<string, object>;
    if (r is null) return Results.Ok(new { esito = (string?)null, filiale = (string?)null });
    var idFil = r.TryGetValue("IdFilialeDistribuzione", out var f) ? f as int? : null;
    string? filiale = idFil is int fid
        ? await cn.ExecuteScalarAsync<string>("SELECT FILIALE FROM FILIALI WHERE IDFILIALE = @fid", new { fid })
        : null;
    return Results.Ok(new { esito = r.TryGetValue("Result", out var e) ? e as string : null, filiale });
}).RequireAuthorization();

// Verifica geografica via Nominatim (OpenStreetMap). Con 'libero' cerca l'indirizzo
// intero come scritto dall'utente; altrimenti ricerca strutturata. In entrambi i
// casi restituisce anche i campi SCOMPOSTI (via, civico, cap, comune, provincia)
// cosi' il form puo' correggersi con quanto trovato.
app.MapGet("/api/sped/geocode", async (string? libero, string? indirizzo, string? civico, string? cap, string? localita, string? provincia) =>
{
    const string basi = "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=5&countrycodes=it&addressdetails=1";

    static List<object> Estrai(string json)
    {
        using var doc = System.Text.Json.JsonDocument.Parse(json);
        return doc.RootElement.EnumerateArray().Select(e =>
        {
            System.Text.Json.JsonElement a = default;
            var haAddr = e.TryGetProperty("address", out a);
            string? A(string k) => haAddr && a.TryGetProperty(k, out var v) ? v.GetString() : null;
            var iso = A("ISO3166-2-lvl6");
            return (object)new
            {
                lat = double.Parse(e.GetProperty("lat").GetString()!, System.Globalization.CultureInfo.InvariantCulture),
                lng = double.Parse(e.GetProperty("lon").GetString()!, System.Globalization.CultureInfo.InvariantCulture),
                descrizione = e.GetProperty("display_name").GetString(),
                indirizzo = A("road"),
                civico = A("house_number"),
                cap = A("postcode"),
                localita = A("city") ?? A("town") ?? A("village") ?? A("municipality") ?? A("hamlet"),
                provincia = iso is not null && iso.StartsWith("IT-") ? iso[3..] : null
            };
        }).ToList();
    }

    try
    {
        List<object> trovati;
        if (!string.IsNullOrWhiteSpace(libero))
        {
            trovati = Estrai(await geocodeHttp.GetStringAsync($"{basi}&q={Uri.EscapeDataString(libero.Trim())}"));
        }
        else
        {
            if (string.IsNullOrWhiteSpace(indirizzo) || string.IsNullOrWhiteSpace(localita))
                return Results.BadRequest(new { errore = "Servono almeno comune e indirizzo" });
            var street = $"{civico} {indirizzo}".Trim();
            var url = $"{basi}&street={Uri.EscapeDataString(street)}&city={Uri.EscapeDataString(localita)}";
            if (!string.IsNullOrWhiteSpace(cap)) url += $"&postalcode={Uri.EscapeDataString(cap)}";
            trovati = Estrai(await geocodeHttp.GetStringAsync(url));
            if (trovati.Count == 0)
            {
                // ripiego: ricerca libera composta (indirizzi scritti in forme non standard)
                var q = $"{street}, {cap} {localita} {provincia}".Trim();
                trovati = Estrai(await geocodeHttp.GetStringAsync($"{basi}&q={Uri.EscapeDataString(q)}"));
            }
        }
        return Results.Ok(trovati);
    }
    catch (Exception ex)
    {
        return Results.Json(new { errore = "Servizio di geocodifica non raggiungibile: " + ex.Message }, statusCode: 502);
    }
}).RequireAuthorization();

// Salvataggio: validazioni e chiamata ad AI_SPED_NuovaParcel (wrapper di SPED_INSERIMENTO)
app.MapPost("/api/sped/nuova", async (SpedNuovaRequest req, ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var idUtente);
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);
    int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda);

    string? err = null;
    if (req.IdCliente <= 0 || req.IdProdotto <= 0) err = "Cliente e prodotto sono obbligatori";
    else if (string.IsNullOrWhiteSpace(req.DestinazioneRagioneSociale) || string.IsNullOrWhiteSpace(req.DestinazioneIndirizzo)
        || string.IsNullOrWhiteSpace(req.DestinazioneLocalita) || string.IsNullOrWhiteSpace(req.DestinazioneCap)
        || string.IsNullOrWhiteSpace(req.DestinazioneProvincia)) err = "La destinazione è incompleta";
    else if (req.DestinazioneLat is null || req.DestinazioneLng is null) err = "L'indirizzo di destinazione non è stato verificato geograficamente";
    else if (req.PesoKg is null or <= 0) err = "Il peso è obbligatorio";
    else if ((req.Nota?.Length ?? 0) > 200) err = "La nota supera i 200 caratteri";
    else if (req.Contrassegno && req.ImportoContrassegno is null or <= 0) err = "Indicare l'importo del contrassegno";
    else if (req.RitiroRichiesto)
    {
        if (req.DataRitiro is null || req.DataRitiro <= DateTime.Now) err = "La data/ora di ritiro deve essere futura";
        else if (string.IsNullOrWhiteSpace(req.RitiroRagioneSociale) || string.IsNullOrWhiteSpace(req.RitiroIndirizzo)
            || string.IsNullOrWhiteSpace(req.RitiroLocalita) || string.IsNullOrWhiteSpace(req.RitiroCap)) err = "I dati di ritiro sono incompleti";
    }
    if (err is not null) return Results.BadRequest(new { errore = err });

    var par = new DynamicParameters(new
    {
        req.IdCliente,
        req.IdProdotto,
        IdAzienda = idAzienda == 0 ? 2 : idAzienda,
        IdUtente = idUtente,
        IdFiliale = idFiliale,
        req.IdMittente,
        req.TariffarioCodice,
        Barcode = string.IsNullOrWhiteSpace(req.Barcode) ? null : req.Barcode.Trim(),
        DataRitiro = req.RitiroRichiesto ? req.DataRitiro : null,
        RitiroRagioneSociale = req.RitiroRichiesto ? req.RitiroRagioneSociale : null,
        RitiroIndirizzo = req.RitiroRichiesto ? req.RitiroIndirizzo : null,
        RitiroNumeroCivico = req.RitiroRichiesto ? req.RitiroNumeroCivico : null,
        RitiroLocalita = req.RitiroRichiesto ? req.RitiroLocalita : null,
        RitiroCap = req.RitiroRichiesto ? req.RitiroCap : null,
        RitiroProvinciaCodice = req.RitiroRichiesto ? req.RitiroProvincia : null,
        RitiroLatitude = req.RitiroRichiesto ? req.RitiroLat : null,
        RitiroLongitude = req.RitiroRichiesto ? req.RitiroLng : null,
        req.MittenteRagioneSociale,
        req.MittenteIndirizzo,
        req.MittenteLocalita,
        req.MittenteCap,
        MittenteProvinciaCodice = req.MittenteProvincia,
        req.MittenteEmail,
        req.DestinazioneRagioneSociale,
        req.DestinazioneIndirizzo,
        req.DestinazioneNumeroCivico,
        req.DestinazioneLocalita,
        req.DestinazioneCap,
        DestinazioneProvinciaCodice = req.DestinazioneProvincia,
        DestinazioneLatitude = req.DestinazioneLat,
        DestinazioneLongitude = req.DestinazioneLng,
        ContattoDestDescrizione = req.ContattoNome,
        ContattoDestTelefono = req.ContattoTelefono,
        ContattoDestEmail = req.ContattoEmail,
        req.Importo,
        ImportoContrassegno = req.Contrassegno ? req.ImportoContrassegno : null,
        PesoDichiaratoKG = req.PesoKg,
        Nota = req.Nota
    });

    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        // la catena SPED_INSERIMENTO/GetCoperture emette piu' result set:
        // l'esito della copertura si riconosce da IdFilialeDistribuzione,
        // quello finale del wrapper dalla colonna Barcode
        using var multi = await cn.QueryMultipleAsync("dbo.AI_SPED_NuovaParcel", par,
            commandType: CommandType.StoredProcedure, commandTimeout: 60);
        IDictionary<string, object>? finale = null;
        string? copertura = null;
        while (!multi.IsConsumed)
        {
            var r = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().FirstOrDefault();
            if (r is null) continue;
            if (r.ContainsKey("Barcode")) finale = r;
            else if (r.ContainsKey("IdFilialeDistribuzione")) copertura = r["Result"] as string;
        }
        if (finale is null || finale["IdSpedizione"] is null)
            return Results.Json(new { errore = "La stored non ha restituito la spedizione" }, statusCode: 500);
        return Results.Ok(new
        {
            idSpedizione = finale["IdSpedizione"],
            idAttivita = finale["IdAttivita"],
            barcode = finale["Barcode"],
            result = finale["Result"],
            copertura
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: 400);
    }
}).RequireAuthorization();

// Stampa della lettera di vettura (DELIVERY_LDV.fr3). Il report server risponde
// SOLO al backend e non va mai esposto al browser: il PDF viene scaricato qui
// (&format=pdf + redirect, senza il quale risponde il viewer HTML a sessione),
// appoggiato in una temp locale, servito come application/pdf e la temp svuotata.
var reportHttp = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
var reportTempDir = Path.Combine(Path.GetTempPath(), "geconew-report");

app.MapGet("/api/sped/ldv/{id:int}", async (int id) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var basis = await cn.ExecuteScalarAsync<string>(
        "SELECT Valore FROM PARAMETRI WHERE Nome = 'ReportServer'");
    if (string.IsNullOrWhiteSpace(basis))
        return Results.Json(new { errore = "Parametro ReportServer non configurato" }, statusCode: 500);
    try
    {
        Directory.CreateDirectory(reportTempDir);
        // svuota i pdf di appoggio rimasti da chiamate precedenti
        foreach (var vecchio in Directory.GetFiles(reportTempDir))
            try { File.Delete(vecchio); } catch { /* in uso da un'altra richiesta */ }

        var scaricato = await reportHttp.GetByteArrayAsync($"{basis}DELIVERY_LDV.fr3&IdSpedizione={id}&format=pdf");
        if (scaricato.Length < 5 || scaricato[0] != (byte)'%' || scaricato[1] != (byte)'P')
            return Results.Json(new { errore = "Il report server non ha restituito un PDF" }, statusCode: 502);

        var percorso = Path.Combine(reportTempDir, $"LDV_{id}_{Guid.NewGuid():N}.pdf");
        await File.WriteAllBytesAsync(percorso, scaricato);
        var pdf = await File.ReadAllBytesAsync(percorso);
        try { File.Delete(percorso); } catch { }
        return Results.File(pdf, "application/pdf", $"LDV_{id}.pdf");
    }
    catch (Exception ex)
    {
        return Results.Json(new { errore = "Report server non raggiungibile: " + ex.Message }, statusCode: 502);
    }
}).RequireAuthorization();

// === Gestione clienti (anagrafica + condizioni + listini, per azienda) ===

// il cliente e' modificabile solo dentro l'azienda dell'utente collegato
async Task<bool> ClienteDellAzienda(SqlConnection cn, int idCliente, int idAzienda) =>
    await cn.ExecuteScalarAsync<int?>(
        "SELECT 1 FROM CLIENTI WHERE IdCliente = @idCliente AND IdAzienda = @idAzienda",
        new { idCliente, idAzienda }) == 1;

// Elenco clienti dell'azienda con conteggi delle tabelle collegate
app.MapGet("/api/clienti", async (bool? anchecessati, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda))
        return Results.BadRequest(new { errore = "Azienda non disponibile" });
    await using var cn = Operatore.Connessione(ConnString());
    var clienti = await cn.QueryAsync(@"
        SELECT c.IdCliente, c.RagioneSociale, c.PartitaIva, c.CodiceCliente,
               c.Comune, c.Prov, CONVERT(varchar(10), c.DataFine, 120) AS DataFine,
               (SELECT COUNT(*) FROM CLIENTI_CONDIZIONI cc WHERE cc.IdCliente = c.IdCliente) AS nCondizioni,
               (SELECT COUNT(*) FROM FATT_LISTINI l WHERE l.IdCliente = c.IdCliente) AS nListini
        FROM CLIENTI c
        WHERE c.IdAzienda = @idAzienda AND (@tutti = 1 OR c.DataFine IS NULL)
        ORDER BY c.RagioneSociale",
        new { idAzienda, tutti = anchecessati == true ? 1 : 0 });
    return Results.Ok(clienti);
}).RequireAuthorization();

// Liste di supporto per i form (famiglie, prodotti, tracciati, filiali, valori in uso)
app.MapGet("/api/clienti/lookup", async (ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda);
    await using var cn = Operatore.Connessione(ConnString());
    var famiglie = await cn.QueryAsync(
        "SELECT CodFamiglia, FamigliaDiProdotto FROM PROD_FAMIGLIE ORDER BY FamigliaDiProdotto");
    var prodotti = await cn.QueryAsync(@"
        SELECT IdProdotto, Prodotto, CodFamiglia FROM PRODOTTI
        WHERE DataFineValidita IS NULL ORDER BY Prodotto");
    var tracciati = await cn.QueryAsync(
        "SELECT IdTracciato, Tracciato FROM FILE_TRACCIATO ORDER BY Tracciato");
    var filiali = await cn.QueryAsync(@"
        SELECT IDFILIALE AS IdFiliale, FILIALE AS Filiale FROM FILIALI
        WHERE IdAzienda = @idAzienda AND DataChiusura IS NULL ORDER BY FILIALE", new { idAzienda });
    var tipiVendita = await cn.QueryAsync<string>(
        "SELECT DISTINCT CodTipoVendita FROM CLIENTI_CONDIZIONI WHERE ISNULL(CodTipoVendita,'') <> '' ORDER BY 1");
    return Results.Ok(new { famiglie, prodotti, tracciati, filiali, tipiVendita });
}).RequireAuthorization();

// Scheda completa: anagrafica + condizioni + listini
app.MapGet("/api/clienti/{idCliente:int}", async (int idCliente, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda))
        return Results.BadRequest(new { errore = "Azienda non disponibile" });
    await using var cn = Operatore.Connessione(ConnString());
    var anagrafica = (await cn.QueryFirstOrDefaultAsync(@"
        SELECT IdCliente, IdAzienda, RagioneSociale, CIG, Descrizione, PartitaIva, CodSDI, PEC,
               Indirizzo, CAP, Comune, Prov, Nazione, Telefono, Email,
               CONVERT(varchar(10), DataFine, 120) AS DataFine,
               CodiceCliente, Gestionale, InvioEmailEventi, EmailPrefattura, Demo
        FROM CLIENTI WHERE IdCliente = @idCliente AND IdAzienda = @idAzienda",
        new { idCliente, idAzienda })) as IDictionary<string, object>;
    if (anagrafica is null) return Results.NotFound(new { errore = "Cliente non trovato in questa azienda" });
    var condizioni = await cn.QueryAsync(@"
        SELECT cc.IdClienteCondizione, cc.CodFamiglia, f.FamigliaDiProdotto, cc.CodTipoVendita,
               CONVERT(varchar(10), cc.DataInizioFatturazione, 120) AS DataInizioFatturazione,
               CONVERT(varchar(10), cc.DataFineFatturazione, 120) AS DataFineFatturazione,
               cc.Ambito, cc.Scansione, cc.IdProdotto, p.Prodotto,
               cc.IdTracciato, t.Tracciato, cc.IdFiliale, fi.FILIALE AS Filiale
        FROM CLIENTI_CONDIZIONI cc
        LEFT JOIN PROD_FAMIGLIE f ON f.CodFamiglia = cc.CodFamiglia
        LEFT JOIN PRODOTTI p ON p.IdProdotto = cc.IdProdotto
        LEFT JOIN FILE_TRACCIATO t ON t.IdTracciato = cc.IdTracciato
        LEFT JOIN FILIALI fi ON fi.IDFILIALE = cc.IdFiliale
        WHERE cc.IdCliente = @idCliente
        ORDER BY cc.IdClienteCondizione", new { idCliente });
    var listini = await cn.QueryAsync(@"
        SELECT l.IdListino, l.CodiceListino, l.Descrizione, l.IdProdotto, p.Prodotto,
               l.PrezzoAttivo, l.ScontoAttivo, l.PrezzoPassivo, l.ScontoPassivo, l.AliquotaIVA,
               CONVERT(varchar(10), l.ValidoDal, 120) AS ValidoDal,
               CONVERT(varchar(10), l.ValidoAl, 120) AS ValidoAl,
               l.ProdottoServizio, l.TipoArea, l.Porto, l.PesoMin, l.PesoMax, l.Tipo, l.tariffaOS
        FROM FATT_LISTINI l
        LEFT JOIN PRODOTTI p ON p.IdProdotto = l.IdProdotto
        WHERE l.IdCliente = @idCliente
        ORDER BY l.Descrizione, l.IdListino", new { idCliente });
    return Results.Ok(new { anagrafica, condizioni, listini });
}).RequireAuthorization();

// Salvataggio anagrafica (nuovo o modifica; DataFine = cancellazione logica)
app.MapPost("/api/clienti", async (ClienteSaveRequest req, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda))
        return Results.BadRequest(new { errore = "Azienda non disponibile" });
    if (string.IsNullOrWhiteSpace(req.RagioneSociale))
        return Results.BadRequest(new { errore = "La ragione sociale è obbligatoria" });
    await using var cn = Operatore.Connessione(ConnString());
    if (req.IdCliente is > 0 && !await ClienteDellAzienda(cn, req.IdCliente.Value, idAzienda))
        return Results.NotFound(new { errore = "Cliente non trovato in questa azienda" });
    try
    {
        var id = await cn.ExecuteScalarAsync<int>("dbo.AI_CLIENTI_Save", new
        {
            IdCliente = req.IdCliente is > 0 ? req.IdCliente : null,
            IdAzienda = idAzienda,   // sempre l'azienda dell'utente collegato
            req.RagioneSociale, req.CIG, req.Descrizione, req.PartitaIva, req.CodSDI, req.PEC,
            req.Indirizzo, req.CAP, req.Comune, req.Prov, req.Nazione, req.Telefono, req.Email,
            DataFine = string.IsNullOrWhiteSpace(req.DataFine) ? (DateTime?)null : DateTime.Parse(req.DataFine),
            req.CodiceCliente, req.Gestionale, req.InvioEmailEventi, req.EmailPrefattura, req.Demo
        }, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex) { return Results.Json(new { errore = ex.Message }, statusCode: 400); }
}).RequireAuthorization();

// Condizioni: upsert e cancellazione
app.MapPost("/api/clienti/{idCliente:int}/condizioni", async (int idCliente, CondizioneSaveRequest req, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda))
        return Results.BadRequest(new { errore = "Azienda non disponibile" });
    await using var cn = Operatore.Connessione(ConnString());
    if (!await ClienteDellAzienda(cn, idCliente, idAzienda))
        return Results.NotFound(new { errore = "Cliente non trovato in questa azienda" });
    try
    {
        var id = await cn.ExecuteScalarAsync<int>("dbo.AI_CLIENTI_CONDIZIONI_Save", new
        {
            IdClienteCondizione = req.IdClienteCondizione is > 0 ? req.IdClienteCondizione : null,
            IdCliente = idCliente,
            req.CodFamiglia, req.CodTipoVendita,
            DataInizioFatturazione = ParseData(req.DataInizioFatturazione),
            DataFineFatturazione = ParseData(req.DataFineFatturazione),
            req.Ambito, req.Scansione, req.IdProdotto, req.IdTracciato, req.IdFiliale
        }, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex) { return Results.Json(new { errore = ex.Message }, statusCode: 400); }
}).RequireAuthorization();

app.MapDelete("/api/clienti/condizioni/{idCondizione:int}", async (int idCondizione, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda))
        return Results.BadRequest(new { errore = "Azienda non disponibile" });
    await using var cn = Operatore.Connessione(ConnString());
    var ok = await cn.ExecuteScalarAsync<int?>(@"
        SELECT 1 FROM CLIENTI_CONDIZIONI cc JOIN CLIENTI c ON c.IdCliente = cc.IdCliente
        WHERE cc.IdClienteCondizione = @idCondizione AND c.IdAzienda = @idAzienda",
        new { idCondizione, idAzienda }) == 1;
    if (!ok) return Results.NotFound(new { errore = "Condizione non trovata in questa azienda" });
    var righe = await cn.ExecuteScalarAsync<int>("dbo.AI_CLIENTI_CONDIZIONI_Del",
        new { IdClienteCondizione = idCondizione }, commandType: CommandType.StoredProcedure);
    return Results.Ok(new { righe });
}).RequireAuthorization();

// Listini: upsert e cancellazione
app.MapPost("/api/clienti/{idCliente:int}/listini", async (int idCliente, ListinoSaveRequest req, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda))
        return Results.BadRequest(new { errore = "Azienda non disponibile" });
    await using var cn = Operatore.Connessione(ConnString());
    if (!await ClienteDellAzienda(cn, idCliente, idAzienda))
        return Results.NotFound(new { errore = "Cliente non trovato in questa azienda" });
    try
    {
        var id = await cn.ExecuteScalarAsync<int>("dbo.AI_FATT_LISTINI_Save", new
        {
            IdListino = req.IdListino is > 0 ? req.IdListino : null,
            IdCliente = idCliente,
            req.CodiceListino, req.Descrizione, req.IdProdotto,
            req.PrezzoAttivo, req.ScontoAttivo, req.PrezzoPassivo, req.ScontoPassivo, req.AliquotaIVA,
            ValidoDal = ParseData(req.ValidoDal), ValidoAl = ParseData(req.ValidoAl),
            req.ProdottoServizio, req.TipoArea, req.Porto, req.PesoMin, req.PesoMax, req.Tipo,
            tariffaOS = req.TariffaOS
        }, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex) { return Results.Json(new { errore = ex.Message }, statusCode: 400); }
}).RequireAuthorization();

app.MapDelete("/api/clienti/listini/{idListino:int}", async (int idListino, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda))
        return Results.BadRequest(new { errore = "Azienda non disponibile" });
    await using var cn = Operatore.Connessione(ConnString());
    var ok = await cn.ExecuteScalarAsync<int?>(@"
        SELECT 1 FROM FATT_LISTINI l JOIN CLIENTI c ON c.IdCliente = l.IdCliente
        WHERE l.IdListino = @idListino AND c.IdAzienda = @idAzienda",
        new { idListino, idAzienda }) == 1;
    if (!ok) return Results.NotFound(new { errore = "Listino non trovato in questa azienda" });
    var righe = await cn.ExecuteScalarAsync<int>("dbo.AI_FATT_LISTINI_Del",
        new { IdListino = idListino }, commandType: CommandType.StoredProcedure);
    return Results.Ok(new { righe });
}).RequireAuthorization();

static DateTime? ParseData(string? s) =>
    string.IsNullOrWhiteSpace(s) ? null : DateTime.Parse(s);

// === Accettazione da file (staging FILE_LOAD + stored legacy LoadFromFile) ===

// Clienti (stored ElencoClienti, filtro famiglia + visibilita' per ruolo/azienda)
// e tracciati di carico (FILE_TRACCIATO, con i dati per l'autoriconoscimento)
app.MapGet("/api/accettazione/init", async (string? codFamiglia, ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var idUtente);
    await using var cn = Operatore.Connessione(ConnString());
    var clienti = await cn.QueryAsync("dbo.ElencoClienti",
        new { CodFamiglia = codFamiglia ?? "", IdUtente = idUtente },
        commandType: CommandType.StoredProcedure);
    var tracciati = await cn.QueryAsync(@"
        SELECT IdTracciato AS idTracciato, Tracciato AS tracciato, IdCliente AS idCliente,
               Separatore AS separatore, ColonneTotali AS colonne,
               ISNULL(RigheIntestazione, 0) AS intestazione, ISNULL(RigheFooter, 0) AS footer,
               infoTracciato AS info
        FROM FILE_TRACCIATO ORDER BY Tracciato");
    return Results.Ok(new { clienti, tracciati });
}).RequireAuthorization();

// Famiglie abilitate per il cliente (stored ElencoFamiglie)
app.MapGet("/api/accettazione/famiglie", async (int idCliente) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var famiglie = await cn.QueryAsync("dbo.ElencoFamiglie",
        new { IdCliente = idCliente }, commandType: CommandType.StoredProcedure);
    return Results.Ok(famiglie);
}).RequireAuthorization();

// Prodotti della famiglia abilitati per il cliente (CLIENTI_CONDIZIONI)
app.MapGet("/api/accettazione/prodotti", async (int idCliente, string codFamiglia) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var prodotti = await cn.QueryAsync(@"
        SELECT p.IdProdotto AS idProdotto, p.Prodotto AS prodotto
        FROM PRODOTTI p
        WHERE p.CodFamiglia = @codFamiglia AND p.DataFineValidita IS NULL
          AND EXISTS (SELECT 1 FROM CLIENTI_CONDIZIONI cc
                      WHERE cc.IdCliente = @idCliente AND cc.CodFamiglia = @codFamiglia
                        AND (cc.IdProdotto IS NULL OR cc.IdProdotto = p.IdProdotto))
        ORDER BY p.Prodotto", new { idCliente, codFamiglia });
    return Results.Ok(prodotti);
}).RequireAuthorization();

// Ricerca fine dei clienti (popup): stessa visibilita' di ElencoClienti
app.MapGet("/api/accettazione/clienti-ricerca", async (string q, string? codFamiglia, ClaimsPrincipal user) =>
{
    if (string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2) return Results.Ok(Array.Empty<object>());
    int.TryParse(user.FindFirstValue("idRuolo"), out var idRuolo);
    int.TryParse(user.FindFirstValue("idAzienda"), out var idAzienda);
    await using var cn = Operatore.Connessione(ConnString());
    var clienti = await cn.QueryAsync(@"
        SELECT DISTINCT TOP 50 c.IdCliente AS idCliente, c.RagioneSociale AS ragioneSociale,
               c.PartitaIva AS partitaIva, c.CodiceCliente AS codiceCliente,
               c.Indirizzo AS indirizzo, c.CAP AS cap, c.Comune AS comune, c.Prov AS prov
        FROM CLIENTI c
        LEFT JOIN CLIENTI_CONDIZIONI cc ON cc.IdCliente = c.IdCliente
        WHERE c.DataFine IS NULL
          AND (@codFamiglia IS NULL OR cc.CodFamiglia = @codFamiglia)
          AND (@idRuolo < 10 OR c.IdAzienda = @idAzienda)
          AND (c.RagioneSociale LIKE '%' + @q + '%' OR c.PartitaIva LIKE @q + '%'
               OR c.CodiceCliente LIKE @q + '%' OR c.Comune LIKE @q + '%')
        ORDER BY c.RagioneSociale",
        new { q = q.Trim(), codFamiglia = string.IsNullOrWhiteSpace(codFamiglia) ? null : codFamiglia, idRuolo, idAzienda });
    return Results.Ok(clienti);
}).RequireAuthorization();

// Carico (o sola verifica) del file: staging in FILE_LOAD e stored LoadFromFile
app.MapPost("/api/accettazione/carica", async (AccettazioneCaricaRequest req, ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var idUtente);
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);

    if (req.IdCliente <= 0) return Results.BadRequest(new { errore = "Scegliere un cliente" });
    if (req.IdProdotto <= 0 && !req.SoloVerifica) return Results.BadRequest(new { errore = "Selezionare un prodotto" });
    if (req.IdTracciato <= 0) return Results.BadRequest(new { errore = "Selezionare un tracciato" });
    if (string.IsNullOrWhiteSpace(req.NomeFile)) return Results.BadRequest(new { errore = "Selezionare un file" });
    if (req.Righe is null || req.Righe.Count == 0) return Results.BadRequest(new { errore = "Il file è vuoto" });
    if (req.Righe.Count > 50000) return Results.BadRequest(new { errore = "Il file supera le 50.000 righe" });

    var docId = Guid.NewGuid().ToString().ToUpperInvariant();
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        await cn.QueryFirstAsync("dbo.AI_FILE_LOAD_Insert", new
        {
            DocID = docId,
            NomeFile = req.NomeFile,
            Righe = System.Text.Json.JsonSerializer.Serialize(req.Righe)
        }, commandType: CommandType.StoredProcedure, commandTimeout: 120);

        var par = new DynamicParameters(new
        {
            DocID = docId,
            NomeFile = req.NomeFile,
            IdCliente = req.IdCliente,
            IdProdotto = req.IdProdotto,
            SoloVerifica = req.SoloVerifica ? 1 : 0,
            IdUtente = idUtente,
            IdFiliale = idFiliale,
            TipoFile = req.IdTracciato
        });
        par.Add("Esito", dbType: DbType.String, size: 250, direction: ParameterDirection.Output);
        var r = (await cn.QueryFirstOrDefaultAsync("dbo.LoadFromFile", par,
            commandType: CommandType.StoredProcedure, commandTimeout: 300)) as IDictionary<string, object>;

        var result = r?["Result"] as string ?? par.Get<string?>("Esito") ?? "Nessun esito dalla stored";
        var ok = result == "OK" || (req.SoloVerifica && result.Contains("OK"));
        return Results.Ok(new
        {
            ok,
            result,
            idLotto = r != null && r.TryGetValue("IdLotto", out var l) ? l : null,
            docId,
            righe = req.Righe.Count
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message, docId }, statusCode: 400);
    }
}).RequireAuthorization();

// Uffici mittenti del cliente (per l'accettazione da banco "con mittenti")
app.MapGet("/api/accettazione/mittenti", async (int idCliente) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var mittenti = await cn.QueryAsync(@"
        SELECT IdMittente AS idMittente, UFFICIOSPEDITORE AS ragioneSociale,
               INDIRIZZO AS indirizzo, CAP AS cap, COMUNE AS localita, PROV AS provincia
        FROM MITTENTI WHERE idCliente = @idCliente
        ORDER BY UFFICIOSPEDITORE", new { idCliente });
    return Results.Ok(mittenti);
}).RequireAuthorization();

// Accettazione da banco: lotto + spedizioni (SPED_INSERIMENTO) + distinta di
// accettazione tramite AI_SPED_AccettazioneBanco. La catena emette piu' result
// set (coperture, eventuali doppioni): gli esiti riga si riconoscono dalla
// colonna EsitoRiga, il riepilogo da IdLotto, gli errori bloccanti da Errore.
app.MapPost("/api/accettazione/banco", async (AccettazioneBancoRequest req, ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var idUtente);
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);

    if (req.IdCliente <= 0) return Results.BadRequest(new { errore = "Scegliere un cliente" });
    if (req.IdProdotto <= 0) return Results.BadRequest(new { errore = "Selezionare un prodotto" });
    if (string.IsNullOrWhiteSpace(req.CodFamiglia)) return Results.BadRequest(new { errore = "Famiglia mancante" });
    if (req.Righe is null || req.Righe.Count == 0) return Results.BadRequest(new { errore = "Nessun atto da inserire" });
    if (req.Righe.Count > 300) return Results.BadRequest(new { errore = "Troppi atti in una sola accettazione (max 300)" });

    var righeJson = System.Text.Json.JsonSerializer.Serialize(req.Righe,
        new System.Text.Json.JsonSerializerOptions { PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase });
    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        using var multi = await cn.QueryMultipleAsync("dbo.AI_SPED_AccettazioneBanco", new
        {
            req.IdCliente,
            req.CodFamiglia,
            req.IdProdotto,
            IdUtente = idUtente,
            IdFiliale = idFiliale,
            req.IdMittente,
            Righe = righeJson
        }, commandType: CommandType.StoredProcedure, commandTimeout: 300);

        List<IDictionary<string, object>>? esiti = null;
        IDictionary<string, object>? riepilogo = null;
        string? errore = null;
        while (!multi.IsConsumed)
        {
            var grid = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().ToList();
            var prima = grid.FirstOrDefault();
            if (prima is null) continue;
            if (prima.ContainsKey("EsitoRiga")) esiti = grid;
            else if (prima.ContainsKey("IdLotto")) riepilogo = prima;
            else if (prima.ContainsKey("Errore")) errore = prima["Errore"] as string;
        }
        if (errore is not null) return Results.BadRequest(new { errore });
        if (esiti is null || riepilogo is null)
            return Results.Json(new { errore = "La stored non ha restituito gli esiti" }, statusCode: 500);
        return Results.Ok(new
        {
            idLotto = riepilogo["IdLotto"],
            lotto = riepilogo["Lotto"],
            idDistinta = riepilogo["IdDistinta"],
            barcodeDistinta = riepilogo["BarcodeDistinta"],
            inseriti = riepilogo["Inseriti"],
            scartati = riepilogo["Scartati"],
            righe = esiti.Select(e => new
            {
                riga = e["Riga"],
                barcode = e["Barcode"],
                idSpedizione = e["IdSpedizione"],
                esito = e["EsitoRiga"]
            })
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: 400);
    }
}).RequireAuthorization();

// Ricevuta di accettazione (DELIVERY_Accettazione.fr3 sulla distinta): stesso
// proxy della LDV, il report server non e' mai esposto al browser
app.MapGet("/api/accettazione/ricevuta/{idDistinta:int}", async (int idDistinta) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var basis = await cn.ExecuteScalarAsync<string>(
        "SELECT Valore FROM PARAMETRI WHERE Nome = 'ReportServer'");
    if (string.IsNullOrWhiteSpace(basis))
        return Results.Json(new { errore = "Parametro ReportServer non configurato" }, statusCode: 500);
    try
    {
        Directory.CreateDirectory(reportTempDir);
        foreach (var vecchio in Directory.GetFiles(reportTempDir))
            try { File.Delete(vecchio); } catch { /* in uso da un'altra richiesta */ }

        var scaricato = await reportHttp.GetByteArrayAsync($"{basis}DELIVERY_Accettazione.fr3&IdDistinta={idDistinta}&format=pdf");
        if (scaricato.Length < 5 || scaricato[0] != (byte)'%' || scaricato[1] != (byte)'P')
            return Results.Json(new { errore = "Il report server non ha restituito un PDF" }, statusCode: 502);

        var percorso = Path.Combine(reportTempDir, $"ACC_{idDistinta}_{Guid.NewGuid():N}.pdf");
        await File.WriteAllBytesAsync(percorso, scaricato);
        var pdf = await File.ReadAllBytesAsync(percorso);
        try { File.Delete(percorso); } catch { }
        return Results.File(pdf, "application/pdf", $"Accettazione_{idDistinta}.pdf");
    }
    catch (Exception ex)
    {
        return Results.Json(new { errore = "Report server non raggiungibile: " + ex.Message }, statusCode: 502);
    }
}).RequireAuthorization();

// === VideoCodifica (correzione lotti da file prima del checkin) ===

// Lotti in attesa di videocodifica (stessa selezione della stored legacy
// ElencoLottiDaVideocodificare: DataCarico e DataVideoCodifica nulle), con
// decodifiche e conteggio dei barcode mancanti
app.MapGet("/api/videocodifica/lotti", async (bool? tutte, string? codFamiglia, int? idCliente, int? idProdotto, bool? conCarico, ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);
    await using var cn = Operatore.Connessione(ConnString());
    // conCarico: i lotti da banco (es. MGG) nascono con DataCarico valorizzata e
    // vanno comunque videocodificati; per quelli da file DataCarico NULL = pendenti
    var lotti = await cn.QueryAsync(@"
        SELECT l.IdLotto, l.Lotto, l.IdCliente, c.RagioneSociale AS Cliente,
               l.CodFamiglia, p.Prodotto, ISNULL(x.Righe, 0) AS Righe,
               ISNULL(x.SenzaBarcode, 0) AS SenzaBarcode,
               l.IdFilialeAccettazione, f.FILIALE AS Filiale,
               CONVERT(varchar(16), l.DataInserimento, 120) AS DataInserimento
        FROM SPED_LOTTI l
        LEFT JOIN CLIENTI c ON c.IdCliente = l.IdCliente
        LEFT JOIN PRODOTTI p ON p.IdProdotto = l.IdProdotto
        LEFT JOIN FILIALI f ON f.IDFILIALE = l.IdFilialeAccettazione
        OUTER APPLY (SELECT COUNT(*) AS Righe,
                            SUM(CASE WHEN ISNULL(sa.Barcode, '') = '' THEN 1 ELSE 0 END) AS SenzaBarcode
                     FROM SPED_ATTIVITA sa WHERE sa.IdLotto = l.IdLotto) x
        WHERE (@conCarico = 1 OR l.DataCarico IS NULL)
          AND l.DataVideoCodifica IS NULL AND l.DataAnnullamento IS NULL
          AND (@idFiliale IS NULL OR l.IdFilialeAccettazione = @idFiliale)
          AND (@codFamiglia IS NULL OR l.CodFamiglia = @codFamiglia)
          AND (@idCliente IS NULL OR l.IdCliente = @idCliente)
          AND (@idProdotto IS NULL OR l.IdProdotto = @idProdotto)
        ORDER BY l.DataInserimento DESC",
        new
        {
            idFiliale = tutte == true || idFiliale == 0 ? (int?)null : idFiliale,
            codFamiglia = string.IsNullOrWhiteSpace(codFamiglia) ? null : codFamiglia,
            idCliente,
            idProdotto,
            conCarico = conCarico == true ? 1 : 0
        });
    return Results.Ok(lotti);
}).RequireAuthorization();

// Righe del lotto da correggere a video
app.MapGet("/api/videocodifica/lotto/{id:int}", async (int id) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var testata = await cn.QueryFirstOrDefaultAsync(@"
        SELECT l.IdLotto, l.Lotto, l.IdCliente, c.RagioneSociale AS Cliente,
               l.CodFamiglia, p.Prodotto, l.NumeroAtti,
               CONVERT(varchar(16), l.DataVideoCodifica, 120) AS DataVideoCodifica
        FROM SPED_LOTTI l
        LEFT JOIN CLIENTI c ON c.IdCliente = l.IdCliente
        LEFT JOIN PRODOTTI p ON p.IdProdotto = l.IdProdotto
        WHERE l.IdLotto = @id", new { id });
    if (testata is null) return Results.NotFound(new { errore = "Lotto inesistente" });
    var righe = await cn.QueryAsync(@"
        SELECT s.IdSpedizione, s.Barcode,
               s.DestinazioneRagioneSociale AS Destinatario,
               s.DestinazioneIndirizzo AS Indirizzo,
               s.DestinazioneNumeroCivico AS Civico,
               s.DestinazioneLocalita AS Localita,
               s.DestinazioneCap AS Cap,
               s.DestinazioneProvinciaCodice AS Prov
        FROM SPED_ATTIVITA s
        WHERE s.IdLotto = @id
        ORDER BY s.IdSpedizione", new { id });
    return Results.Ok(new { testata, righe });
}).RequireAuthorization();

// Salvataggio di una riga corretta (AI_SPED_VideoCodifica_Save)
app.MapPost("/api/videocodifica/riga", async (VideoCodificaRigaRequest req) =>
{
    if (req.IdSpedizione <= 0) return Results.BadRequest(new { errore = "Spedizione mancante" });
    await using var cn = Operatore.Connessione(ConnString());
    var r = await cn.QueryFirstAsync("dbo.AI_SPED_VideoCodifica_Save", new
    {
        req.IdSpedizione,
        req.Barcode,
        req.Destinatario,
        req.Indirizzo,
        req.Civico,
        req.Localita,
        req.Cap,
        req.Prov
    }, commandType: CommandType.StoredProcedure);
    string result = r.Result;
    return result == "OK" ? Results.Ok(new { ok = true })
                          : Results.BadRequest(new { errore = result });
}).RequireAuthorization();

// Chiusura della videocodifica: la stored legacy genera i barcode mancanti,
// esegue tutte le validazioni e marca il lotto (DataVideoCodifica)
app.MapPost("/api/videocodifica/chiudi", async (VideoCodificaChiudiRequest req) =>
{
    if (req.IdLotto <= 0) return Results.BadRequest(new { errore = "Lotto mancante" });
    await using var cn = Operatore.Connessione(ConnString());
    var r = await cn.QueryFirstAsync("dbo.Lotto_VideoCodifica",
        new { req.IdLotto }, commandType: CommandType.StoredProcedure, commandTimeout: 300);
    string result = r.result;
    return result == "OK" ? Results.Ok(new { ok = true })
                          : Results.BadRequest(new { errore = result });
}).RequireAuthorization();

// === Checkin lotti (accettazione dei lotti in filiale) ===

// Clienti con lotti in attesa di checkin (stored legacy FORM_CHECKIN)
app.MapGet("/api/checkin/clienti", async (bool? tutte, int? idCliente, ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);
    await using var cn = Operatore.Connessione(ConnString());
    var clienti = (await cn.QueryAsync("dbo.FORM_CHECKIN", new
    {
        Tipo = "clienti",
        IdFiliale = tutte == true || idFiliale == 0 ? (int?)null : idFiliale
    }, commandType: CommandType.StoredProcedure, commandTimeout: 120))
        .Cast<IDictionary<string, object>>().ToList();
    // filtro cliente delle varianti legacy (Checkin MGG / Checkindb)
    if (idCliente is int filtro)
        clienti = clienti.Where(c => c["IdCliente"] is int ic && ic == filtro).ToList();
    // decodifica filiali e utenti (la stored restituisce solo gli id)
    var filiali = (await cn.QueryAsync("SELECT IDFILIALE, FILIALE FROM FILIALI"))
        .ToDictionary(f => (int)f.IDFILIALE, f => (string)f.FILIALE);
    var utenti = (await cn.QueryAsync("SELECT IdUtente, Utente FROM UTENTI"))
        .ToDictionary(u => (int)u.IdUtente, u => (string)u.Utente);
    return Results.Ok(clienti.Select(c => new
    {
        idCliente = c["IdCliente"],
        cliente = c["Cliente"],
        numDoc = c["NumDoc"],
        idFiliale = c["IdFiliale"],
        filiale = c["IdFiliale"] is int fi && filiali.TryGetValue(fi, out var fn) ? fn : null,
        codFamiglia = c["CodFamiglia"],
        famiglia = c["FamigliaDiProdotto"],
        utente = c["IdUtente"] is int ui && utenti.TryGetValue(ui, out var un) ? un : null
    }));
}).RequireAuthorization();

// Lotti del cliente ancora da accettare (DataAccettazione nulla)
app.MapGet("/api/checkin/lotti", async (int idCliente, bool? tutte, ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);
    await using var cn = Operatore.Connessione(ConnString());
    var lotti = await cn.QueryAsync(@"
        SELECT l.IdLotto, l.Lotto, l.CodFamiglia, p.Prodotto, l.NumeroAtti,
               ISNULL(x.Righe, 0) AS Righe,
               CONVERT(varchar(10), l.DataCarico, 120) AS DataCarico,
               CONVERT(varchar(16), l.DataVideoCodifica, 120) AS DataVideoCodifica,
               CONVERT(varchar(16), l.DataInserimento, 120) AS DataInserimento,
               l.IdFilialeAccettazione, f.FILIALE AS Filiale, u.Utente
        FROM SPED_LOTTI l
        LEFT JOIN PRODOTTI p ON p.IdProdotto = l.IdProdotto
        LEFT JOIN FILIALI f ON f.IDFILIALE = l.IdFilialeAccettazione
        LEFT JOIN UTENTI u ON u.IdUtente = l.IdUtente
        OUTER APPLY (SELECT COUNT(*) AS Righe FROM SPED_ATTIVITA sa WHERE sa.IdLotto = l.IdLotto) x
        WHERE l.IdCliente = @idCliente
          AND l.DataAccettazione IS NULL AND l.DataAnnullamento IS NULL
          AND (@idFiliale IS NULL OR l.IdFilialeAccettazione = @idFiliale)
        ORDER BY l.IdLotto DESC",
        new { idCliente, idFiliale = tutte == true || idFiliale == 0 ? (int?)null : idFiliale });
    return Results.Ok(lotti);
}).RequireAuthorization();

// Checkin dei lotti selezionati (stored legacy Lotto_Checkin): imposta la data di
// accettazione e, a richiesta, crea la distinta con l'esito di accettazione
app.MapPost("/api/checkin", async (CheckinRequest req, ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var idUtente);
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);
    if (req.IdLotti is null || req.IdLotti.Count == 0)
        return Results.BadRequest(new { errore = "Selezionare almeno un lotto" });
    if (req.IdLotti.Count > 100)
        return Results.BadRequest(new { errore = "Troppi lotti in un solo checkin (max 100)" });

    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var par = new DynamicParameters(new
        {
            IdLotti = string.Join(",", req.IdLotti),
            CreaDistinta = req.CreaDistinta ? 1 : 0,
            DataCheckin = req.DataCheckin?.Date,
            IdUtente = idUtente,
            IdFiliale = idFiliale
        });
        par.Add("Result", dbType: DbType.String, size: 100, direction: ParameterDirection.Output);
        // InserimentoEsiti (chiamata dentro Lotto_Checkin) emette i propri result
        // set prima dell'esito finale: si tiene l'ULTIMA griglia con la colonna result
        using var multi = await cn.QueryMultipleAsync("dbo.Lotto_Checkin", par,
            commandType: CommandType.StoredProcedure, commandTimeout: 300);
        IDictionary<string, object>? r = null;
        while (!multi.IsConsumed)
        {
            var prima = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().FirstOrDefault();
            if (prima is not null && prima.ContainsKey("result")) r = prima;
        }
        var result = r?["result"] as string ?? "Nessun esito dalla stored";
        if (result != "OK") return Results.BadRequest(new { errore = result });
        return Results.Ok(new
        {
            ok = true,
            idDistinta = r!.TryGetValue("IdDistinta", out var d) ? d : null,
            webReport = r.TryGetValue("Webreport", out var w) ? w : null
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: 400);
    }
}).RequireAuthorization();

// Stampa generica di una distinta: il template e' il WebReport memorizzato sulla
// distinta stessa (mai scelto dal client), servito col solito proxy del report server
app.MapGet("/api/distinte/{id:int}/stampa", async (int id) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var info = await cn.QueryFirstOrDefaultAsync(
        "SELECT WebReport FROM SPED_DISTINTE WHERE IdDistinta = @id", new { id });
    string? template = info?.WebReport;
    if (string.IsNullOrWhiteSpace(template))
        return Results.NotFound(new { errore = "Distinta senza report associato" });
    if (!System.Text.RegularExpressions.Regex.IsMatch(template, @"^[\w\-. ]+\.fr3$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
        return Results.Json(new { errore = "Nome report non valido" }, statusCode: 500);
    var basis = await cn.ExecuteScalarAsync<string>(
        "SELECT Valore FROM PARAMETRI WHERE Nome = 'ReportServer'");
    if (string.IsNullOrWhiteSpace(basis))
        return Results.Json(new { errore = "Parametro ReportServer non configurato" }, statusCode: 500);
    try
    {
        Directory.CreateDirectory(reportTempDir);
        foreach (var vecchio in Directory.GetFiles(reportTempDir))
            try { File.Delete(vecchio); } catch { /* in uso da un'altra richiesta */ }

        var scaricato = await reportHttp.GetByteArrayAsync($"{basis}{Uri.EscapeDataString(template)}&IdDistinta={id}&format=pdf");
        if (scaricato.Length < 5 || scaricato[0] != (byte)'%' || scaricato[1] != (byte)'P')
            return Results.Json(new { errore = "Il report server non ha restituito un PDF" }, statusCode: 502);

        var percorso = Path.Combine(reportTempDir, $"DIST_{id}_{Guid.NewGuid():N}.pdf");
        await File.WriteAllBytesAsync(percorso, scaricato);
        var pdf = await File.ReadAllBytesAsync(percorso);
        try { File.Delete(percorso); } catch { }
        return Results.File(pdf, "application/pdf", $"Distinta_{id}.pdf");
    }
    catch (Exception ex)
    {
        return Results.Json(new { errore = "Report server non raggiungibile: " + ex.Message }, statusCode: 502);
    }
}).RequireAuthorization();

// === Presenze TeamSystem (file mensile per lo studio paghe) ===
// Trasforma UTENTI_ATTIVITA nel tracciato INTM/DIPE/GG01/GG02/PRES di TeamSystem
// (stessa logica dello script hr-presenze/genera_presenze_teamsystem.py).

// fasce orarie della legenda dello studio: ore giornaliere -> (ORD, RO)
var presenzeFasce = new (double Tot, double Ord, double Rol)[]
{
    (8.0, 7.73, 0.27), (7.0, 6.8, 0.2), (6.66, 6.45, 0.21), (6.0, 5.8, 0.2),
    (5.0, 4.84, 0.16), (4.5, 4.35, 0.15), (4.0, 3.87, 0.13)
};
var presenzeAssenze = new Dictionary<string, string> { ["FER"] = "FE", ["INF"] = "INF", ["MAL"] = "ML", ["MAT"] = "MT" };
var presenzeMesi = new[] { "gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic" };
var presenzeGiorni = new[] { "Domenica", "Lunedì", "Martedì", "Mercoledì", "Giovedì", "Venerdì", "Sabato" };

(double Tot, double Ord, double Rol) PresenzeFascia(double? partime)
{
    var ore = partime is null or 0 ? 8.0 : 40.0 * partime.Value / 100.0 / 6.0;
    return presenzeFasce.MinBy(f => Math.Abs(f.Tot - ore));
}
string PresenzeNum(double v) => v.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture).Replace('.', ',');

// dati del mese per una filiale: dipendenti validi (CF a 16), giorni, esclusi
async Task<(dynamic? filiale, List<PresenzeDip> dipendenti, IEnumerable<dynamic> esclusi)>
    PresenzeCarica(SqlConnection cn, int idFiliale, DateTime dal, DateTime al)
{
    var filiale = await cn.QueryFirstOrDefaultAsync(
        "SELECT FILIALE, IdFiliale_HRSpeedy FROM FILIALI WHERE IDFILIALE = @idFiliale", new { idFiliale });
    var righe = await cn.QueryAsync(@"
        SELECT u.IdUtente, RTRIM(ISNULL(u.Matricola, '')) AS Matricola,
               UPPER(RTRIM(ISNULL(u.Nome, ''))) AS Nome, u.Partime,
               ua.data, RTRIM(ISNULL(ua.codPresenza, '')) AS Cod
        FROM UTENTI_ATTIVITA ua
        INNER JOIN UTENTI u ON u.IdUtente = ua.idUtente
        WHERE u.idFiliale = @idFiliale AND ua.data >= @dal AND ua.data < @al
          AND LEN(u.CodiceFiscale) = 16
        ORDER BY u.IdUtente, ua.data", new { idFiliale, dal, al });
    var dip = new Dictionary<int, PresenzeDip>();
    foreach (var r in righe)
    {
        if (!dip.TryGetValue((int)r.IdUtente, out PresenzeDip? d))
            dip[(int)r.IdUtente] = d = new PresenzeDip((string)r.Matricola, (string)r.Nome, (double?)r.Partime, new());
        d.Giorni[((DateTime)r.data).Day] = (string)r.Cod;
    }
    var esclusi = await cn.QueryAsync(@"
        SELECT DISTINCT RTRIM(ISNULL(u.Matricola, '')) AS matricola, u.Utente AS utente,
               UPPER(RTRIM(ISNULL(u.Nome, ''))) AS nome
        FROM UTENTI_ATTIVITA ua
        INNER JOIN UTENTI u ON u.IdUtente = ua.idUtente
        WHERE u.idFiliale = @idFiliale AND ua.data >= @dal AND ua.data < @al
          AND LEN(ISNULL(u.CodiceFiscale, '')) <> 16", new { idFiliale, dal, al });
    var ordinati = dip.Values
        .OrderBy(d => int.TryParse(d.Matricola, out var m) ? 0 : 1)
        .ThenBy(d => int.TryParse(d.Matricola, out var m) ? m : 0)
        .ToList();
    return (filiale, ordinati, esclusi);
}

// filiali con il codice TeamSystem impostato (IdFiliale_HRSpeedy)
app.MapGet("/api/presenze/init", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var filiali = await cn.QueryAsync(@"
        SELECT IDFILIALE AS idFiliale, FILIALE AS filiale, IdFiliale_HRSpeedy AS codiceTs
        FROM FILIALI
        WHERE IdFiliale_HRSpeedy IS NOT NULL AND DataChiusura IS NULL
        ORDER BY FILIALE");
    return Results.Ok(filiali);
}).RequireAuthorization();

// riepilogo del mese: conteggi per dipendente, giorni mancanti, anomalie
app.MapGet("/api/presenze/riepilogo", async (int idFiliale, string mese) =>
{
    if (!DateTime.TryParseExact(mese + "-01", "yyyy-MM-dd", null, System.Globalization.DateTimeStyles.None, out var dal))
        return Results.BadRequest(new { errore = "Mese non valido (atteso AAAA-MM)" });
    var al = dal.AddMonths(1);
    var ngiorni = DateTime.DaysInMonth(dal.Year, dal.Month);

    await using var cn = Operatore.Connessione(ConnString());
    var (filiale, dipendenti, esclusi) = await PresenzeCarica(cn, idFiliale, dal, al);
    if (filiale is null) return Results.NotFound(new { errore = "Filiale inesistente" });

    var anomalieGlobali = new List<string>();
    if (filiale.IdFiliale_HRSpeedy is null)
        anomalieGlobali.Add("La filiale non ha il codice TeamSystem (FILIALI.IdFiliale_HRSpeedy): impossibile generare il file");
    foreach (var e in esclusi)
        anomalieGlobali.Add($"{e.utente} ({e.nome}): codice fiscale non valido, escluso dal file");

    var listaDip = new List<object>();
    int totPresenze = 0, totAssenze = 0, totMancanti = 0;
    foreach (var d in dipendenti)
    {
        var (tot, _, _) = PresenzeFascia(d.Partime);
        var conteggi = d.Giorni.Values.GroupBy(c => c).ToDictionary(g => g.Key, g => g.Count());
        var mancanti = new List<int>();
        for (var g = 1; g <= ngiorni; g++)
            if (!d.Giorni.ContainsKey(g) && new DateTime(dal.Year, dal.Month, g).DayOfWeek != DayOfWeek.Sunday)
                mancanti.Add(g);
        var anomalie = new List<string>();
        if (d.Matricola == "") anomalie.Add("matricola mancante");
        if (d.Partime is null) anomalie.Add("Partime non impostato: trattato come full time");
        foreach (var cod in conteggi.Keys)
            if (cod is not ("PRE" or "INT" or "NLV") && !presenzeAssenze.ContainsKey(cod)
                && !(cod.StartsWith("PE") && cod.Length == 3 && char.IsDigit(cod[2])) && cod is not ("C05" or "C10"))
                anomalie.Add($"codice '{cod}' non gestito ({conteggi[cod]} gg)");
        if (conteggi.ContainsKey("C05") || conteggi.ContainsKey("C10"))
            anomalie.Add("giorni di cassa integrazione: verificare la sigla con lo studio");

        int pres = conteggi.GetValueOrDefault("PRE") + conteggi.GetValueOrDefault("INT");
        int assenze = conteggi.Where(c => c.Key is not ("PRE" or "INT" or "NLV")).Sum(c => c.Value);
        totPresenze += pres; totAssenze += assenze; totMancanti += mancanti.Count;
        listaDip.Add(new
        {
            matricola = d.Matricola,
            nome = d.Nome,
            oreGiornaliere = tot,
            presenze = pres,
            ferie = conteggi.GetValueOrDefault("FER"),
            infortunio = conteggi.GetValueOrDefault("INF"),
            malattia = conteggi.GetValueOrDefault("MAL"),
            altreAssenze = assenze - conteggi.GetValueOrDefault("FER") - conteggi.GetValueOrDefault("INF") - conteggi.GetValueOrDefault("MAL"),
            riposi = conteggi.GetValueOrDefault("NLV"),
            mancanti,
            anomalie
        });
    }
    return Results.Ok(new
    {
        filiale = (string)filiale.FILIALE,
        codiceTs = (int?)filiale.IdFiliale_HRSpeedy,
        mese = $"{presenzeMesi[dal.Month - 1]}-{dal.Year % 100:00}",
        giorniMese = ngiorni,
        dipendenti = listaDip,
        totali = new { dipendenti = listaDip.Count, presenze = totPresenze, assenze = totAssenze, mancanti = totMancanti },
        anomalie = anomalieGlobali
    });
}).RequireAuthorization();

// file TeamSystem: ore = override per matricola "336=10,952=6,5" (straordinari stabili)
app.MapGet("/api/presenze/file", async (int idFiliale, string mese, bool? completa, string? ore, int? aziendaTs) =>
{
    if (!DateTime.TryParseExact(mese + "-01", "yyyy-MM-dd", null, System.Globalization.DateTimeStyles.None, out var dal))
        return Results.BadRequest(new { errore = "Mese non valido (atteso AAAA-MM)" });
    var al = dal.AddMonths(1);
    var ngiorni = DateTime.DaysInMonth(dal.Year, dal.Month);
    var azienda = aziendaTs ?? 574;
    var label = $"{presenzeMesi[dal.Month - 1]}-{dal.Year % 100:00}";

    var overrideOre = new Dictionary<string, double>();
    foreach (var o in (ore ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries))
    {
        var p = o.Split('=');
        if (p.Length == 2 && double.TryParse(p[1].Replace(',', '.'),
            System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var v))
            overrideOre[p[0].Trim()] = v;
    }

    await using var cn = Operatore.Connessione(ConnString());
    var (filiale, dipendenti, _) = await PresenzeCarica(cn, idFiliale, dal, al);
    if (filiale is null) return Results.NotFound(new { errore = "Filiale inesistente" });
    if (filiale.IdFiliale_HRSpeedy is null)
        return Results.BadRequest(new { errore = "La filiale non ha il codice TeamSystem (FILIALI.IdFiliale_HRSpeedy)" });
    if (dipendenti.Count == 0)
        return Results.BadRequest(new { errore = "Nessun dipendente con presenze nel mese" });
    var filialeTs = ((int)filiale.IdFiliale_HRSpeedy).ToString();

    const int NCAMPI = 6 + 31 * 2;
    string Riga(Dictionary<int, string> campi)
    {
        var v = new string[NCAMPI];
        Array.Fill(v, "");
        foreach (var (i, s) in campi) v[i] = s;
        return string.Join(';', v);
    }

    var testataGiorni = new Dictionary<int, string> { [0] = "GG01" };
    var testataSigle = new Dictionary<int, string> { [0] = "GG02" };
    for (var g = 1; g <= ngiorni; g++)
    {
        testataGiorni[6 + (g - 1) * 2] = $"{g} - {presenzeGiorni[(int)new DateTime(dal.Year, dal.Month, g).DayOfWeek]}";
        testataSigle[6 + (g - 1) * 2] = "Sigla";
        testataSigle[6 + (g - 1) * 2 + 1] = "Ore";
    }

    var righeFile = new List<string>
    {
        Riga(new() { [0] = "INTM", [1] = "Mese", [2] = "Azienda", [3] = "Filiale", [4] = "Matricola",
                     [6] = "Codice Azienda:", [8] = azienda.ToString(), [10] = "Mese Presenze:", [12] = label }),
        Riga(new())
    };

    for (var nd = 0; nd < dipendenti.Count; nd++)
    {
        var d = dipendenti[nd];
        var (tot, ordH, rol) = PresenzeFascia(d.Partime);
        if (overrideOre.TryGetValue(d.Matricola, out var forzate))
        {
            tot = forzate;
            ordH = forzate - rol;   // il ROL resta la quota della fascia contrattuale
        }
        var coppie = new Dictionary<int, List<(string Sigla, string Ore)>>();
        for (var g = 1; g <= ngiorni; g++)
        {
            var domenica = new DateTime(dal.Year, dal.Month, g).DayOfWeek == DayOfWeek.Sunday;
            if (!d.Giorni.TryGetValue(g, out var cod))
            {
                if (!domenica && completa == true)
                    coppie[g] = new() { ("ORD", PresenzeNum(ordH)), ("RO", PresenzeNum(rol)) };
                continue;
            }
            if (cod is "PRE" or "INT")
                coppie[g] = new() { ("ORD", PresenzeNum(ordH)), ("RO", PresenzeNum(rol)) };
            else if (presenzeAssenze.TryGetValue(cod, out var sigla))
                coppie[g] = new() { ("ORD", ""), (sigla, PresenzeNum(tot)) };
            else if (cod.StartsWith("PE") && cod.Length == 3 && char.IsDigit(cod[2]))
            {
                var n = cod[2] - '0';
                coppie[g] = new() { ("ORD", PresenzeNum(ordH - n)), ("RO", PresenzeNum(rol + n)) };
            }
            else if (cod is "C05" or "C10")
                coppie[g] = new() { ("ORD", ""), ("CIG", PresenzeNum(tot)) };
            // NLV e codici non gestiti: giorno vuoto
        }

        righeFile.Add(Riga(new() { [0] = "DIPE", [6] = "Matricola:", [8] = d.Matricola,
                                   [10] = "Nominativo:", [12] = d.Nome }));
        righeFile.Add(Riga(testataGiorni));
        righeFile.Add(Riga(testataSigle));
        for (var slot = 0; slot < 7; slot++)
        {
            var campi = new Dictionary<int, string>
            { [0] = "PRES", [1] = label, [2] = azienda.ToString(), [3] = filialeTs, [4] = d.Matricola };
            foreach (var (g, elenco) in coppie)
                if (slot < elenco.Count)
                {
                    campi[6 + (g - 1) * 2] = elenco[slot].Sigla;
                    campi[6 + (g - 1) * 2 + 1] = elenco[slot].Ore;
                }
            righeFile.Add(Riga(campi));
        }
        if (nd < dipendenti.Count - 1) righeFile.Add(Riga(new()));
    }

    // ANSI come il modello dello studio (per i caratteri usati Latin1 == cp1252)
    var bytes = System.Text.Encoding.Latin1.GetBytes(string.Join("\r\n", righeFile) + "\r\n");
    return Results.File(bytes, "text/csv", $"Presenze_TS_Fil{filialeTs}_{label}.csv");
}).RequireAuthorization();

// === Scontrini di Fine Gita ===
// Replica della videata legacy "Scontrini Fine Gita": riepilogo delle gite dei
// driver (stessa query dell'interrogazione 1026) con scontrino a video dalle
// stored legacy ElencoFineGita/ElencoFineGitaDettaglio. I cedolini PDF passano
// dal proxy /api/report gia' esistente (DELIVERY_FINEGITA[Dettaglio].fr3).

// Elenco gite: una riga per driver/giorno (idFineGita NULL = gita ancora aperta).
app.MapGet("/api/finegita/elenco", async (string? dal, string? al, bool? tutte, ClaimsPrincipal user) =>
{
    var idFiliale = int.TryParse(user.FindFirstValue("idFiliale"), out var f) ? f : 0;
    var dDal = DateTime.TryParse(dal, out var d1) ? d1.Date : DateTime.Today.AddDays(-7);
    var dAl = (DateTime.TryParse(al, out var d2) ? d2.Date : DateTime.Today).AddDays(1);

    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT pa.idPalmFineGita AS idFineGita, pa.DriverAssegnato AS driver, u.Nome AS nome,
               u.IdFiliale AS idFiliale, f.FILIALE AS filiale,
               CONVERT(varchar(10), CONVERT(date, pa.DataEffettiva), 120) AS data,
               CONVERT(varchar(5), CONVERT(time, ua.Login)) AS login,
               CONVERT(varchar(5), CONVERT(time, ua.Logout)) AS logout,
               SUM(CASE WHEN pa.idPalmServizio = 0 THEN 1 ELSE 0 END) AS cert,
               SUM(CASE WHEN pa.idPalmServizio = 1 THEN 1 ELSE 0 END) AS parc,
               SUM(CASE WHEN pa.idPalmServizio = 2 THEN 1 ELSE 0 END) AS racc,
               SUM(CASE WHEN pa.idPalmServizio = 3 THEN 1 ELSE 0 END) AS raccAr,
               SUM(CASE WHEN pa.idPalmServizio = 4 THEN 1 ELSE 0 END) AS ag,
               SUM(CASE WHEN pa.idPalmServizio = 5 THEN 1 ELSE 0 END) AS notifiche,
               COUNT(*) AS totale
        FROM PALM_ATTIVITA pa (nolock)
        INNER JOIN UTENTI u (nolock) ON u.codAppLogin = pa.DriverAssegnato
        LEFT JOIN FILIALI f (nolock) ON f.IDFILIALE = u.IdFiliale
        LEFT JOIN UTENTI_ATTIVITA ua (nolock)
               ON ua.data = CONVERT(date, pa.DataEffettiva) AND ua.idUtente = u.IdUtente
        WHERE pa.STATO = '02'
          AND pa.DataEffettiva >= @dal AND pa.DataEffettiva < @al
          AND (@tutte = 1 OR u.IdFiliale = @idFiliale)
        GROUP BY pa.idPalmFineGita, pa.DriverAssegnato, u.Nome, u.IdFiliale, f.FILIALE,
                 CONVERT(varchar(10), CONVERT(date, pa.DataEffettiva), 120), ua.Login, ua.Logout
        ORDER BY 6 DESC, u.Nome",
        new { dal = dDal, al = dAl, tutte = tutte == true ? 1 : 0, idFiliale },
        commandTimeout: 90);
    return Results.Ok(righe);
}).RequireAuthorization();

// Scontrino a video: righe raggruppate per distinta di reso/servizio/evento.
// La stored legacy per la filiale 1 (hub) aggiunge il prodotto nell'evento.
app.MapGet("/api/finegita/{id:int}/scontrino", async (int id) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync("ElencoFineGita",
        new { IdPalmFineGita = id },
        commandType: CommandType.StoredProcedure, commandTimeout: 90);
    return Results.Ok(righe);
}).RequireAuthorization();

// Dettaglio atto per atto (barcode + destinatario) della gita.
app.MapGet("/api/finegita/{id:int}/dettaglio", async (int id) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync("ElencoFineGitaDettaglio",
        new { IdPalmFineGita = id },
        commandType: CommandType.StoredProcedure, commandTimeout: 90);
    return Results.Ok(righe);
}).RequireAuthorization();

// === Lavorato Driver (videata legacy Lavoratodriver) ===
// Riepilogo mensile del lavorato per driver: la stored legacy getLavoratoByIdUtente
// accetta piu' driver (CSV di IdUtente) e restituisce i conteggi per giorno.
app.MapGet("/api/lavorato/driver", async (ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);
    await using var cn = Operatore.Connessione(ConnString());
    var driver = await cn.QueryAsync(@"
        SELECT u.IdUtente AS idUtente, u.Nome AS nome, u.codAppLogin AS codAppLogin
        FROM UTENTI u
        WHERE u.IdFiliale = @idFiliale AND ISNULL(u.codAppLogin, '') <> ''
          AND (u.DataFine IS NULL OR u.DataFine >= CONVERT(date, GETDATE()))
        ORDER BY u.Nome", new { idFiliale });
    return Results.Ok(driver);
}).RequireAuthorization();

app.MapGet("/api/lavorato", async (string idUtenti, int mese, int anno) =>
{
    // un driver alla volta: la stored dichiara un CSV ma il ramo AG confronta il
    // parametro con un int e col CSV esplode (il legacy la chiamava per singolo id)
    if (!int.TryParse(idUtenti.Split(',')[0], out var idDriver) || mese is < 1 or > 12 || anno < 2000)
        return Results.BadRequest(new { errore = "Driver, mese e anno sono obbligatori" });

    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync("dbo.getLavoratoByIdUtente",
        new { idMesso = idDriver.ToString(), mese, anno },
        commandType: CommandType.StoredProcedure, commandTimeout: 180);
    return Results.Ok(righe);
}).RequireAuthorization();

// === Il mio profilo (videata legacy Profilo) ===
app.MapGet("/api/profilo", async (ClaimsPrincipal user) =>
{
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    await using var cn = Operatore.Connessione(ConnString());
    var p = await cn.QueryFirstOrDefaultAsync(@"
        SELECT u.IdUtente AS idUtente, u.Utente AS utente, u.Nome AS nome, u.Email AS email,
               u.Telefono AS telefono, u.CodiceFiscale AS codiceFiscale, u.Matricola AS matricola,
               u.codAppLogin AS codAppLogin, r.Ruolo AS ruolo, f.FILIALE AS filiale,
               c.RagioneSociale AS cliente,
               CONVERT(varchar(16), u.DataUltimoAccesso, 120) AS ultimoAccesso,
               CONVERT(varchar(10), u.DataInizio, 120) AS attivoDal
        FROM UTENTI u
        LEFT JOIN RUOLI r ON r.IdRuolo = u.IdRuolo
        LEFT JOIN FILIALI f ON f.IDFILIALE = u.IdFiliale
        LEFT JOIN CLIENTI c ON c.IdCliente = u.IdCliente
        WHERE u.IdUtente = @idUtente", new { idUtente });
    return p is null ? Results.NotFound(new { errore = "Utente non trovato" }) : Results.Ok(p);
}).RequireAuthorization();

app.MapPost("/api/profilo/password", async (CambiaPasswordRequest req, ClaimsPrincipal user) =>
{
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    await using var cn = Operatore.Connessione(ConnString());
    var esito = await cn.ExecuteScalarAsync<int>("dbo.AI_UTENTI_CambiaPassword",
        new { IdUtente = idUtente, VecchiaPwd = req.VecchiaPwd ?? "", NuovaPwd = req.NuovaPwd ?? "" },
        commandType: CommandType.StoredProcedure);
    return esito switch
    {
        0 => Results.Ok(new { ok = true }),
        1 => Results.BadRequest(new { errore = "La vecchia password non è corretta" }),
        3 => Results.BadRequest(new { errore = "La nuova password deve avere almeno 6 caratteri" }),
        _ => Results.BadRequest(new { errore = "Utente non abilitato al cambio password" })
    };
}).RequireAuthorization();

// === Creazione Scatole e Ceste blu (videate legacy Scatola / Ceste) ===
app.MapGet("/api/scatole/tipi", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    // il tipo 0 e' la spedizione interna, che ha la sua pagina dedicata
    var tipi = await cn.QueryAsync(@"
        SELECT IdTipoScatola AS idTipoScatola, Descrizione AS descrizione, Prefisso AS prefisso
        FROM SCATOLE_TIPI WHERE IdTipoScatola <> 0 ORDER BY IdTipoScatola");
    return Results.Ok(tipi);
}).RequireAuthorization();

app.MapPost("/api/scatole", async (CreaScatolaRequest req, ClaimsPrincipal user) =>
{
    if (req.IdTipoScatola <= 0)
        return Results.BadRequest(new { errore = "Tipo scatola non valido" });
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);

    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var r = await cn.QueryFirstOrDefaultAsync("dbo.SCATOLA_Crea", new
        {
            IdUtente = idUtente,
            IdFiliale = idFiliale,
            req.IdFilialeDestinazione,
            NotaConsegna = req.NotaConsegna ?? "",
            req.RiferimentoEsterno1,
            req.IdTipoScatola
        }, commandType: CommandType.StoredProcedure) as IDictionary<string, object>;

        if (r is null)
            return Results.Json(new { errore = "SCATOLA_Crea non ha restituito la scatola" },
                statusCode: StatusCodes.Status500InternalServerError);
        return Results.Ok(new
        {
            idSpedizione = r["IdSpedizione"],
            barcode = r["Barcode"],
            distinta = r["distinta"],
            webReport = r["webreport"]
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

app.MapGet("/api/scatole/aperte", async (int idTipoScatola, ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync("dbo.ElencoScatoleAperte",
        new { IdTipoScatola = idTipoScatola, IdFiliale = idFiliale },
        commandType: CommandType.StoredProcedure, commandTimeout: 90);
    return Results.Ok(righe);
}).RequireAuthorization();

// Monitor delle ceste blu: ultimo evento per cesta (fndCesteBlu; gli hub 1 e 20
// vedono tutte le ceste, le altre filiali solo le proprie)
app.MapGet("/api/ceste", async (ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync("dbo.fndCesteBlu", new { idFiliale },
        commandType: CommandType.StoredProcedure, commandTimeout: 90);
    return Results.Ok(righe);
}).RequireAuthorization();

// === Dipendenti di Filiale (videata legacy Dipendenti) ===
// Vista HR in sola lettura dei dipendenti della filiale corrente.
app.MapGet("/api/dipendenti-filiale", async (bool? ancheCessati, ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT u.IdUtente AS idUtente, u.Matricola AS matricola, u.Nome AS nome,
               u.CodiceFiscale AS codiceFiscale, u.Mansione AS mansione, u.Livello AS livello,
               u.TipoContratto AS tipoContratto, u.CCNL AS ccnl,
               CONVERT(varchar(10), u.DataInizio, 120) AS assunto,
               CONVERT(varchar(10), u.DataFineContratto, 120) AS fineContratto,
               CASE WHEN u.DataFine < CONVERT(date, GETDATE())
                    THEN CONVERT(varchar(10), u.DataFine, 120) END AS cessato,
               u.Partime AS partime, u.OreSettimanali AS oreSettimanali,
               u.Telefono AS telefono, u.Email AS email, u.codAppLogin AS codAppLogin
        FROM UTENTI u
        WHERE u.IdFiliale = @idFiliale
          AND LEN(ISNULL(u.CodiceFiscale, '')) = 16
          AND (@anche = 1 OR u.DataFine IS NULL OR u.DataFine >= CONVERT(date, GETDATE()))
        ORDER BY u.Nome",
        new { idFiliale, anche = ancheCessati == true ? 1 : 0 });
    return Results.Ok(righe);
}).RequireAuthorization();

// === Punteggi driver (videata legacy Punteggi) ===
// Dalla vista V_UtentiAttivita2024: una riga per driver/giorno con i conteggi
// per prodotto e il punteggio; il riepilogo per driver lo fa il frontend.
app.MapGet("/api/punteggi", async (string? dal, string? al, bool? tutte, ClaimsPrincipal user) =>
{
    var idFiliale = int.TryParse(user.FindFirstValue("idFiliale"), out var f) ? f : 0;
    var dDal = DateTime.TryParse(dal, out var d1) ? d1.Date : DateTime.Today.AddDays(-15);
    var dAl = (DateTime.TryParse(al, out var d2) ? d2.Date : DateTime.Today).AddDays(1);

    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT CONVERT(varchar(10), Data, 120) AS data, Driver AS driver, Filiale AS filiale,
               IDFILIALE AS idFiliale, Punteggio AS punteggio, KmPercorsi AS km,
               Parcel_Poste AS parcelPoste, Parcel_Speedy AS parcelSpeedy,
               Parcel_Hermes + Parcel_InPost + Parcel_iMile + Parcel_Folletto + Parcel_Gofo + Parcel_Altri AS parcelAltri,
               RAC140_Cons AS rac140, RAC140_AvvSco AS rac140Avv,
               M1_Cons AS m1, M1_Ass + M1_Sco AS m1Altro,
               M2_Cons AS m2, M2_Ass + M2_Sco AS m2Altro, AG AS ag
        FROM V_UtentiAttivita2024
        WHERE Data >= @dal AND Data < @al
          AND (@tutte = 1 OR IDFILIALE = @idFiliale)
        ORDER BY Data DESC, Driver",
        new { dal = dDal, al = dAl, tutte = tutte == true ? 1 : 0, idFiliale },
        commandTimeout: 120);
    return Results.Ok(righe);
}).RequireAuthorization();

// === Nuovo Pickup su richiesta (videata legacy Pickup, gruppo Ministero GG) ===
// La stored legacy PICKUP_Genera crea la spedizione PCK# (barcode 96+9 cifre)
// verso l'ufficio speditore MGG e restituisce il report della ricevuta.
app.MapGet("/api/pickup/lookups", async (ClaimsPrincipal user) =>
{
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile nel profilo" });
    await using var cn = Operatore.Connessione(ConnString());
    var uffici = await cn.QueryAsync(@"
        SELECT IdMggMittenti AS idMittente, UFFICIOSPEDITORE AS ufficio, COMUNE AS comune, PROV AS prov
        FROM MGG_Mittenti ORDER BY UFFICIOSPEDITORE");
    var destinazioni = await cn.QueryAsync("dbo.ElencoFiliali",
        new { idtipo = 10, IdFiliale = idFiliale, IdUtente = idUtente }, commandType: CommandType.StoredProcedure);
    return Results.Ok(new { uffici, destinazioni });
}).RequireAuthorization();

app.MapPost("/api/pickup", async (CreaPickupRequest req, ClaimsPrincipal user) =>
{
    if (req.IdMittente <= 0 || req.IdFilialeDestinazione <= 0)
        return Results.BadRequest(new { errore = "Ufficio e filiale di destinazione sono obbligatori" });
    var idUtente = int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);

    await using var cn = Operatore.Connessione(ConnString());
    try
    {
        var r = await cn.QueryFirstOrDefaultAsync("dbo.PICKUP_Genera", new
        {
            IdUtente = idUtente,
            req.IdFilialeDestinazione,
            req.IdMittente,
            NotaConsegna = req.NotaConsegna ?? "",
            DataPickup = req.DataPickup
        }, commandType: CommandType.StoredProcedure) as IDictionary<string, object>;

        if (r is null)
            return Results.Json(new { errore = "PICKUP_Genera non ha restituito la spedizione" },
                statusCode: StatusCodes.Status500InternalServerError);
        return Results.Ok(new
        {
            idSpedizione = r["IdSpedizione"],
            barcode = r["Barcode"],
            webReport = r["WebReport"],
            parametri = r["Parametri"]
        });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

app.MapGet("/api/pickup/elenco", async (ClaimsPrincipal user) =>
{
    int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale);
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT TOP 200 sa.IdSpedizione AS idSpedizione, sa.Barcode AS barcode,
               CONVERT(varchar(16), sa.DataInserimento, 120) AS inserita,
               sa.DestinazioneRagioneSociale AS ufficio, u.Nome AS utente,
               sa.ContattoDestDescrizione AS nota, sa.Stato AS stato, st.Descrizione AS statoDescrizione
        FROM SPED_ATTIVITA sa (nolock)
        LEFT JOIN UTENTI u (nolock) ON u.IdUtente = sa.IdUtente
        LEFT JOIN SPED_STATI st (nolock) ON st.Stato = sa.Stato
        WHERE sa.nota2 = 'PCK#' AND sa.IdFiliale = @idFiliale
        ORDER BY sa.IdSpedizione DESC", new { idFiliale }, commandTimeout: 90);
    return Results.Ok(righe);
}).RequireAuthorization();

// === Dati storici Speedy (consegne NEXIVE ott 2019 - set 2020) ===
// Le viste NEXIVE_consegne / NEXIVE_Servizio / NEXIVE_TipologieServizio sono
// passanti verso Speedy.dbo.*; la Filiale e' un testo libero dell'export NEXIVE,
// non un IDFILIALE di FILIALI.

// Filiali presenti nello storico con periodo coperto e volumi (testata pagina)
app.MapGet("/api/storici/init", async () =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var filiali = await cn.QueryAsync(@"
        SELECT Filiale AS filiale, COUNT(*) AS eventi,
               CONVERT(varchar(10), MIN(DataRecapito), 120) AS dal,
               CONVERT(varchar(10), MAX(DataRecapito), 120) AS al
        FROM NEXIVE_consegne
        WHERE Filiale IS NOT NULL
        GROUP BY Filiale
        ORDER BY Filiale", commandTimeout: 120);
    return Results.Ok(filiali);
}).RequireAuthorization();

// Eventi geolocalizzati di una filiale in un giorno, con decodifica servizio.
// "consegnato" marca il recapito effettivo; gli altri eventi (assente, indirizzo
// errato, ...) restano utili per ricostruire il percorso del postino.
app.MapGet("/api/storici/consegne", async (string filiale, DateTime data) =>
{
    await using var cn = Operatore.Connessione(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT c.IdNexive AS id, c.Postino AS postino, c.barcode,
               c.TipoEvento AS esito, c.Indirizzo AS indirizzo, c.Cap AS cap,
               c.Localita AS localita, c.Colli AS colli,
               CONVERT(varchar(19), c.DataRecapito, 126) AS orario,
               c.Latitudine AS lat, c.Longitudine AS lng,
               t.tipologiaservizio AS servizio, t.Area AS area,
               CASE WHEN c.TipoEvento IN ('C', 'RECAPITATA', 'Consegnato', 'RICONSEGNATO AL CLIENTE',
                    'RITIRATA DAL DESTINATARIO', 'RITIRO DIGITALE') THEN 1 ELSE 0 END AS consegnato
        FROM NEXIVE_consegne c
        LEFT JOIN NEXIVE_Servizio s ON s.idservizio = c.Servizio
        LEFT JOIN NEXIVE_TipologieServizio t ON t.idtipologia = s.idtipologia
        WHERE c.Filiale = @filiale
          AND c.DataRecapito >= @dal AND c.DataRecapito < @al
          AND c.Latitudine IS NOT NULL AND c.Longitudine IS NOT NULL AND c.Latitudine <> 0
        ORDER BY c.Postino, c.DataRecapito, c.IdNexive",
        new { filiale, dal = data.Date, al = data.Date.AddDays(1) }, commandTimeout: 120);
    return Results.Ok(righe);
}).RequireAuthorization();

// SPA fallback: ogni rotta non-API (router in history mode: /, /login, ...) torna
// index.html, che poi gestisce il routing lato client. Le /api/* sono gia' mappate sopra.
app.MapFallbackToFile("index.html");

app.Run();

record LoginRequest(string Utente, string Password);
record ClienteSaveRequest(
    int? IdCliente, string RagioneSociale, string? CIG, string? Descrizione, string? PartitaIva,
    string? CodSDI, string? PEC, string? Indirizzo, string? CAP, string? Comune, string? Prov,
    string? Nazione, string? Telefono, string? Email, string? DataFine, string? CodiceCliente,
    string? Gestionale, int? InvioEmailEventi, string? EmailPrefattura, int? Demo);
record CondizioneSaveRequest(
    int? IdClienteCondizione, string? CodFamiglia, string? CodTipoVendita,
    string? DataInizioFatturazione, string? DataFineFatturazione, string? Ambito,
    int? Scansione, int? IdProdotto, int? IdTracciato, int? IdFiliale);
record ListinoSaveRequest(
    int? IdListino, string? CodiceListino, string? Descrizione, int? IdProdotto,
    double? PrezzoAttivo, double? ScontoAttivo, double? PrezzoPassivo, double? ScontoPassivo,
    int? AliquotaIVA, string? ValidoDal, string? ValidoAl, string? ProdottoServizio,
    string? TipoArea, int? Porto, int? PesoMin, int? PesoMax, string? Tipo, double? TariffaOS);
record AccettazioneCaricaRequest(
    int IdCliente, int IdProdotto, int IdTracciato, string NomeFile,
    bool SoloVerifica, List<string> Righe);
record AccettazioneBancoRiga(
    string? Barcode, string? BarcodeAr, string? Destinatario, string? Indirizzo,
    string? Civico, string? Localita, string? Cap, string? Prov, string? Nota);
record AccettazioneBancoRequest(
    int IdCliente, string CodFamiglia, int IdProdotto, int? IdMittente,
    List<AccettazioneBancoRiga> Righe);
record VideoCodificaRigaRequest(
    int IdSpedizione, string? Barcode, string? Destinatario, string? Indirizzo,
    string? Civico, string? Localita, string? Cap, string? Prov);
record VideoCodificaChiudiRequest(int IdLotto);
record CheckinRequest(List<int> IdLotti, bool CreaDistinta, DateTime? DataCheckin);
record MenuDuplicaRequest(int IdMenuElemento, bool ConFoglie);
record SpedInternaRequest(int IdFilialeDestinazione, string? NotaConsegna);
record CambiaPasswordRequest(string? VecchiaPwd, string? NuovaPwd);
record CreaScatolaRequest(int IdTipoScatola, int? IdFilialeDestinazione, string? NotaConsegna, string? RiferimentoEsterno1);
record CreaPickupRequest(int IdMittente, int IdFilialeDestinazione, string? NotaConsegna, string? DataPickup);
record GruppoMenuReq(int IdMenu);
record GruppoUtenteReq(int IdUtente);
record PresenzeDip(string Matricola, string Nome, double? Partime, Dictionary<int, string> Giorni);
record SpedNuovaRequest(
    int IdCliente, int IdProdotto, int? IdMittente, string? TariffarioCodice, string? Barcode,
    bool RitiroRichiesto, DateTime? DataRitiro,
    string? RitiroRagioneSociale, string? RitiroIndirizzo, string? RitiroNumeroCivico,
    string? RitiroLocalita, string? RitiroCap, string? RitiroProvincia, double? RitiroLat, double? RitiroLng,
    string? MittenteRagioneSociale, string? MittenteIndirizzo, string? MittenteLocalita,
    string? MittenteCap, string? MittenteProvincia, string? MittenteEmail,
    string DestinazioneRagioneSociale, string DestinazioneIndirizzo, string? DestinazioneNumeroCivico,
    string DestinazioneLocalita, string DestinazioneCap, string DestinazioneProvincia,
    double? DestinazioneLat, double? DestinazioneLng,
    string? ContattoNome, string? ContattoTelefono, string? ContattoEmail,
    decimal? Importo, bool Contrassegno, decimal? ImportoContrassegno,
    decimal? PesoKg, string? Nota);
record EseguiInterrogazioneRequest(int IdQuery, string? SWhere, Dictionary<string, string>? Valori);
record UtenteStatoRequest(int IdUtente, string? Stato);
record LogRiga(int Id, DateTime Data, string? Operatore, string? TipoOperazione, string? Xml);
record LogVideataRequest(string? Videata, string? Parametri);
record CambiaFilialeRequest(int IdFiliale);
record ColMeta(string Col, string Tipo, int MaxLen, bool Nullable, bool Identita, bool Pk);
record GruppoReq(int IdGruppo);
record SalvaWorkflowRequest(int? IdWorkflow, int IdAzione, string? Stato_Inizio, string? Stato_Fine, int? GiorniSLA);
record ComandoSqlRequest(string Sql, string? Data, string? Valore);
record EsitiVerificaRequest(string Barcode, int IdAzione, int IdProcesso, string? Comune, string? Operatore, string? Attributo, string? Data);
record UnilavParseRequest(string? Testo, string? TracciatoJson, string? PdfBase64);
record UnilavApplicaRequest(int IdUtente, Dictionary<string, string?> Valori, bool NuovaScheda = false);
record EsitiConfermaRequest(int IdAzione, int IdProcesso, string ElencoBarcode, string ElencoParametri1, string? Comune, string? Operatore, string? Data);
record ComandoEsitiRequest(int IdAzione, string? Barcodes, string? Nota);
record CreaDdtRequest(int IdFilialeMittente, int IdFilialeDestinazione, string? NotaConsegna,
    int? IdDriver, string? Driver, int? IdMezzo, string? Targa, string? Sigillo1, string? Sigillo2, string? Sigillo3);
record SalvaProcessoAzioneRequest(int? IdProcessoAzione, int IdProcesso, int IdAzione, string? TipoEventoCodice);
record SalvaAttivitaFilialeRequest(long? IdAttivita, string Data, short[]? Contatori);
record ProfiloReq(string CodFamiglia);
record ProcessoReq(int IdProcesso, string? Belfiore);
record FilialeReq(int IdFiliale);
