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

// SPA fallback: ogni rotta non-API (router in history mode: /, /login, ...) torna
// index.html, che poi gestisce il routing lato client. Le /api/* sono gia' mappate sopra.
app.MapFallbackToFile("index.html");

app.Run();

record LoginRequest(string Utente, string Password);
record EseguiInterrogazioneRequest(int IdQuery, string? SWhere);
record CambiaFilialeRequest(int IdFiliale);
record ColMeta(string Col, string Tipo, int MaxLen, bool Nullable, bool Identita, bool Pk);
record GruppoReq(int IdGruppo);
record ProfiloReq(string CodFamiglia);
record ProcessoReq(int IdProcesso, string? Belfiore);
record FilialeReq(int IdFiliale);
