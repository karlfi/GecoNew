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
    ["menu"] = "MENU_ELEMENTI"
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

app.MapGet("/api/ping", () => Results.Ok(new { ok = true, ora = DateTime.Now }));

// Login: verifica via SP AI_AuthLogin, emette il JWT
app.MapPost("/api/auth/login", async (LoginRequest req) =>
{
    if (string.IsNullOrWhiteSpace(req.Utente) || string.IsNullOrWhiteSpace(req.Password))
        return Results.BadRequest(new { errore = "Utente e password sono obbligatori" });

    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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
        await using var cn = new SqlConnection(ConnString());

        var mese = await cn.QueryAsync(
            @"SELECT mese, Punteggio AS punteggio, Media AS media, Giornate AS giornate
              FROM V_DW_punteggiMese WHERE IDFILIALE = @id ORDER BY mese",
            new { id = idFiliale });

        var giorno = await cn.QueryAsync(
            @"SELECT CONVERT(varchar(10), Data, 23) AS data, Punteggio AS punteggio,
                     Media AS media, Giornate AS giornate
              FROM V_DW_punteggiGiorno WHERE IDFILIALE = @id ORDER BY Data",
            new { id = idFiliale });

        // azienda della filiale corrente
        var idAzienda = await cn.ExecuteScalarAsync<int?>(
            "SELECT IdAzienda FROM FILIALI WHERE IDFILIALE = @id", new { id = idFiliale });
        var aziendaNome = await cn.ExecuteScalarAsync<string>(
            "SELECT Azienda FROM AZIENDE WHERE IdAzienda = @a", new { a = idAzienda });

        // aggregato AZIENDA: somma punteggi e giornate su tutte le filiali attive,
        // media pesata = somma punteggi / somma giornate (NON media delle medie)
        var meseAzienda = await cn.QueryAsync(
            @"SELECT m.mese, SUM(m.Punteggio) AS punteggio, SUM(m.Giornate) AS giornate,
                     CASE WHEN SUM(m.Giornate) > 0 THEN CONVERT(int, SUM(m.Punteggio)/SUM(m.Giornate)) ELSE 0 END AS media
              FROM V_DW_punteggiMese m
              JOIN FILIALI f ON f.IDFILIALE = m.IDFILIALE
              WHERE f.IdAzienda = @a AND f.DataChiusura IS NULL
              GROUP BY m.mese ORDER BY m.mese", new { a = idAzienda });

        var giornoAzienda = await cn.QueryAsync(
            @"SELECT CONVERT(varchar(10), g.Data, 23) AS data, SUM(g.Punteggio) AS punteggio, SUM(g.Giornate) AS giornate,
                     CASE WHEN SUM(g.Giornate) > 0 THEN CONVERT(int, SUM(g.Punteggio)/SUM(g.Giornate)) ELSE 0 END AS media
              FROM V_DW_punteggiGiorno g
              JOIN FILIALI f ON f.IDFILIALE = g.IDFILIALE
              WHERE f.IdAzienda = @a AND f.DataChiusura IS NULL
              GROUP BY g.Data ORDER BY g.Data", new { a = idAzienda });

        // confronto filiali attive dell'azienda sull'ultimo mese disponibile
        var meseLabel = await cn.ExecuteScalarAsync<string>("SELECT MAX(mese) FROM V_DW_punteggiMese");
        var confrontoFiliali = await cn.QueryAsync(
            @"SELECT m.IDFILIALE AS idFiliale, f.FILIALE AS filiale, m.Punteggio AS punteggio,
                     m.Media AS media, m.Giornate AS giornate
              FROM V_DW_punteggiMese m
              JOIN FILIALI f ON f.IDFILIALE = m.IDFILIALE
              WHERE f.IdAzienda = @a AND f.DataChiusura IS NULL AND m.mese = @mese
              ORDER BY m.Punteggio DESC", new { a = idAzienda, mese = meseLabel });

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
        await using var cn = new SqlConnection(ConnString());
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

// Esegue un'interrogazione del catalogo INTERROGAZIONI componendo l'SQL come il legacy:
// SqlSelect + SqlFrom + SqlWhere + sWhere extra (dal menu o dal tasto destro) + SqlGroup + SqlOrder.
// Le parti sono unite con newline (gli sWhere possono contenere commenti --).
// Le variabili globali @[Nome] sono risolte dai claims del token, MAI da input del client.
app.MapPost("/api/interrogazioni/esegui", async (EseguiInterrogazioneRequest req, ClaimsPrincipal user) =>
{
    await using var cn = new SqlConnection(ConnString());

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

// Proxy dei report FastReport: il report server (PARAMETRI.ReportServer) NON e'
// raggiungibile dai client, quindi il PDF lo scarica l'API e lo gira al browser.
// src = valore delle colonne REPORT# delle interrogazioni: "<nome>.fr3|par1=v1|par2=v2"
var httpReport = new HttpClient { Timeout = TimeSpan.FromSeconds(90) };
string? reportServerCache = null;

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
        await using var cn = new SqlConnection(ConnString());
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

    await using var cn = new SqlConnection(ConnString());
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
app.MapGet("/api/config/{key}", async (string key, HttpRequest req) =>
{
    if (!ConfigTabelle.TryGetValue(key, out var tabella))
        return Results.NotFound(new { errore = $"Tabella di configurazione '{key}' non gestita" });

    await using var cn = new SqlConnection(ConnString());
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
    var where = "";
    if (!string.IsNullOrWhiteSpace(q))
    {
        var testo = cols.Where(c => TipoTesto(c.Tipo)).Select(c => $"[{c.Col}] LIKE @q").ToList();
        if (testo.Count > 0) { where = " WHERE " + string.Join(" OR ", testo); par.Add("q", $"%{q}%"); }
    }
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

    await using var cn = new SqlConnection(ConnString());
    var cols = await LoadColonne(cn, tabella);
    var validi = cols.Where(c => !TipoBinario(c.Tipo))
        .ToDictionary(c => c.Col, StringComparer.OrdinalIgnoreCase);

    var par = new DynamicParameters();
    foreach (var prop in body.EnumerateObject())
        if (validi.ContainsKey(prop.Name))
            // TrimEnd: alcune colonne legacy hanno spazi finali nel nome (es. MITTENTI."CODICE_FISCALE ");
            // un nome di parametro SQL non puo' contenere spazi, quindi lo si normalizza. No-op per tutte le altre.
            par.Add(prop.Name.TrimEnd(), JsonToClr(prop.Value));

    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<int?>(
            $"dbo.AI_{tabella}_Save", par, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Albero completo del menu (per l'editor: tutte le righe, senza paginazione)
app.MapGet("/api/menu/all", async () =>
{
    await using var cn = new SqlConnection(ConnString());
    var righe = await cn.QueryAsync(@"
        SELECT IdMenuElemento, ParentID, Text, Descrizione, Videata, Link, Parametri,
               NavigateUrl, Sorting, ToolTip, Disabled, Icon, Popup, CodFamiglia
        FROM MENU_ELEMENTI ORDER BY ISNULL(ParentID,0), ISNULL(Sorting, IdMenuElemento)");
    return Results.Ok(righe.Cast<IDictionary<string, object>>());
}).RequireAuthorization();

// === Workflow / Azioni: macchina a stati per processo ===

// Elenco processi (per la tendina iniziale)
app.MapGet("/api/workflow/processi", async () =>
{
    await using var cn = new SqlConnection(ConnString());
    var p = await cn.QueryAsync(
        "SELECT IdProcesso AS idProcesso, Processo AS processo, GiorniSLA AS giorniSLA, CodFamiglia AS codFamiglia FROM PROCESSI ORDER BY Processo");
    return Results.Ok(p);
}).RequireAuthorization();

// Grafo di un processo: nodi (stati), archi (transizioni), azioni (per il filtro)
app.MapGet("/api/workflow/{idProcesso:int}", async (int idProcesso) =>
{
    await using var cn = new SqlConnection(ConnString());

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
    await using var cn = new SqlConnection(ConnString());
    var s = await cn.QueryAsync(
        "SELECT STATO AS stato, Descrizione AS descrizione FROM SPED_STATI ORDER BY STATO");
    return Results.Ok(s);
}).RequireAuthorization();

// Dettaglio completo di un'azione (tutti i parametri Chiedi_* ecc.)
app.MapGet("/api/workflow/azione/{idAzione:int}", async (int idAzione) =>
{
    await using var cn = new SqlConnection(ConnString());
    var a = await cn.QueryFirstOrDefaultAsync(
        "SELECT * FROM SPED_AZIONI WHERE IdAzione = @id", new { id = idAzione });
    return a is null ? Results.NotFound() : Results.Ok(a);
}).RequireAuthorization();

// Salvataggio transizione (arco) via SP
app.MapPost("/api/workflow/transizione", async (JsonElement body) =>
{
    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
    var validi = (await LoadColonne(cn, "SPED_AZIONI")).Select(c => c.Col)
        .Concat(new[] { "IdProcesso" })
        .ToHashSet(StringComparer.OrdinalIgnoreCase);

    var par = new DynamicParameters();
    foreach (var prop in body.EnumerateObject())
        if (validi.Contains(prop.Name)) par.Add(prop.Name, JsonToClr(prop.Value));

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
    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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

    await using var cn = new SqlConnection(ConnString());
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
                link = m.TryGetValue("Link", out var l) ? l as string : null,
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

    await using var cn = new SqlConnection(ConnString());
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

    await using var cn = new SqlConnection(ConnString());
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

    await using var cn = new SqlConnection(ConnString());

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

    // la pagina blocca le modifiche oltre 10 giorni (stessa regola della SP)
    var modificabile = (DateTime.Today - giorno.Date).TotalDays <= 10;

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

    await using var cn = new SqlConnection(ConnString());
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

    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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
        await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
    var p = await cn.QueryAsync("dbo.ElencoProcessi",
        new { CodFamiglia = string.IsNullOrEmpty(codFamiglia) ? null : codFamiglia },
        commandType: CommandType.StoredProcedure);
    return Results.Ok(p.Cast<IDictionary<string, object>>()
        .Select(x => new { idProcesso = x["IdProcesso"], processo = x["Processo"] }));
}).RequireAuthorization();

// Combo azioni del processo (ElencoAzioni)
app.MapGet("/api/esiti/azioni", async (int idProcesso, string? codFamigliaAzione) =>
{
    await using var cn = new SqlConnection(ConnString());
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

    await using var cn = new SqlConnection(ConnString());
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
        var opt = await cn.QueryAsync("dbo.ElencoStatiResi", new { IdAzione = idAzione, IdProcesso = idProcesso }, commandType: CommandType.StoredProcedure);
        campoComune = new { tipo = "combo", label = "Tipologia Reso", valueKey = "IdStatoReso", labelKey = "StatoReso", options = opt };
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
        var opt = await cn.QueryAsync("dbo.ElencoFiliali", new { IdAzione = idAzione, IdProcesso = idProcesso, IdFiliale = idFiliale }, commandType: CommandType.StoredProcedure);
        campoComune = new { tipo = "combo", label = "Filiale Dest.", valueKey = "idfiliale", labelKey = "filiale", options = opt };
    }
    else if (bFilialeGiac)
    {
        var opt = await cn.QueryAsync("dbo.ElencoFiliali", new { IdAzione = idAzione, IdProcesso = idProcesso, IdFiliale = idFiliale }, commandType: CommandType.StoredProcedure);
        campoComune = new { tipo = "combo", label = "Filiale Giac.", valueKey = "idfiliale", labelKey = "filiale", options = opt };
    }
    else if (bTerzi)
    {
        campoComune = new { tipo = "text", label = "Nome del Terzo", valueKey = "", labelKey = "", options = Array.Empty<object>() };
    }
    else if (iScatola > 0)
    {
        var opt = await cn.QueryAsync("dbo.ElencoScatoleAperte", new { IdFiliale = idFiliale, IdTipoScatola = iScatola }, commandType: CommandType.StoredProcedure);
        campoComune = new { tipo = "combo", label = "Scatola", valueKey = "barcode", labelKey = "barcode", options = opt };
    }
    else if (!string.IsNullOrEmpty(param1Tipo))
    {
        campoComune = new { tipo = param1Tipo.Equals("Data", StringComparison.OrdinalIgnoreCase) ? "date" : "text", label = string.IsNullOrEmpty(param1Desc) ? "Parametro" : param1Desc, valueKey = "", labelKey = "", options = Array.Empty<object>() };
    }

    // campo "Operatore" (secondo campo dinamico)
    if (bTerzi)
    {
        var opt = await cn.QueryAsync("dbo.ElencoQualifiche", new { IdAzione = idAzione, IdProcesso = idProcesso }, commandType: CommandType.StoredProcedure);
        campoOperatore = new { tipo = "combo", label = "Qualifica", valueKey = "IdQualifica", labelKey = "Qualifica", options = opt };
    }
    else if (bOperatore)
    {
        var opt = await cn.QueryAsync("dbo.ElencoOperatori", new { IdAzione = idAzione, IdProcesso = idProcesso, IdFiliale = idFiliale, IdRuolo = 40 }, commandType: CommandType.StoredProcedure);
        campoOperatore = new { tipo = "combo", label = "Postino", valueKey = "IdUtente", labelKey = "nome", options = opt };
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

    await using var cn = new SqlConnection(ConnString());
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

    await using var cn = new SqlConnection(ConnString());
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

// === Giri su Mappa (videata legacy "Creazione giri su Mappa") ===

// Centro mappa = coordinate della filiale corrente (fallback Toscana)
app.MapGet("/api/giri/init", async (ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile" });
    await using var cn = new SqlConnection(ConnString());
    var f = await cn.QueryFirstOrDefaultAsync(
        "SELECT Latitude AS lat, Longitude AS lng, FILIALE AS filiale FROM FILIALI WHERE IDFILIALE = @id",
        new { id = idFiliale }) as IDictionary<string, object>;
    double lat = f?["lat"] is double la ? la : 43.84;
    double lng = f?["lng"] is double lo ? lo : 11.1143;
    return Results.Ok(new { lat, lng, filiale = f?["filiale"] as string });
}).RequireAuthorization();

// Elenco giri della filiale (GEO_GIRI)
app.MapGet("/api/giri/elenco", async (ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile" });
    await using var cn = new SqlConnection(ConnString());
    var g = await cn.QueryAsync(@"
        SELECT IdGiro AS idGiro, Giro AS giro, CAP AS cap, Belfiore AS belfiore, Colore AS colore
        FROM GEO_GIRI WHERE IdFiliale = @id AND DataFine IS NULL ORDER BY Giro",
        new { id = idFiliale });
    return Results.Ok(g);
}).RequireAuthorization();

// Comuni coperti dalla filiale (via GEO_COPERTURE.CAP)
app.MapGet("/api/giri/comuni", async (ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile" });
    await using var cn = new SqlConnection(ConnString());
    var c = await cn.QueryAsync(@"
        SELECT c.IdComune AS idComune, c.DENOMINAZIONE AS denominazione, c.BELFIORE AS belfiore,
               MIN(c.CAP) AS cap, MIN(c.SIGLAPROV) AS siglaProv
        FROM GEO_COMUNE c
        JOIN GEO_COPERTURE cop ON cop.CAP = c.CAP
        WHERE cop.IdFilialeDistribuzione = @id
        GROUP BY c.IdComune, c.DENOMINAZIONE, c.BELFIORE
        ORDER BY c.DENOMINAZIONE", new { id = idFiliale });
    return Results.Ok(c);
}).RequireAuthorization();

// Vertici di un comune o di un giro (Geo_GetVertici) -> poligono
app.MapGet("/api/giri/vertici", async (int? idComune, int? idGiro) =>
{
    if (idComune is null && idGiro is null)
        return Results.BadRequest(new { errore = "Specificare idComune o idGiro" });
    await using var cn = new SqlConnection(ConnString());
    var v = await cn.QueryAsync("dbo.Geo_GetVertici",
        new { IdComune = idComune, IdGiro = idGiro }, commandType: CommandType.StoredProcedure);
    // NB: Geo_GetVertici restituisce le colonne con casing diverso tra comune
    // (Latitude/Longitude) e giro (latitude/longitude); il lookup di Dapper e'
    // case-sensitive -> leggo i valori in modo case-insensitive.
    static object? Cerca(IDictionary<string, object> r, string nome)
    {
        foreach (var kv in r)
            if (string.Equals(kv.Key, nome, StringComparison.OrdinalIgnoreCase)) return kv.Value;
        return null;
    }
    return Results.Ok(v.Cast<IDictionary<string, object>>()
        .Select(r => new { lat = Cerca(r, "Latitude"), lng = Cerca(r, "Longitude") }));
}).RequireAuthorization();

// Spedizioni geolocalizzate da consegnare (V_ElencoGeoSped), filtrabili per giro/cap
app.MapGet("/api/giri/spedizioni", async (int? idGiro, string? cap, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile" });
    var par = new DynamicParameters();
    par.Add("id", idFiliale);
    var where = " WHERE idFiliale = @id AND latitude IS NOT NULL";
    if (idGiro is int g) { where += " AND IdGiro = @g"; par.Add("g", g); }
    if (!string.IsNullOrWhiteSpace(cap) && cap.Length == 5) { where += " AND destinazionecap = @cap"; par.Add("cap", cap); }
    await using var cn = new SqlConnection(ConnString());
    var s = await cn.QueryAsync($@"
        SELECT idspedizione AS idSpedizione, barcode, latitude AS lat, longitude AS lng,
               destinazioneindirizzo AS indirizzo, DestinazioneLocalita AS localita,
               destinazionecap AS cap, giro, IdGiro AS idGiro, colore
        FROM V_ElencoGeoSped{where}", par);
    return Results.Ok(s);
}).RequireAuthorization();

// Geometria (WKT) di un giro o di un comune: rendering unificato che gestisce
// anche i MULTIPOLYGON (es. giri creati come unione di comuni non adiacenti)
app.MapGet("/api/giri/shape", async (int? idGiro, int? idComune) =>
{
    await using var cn = new SqlConnection(ConnString());
    string? wkt = (idGiro, idComune) switch
    {
        (int g, _) => await cn.ExecuteScalarAsync<string>(
            "SELECT SHAPE.STAsText() FROM GEO_GIRI WHERE IdGiro = @id AND SHAPE IS NOT NULL", new { id = g }),
        (_, int c) => await cn.ExecuteScalarAsync<string>(
            "SELECT SHAPE.STAsText() FROM GEO_COMUNE WHERE IdComune = @id AND SHAPE IS NOT NULL", new { id = c }),
        _ => null
    };
    return Results.Ok(new { wkt });
}).RequireAuthorization();

// Crea un giro come unione delle geometrie dei comuni selezionati
app.MapPost("/api/giri/da-comuni", async (CreaGiroComuniRequest req, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile" });
    if (req.IdComuni is null || req.IdComuni.Count == 0)
        return Results.BadRequest(new { errore = "Seleziona almeno un comune" });

    var json = JsonSerializer.Serialize(req.IdComuni);
    await using var cn = new SqlConnection(ConnString());
    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<int?>("dbo.AI_GEO_CreaGiroDaComuni",
            new { Giro = req.Nome, IdFiliale = idFiliale, Colore = req.Colore, IdComuni = json },
            commandType: CommandType.StoredProcedure);
        return Results.Ok(new { idGiro = id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Crea un nuovo giro con i vertici disegnati (AI_GEO_CreaGiro, atomico)
app.MapPost("/api/giri", async (CreaGiroRequest req, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile" });
    if (req.Vertici is null || req.Vertici.Count < 3)
        return Results.BadRequest(new { errore = "Servono almeno 3 punti per definire il giro" });

    var json = JsonSerializer.Serialize(req.Vertici.Select(v => new { lat = v.Lat, lng = v.Lng }));
    await using var cn = new SqlConnection(ConnString());
    try
    {
        var id = await cn.QueryFirstOrDefaultAsync<int?>("dbo.AI_GEO_CreaGiro",
            new { Giro = req.Nome, IdFiliale = idFiliale, Colore = req.Colore, Vertici = json },
            commandType: CommandType.StoredProcedure);
        return Results.Ok(new { idGiro = id });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
    }
}).RequireAuthorization();

// Aggiorna i giri alle spedizioni (GEO_AssegnaGIRI per ogni giro selezionato)
app.MapPost("/api/giri/assegna", async (AssegnaGiriRequest req, ClaimsPrincipal user) =>
{
    if (!int.TryParse(user.FindFirstValue("idFiliale"), out var idFiliale))
        return Results.BadRequest(new { errore = "Filiale non disponibile" });
    if (req.IdGiri is null || req.IdGiri.Count == 0)
        return Results.BadRequest(new { errore = "Nessun giro selezionato" });
    await using var cn = new SqlConnection(ConnString());
    try
    {
        foreach (var idGiro in req.IdGiri)
            await cn.ExecuteAsync("dbo.GEO_AssegnaGIRI",
                new { idgiro = idGiro, forza = 1, IdFiliale = idFiliale },
                commandType: CommandType.StoredProcedure);
        return Results.Ok(new { ok = true });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: StatusCodes.Status400BadRequest);
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

    await using var cn = new SqlConnection(ConnString());
    var total = await cn.ExecuteScalarAsync<int>($"SELECT COUNT(*) FROM UTENTI u{where}", par);
    var rows = await cn.QueryAsync($@"
        SELECT u.IdUtente, u.Utente, u.Nome, u.Email, u.IdRuolo, r.Ruolo,
               u.IdFiliale, f.FILIALE AS Filiale, u.IdCliente, cl.RagioneSociale AS Cliente,
               u.codAppLogin, u.DataUltimoAccesso,
               CAST(CASE WHEN u.DataFine IS NULL THEN 1 ELSE 0 END AS bit) AS Attivo
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
    await using var cn = new SqlConnection(ConnString());
    var cols = (await LoadColonne(cn, "UTENTI")).Where(c => c.Col != "Pass").Select(c => $"[{c.Col}]");
    var u = await cn.QueryFirstOrDefaultAsync(
        $"SELECT {string.Join(",", cols)} FROM UTENTI WHERE IdUtente = @id", new { id });
    return u is null ? Results.NotFound() : Results.Ok(u);
}).RequireAuthorization();

// Lookup per le tendine del form
app.MapGet("/api/utenti/lookups", async () =>
{
    await using var cn = new SqlConnection(ConnString());
    var ruoli = await cn.QueryAsync("SELECT IdRuolo AS idRuolo, Ruolo AS ruolo FROM RUOLI ORDER BY Ruolo");
    var filiali = await cn.QueryAsync("SELECT IDFILIALE AS idFiliale, FILIALE AS filiale FROM FILIALI WHERE DataChiusura IS NULL ORDER BY FILIALE");
    var clienti = await cn.QueryAsync("SELECT IdCliente AS idCliente, RagioneSociale AS ragioneSociale FROM CLIENTI ORDER BY RagioneSociale");
    var aziende = await cn.QueryAsync("SELECT IdAzienda AS idAzienda, Azienda AS azienda FROM AZIENDE ORDER BY Azienda");
    var padri = await cn.QueryAsync("SELECT IdUtente AS idUtente, ISNULL(NULLIF(Nome,''), Utente) + ' (' + Utente + ')' AS label FROM UTENTI WHERE DataFine IS NULL ORDER BY label");
    var gruppi = await cn.QueryAsync("SELECT IdGruppo AS idGruppo, Gruppo AS gruppo FROM GRUPPI ORDER BY Gruppo");
    var processi = await cn.QueryAsync("SELECT IdProcesso AS idProcesso, Processo AS processo FROM PROCESSI ORDER BY Processo");
    var famiglie = await cn.QueryAsync("SELECT CodFamiglia AS codFamiglia, FamigliaDiProdotto AS famiglia FROM PROD_FAMIGLIE ORDER BY FamigliaDiProdotto");
    return Results.Ok(new { ruoli, filiali, clienti, aziende, padri, gruppi, processi, famiglie });
}).RequireAuthorization();

// Comuni (lookup pesante, caricato a richiesta per il Belfiore dei processi)
app.MapGet("/api/utenti/comuni", async () =>
{
    await using var cn = new SqlConnection(ConnString());
    var comuni = await cn.QueryAsync(
        @"SELECT BELFIORE AS belfiore, DENOMINAZIONE + ' (' + ISNULL(SIGLAPROV,'') + ')' AS label
          FROM GEO_Comune WHERE DataFine IS NULL ORDER BY DENOMINAZIONE");
    return Results.Ok(comuni);
}).RequireAuthorization();

// Tutte le associazioni N:N dell'utente
app.MapGet("/api/utenti/{id:int}/relazioni", async (int id) =>
{
    await using var cn = new SqlConnection(ConnString());
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
    await using var cn = new SqlConnection(ConnString());
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
app.MapPost("/api/utenti", async (JsonElement body) =>
{
    await using var cn = new SqlConnection(ConnString());
    var validi = (await LoadColonne(cn, "UTENTI"))
        .Where(c => !c.Identita && c.Col != "Pass").Select(c => c.Col)
        .Concat(new[] { "IdUtente", "NuovaPassword" })
        .ToHashSet(StringComparer.OrdinalIgnoreCase);

    var par = new DynamicParameters();
    foreach (var prop in body.EnumerateObject())
        if (validi.Contains(prop.Name)) par.Add(prop.Name, JsonToClr(prop.Value));

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
    await using var cn = new SqlConnection(ConnString());
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
    // la provincia OT (Olbia-Tempio) non esiste piu': oggi quei comuni sono in SS
    string ProvFix(string p) => p == "OT" ? "SS" : p;
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
                ["DataInizioRapporto"] = J("inizioRapporto", "dataInizioDescrizione"),
                ["DataFineRapporto"] = J("inizioRapporto", "dataFineDescrizione"),
                ["TipoContratto"] = J("inizioRapporto", "tipologiaContrattualeDescrizione"),
                ["TipoOrario"] = J("inizioRapporto", "tipoOrarioDescrizione"),
                ["OreSettimanali"] = J("inizioRapporto", "oreSettimanaliMedie"),
                ["Qualifica"] = J("inizioRapporto", "qualificaProfessionaleDescrizione"),
                ["CCNL"] = J("inizioRapporto", "ccnlDescrizione"),
                ["LivelloInquadramento"] = J("inizioRapporto", "livelloInquadramentoDescrizione"),
                ["PatInail"] = J("inizioRapporto", "patINAIL"),
                ["SedeLavoroComune"] = J("datoreLavoro", "comuneSedeLavoroDescrizione"),
                ["UnilavCodice"] = J("codiceComunicazione"),
                ["UnilavData"] = J("dataInvioDescrizione"),
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
        "Lavoro in agricoltura:", "Giornate lavorative previste:", "Tipo lavorazione:", "Data invio:", "Note:"
    };
    // titoli di sezione: non sono campi ma delimitano i valori che li precedono
    var sezioni = new[] { "Datore di Lavoro", "Lavoratore", "Dati Rapporto", "Dati invio", "Inizio", "Pagina " };
    // posizioni di tutte le occorrenze di etichette e titoli di sezione
    var occ = new List<(int Pos, string Lab)>();
    foreach (var lab in etichette.Concat(sezioni))
    {
        int i = 0;
        while ((i = testo.IndexOf(lab, i, StringComparison.Ordinal)) >= 0) { occ.Add((i, lab)); i += lab.Length; }
    }
    occ.Sort((a, b) => a.Pos.CompareTo(b.Pos));
    string Valore(string lab, int daPos = 0)
    {
        var hit = occ.FirstOrDefault(o => o.Lab == lab && o.Pos >= daPos);
        if (hit.Lab is null) return "";
        var inizio = hit.Pos + lab.Length;
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
    };
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
    string? mansione = qual.Contains("FACCHIN") ? "FACCHINO"
        : qual.Contains("CONDUCENT") || qual.Contains("AUTIST") || qual.Contains("CORRIER") ? "DRIVER"
        : estratti["Qualifica"] is { Length: > 0 } q ? (q.Length > 50 ? q[..50] : q) : null;

    // provincia del comune di domicilio: dal Belfiore (se il tracciato lo da') o dal nome
    await using var cn = new SqlConnection(ConnString());
    string? provDom = null;
    if (belfioreDom is { Length: > 0 })
        provDom = await cn.ExecuteScalarAsync<string?>(@"
            SELECT TOP 1 sigla_provincia FROM MAP_comuni_nazioni_cf
            WHERE data_fine_validita IS NULL AND codice_belfiore = @b", new { b = belfioreDom });
    if (provDom is null && (estratti["ComuneDomicilio"] ?? "") != "")
        provDom = await cn.ExecuteScalarAsync<string?>(@"
            SELECT TOP 1 sigla_provincia FROM MAP_comuni_nazioni_cf
            WHERE data_fine_validita IS NULL AND UPPER(denominazione_ita) = @c",
            new { c = estratti["ComuneDomicilio"]!.ToUpperInvariant() });
    if (provDom == "OT") provDom = "SS"; // provincia abolita

    // scheda utente per CF (preferisce l'account attivo)
    var utenti = (await cn.QueryAsync(@"
        SELECT u.IdUtente, u.Utente, u.Nome, u.Matricola, u.CodiceFiscale,
               CONVERT(varchar(10), u.DataInizio, 120) AS DataInizio, CONVERT(varchar(10), u.DataFine, 120) AS DataFine,
               CONVERT(varchar(10), u.DataNascita, 120) AS DataNascita,
               u.IndirizzoRes, u.CapRes, u.ComuneRes, u.ProvRes, u.Livello, u.Mansione,
               u.Cittadinanza, u.LuogoNascita, u.TitoloStudio, u.TipoContratto,
               CONVERT(varchar(10), u.DataFineContratto, 120) AS DataFineContratto,
               u.OreSettimanali, u.CCNL, u.SoggiornoTipo, u.SoggiornoNumero, u.SoggiornoMotivo,
               CONVERT(varchar(10), u.SoggiornoScadenza, 120) AS SoggiornoScadenza,
               u.SoggiornoQuestura, u.UnilavCodice, u.IdFiliale, f.FILIALE AS Filiale
        FROM UTENTI u LEFT JOIN FILIALI f ON f.IDFILIALE = u.IdFiliale
        WHERE u.CodiceFiscale = @cf
        ORDER BY CASE WHEN u.DataFine IS NULL THEN 0 ELSE 1 END, u.DataInizio DESC", new { cf }))
        .Cast<IDictionary<string, object>>().ToList();
    var u0 = utenti.FirstOrDefault();
    if (u0 is null)
        avvisi.Add("Nessun utente con questo codice fiscale: crealo prima dalla pagina Utenti, poi ricarica il PDF");

    // proposte di aggiornamento (campo tabella -> valore dal PDF), solo se diverse
    var proposte = new List<object>();
    void Proponi(string campo, string etichetta, string? nuovo)
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
        if (campo == "OreSettimanali"
            && decimal.TryParse(attualeCmp.Replace(',', '.'), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var oa)
            && decimal.TryParse(nuovoCmp.Replace(',', '.'), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var on)
            && oa == on) return;
        if (string.Equals(attualeCmp, nuovoCmp, StringComparison.OrdinalIgnoreCase)) return;
        proposte.Add(new { campo, etichetta, attuale, nuovo = nuovoCmp });
    }
    Proponi("Nome", "Cognome e nome", (cognome + " " + nome).Trim());
    Proponi("DataNascita", "Data di nascita", estratti["DataNascita"]);
    Proponi("DataInizio", "Inizio rapporto", estratti["DataInizioRapporto"]);
    Proponi("DataFineContratto", "Fine prevista contratto", estratti["DataFineRapporto"]);
    Proponi("IndirizzoRes", "Indirizzo (domicilio)", estratti["IndirizzoDomicilio"]);
    Proponi("CapRes", "CAP", estratti["CapDomicilio"]);
    Proponi("ComuneRes", "Comune", estratti["ComuneDomicilio"]);
    Proponi("ProvRes", "Provincia", provDom);
    Proponi("Livello", "Livello", livello);
    Proponi("Mansione", "Mansione", mansione);
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

    return Results.Ok(new { fonte, estratti, utente = u0, altriAccount = utenti.Count - (u0 is null ? 0 : 1), proposte, avvisi });
}).RequireAuthorization();

app.MapPost("/api/hr/unilav/applica", async (UnilavApplicaRequest req) =>
{
    if (req.IdUtente <= 0 || req.Valori is null || req.Valori.Count == 0)
        return Results.Json(new { errore = "Nessun campo da applicare" }, statusCode: 400);
    var ammessi = new[] { "Nome", "DataNascita", "DataInizio", "IndirizzoRes", "CapRes", "ComuneRes", "ProvRes",
        "Livello", "Mansione", "Cittadinanza", "LuogoNascita", "TitoloStudio", "TipoContratto", "DataFineContratto",
        "OreSettimanali", "CCNL", "SoggiornoTipo", "SoggiornoNumero", "SoggiornoMotivo", "SoggiornoScadenza",
        "SoggiornoQuestura", "UnilavCodice", "UnilavData" };
    var par = new DynamicParameters();
    par.Add("IdUtente", req.IdUtente);
    foreach (var (k, v) in req.Valori)
    {
        if (!ammessi.Contains(k, StringComparer.OrdinalIgnoreCase) || string.IsNullOrWhiteSpace(v)) continue;
        if (k is "DataNascita" or "DataInizio" or "DataFineContratto" or "SoggiornoScadenza" or "UnilavData")
        {
            if (DateTime.TryParse(v, out var d)) par.Add(k, d);
        }
        else if (k == "OreSettimanali")
        {
            if (decimal.TryParse(v.Replace(',', '.'), System.Globalization.NumberStyles.Any,
                System.Globalization.CultureInfo.InvariantCulture, out var ore)) par.Add(k, ore);
        }
        else par.Add(k, v.Trim());
    }
    await using var cn = new SqlConnection(ConnString());
    try
    {
        var righe = await cn.QueryFirstAsync<int>("dbo.AI_UTENTI_Unilav_Applica", par, commandType: CommandType.StoredProcedure);
        return Results.Ok(new { righe });
    }
    catch (SqlException ex)
    {
        return Results.Json(new { errore = ex.Message }, statusCode: 400);
    }
}).RequireAuthorization();

// SPA fallback: ogni rotta non-API (router in history mode: /, /login, ...) torna
// index.html, che poi gestisce il routing lato client. Le /api/* sono gia' mappate sopra.
app.MapFallbackToFile("index.html");

app.Run();

record LoginRequest(string Utente, string Password);
record EseguiInterrogazioneRequest(int IdQuery, string? SWhere);
record CambiaFilialeRequest(int IdFiliale);
record ColMeta(string Col, string Tipo, int MaxLen, bool Nullable, bool Identita, bool Pk);
record GruppoReq(int IdGruppo);
record SalvaWorkflowRequest(int? IdWorkflow, int IdAzione, string? Stato_Inizio, string? Stato_Fine, int? GiorniSLA);
record ComandoSqlRequest(string Sql, string? Data, string? Valore);
record EsitiVerificaRequest(string Barcode, int IdAzione, int IdProcesso, string? Comune, string? Operatore, string? Attributo, string? Data);
record UnilavParseRequest(string? Testo, string? TracciatoJson, string? PdfBase64);
record UnilavApplicaRequest(int IdUtente, Dictionary<string, string?> Valori);
record EsitiConfermaRequest(int IdAzione, int IdProcesso, string ElencoBarcode, string ElencoParametri1, string? Comune, string? Operatore, string? Data);
record VerticeGiro(double Lat, double Lng);
record CreaGiroRequest(string Nome, string? Colore, List<VerticeGiro> Vertici);
record CreaGiroComuniRequest(string Nome, string? Colore, List<int> IdComuni);
record AssegnaGiriRequest(List<int> IdGiri);
record ComandoEsitiRequest(int IdAzione, string? Barcodes, string? Nota);
record CreaDdtRequest(int IdFilialeMittente, int IdFilialeDestinazione, string? NotaConsegna,
    int? IdDriver, string? Driver, int? IdMezzo, string? Targa, string? Sigillo1, string? Sigillo2, string? Sigillo3);
record SalvaProcessoAzioneRequest(int? IdProcessoAzione, int IdProcesso, int IdAzione, string? TipoEventoCodice);
record SalvaAttivitaFilialeRequest(long? IdAttivita, string Data, short[]? Contatori);
record ProfiloReq(string CodFamiglia);
record ProcessoReq(int IdProcesso, string? Belfiore);
record FilialeReq(int IdFiliale);
