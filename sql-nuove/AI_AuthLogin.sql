-- =============================================================
-- AI_AuthLogin — login per la nuova webapp
-- Verifica la password SERVER-SIDE (equivalente di SimpleCrypter.MD5
-- dell'app InDe: if passDB == MD5(pass)) e non restituisce MAI
-- password o hash al chiamante.
--
-- Esiti (prima colonna del primo result set):
--   0 = OK (seguono profilo utente + result set gruppi)
--   1 = credenziali non valide (utente inesistente, disattivato o pwd errata)
--   2 = utente bloccato per troppi tentativi
--   3 = utente solo-palmare (nessuna password web): accesso web negato
--
-- Convenzione: prefisso AI_ per tutte le SP della nuova webapp.
-- =============================================================
CREATE PROCEDURE dbo.AI_AuthLogin
    @Utente    varchar(100),
    @Pwd       varchar(250),
    @MaxErrori int = 10          -- soglia di blocco: allineare a quella dell'app InDe
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IdUtente int, @PassDB varchar(50), @LoginErrors int;

    SELECT @IdUtente    = u.IdUtente,
           @PassDB      = u.Pass,
           @LoginErrors = ISNULL(u.LoginErrors, 0)
    FROM dbo.UTENTI u
    WHERE u.Utente = @Utente
      AND u.DataFine IS NULL;          -- stesso criterio di "utente attivo" di LogInCSO

    -- Utente inesistente o disattivato: esito generico, non riveliamo quale dei due
    IF @IdUtente IS NULL
    BEGIN
        SELECT 1 AS Esito;
        RETURN;
    END

    -- Utente solo-palmare (password vuota): mai ammesso dal web
    IF @PassDB IS NULL OR @PassDB = ''
    BEGIN
        SELECT 3 AS Esito;
        RETURN;
    END

    -- Bloccato per troppi tentativi falliti
    IF @LoginErrors >= @MaxErrori
    BEGIN
        SELECT 2 AS Esito;
        RETURN;
    END

    -- Confronto MD5 server-side. CONVERT(...,2) = hex senza prefisso '0x' (maiuscolo).
    -- NB: HASHBYTES su varchar lavora sulla code page del DB: per password ASCII
    --     (lettere/numeri/simboli comuni) e' identico all'MD5(UTF8) di .NET.
    --     Se esistono password con caratteri accentati, verificare un caso reale.
    IF UPPER(@PassDB) <> CONVERT(char(32), HASHBYTES('MD5', @Pwd), 2)
    BEGIN
        -- Il trigger TR_UP_UTENTI ignora gli update di soli LoginErrors/DataUltimoAccesso:
        -- niente spam in LogTabelle.
        UPDATE dbo.UTENTI
        SET LoginErrors = ISNULL(LoginErrors, 0) + 1
        WHERE IdUtente = @IdUtente;

        SELECT 1 AS Esito;
        RETURN;
    END

    -- Successo: azzero i tentativi e registro l'accesso
    UPDATE dbo.UTENTI
    SET LoginErrors = 0,
        DataUltimoAccesso = GETDATE()
    WHERE IdUtente = @IdUtente;

    -- Result set 1: esito + profilo per costruire il JWT (MAI Pass o hash)
    SELECT 0 AS Esito,
           u.IdUtente, u.Utente, u.Nome, u.Email,
           u.IdRuolo, r.Ruolo,
           u.IdFiliale, u.IdCliente, u.IdUtentePadre
    FROM dbo.UTENTI u
    LEFT JOIN dbo.RUOLI r ON r.IdRuolo = u.IdRuolo
    WHERE u.IdUtente = @IdUtente;

    -- Result set 2: gruppi dell'utente (per i claims di autorizzazione)
    SELECT g.IdGruppo, g.Gruppo
    FROM dbo.UTENTI_GRUPPI ug
    JOIN dbo.GRUPPI g ON g.IdGruppo = ug.IdGruppo
    WHERE ug.IdUtente = @IdUtente;
END

