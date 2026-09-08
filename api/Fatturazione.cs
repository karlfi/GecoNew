using System.Data;
using System.Security.Claims;
using System.Text.RegularExpressions;
using ClosedXML.Excel;
using Dapper;
using MailKit.Net.Smtp;
using MailKit.Security;
using Microsoft.Data.SqlClient;
using MimeKit;

// === Fatturazione a consuntivo per tipo di vendita (ANCI, ALIA/FFM) ===
// Erano step dello schedulatore (DELIVERY-06_*.sql), uguali a parte il tipo di
// vendita e i report: elenco clienti, FATT_Genera per ognuno, export Excel di
// FATT_Report per fattura e la mail di prefattura con gli allegati.
// La parte SQL sta in FATT_TIPO_Genera / FATT_TIPO_Previsione; qui i file
// (ClosedXML) e le mail (MailKit, SMTP da LISTA_VALORI). Data fattura = primo
// del mese corrente, la fattura copre quello che sta prima.
//
// Ogni tipo e' un "profilo": codice del tipo di vendita, famiglia delle
// condizioni per l'elenco fatture, se produrre il report delle voci, quali
// file allegare alla mail. Le rotte sono /api/fatturazione/{profilo}/...
//
// Le prove non devono arrivare ai clienti: con DestinatarioProva le mail vanno
// solo a quell'indirizzo, con i destinatari veri scritti nel testo.
static class Fatturazione
{
    record Profilo(string Nome, string Titolo, string TipoVendita, string? CodFamiglia, bool Riepilogo, string[] Allegati);

    static readonly Dictionary<string, Profilo> Profili = new(StringComparer.OrdinalIgnoreCase)
    {
        // ANCI: dettaglio, voci e ripartizione CDC; in mail dettaglio e voci
        ["anci"] = new("anci", "Fatturazione ANCI", "ANCI", null, true, new[] { "Dettaglio", "VociFattura" }),
        // ALIA: tipo di vendita FFM, condizioni aperte di famiglia N; niente voci;
        // in mail dettaglio e ripartizione CDC
        ["alia"] = new("alia", "Fatturazione ALIA", "FFM", "N", false, new[] { "Dettaglio", "RipartizioneCDC" }),
    };

