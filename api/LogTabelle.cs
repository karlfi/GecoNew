using Dapper;
using Microsoft.Data.SqlClient;

// Storico delle modifiche a una riga: i trigger TR_INSUP_* scrivono in
// LOGTabelle una riga per ogni cambiamento, con dentro l'XML della riga COME
// E' RIMASTA (non com'era prima). Quello che e' cambiato si ricava dal
// confronto con la fotografia precedente; la prima riga di log non ha un
// prima, ed esce senza dettaglio. Lo usano le schede utente e mezzo.
static class LogTabelle
{
    // nascosti: campi che non si mostrano mai in chiaro (es. la password), si dice solo che sono cambiati
    public static async Task<List<object>> Modifiche(SqlConnection cn, string tabella, int id, string[]? nascosti = null)
    {
        var righe = (await cn.QueryAsync<LogRiga>(@"
            SELECT Id, Data, Operatore, TipoOperazione, CONVERT(varchar(max), Record) AS Xml
            FROM LOGTabelle WHERE Tabella = @tabella AND IdTabella = @id ORDER BY Id", new { tabella, id })).ToList();
        var segreti = new HashSet<string>(nascosti ?? Array.Empty<string>(), StringComparer.OrdinalIgnoreCase);
        // Operatore: il login dell'utente del portale (Operatore.cs), che si mostra col nome dell'utente quando quel
        // login e' di un utente solo; prima c'era sempre il login SQL dell'applicazione
        var logins = righe.Select(r => r.Operatore).Where(o => !string.IsNullOrEmpty(o)).Distinct().ToList();
        var nomi = logins.Count == 0 ? new Dictionary<string, string>() : (await cn.QueryAsync<(string Utente, string Nome)>(@"
            SELECT Utente, MIN(Nome) FROM UTENTI WHERE Utente IN @logins AND Nome > ''
            GROUP BY Utente HAVING COUNT(*) = 1", new { logins }))
            .ToDictionary(x => x.Utente, x => x.Nome, StringComparer.OrdinalIgnoreCase);
        var modifiche = new List<object>();
        for (var i = 0; i < righe.Count; i++)
        {
            var dopo = Campi(righe[i].Xml);
            var prima = i > 0 ? Campi(righe[i - 1].Xml) : null;
            var campi = new List<object>();
            if (prima is not null)
            {
                foreach (var k in prima.Keys.Union(dopo.Keys, StringComparer.OrdinalIgnoreCase).OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
                {
                    var a = prima.TryGetValue(k, out var va) ? va : "";
                    var b = dopo.TryGetValue(k, out var vb) ? vb : "";
                    if (a == b) continue;
                    if (segreti.Contains(k)) { campi.Add(new { campo = k, prima = "•••", dopo = "•••" }); continue; }
                    campi.Add(new { campo = k, prima = Leggibile(a), dopo = Leggibile(b) });
                }
            }
            modifiche.Add(new
            {
                id = righe[i].Id,
                data = righe[i].Data,
                operatore = righe[i].Operatore is string op && nomi.TryGetValue(op, out var nome) ? nome : righe[i].Operatore,
                login = righe[i].Operatore,
                tipoOperazione = righe[i].TipoOperazione,
                prima = prima is not null,      // false = e' la prima fotografia, non c'e' un confronto
                campi
            });
        }
        modifiche.Reverse();                    // le piu' recenti in cima
        return modifiche;
    }

    static Dictionary<string, string> Campi(string? xml)
    {
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrWhiteSpace(xml)) return d;
        try
        {
            foreach (var e in System.Xml.Linq.XElement.Parse(xml).Elements())
                d[e.Name.LocalName] = e.Value;
        }
        catch { /* xml illeggibile: si tratta come vuoto */ }
        return d;
    }

    // "2026-06-01T00:00:00" -> "01/06/2026"; "7.5e+001" -> "75"
    static string Leggibile(string v)
    {
        if (string.IsNullOrEmpty(v)) return "";
        if (DateTime.TryParse(v, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var d) && v.Contains('-'))
            return d.TimeOfDay == TimeSpan.Zero ? d.ToString("dd/MM/yyyy") : d.ToString("dd/MM/yyyy HH:mm");
        if (v.Contains('e', StringComparison.OrdinalIgnoreCase)
            && decimal.TryParse(v, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var n))
            return n.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture);
        return v;
    }
}
