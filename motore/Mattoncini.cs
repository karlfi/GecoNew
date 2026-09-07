using System.Data;
using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using ClosedXML.Excel;
using Dapper;
using MailKit.Net.Smtp;
using MailKit.Security;
using Microsoft.Data.SqlClient;
using MimeKit;

namespace GecoMotore;

// I mattoncini: un metodo per tipo di step, con gli stessi nomi di parametro dei
// file step legacy (refusi compresi: "Destintatario", "ApriEAggiungiAEsitente").
// I sette gia' presenti nel motore TypeScript sono portati pari pari; APRIMAIL e
// IMPORTTXT sono nuovi, ricavati dai parametri usati nei workflow veri.
public static class Mattoncini
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };

    // ---- ESEGUIQUERY: esegue una query; con sottopassi, li ripete per ogni record (+[campo]) ----
    public static async Task EseguiQuery(Contesto ctx, Step step, Func<IDictionary<string, object?>, Task> figli)
    {
        var extra = Sostituzioni.ParametriDaStringa(step.P("Parametri"));
        var spec = ctx.S(step.P("QuerySQL"), extra);
        var sql = ctx.S(Query.Carica(spec, ctx.O.CartellaScript), extra);
        var (righe, interessate, conRecordset) = await Query.Esegui(ctx, sql);
        await ctx.Scrivi("INFO", $"ESEGUIQUERY {Riassunto(spec)}", step.IdStep, conRecordset ? righe.Count : interessate);

        var limite = int.TryParse(step.P("EsciSuRecordCountMaggiore"), out var l) ? l : -1;
        if (limite > -1 && righe.Count > limite) throw new Exception($"ESEGUIQUERY: {righe.Count} record, piu' del limite {limite}");

        if (step.Sottopassi.Count > 0 && !step.Flag("NoRecordset", false))
            foreach (var r in righe) await figli(r);
    }

    // ---- EXPORTTXT: query su file di testo, delimitato o a campi fissi (ANSI, CRLF) ----
    public static async Task ExportTxt(Contesto ctx, Step step)
    {
        var extra = Sostituzioni.ParametriDaStringa(step.P("Parametri"));
        var spec = ctx.S(step.P("QuerySQL"), extra);
        var sql = ctx.S(Query.Carica(spec, ctx.O.CartellaScript), extra);
        var (righe, _, _) = await Query.Esegui(ctx, sql);
        var dest = ctx.S(step.P("NomeFileDest"), extra);
        if (dest == "") throw new Exception("EXPORTTXT: NomeFileDest mancante");

        if (righe.Count == 0 && !step.Flag("EsportaSeVuoto", false))
        {
            await ctx.Scrivi("WARN", $"EXPORTTXT: nessun record, file non generato ({dest})", step.IdStep);
            return;
        }
        var colonne = righe.Count > 0 ? righe[0].Keys.ToList() : new List<string>();
        var linee = new List<string>();
        if (step.P("Modalita", "TestoDelimitato").Equals("CampiFissi", StringComparison.OrdinalIgnoreCase))
        {
            var campi = step.Lista("campiFissi");
            var padNum = (step.P("PadNumeri", " ") + " ")[0];
            var padStr = (step.P("PadStringhe", " ") + " ")[0];
            foreach (var r in righe)
            {
                var sb = new StringBuilder();
                foreach (var c in campi)
                {
                    var dim = int.TryParse(c.GetValueOrDefault("Dimensione"), out var d) ? d : 0;
                    var s = Sostituzioni.Testo(r.TryGetValue(c.GetValueOrDefault("NomeCampo") ?? "", out var v) ? v : null);
                    var tipo = (c.GetValueOrDefault("Tipo") ?? "A").ToUpperInvariant();
                    var numerico = tipo == "N" || tipo == "F";
                    var pezzo = numerico ? s.PadLeft(dim, padNum) : s.PadRight(dim, padStr);
                    sb.Append(pezzo.Length > dim ? pezzo[..dim] : pezzo);
                }
                linee.Add(sb.ToString());
            }
        }
        else
        {
            var delim = step.P("Delimitatore", ";");
            if (step.Flag("EsportaIntestazione", false) && colonne.Count > 0) linee.Add(string.Join(delim, colonne));
            foreach (var r in righe) linee.Add(string.Join(delim, colonne.Select(c => Sostituzioni.Testo(r[c]))));
        }
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        var contenuto = Query.Ansi.GetBytes(string.Join("\r\n", linee) + (linee.Count > 0 ? "\r\n" : ""));
        if (step.Flag("ApriEAggiungiAEsitente", false) && File.Exists(dest))
        {
            await using var f = new FileStream(dest, FileMode.Append);
            await f.WriteAsync(contenuto);
        }
        else await File.WriteAllBytesAsync(dest, contenuto);
        await ctx.Scrivi("INFO", $"EXPORTTXT: {righe.Count} righe -> {dest}", step.IdStep, righe.Count);
    }

    // ---- EXPORTXLS: query su file Excel ----
    public static async Task ExportXls(Contesto ctx, Step step)
    {
        var extra = Sostituzioni.ParametriDaStringa(step.P("Parametri"));
        var spec = ctx.S(step.P("QuerySQL"), extra);
        var sql = ctx.S(Query.Carica(spec, ctx.O.CartellaScript), extra);
        var (righe, _, _) = await Query.Esegui(ctx, sql);
        var dest = ctx.S(step.P("NomeFileDest"), extra);
        if (dest == "") throw new Exception("EXPORTXLS: NomeFileDest mancante");
        if (righe.Count == 0 && step.Flag("nongeneraresevuoto", false))
        {
            await ctx.Scrivi("WARN", $"EXPORTXLS: nessun record, file non generato ({dest})", step.IdStep);
            return;
        }
        var colonne = righe.Count > 0 ? righe[0].Keys.ToList() : new List<string>();
        using var wb = new XLWorkbook();
        var nomeFoglio = step.P("NomeFoglio", "Foglio1");
        var ws = wb.AddWorksheet(nomeFoglio.Length > 31 ? nomeFoglio[..31] : nomeFoglio);
        var riga = 1;
        if (step.Flag("EsportaIntestazione", false) && colonne.Count > 0)
        {
            for (var c = 0; c < colonne.Count; c++) ws.Cell(riga, c + 1).Value = colonne[c];
            ws.Row(riga).Style.Font.Bold = true;
            riga++;
        }
        foreach (var r in righe)
        {
            for (var c = 0; c < colonne.Count; c++) ws.Cell(riga, c + 1).Value = Cella(r[colonne[c]]);
            riga++;
        }
        ws.Columns().AdjustToContents();
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        wb.SaveAs(dest);
        await ctx.Scrivi("INFO", $"EXPORTXLS: {righe.Count} righe -> {dest}", step.IdStep, righe.Count);
    }

    static XLCellValue Cella(object? v) => v switch
    {
        null or DBNull => Blank.Value,
        string s => s,
        DateTime d => d,
        bool b => b,
        byte[] => "(binario)",
        decimal m => (double)m,
        float f => (double)f,
        double d => d,
        int or long or short or byte => Convert.ToDouble(v),
        _ => v.ToString() ?? "",
    };

    // ---- COPYFILE: copia (o sposta) un file; con * nel nome, tutti quelli che combaciano ----
    public static async Task CopyFile(Contesto ctx, Step step)
    {
        var src = ctx.S(step.P("FileSorgente"));
        var dst = ctx.S(step.P("FileDestinazione"));
        if (src == "" || dst == "") throw new Exception("COPYFILE: FileSorgente/FileDestinazione mancante");
        var sostituisci = step.Flag("SostituisciFile", true);
        var elimina = step.Flag("EliminaFileSorgente", false);

        if (src.IndexOfAny(new[] { '*', '?' }) >= 0)
        {
            var cartella = Path.GetDirectoryName(src) ?? ".";
            var trovati = Directory.Exists(cartella) ? Directory.GetFiles(cartella, Path.GetFileName(src)) : Array.Empty<string>();
            if (trovati.Length == 0) { await ctx.Scrivi("WARN", $"COPYFILE: nessun file per {src}", step.IdStep); return; }
            Directory.CreateDirectory(dst.TrimEnd('\\', '/'));
            foreach (var f in trovati) Copia(f, Path.Combine(dst, Path.GetFileName(f)), sostituisci, elimina);
            await ctx.Scrivi("INFO", $"COPYFILE: {trovati.Length} file {src} -> {dst}", step.IdStep, trovati.Length);
            return;
        }
        if (src.EndsWith('\\') || dst.EndsWith('\\'))
        {
            await ctx.Scrivi("WARN", "COPYFILE: copia di intere directory non supportata (usa * nel nome)", step.IdStep);
            return;
        }
        if (!File.Exists(src)) throw new FileNotFoundException($"COPYFILE: sorgente non trovato: {src}");
        Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
        Copia(src, dst, sostituisci, elimina);
        await ctx.Scrivi("INFO", $"COPYFILE: {src} -> {dst}", step.IdStep);
    }

    static void Copia(string src, string dst, bool sostituisci, bool elimina)
    {
        if (File.Exists(dst) && !sostituisci) throw new Exception($"COPYFILE: destinazione gia' esistente: {dst}");
        File.Copy(src, dst, true);
        if (elimina) File.Delete(src);
    }

    // ---- COMPRIMIFILE: zip di file/cartelle, o decompressione ----
    public static async Task ComprimiFile(Contesto ctx, Step step)
    {
        var fileZip = ctx.S(step.P("FileZip"));
        if (fileZip == "") throw new Exception("COMPRIMIFILE: FileZip mancante");

        if (step.Flag("Decomprimi", false))
        {
            if (!File.Exists(fileZip)) throw new FileNotFoundException($"COMPRIMIFILE: zip non trovato: {fileZip}");
            var fuori = ctx.S(step.P("DirectoryOut"));
            if (fuori == "") fuori = ctx.CartellaOutput ?? ".";
            Directory.CreateDirectory(fuori);
            ZipFile.ExtractToDirectory(fileZip, fuori, true);
            await ctx.Scrivi("INFO", $"COMPRIMIFILE: decompresso {fileZip} -> {fuori}", step.IdStep);
            return;
        }

        var lista = (step.P("ListaFile") ?? "").Split(',').Select(f => ctx.S(f.Trim())).Where(f => f != "").ToList();
        if (lista.Count == 0) throw new Exception("COMPRIMIFILE: ListaFile mancante");
        var conSottocartelle = step.Flag("ComprimiSubDir", true);
        Directory.CreateDirectory(Path.GetDirectoryName(fileZip)!);
        var aggiunti = 0;
        var provvisorio = fileZip + ".tmp";
        using (var zip = ZipFile.Open(provvisorio, ZipArchiveMode.Create))
            foreach (var f in lista)
            {
                if (Directory.Exists(f))
                {
                    if (!conSottocartelle) continue;
                    var radice = Path.GetFileName(f.TrimEnd('\\', '/'));
                    foreach (var x in Directory.GetFiles(f, "*", SearchOption.AllDirectories))
                        zip.CreateEntryFromFile(x, Path.Combine(radice, Path.GetRelativePath(f, x)).Replace('\\', '/'));
                    aggiunti++;
                }
                else if (File.Exists(f)) { zip.CreateEntryFromFile(f, Path.GetFileName(f)); aggiunti++; }
                else await ctx.Scrivi("WARN", $"COMPRIMIFILE: non trovato {f}", step.IdStep);
            }
        File.Move(provvisorio, fileZip, true);
        if (step.Flag("EliminaSrc", false))
            foreach (var f in lista)
            {
                if (Directory.Exists(f)) Directory.Delete(f, true);
                else if (File.Exists(f)) File.Delete(f);
            }
        await ctx.Scrivi("INFO", $"COMPRIMIFILE: creato {fileZip} ({aggiunti} elementi)", step.IdStep, aggiunti);
    }

    // ---- ESEGUISHELL: un comando esterno, aspettando o no ----
    public static async Task EseguiShell(Contesto ctx, Step step)
    {
        var programma = ctx.S(step.P("Programma"));
        var cartella = ctx.S(step.P("directory"));
        if (programma == "") throw new Exception("ESEGUISHELL: Programma mancante");
        var aspetta = step.Flag("EseguiEAspetta", false);
        var psi = new ProcessStartInfo("cmd.exe", "/c " + programma)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = aspetta, RedirectStandardError = aspetta,
            WorkingDirectory = cartella != "" ? cartella : Environment.CurrentDirectory,
        };
        using var p = Process.Start(psi) ?? throw new Exception("ESEGUISHELL: avvio fallito");
        if (!aspetta)
        {
            await ctx.Scrivi("INFO", $"ESEGUISHELL avviato (senza attendere): {programma}", step.IdStep);
            return;
        }
        var so = p.StandardOutput.ReadToEndAsync();
        var se = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        var errore = (await se).Trim();
        var uscita = (await so).Trim();
        if (p.ExitCode != 0) throw new Exception($"ESEGUISHELL \"{programma}\" exit {p.ExitCode} {errore}".Trim());
        await ctx.Scrivi("INFO", $"ESEGUISHELL \"{programma}\" completato" + (uscita.Length > 0 ? ": " + Taglia(uscita, 500) : ""), step.IdStep);
    }

    // ---- ESEGUIPYTHON: uno script Python. Script relativo alla cartella script o
    // assoluto, Argomenti con le sostituzioni, directory di lavoro, TimeoutSecondi.
    // Lo script trova nell'ambiente WF_ID_ESECUZIONE, WF_ID_WORKFLOW, WF_PARAMETRI
    // (JSON) e, nei sottopassi, WF_RECORD (JSON del record corrente); quello che
    // stampa finisce nel log, exit code diverso da zero = errore. ----
    public static async Task EseguiPython(Contesto ctx, Step step)
    {
        var script = ctx.S(step.P("Script") ?? step.P("File") ?? step.P("Programma"));
        if (script == "") throw new Exception("ESEGUIPYTHON: Script mancante");
        var rel = System.Text.RegularExpressions.Regex.Replace(script, @"^\.[\\/]", "");
        var pieno = Path.IsPathRooted(script) ? script : Path.Combine(ctx.O.CartellaScript ?? AppContext.BaseDirectory, rel);
        if (!File.Exists(pieno)) throw new FileNotFoundException($"ESEGUIPYTHON: script non trovato: {pieno}");
        var argomenti = ctx.S(step.P("Argomenti"));
        var cartella = ctx.S(step.P("directory"));
        if (cartella == "") cartella = Path.GetDirectoryName(pieno)!;
        var timeout = int.TryParse(step.P("TimeoutSecondi"), out var t) && t > 0 ? t : ctx.O.TimeoutQuerySecondi;
        var interprete = ctx.S(step.P("Python"));
        if (interprete == "") interprete = ctx.O.Python;

        var psi = new ProcessStartInfo(interprete)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = cartella, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        psi.ArgumentList.Add("-X"); psi.ArgumentList.Add("utf8");
        psi.ArgumentList.Add(pieno);
        foreach (var a in SpezzaArgomenti(argomenti)) psi.ArgumentList.Add(a);
        psi.Environment["PYTHONIOENCODING"] = "utf-8";
        psi.Environment["PYTHONUNBUFFERED"] = "1";
        psi.Environment["WF_ID_ESECUZIONE"] = ctx.IdEsecuzione.ToString();
        psi.Environment["WF_ID_WORKFLOW"] = ctx.IdWorkflow.ToString();
        psi.Environment["WF_ID_STEP"] = step.IdStep.ToString();
        psi.Environment["WF_PARAMETRI"] = System.Text.Json.JsonSerializer.Serialize(ctx.Parametri);
        if (ctx.Record is not null)
            psi.Environment["WF_RECORD"] = System.Text.Json.JsonSerializer.Serialize(ctx.Record.ToDictionary(k => k.Key, k => (object?)Sostituzioni.Segnaposto(k.Value)));
        if (ctx.CartellaOutput is not null) psi.Environment["WF_OUTPUT"] = ctx.CartellaOutput;

        using var p = Process.Start(psi) ?? throw new Exception("ESEGUIPYTHON: avvio fallito");
        var so = p.StandardOutput.ReadToEndAsync();
        var se = p.StandardError.ReadToEndAsync();
        var finito = await Task.WhenAny(p.WaitForExitAsync(), Task.Delay(TimeSpan.FromSeconds(timeout)));
        if (!p.HasExited)
        {
            try { p.Kill(true); } catch { }
            throw new Exception($"ESEGUIPYTHON: {Path.GetFileName(pieno)} interrotto dopo {timeout} s");
        }
        var uscita = (await so).Trim();
        var errore = (await se).Trim();
        foreach (var riga in uscita.Split('\n').Select(r => r.TrimEnd('\r')).Where(r => r != "").Take(200))
            await ctx.Scrivi("INFO", $"  py> {Taglia(riga, 1000)}", step.IdStep);
        if (p.ExitCode != 0)
            throw new Exception($"ESEGUIPYTHON: {Path.GetFileName(pieno)} exit {p.ExitCode}" + (errore != "" ? ": " + Taglia(errore, 1500) : ""));
        if (errore != "") await ctx.Scrivi("WARN", $"ESEGUIPYTHON stderr: {Taglia(errore, 1000)}", step.IdStep);
        await ctx.Scrivi("INFO", $"ESEGUIPYTHON: {Path.GetFileName(pieno)} {argomenti} completato", step.IdStep);
    }

    // argomenti separati da spazio, con le virgolette per quelli che contengono spazi
    static List<string> SpezzaArgomenti(string s)
    {
        var fuori = new List<string>(); var sb = new StringBuilder(); var inVirgolette = false;
        foreach (var c in s)
        {
            if (c == '"') { inVirgolette = !inVirgolette; continue; }
            if (char.IsWhiteSpace(c) && !inVirgolette) { if (sb.Length > 0) { fuori.Add(sb.ToString()); sb.Clear(); } continue; }
            sb.Append(c);
        }
        if (sb.Length > 0) fuori.Add(sb.ToString());
        return fuori;
    }

    // ---- GENERAREPORT: il server FastReport genera il PDF, qui si salva su file ----
    public static async Task GeneraReport(Contesto ctx, Step step)
    {
        // dal percorso legacy (X:\report\X.fr3) al server serve solo il nome
        var nomeReport = Path.GetFileName(ctx.S(step.P("NomeReport")));
        var dest = ctx.S(step.P("NomeFileDest"));
        if (nomeReport == "") throw new Exception("GENERAREPORT: NomeReport mancante");
        if (dest == "") throw new Exception("GENERAREPORT: NomeFileDest mancante");
        var parametri = Sostituzioni.ParametriDaStringa(ctx.S(step.P("Parametri")));
        var q = new List<string> { "report=" + Uri.EscapeDataString(nomeReport), "format=" + Uri.EscapeDataString(step.P("Formato", "PDF")) };
        q.AddRange(parametri.Select(kv => Uri.EscapeDataString(kv.Key) + "=" + Uri.EscapeDataString(kv.Value)));
        var url = ctx.O.FastReportUrl + (ctx.O.FastReportUrl.Contains('?') ? "&" : "?") + string.Join("&", q);

        using var risposta = await Http.GetAsync(url);
        if (!risposta.IsSuccessStatusCode) throw new Exception($"GENERAREPORT: HTTP {(int)risposta.StatusCode} {risposta.ReasonPhrase} su {url}");
        var bytes = await risposta.Content.ReadAsByteArrayAsync();
        if (bytes.Length < 5 || Encoding.ASCII.GetString(bytes, 0, 4) != "%PDF")
            await ctx.Scrivi("WARN", $"GENERAREPORT: la risposta non sembra un PDF ({bytes.Length} byte) - {url}", step.IdStep);
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        await File.WriteAllBytesAsync(dest, bytes);
        await ctx.Scrivi("INFO", $"GENERAREPORT: {nomeReport} -> {dest} ({bytes.Length} byte)", step.IdStep);
    }

    // ---- APRIMAIL: una mail. Nel legacy "apriva" il client di posta; qui con
    // InviaDirettamente=1 si spedisce via SMTP (quello dello step, o il relay di
    // LISTA_VALORI), altrimenti si registra soltanto. ----
    public static async Task ApriMail(Contesto ctx, Step step)
    {
        var a = Indirizzi(ctx.S(step.P("Destintatario") ?? step.P("Destinatario")));
        var cc = Indirizzi(ctx.S(step.P("DestinatarioCC")));
        var ccn = Indirizzi(ctx.S(step.P("DestinatarioCCN")));
        var oggetto = ctx.S(step.P("Oggetto") ?? step.P("TestoEMail"));
        var corpo = ctx.S(step.P("CorpoMessaggio") ?? step.P("TestoEMail"));
        var allegati = (ctx.S(step.P("Allegati") ?? step.P("FileAllegato") ?? step.P("Allegato")))
            .Split(new[] { ';', ',' }, StringSplitOptions.RemoveEmptyEntries).Select(x => x.Trim()).Where(x => x != "").ToList();
        if (a.Count == 0) throw new Exception("APRIMAIL: Destinatario mancante");
        if (!step.Flag("InviaDirettamente", false))
        {
            await ctx.Scrivi("WARN", $"APRIMAIL: InviaDirettamente=0, mail non spedita (a {string.Join(", ", a)}: \"{Taglia(oggetto, 80)}\")", step.IdStep);
            return;
        }

        var msg = new MimeMessage();
        var mittente = ctx.S(step.P("MittenteSMTP"));
        // l'SMTP scritto nello step vale se c'e' il server; altrimenti quello centrale di Lista Valori (SMTP_SERVER)
        string server = ctx.S(step.P("ServerSMTP")); int porta = int.TryParse(step.P("PortaSMTP"), out var pp) ? pp : 25;
        string? utente = step.P("UserSMTP"), password = step.P("PasswordSMTP");
        var origine = "dello step";
        if (server == "" && ctx.O.SmtpDaListaValori)
        {
            var lv = (await ctx.Cn.QueryAsync("SELECT Valore, Codice FROM dbo.LISTA_VALORI WHERE Lista = 'SMTP_SERVER'"))
                .ToDictionary(r => (string)r.Valore, r => (string?)r.Codice, StringComparer.OrdinalIgnoreCase);
            server = (lv.GetValueOrDefault("SERVER") ?? "").Trim();
            porta = int.TryParse(lv.GetValueOrDefault("PORT"), out var lp) ? lp : porta;
            utente = lv.GetValueOrDefault("USER"); password = lv.GetValueOrDefault("PASS");
            if (mittente == "") mittente = utente ?? "";
            origine = "da Lista Valori";
        }
        if (server == "") throw new Exception("APRIMAIL: ServerSMTP mancante nello step" + (ctx.O.SmtpDaListaValori ? " e SMTP_SERVER vuoto in Lista Valori" : " (SmtpDaListaValori e' spento)"));
        msg.From.Add(MailboxAddress.Parse(mittente != "" ? mittente : "noreply@speedyworld.it"));

        var prova = ctx.O.MailSoloA;
        if (!string.IsNullOrWhiteSpace(prova))
        {
            msg.To.Add(MailboxAddress.Parse(prova.Trim()));
            corpo = $"[PROVA - destinatari veri: {string.Join(", ", a)}{(cc.Count > 0 ? "; cc " + string.Join(", ", cc) : "")}]\r\n\r\n" + corpo;
            oggetto = "[PROVA] " + oggetto;
        }
        else
        {
            foreach (var x in a) msg.To.Add(MailboxAddress.Parse(x));
            foreach (var x in cc) msg.Cc.Add(MailboxAddress.Parse(x));
            foreach (var x in ccn) msg.Bcc.Add(MailboxAddress.Parse(x));
        }
        msg.Subject = oggetto;
        var contenuto = new BodyBuilder { TextBody = corpo };
        foreach (var f in allegati)
        {
            if (File.Exists(f)) contenuto.Attachments.Add(f);
            else await ctx.Scrivi("WARN", $"APRIMAIL: allegato non trovato {f}", step.IdStep);
        }
        msg.Body = contenuto.ToMessageBody();

        using var smtp = new SmtpClient();
        await smtp.ConnectAsync(server, porta, porta == 465 ? SecureSocketOptions.SslOnConnect : SecureSocketOptions.StartTlsWhenAvailable);
        if (!string.IsNullOrEmpty(utente)) await smtp.AuthenticateAsync(utente, password ?? "");
        await smtp.SendAsync(msg);
        await smtp.DisconnectAsync(true);
        await ctx.Scrivi("INFO", $"APRIMAIL: spedita a {string.Join(", ", msg.To.Mailboxes.Select(m => m.Address))} via {server} ({origine}): \"{Taglia(oggetto, 80)}\"", step.IdStep);
    }

    static List<string> Indirizzi(string s) =>
        s.Split(new[] { ';', ',' }, StringSplitOptions.RemoveEmptyEntries).Select(x => x.Trim()).Where(x => x.Contains('@')).ToList();

    // ---- IMPORTTXT: file di testo in tabella. Semantica ricavata dai workflow
    // veri: NomeFileInput con jolly, una riga per record, Separatore vuoto = tutta
    // la riga in un campo (NomeCampi), NomeCampoFile prende il nome del file,
    // SvuotaTabella prima di partire, RicreaTabella la butta e la rifa',
    // AlTermineSpostaFileIn sposta i file letti in quella sottocartella. ----
    public static async Task ImportTxt(Contesto ctx, Step step)
    {
        var maschera = ctx.S(step.P("NomeFileInput"));
        var tabella = ctx.S(step.P("TabellaDestinazione"));
        if (maschera == "" || tabella == "") throw new Exception("IMPORTTXT: NomeFileInput/TabellaDestinazione mancante");
        if (!System.Text.RegularExpressions.Regex.IsMatch(tabella, @"^[\w.\[\]]+$")) throw new Exception($"IMPORTTXT: nome tabella non valido: {tabella}");
        var campi = (step.P("NomeCampi") ?? "Riga").Split(',').Select(c => c.Trim()).Where(c => c != "").ToList();
        var campoFile = step.P("NomeCampoFile")?.Trim();
        var campoId = step.P("NomeCampoAutoIncrementale")?.Trim();
        var separatore = step.P("Separatore") ?? "";
        var aCampiFissi = step.P("Modalita", "Separatore").Equals("CampiFissi", StringComparison.OrdinalIgnoreCase);
        var fissi = aCampiFissi ? step.Lista("campiFissi") : new();
        var interrompi = step.Flag("InterrompiSuErrore", true);
        var spostaIn = ctx.S(step.P("AlTermineSpostaFileIn"));

        var cartella = Path.GetDirectoryName(maschera) ?? ".";
        var file = Directory.Exists(cartella) ? Directory.GetFiles(cartella, Path.GetFileName(maschera)).OrderBy(f => f).ToList() : new List<string>();

        // la tabella: rifatta, creata se manca, svuotata
        var esiste = await ctx.Cn.ExecuteScalarAsync<int?>("SELECT OBJECT_ID(@t, 'U')", new { t = tabella }) is not null;
        if (step.Flag("RicreaTabella", false) && esiste)
        {
            await ctx.Cn.ExecuteAsync($"DROP TABLE {tabella}");
            esiste = false;
        }
        if (!esiste)
        {
            var colonne = new List<string>();
            if (!string.IsNullOrEmpty(campoId)) colonne.Add($"[{campoId}] INT IDENTITY(1,1) PRIMARY KEY");
            colonne.AddRange(campi.Select(c => $"[{c}] NVARCHAR(MAX) NULL"));
            if (!string.IsNullOrEmpty(campoFile)) colonne.Add($"[{campoFile}] NVARCHAR(260) NULL");
            await ctx.Cn.ExecuteAsync($"CREATE TABLE {tabella} ({string.Join(", ", colonne)})");
            await ctx.Scrivi("WARN", $"IMPORTTXT: tabella {tabella} creata ({string.Join(", ", campi)})", step.IdStep);
        }
        else if (step.Flag("SvuotaTabella", false))
        {
            var tolte = await ctx.Cn.ExecuteAsync($"DELETE FROM {tabella}");
            await ctx.Scrivi("INFO", $"IMPORTTXT: tabella {tabella} svuotata ({tolte} righe)", step.IdStep, tolte);
        }
        if (file.Count == 0)
        {
            await ctx.Scrivi("WARN", $"IMPORTTXT: nessun file per {maschera}", step.IdStep);
            return;
        }

        var totale = 0;
        foreach (var f in file)
        {
            try
            {
                var dt = new DataTable();
                foreach (var c in campi) dt.Columns.Add(c, typeof(string));
                if (!string.IsNullOrEmpty(campoFile)) dt.Columns.Add(campoFile, typeof(string));
                var nomeFile = Path.GetFileName(f);
                var testo = Query.Ansi.GetString(await File.ReadAllBytesAsync(f)).Replace("\r\n", "\n").Replace('\r', '\n');
                var linee = testo.Split('\n');
                if (linee.Length > 0 && linee[^1] == "") linee = linee[..^1];   // la riga vuota finale non e' un record
                var n = 0;
                foreach (var linea in linee)
                {
                    var valori = aCampiFissi
                        ? Fissi(linea, fissi)
                        : separatore == "" ? new[] { linea } : linea.Split(separatore);
                    if (valori.Length < campi.Count && interrompi)
                        throw new Exception($"riga {n + 1} di {nomeFile}: {valori.Length} campi invece di {campi.Count}");
                    var r = dt.NewRow();
                    for (var i = 0; i < campi.Count; i++) r[i] = i < valori.Length ? valori[i] : "";
                    if (!string.IsNullOrEmpty(campoFile)) r[campoFile] = nomeFile;
                    dt.Rows.Add(r); n++;
                }
                using (var bulk = new SqlBulkCopy(ctx.Cn) { DestinationTableName = tabella, BulkCopyTimeout = ctx.O.TimeoutQuerySecondi })
                {
                    foreach (DataColumn c in dt.Columns) bulk.ColumnMappings.Add(c.ColumnName, c.ColumnName);
                    await bulk.WriteToServerAsync(dt);
                }
                totale += n;
                await ctx.Scrivi("INFO", $"IMPORTTXT: {nomeFile} -> {n} righe in {tabella}", step.IdStep, n);
                if (spostaIn != "")
                {
                    var dest = Path.IsPathRooted(spostaIn) ? spostaIn : Path.Combine(cartella, spostaIn);
                    Directory.CreateDirectory(dest);
                    var destFile = Path.Combine(dest, nomeFile);
                    if (File.Exists(destFile)) destFile = Path.Combine(dest, $"{Path.GetFileNameWithoutExtension(nomeFile)}_{DateTime.Now:yyyyMMdd_HHmmss}{Path.GetExtension(nomeFile)}");
                    File.Move(f, destFile);
                }
            }
            catch (Exception ex) when (!interrompi)
            {
                await ctx.Scrivi("ERRORE", $"IMPORTTXT: {Path.GetFileName(f)} saltato: {ex.Message}", step.IdStep);
            }
        }
        await ctx.Scrivi("INFO", $"IMPORTTXT: {file.Count} file, {totale} righe in {tabella}", step.IdStep, totale);
    }

    static string[] Fissi(string linea, List<Dictionary<string, string>> campi)
    {
        var fuori = new List<string>(); var pos = 0;
        foreach (var c in campi)
        {
            var dim = int.TryParse(c.GetValueOrDefault("Dimensione"), out var d) ? d : 0;
            fuori.Add(pos < linea.Length ? linea.Substring(pos, Math.Min(dim, linea.Length - pos)).Trim() : "");
            pos += dim;
        }
        return fuori.ToArray();
    }

    static string Taglia(string s, int n) => s.Length <= n ? s : s[..n] + "…";

    // per il log: un percorso resta com'e', una query scritta nello step si riduce alla prima riga utile
    static string Riassunto(string spec)
    {
        if (!spec.Contains('\n')) return Taglia(spec, 200);
        var prima = spec.Split('\n').Select(r => r.Trim()).FirstOrDefault(r => r != "" && !r.StartsWith("--")) ?? spec.Split('\n')[0];
        return Taglia(prima, 120) + " …";
    }
}