    public static void Map(WebApplication app, Func<string> connString)
    {
        // stato per una data: chi e' ancora da fatturare e le fatture gia' fatte
        app.MapGet("/api/fatturazione/{profilo}/stato", async (string profilo, DateTime? dataFattura) =>
        {
            if (!Profili.TryGetValue(profilo, out var p)) return ProfiloIgnoto(profilo);
            var data = PrimoDelMese(dataFattura);
            await using var cn = new SqlConnection(connString());
            var (daFatturare, fatture) = await Elenchi(cn, p, data, null, genera: false);
            var (cartella, avviso) = await CartellaScrivibile(cn);
            return Results.Ok(new
            {
                profilo = p.Nome, titolo = p.Titolo, tipoVendita = p.TipoVendita,
                riepilogo = p.Riepilogo, allegati = p.Allegati,
                dataFattura = data.ToString("yyyy-MM-dd"), cartella,
                avvisi = avviso is null ? Array.Empty<string>() : new[] { avviso },
                daFatturare,
                fatture = fatture.Select(f => Riga(f, cartella)).ToList()
            });
        }).RequireAuthorization();

        // previsione: quanto verrebbe fatturato oggi, senza fatturare (FATT_Genera
        // eseguita davvero e annullata: pezzi, importo e voci sono quelli veri)
        app.MapGet("/api/fatturazione/{profilo}/previsione", async (string profilo, DateTime? dataFattura, int? idCliente) =>
        {
            if (!Profili.TryGetValue(profilo, out var p)) return ProfiloIgnoto(profilo);
            var data = PrimoDelMese(dataFattura);
            await using var cn = new SqlConnection(connString());
            using var multi = await cn.QueryMultipleAsync("dbo.FATT_TIPO_Previsione",
                new { CodTipoVendita = p.TipoVendita, DataFattura = data, IdCliente = idCliente },
                commandType: CommandType.StoredProcedure, commandTimeout: 900);
            var stime = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().ToList();
            var voci = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().ToList();
            var clienti = stime.Select(s => new
            {
                idCliente = Int(s["IdCliente"]),
                ragioneSociale = s["RagioneSociale"]?.ToString(),
                emailPrefattura = s["EmailPrefattura"]?.ToString(),
                pezzi = Int(s["Pezzi"]),
                importo = Convert.ToDecimal(s["Importo"] ?? 0m),
                errore = s["Errore"]?.ToString(),
                voci = voci.Where(v => Int(v["IdCliente"]) == Int(s["IdCliente"])).Select(v => new
                {
                    cig = v["CIG"]?.ToString(), descrizione = v["Descrizione"]?.ToString(),
                    numPezzi = Int(v["NumPezzi"]),
                    prezzoUnitario = Convert.ToDecimal(v["PrezzoUnitario"] ?? 0m),
                    totale = Convert.ToDecimal(v["Totale"] ?? 0m)
                }).ToList()
            }).ToList();
            return Results.Ok(new
            {
                dataFattura = data.ToString("yyyy-MM-dd"), clienti,
                totalePezzi = clienti.Sum(c => c.pezzi), totaleImporto = clienti.Sum(c => c.importo)
            });
        }).RequireAuthorization();

        // esecuzione: fatture (se richiesto), report Excel, mail
        app.MapPost("/api/fatturazione/{profilo}/esegui", async (string profilo, FattRequest req, ClaimsPrincipal user) =>
        {
            if (!Profili.TryGetValue(profilo, out var p)) return ProfiloIgnoto(profilo);
            var data = PrimoDelMese(req.DataFattura);
            await using var cn = new SqlConnection(connString());
            var (cartella, avvisoCartella) = await CartellaScrivibile(cn);

            var (daFatturare, fatture) = await Elenchi(cn, p, data, req.IdCliente, req.Genera);

            // su quali fatture lavorare: quelle scelte a video; altrimenti quelle
            // appena generate; senza generazione, tutte quelle della data
            var scelte = fatture.Where(f =>
                req.IdFatture is { Length: > 0 } ? req.IdFatture.Contains(Int(f["IdFattura"]))
                : req.Genera ? Int(f["GenerataOra"]) == 1
                : true).ToList();

            SmtpConfig? smtp = null;
            var avvisi = new List<string>();
            if (avvisoCartella is not null) avvisi.Add(avvisoCartella);
            if (req.InviaMail)
            {
                smtp = await LeggiSmtp(cn);
                if (smtp is null) avvisi.Add("Configurazione SMTP_SERVER assente in LISTA_VALORI: mail non inviate");
            }

            var esiti = new List<object>();
            foreach (var f in scelte)
            {
                var idFattura = Int(f["IdFattura"]);
                var prefix = f["PrefixFile"]?.ToString() ?? $"FAT_{idFattura}";
                var file = new List<string>();
                string? erroreFile = null;
                try
                {
                    // Dettaglio (tipo 0, o 3 per Nexive), Voci (1) dove il profilo le
                    // prevede, RipartizioneCDC (2) dove prevista per il cliente
                    file.Add(await Esporta(cn, cartella, idFattura, Int(f["TipoReport"]), $"{prefix}_Dettaglio.xlsx"));
                    if (p.Riepilogo)
                        file.Add(await Esporta(cn, cartella, idFattura, 1, $"{prefix}_VociFattura.xlsx"));
                    if (Int(f["ReportCDC"]) == 1)
                        file.Add(await Esporta(cn, cartella, idFattura, 2, $"{prefix}_RipartizioneCDC.xlsx"));
                }
                catch (Exception ex) { erroreFile = ex.Message; }

                object mail = new { inviata = false, a = "", errore = (string?)null };
                if (req.InviaMail && smtp is not null && erroreFile is null)
                {
                    var destinatari = Destinatari(f["EmailPrefattura"]?.ToString());
                    var prova = (req.DestinatarioProva ?? "").Trim();
                    var a = prova.Length > 0 ? new List<string> { prova } : destinatari;
                    try
                    {
                        if (a.Count == 0) throw new InvalidOperationException("nessun indirizzo di prefattura sul cliente");
                        // gli allegati del profilo, se esistono (RimuoviAllegatiNonPresenti dello step)
                        var allegati = p.Allegati.Select(n => Path.Combine(cartella, $"{prefix}_{n}.xlsx")).Where(File.Exists).ToList();
                        await InviaMail(smtp, f, data, a, allegati,
                            prova.Length > 0 ? $"destinatari reali: {string.Join(", ", destinatari)}" : null);
                        await cn.ExecuteAsync("dbo.AI_LOG_Exec_Add", new
                        {
                            Chiamata = $"FATT_{p.Nome.ToUpperInvariant()}_Mail",
                            Parametri = $"IdFattura={idFattura}; a={string.Join(",", a)}; allegati={allegati.Count}"
                                + (prova.Length > 0 ? "; PROVA" : "") + $"; utente={user.Identity?.Name}"
                        }, commandType: CommandType.StoredProcedure);
                        mail = new { inviata = true, a = string.Join(", ", a), errore = (string?)null };
                    }
                    catch (Exception ex)
                    {
                        mail = new { inviata = false, a = string.Join(", ", a), errore = ex.Message };
                    }
                }

                esiti.Add(new
                {
                    idFattura, idCliente = Int(f["IdCliente"]),
                    ragioneSociale = f["RagioneSociale"]?.ToString(),
                    numero = f["Numero"]?.ToString(), pezzi = Int(f["Pezzi"]),
                    importo = Convert.ToDecimal(f["Importo"] ?? 0m),
                    generataOra = Int(f["GenerataOra"]) == 1,
                    emailPrefattura = f["EmailPrefattura"]?.ToString(),
                    file, erroreFile, mail
                });
            }

            return Results.Ok(new
            {
                dataFattura = data.ToString("yyyy-MM-dd"), cartella,
                generate = req.Genera ? daFatturare.Count : 0,
                esiti, avvisi
            });
        }).RequireAuthorization();

        // scarica uno dei file prodotti (solo nomi nella forma FAT_..., niente percorsi)
        app.MapGet("/api/fatturazione/{profilo}/file", async (string profilo, string nome) =>
        {
            if (!Profili.ContainsKey(profilo)) return ProfiloIgnoto(profilo);
            if (!Regex.IsMatch(nome ?? "", @"^FAT_[\w\-]+\.xlsx$"))
                return Results.BadRequest(new { errore = "Nome file non valido" });
            await using var cn = new SqlConnection(connString());
            var (cartella, _) = await CartellaScrivibile(cn);
            var percorso = Path.Combine(cartella, nome!);
            if (!File.Exists(percorso)) return Results.NotFound(new { errore = "File non trovato" });
            return Results.File(percorso, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", nome);
        }).RequireAuthorization();
    }

    static IResult ProfiloIgnoto(string profilo) =>
        Results.NotFound(new { errore = $"Fatturazione '{profilo}' non prevista: {string.Join(", ", Profili.Keys)}" });

    static DateTime PrimoDelMese(DateTime? d)
    {
        var x = d?.Date ?? DateTime.Today;
        return new DateTime(x.Year, x.Month, 1);
    }

    static int Int(object? v) => v is null || v is DBNull ? 0 : Convert.ToInt32(v);

    static async Task<(List<object> DaFatturare, List<IDictionary<string, object>> Fatture)> Elenchi(
        SqlConnection cn, Profilo p, DateTime data, int? idCliente, bool genera)
    {
        using var multi = await cn.QueryMultipleAsync("dbo.FATT_TIPO_Genera",
            new { CodTipoVendita = p.TipoVendita, p.CodFamiglia, DataFattura = data, IdCliente = idCliente, Genera = genera },
            commandType: CommandType.StoredProcedure, commandTimeout: 900);
        var daFatturare = (await multi.ReadAsync()).Cast<object>().ToList();
        var fatture = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().ToList();
        return (daFatturare, fatture);
    }

    static object Riga(IDictionary<string, object> f, string cartella)
    {
        var prefix = f["PrefixFile"]?.ToString() ?? "";
        var nomi = new[] { $"{prefix}_Dettaglio.xlsx", $"{prefix}_VociFattura.xlsx", $"{prefix}_RipartizioneCDC.xlsx" };
        return new
        {
            idFattura = Int(f["IdFattura"]), idCliente = Int(f["IdCliente"]),
            ragioneSociale = f["RagioneSociale"]?.ToString(),
            numero = f["Numero"]?.ToString(), pezzi = Int(f["Pezzi"]),
            importo = Convert.ToDecimal(f["Importo"] ?? 0m),
            emailPrefattura = f["EmailPrefattura"]?.ToString(),
            // i file gia' prodotti in una esecuzione precedente, e di quando sono
            file = nomi.Where(n => File.Exists(Path.Combine(cartella, n))).ToList(),
            fileData = nomi.Select(n => Path.Combine(cartella, n)).Where(File.Exists)
                           .Select(x => (DateTime?)File.GetLastWriteTime(x)).DefaultIfEmpty(null).Max()
        };
    }

    // La cartella dei file sta in PARAMETRI (PercorsoFatturazione), come le altre
    // cartelle dell'app; %TEMP% viene espanso.
    static async Task<string> Cartella(SqlConnection cn)
    {
        var v = await cn.ExecuteScalarAsync<string?>(
            "SELECT Valore FROM PARAMETRI WHERE Nome = 'PercorsoFatturazione'");
        if (string.IsNullOrWhiteSpace(v)) return Ripiego;
        return Environment.ExpandEnvironmentVariables(v.Trim()
            .Replace("%TEMP%", Path.GetTempPath().TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase));
    }

    // Se la cartella configurata non e' scrivibile dall'utente con cui gira il
    // sito (sul server e' l'identita' dell'app pool, che sulle cartelle di altri
    // siti spesso non ha i permessi), si ripiega sulla temp del processo: i file
    // sono rifacibili in ogni momento, meglio che bloccare la fatturazione. Il
    // ripiego non e' silenzioso, torna un avviso che la pagina mostra.
    static readonly string Ripiego = Path.Combine(Path.GetTempPath(), "geconew-fatturazione");

    static async Task<(string Dove, string? Avviso)> CartellaScrivibile(SqlConnection cn)
    {
        var voluta = await Cartella(cn);
        if (Scrivibile(voluta, out _)) return (voluta, null);
        Scrivibile(voluta, out var perche);
        Directory.CreateDirectory(Ripiego);
        return (Ripiego, $"Non riesco a scrivere in {voluta} ({perche}): i file finiscono in {Ripiego}. "
            + "Per usare la cartella voluta serve dare la scrittura all'identita' del sito.");
    }

    static bool Scrivibile(string dir, out string perche)
    {
        perche = "";
        try
        {
            Directory.CreateDirectory(dir);
            var prova = Path.Combine(dir, $".prova_{Guid.NewGuid():N}");
            File.WriteAllText(prova, "");
            File.Delete(prova);
            return true;
        }
        catch (Exception ex) { perche = ex.Message; return false; }
    }

    // FATT_Report -> un foglio Excel con intestazione (era EXPORTXLS con EsportaIntestazione=1)
    static async Task<string> Esporta(SqlConnection cn, string cartella, int idFattura, int tipo, string nomeFile)
    {
        var righe = (await cn.QueryAsync("dbo.FATT_Report", new { IdFattura = idFattura, Tipo = tipo },
                commandType: CommandType.StoredProcedure, commandTimeout: 600))
            .Cast<IDictionary<string, object>>().ToList();
        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add("Dati");
        if (righe.Count > 0)
        {
            var colonne = righe[0].Keys.ToList();
            for (var c = 0; c < colonne.Count; c++)
            {
                ws.Cell(1, c + 1).Value = colonne[c];
                ws.Cell(1, c + 1).Style.Font.Bold = true;
            }
            for (var r = 0; r < righe.Count; r++)
                for (var c = 0; c < colonne.Count; c++)
                    Scrivi(ws.Cell(r + 2, c + 1), righe[r][colonne[c]]);
            ws.Columns().AdjustToContents();
        }
        else ws.Cell(1, 1).Value = "(nessuna riga)";
        wb.SaveAs(Path.Combine(cartella, nomeFile));
        return nomeFile;
    }

    static void Scrivi(IXLCell cella, object? v)
    {
        switch (v)
        {
            case null or DBNull: cella.Value = Blank.Value; break;
            case string s: cella.Value = s; break;
            case bool b: cella.Value = b; break;
            case DateTime d:
                cella.Value = d;
                cella.Style.DateFormat.Format = d.TimeOfDay == TimeSpan.Zero ? "dd/MM/yyyy" : "dd/MM/yyyy HH:mm";
                break;
            case byte or short or int or long or float or double or decimal:
                cella.Value = Convert.ToDouble(v); break;
            default: cella.Value = v.ToString(); break;
        }
    }

    // gli indirizzi di prefattura sul cliente: separati da virgola o punto e virgola
    static List<string> Destinatari(string? testo) =>
        (testo ?? "").Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim()).Where(s => MailboxAddress.TryParse(s, out _)).Distinct().ToList();

