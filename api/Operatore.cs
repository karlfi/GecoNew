using System.Data;
using System.Security.Claims;
using Microsoft.Data.SqlClient;

// Chi scrive, per lo storico delle modifiche. I trigger di storico (TR_INSUP_*, TR_DEL_UTENTI,
// TR_UP_UTENTIATTIVITA -> LogTabelle) mettono in Operatore dbo.AI_Operatore(): il SESSION_CONTEXT
// 'Operatore' della connessione se c'e', altrimenti il login SQL, che per l'API e' sempre lo stesso
// (sql-nuove/LogTabelle_operatore.sql). Tutte le connessioni dell'API nascono qui e a ogni apertura
// (anche quella che Dapper fa da solo su una connessione chiusa) dichiarano il login dell'utente del
// portale che ha fatto la richiesta. Il pool azzera il contesto quando ripassa una connessione, quindi
// nessuno eredita l'utente di un altro. Senza utente (login, chiamate anonime) non si dichiara niente.
static class Operatore
{
    static readonly AsyncLocal<string?> utente = new();

    // middleware, dopo l'autenticazione: l'utente segue tutto il flusso async della richiesta
    public static void DaRichiesta(ClaimsPrincipal user) =>
        utente.Value = user.Identity?.IsAuthenticated == true ? user.FindFirstValue(ClaimTypes.Name) : null;

    public static SqlConnection Connessione(string connString)
    {
        var cn = new SqlConnection(connString);
        var chi = utente.Value;
        if (!string.IsNullOrEmpty(chi))
            cn.StateChange += (_, e) =>
            {
                if (e.CurrentState != ConnectionState.Open) return;
                using var cmd = cn.CreateCommand();
                cmd.CommandText = "EXEC sys.sp_set_session_context @key = N'Operatore', @value = @chi";
                cmd.Parameters.Add(new SqlParameter("@chi", SqlDbType.NVarChar, 100) { Value = chi });
                cmd.ExecuteNonQuery();
            };
        return cn;
    }
}
