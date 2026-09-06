using System.Runtime.InteropServices;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GecoMotore;

// Le condivisioni di rete dei workflow (es. \\192.168.0.252\...): un servizio
// non ha unita' mappate ne' credenziali sue, quindi la sessione SMB si apre qui
// con utente e password presi da LISTA_VALORI, Lista = 'SMB_SERVER' (piu' server:
// SMB_SERVER_2, SMB_SERVER_3 ...), righe Valore/Codice: SERVER, USER, PASS.
// Stessa forma di SMTP_SERVER, modificabile dalla pagina Lista Valori.
public static class Condivisioni
{
    static readonly Dictionary<string, string> stato = new(StringComparer.OrdinalIgnoreCase);   // server -> esito, per loggare solo i cambi

    public static async Task Apri(Opzioni o, ILogger log)
    {
        List<dynamic> righe;
        await using (var cn = new SqlConnection(o.ConnString))
            righe = (await cn.QueryAsync("SELECT Lista, Valore, Codice FROM dbo.LISTA_VALORI WHERE Lista LIKE 'SMB[_]SERVER%'")).ToList();
        foreach (var g in righe.GroupBy(r => (string)r.Lista))
        {
            var v = g.ToDictionary(r => ((string)r.Valore).Trim(), r => ((string?)r.Codice)?.Trim() ?? "", StringComparer.OrdinalIgnoreCase);
            // SERVER puo' essere solo l'host (192.168.0.252) o un percorso UNC
            // (\\192.168.0.252\Flussi\...): la sessione si apre sull'host, o
            // sulla share se e' indicata
            var pezzi = (v.GetValueOrDefault("SERVER") ?? "").Trim().Trim('\\', '/').Split(new[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
            if (pezzi.Length == 0) continue;
            var risorsa = pezzi.Length >= 2 ? $"\\\\{pezzi[0]}\\{pezzi[1]}" : $"\\\\{pezzi[0]}\\IPC$";
            var utente = v.GetValueOrDefault("USER");
            if (string.IsNullOrWhiteSpace(utente)) utente = null;
            if (!string.IsNullOrEmpty(v.GetValueOrDefault("DOMAIN")) && utente is not null && !utente.Contains('\\'))
                utente = v["DOMAIN"] + "\\" + utente;
            var esito = Connetti(risorsa, utente, v.GetValueOrDefault("PASS"));
            lock (stato)
            {
                if (stato.TryGetValue(risorsa, out var prima) && prima == esito) continue;
                stato[risorsa] = esito;
            }
            if (esito == "ok") log.LogInformation("Condivisione {r}: sessione aperta come {u} ({l})", risorsa, utente ?? "(senza credenziali)", g.Key);
            else log.LogWarning("Condivisione {r} ({l}): {e}", risorsa, g.Key, esito);
        }
    }

    // sessione verso \\server\IPC$ (o \\server\share): da quel momento i percorsi
    // su quel server sono raggiungibili con quelle credenziali
    static string Connetti(string risorsa, string? utente, string? password)
    {
        var ris = new NETRESOURCE { dwType = 1 /* disk */, lpRemoteName = risorsa };
        var codice = WNetAddConnection2(ref ris, password, utente, 0);
        return codice switch
        {
            0 => "ok",
            85 => "ok",      // ERROR_ALREADY_ASSIGNED
            1219 => "ok",    // ERROR_SESSION_CREDENTIAL_CONFLICT: c'e' gia' una sessione con altre credenziali, si usa quella
            1326 => "utente o password errati (1326)",
            5 => "accesso negato (5): utente valido ma senza permessi sulla share",
            53 => "server non trovato (53)",
            67 => "share inesistente (67)",
            _ => $"errore {codice}: {new System.ComponentModel.Win32Exception(codice).Message}",
        };
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NETRESOURCE
    {
        public int dwScope, dwType, dwDisplayType, dwUsage;
        public string? lpLocalName, lpRemoteName, lpComment, lpProvider;
    }

    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    static extern int WNetAddConnection2(ref NETRESOURCE netResource, string? password, string? username, int flags);
}