    record SmtpConfig(string Server, int Port, string User, string Pass);

    // LISTA_VALORI, lista SMTP_SERVER: Valore = chiave (SERVER/PORT/USER/PASS), Codice = valore
    static async Task<SmtpConfig?> LeggiSmtp(SqlConnection cn)
    {
        var righe = (await cn.QueryAsync<(string Valore, string Codice)>(
            "SELECT Valore, Codice FROM LISTA_VALORI WHERE Lista = 'SMTP_SERVER'")).ToList();
        string? V(string k) => righe.FirstOrDefault(r => string.Equals(r.Valore, k, StringComparison.OrdinalIgnoreCase)).Codice;
        var server = V("SERVER"); var user = V("USER"); var pass = V("PASS");
        if (string.IsNullOrWhiteSpace(server) || string.IsNullOrWhiteSpace(user)) return null;
        return new SmtpConfig(server.Trim(), int.TryParse(V("PORT"), out var port) ? port : 465, user.Trim(), pass ?? "");
    }

    // la mail di prefattura, con lo stesso testo dello schedulatore (APRIMAIL)
    static async Task InviaMail(SmtpConfig smtp, IDictionary<string, object> f, DateTime data,
        List<string> a, List<string> allegati, string? notaProva)
    {
        var msg = new MimeMessage();
        msg.From.Add(MailboxAddress.Parse(smtp.User));
        foreach (var d in a) msg.To.Add(MailboxAddress.Parse(d));
        var numero = f["Numero"]?.ToString();
        var importo = Convert.ToDecimal(f["Importo"] ?? 0m);
        msg.Subject = (notaProva is null ? "" : "[PROVA] ")
            + $"PreFattura n.{numero} del {data:dd/MM/yyyy} del Cliente {f["RagioneSociale"]}";
        var corpo = new BodyBuilder
        {
            TextBody = $"In allegato i dettagli di fatturazione. La prefattura è composta da {Int(f["Pezzi"])} pezzi "
                + $"per un importo complessivo di {importo:N2} euro. Questa mail e' stata generata da una procedura automatica"
                + (notaProva is null ? "" : $"\n\n[{notaProva}]")
        };
        foreach (var p in allegati) corpo.Attachments.Add(p);
        msg.Body = corpo.ToMessageBody();

        using var client = new SmtpClient();
        // il relay Gmail sulla 465 vuole SSL dall'inizio; sulla 587 STARTTLS
        await client.ConnectAsync(smtp.Server, smtp.Port,
            smtp.Port == 465 ? SecureSocketOptions.SslOnConnect : SecureSocketOptions.StartTlsWhenAvailable);
        if (smtp.Pass.Length > 0) await client.AuthenticateAsync(smtp.User, smtp.Pass);
        await client.SendAsync(msg);
        await client.DisconnectAsync(true);
    }
}

record FattRequest(DateTime? DataFattura, int? IdCliente, bool Genera, bool InviaMail,
    string? DestinatarioProva, int[]? IdFatture);
