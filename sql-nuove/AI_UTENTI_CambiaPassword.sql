-- =============================================================
-- AI_UTENTI_CambiaPassword — cambio password dalla pagina "Il mio profilo".
-- Verifica la vecchia password SERVER-SIDE (stesso MD5 di AI_AuthLogin) e
-- salva la nuova; non restituisce mai hash al chiamante.
--
-- Esiti: 0 = OK, 1 = vecchia password errata, 2 = utente non valido,
--        3 = nuova password troppo corta (min 6)
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_CambiaPassword
    @IdUtente    int,
    @VecchiaPwd  varchar(250),
    @NuovaPwd    varchar(250)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PassDB varchar(50);
    SELECT @PassDB = u.Pass
    FROM dbo.UTENTI u
    WHERE u.IdUtente = @IdUtente AND u.DataFine IS NULL;

    IF @PassDB IS NULL OR @PassDB = ''
    BEGIN
        SELECT 2 AS Esito;
        RETURN;
    END

    IF LEN(ISNULL(@NuovaPwd, '')) < 6
    BEGIN
        SELECT 3 AS Esito;
        RETURN;
    END

    IF UPPER(@PassDB) <> CONVERT(char(32), HASHBYTES('MD5', @VecchiaPwd), 2)
    BEGIN
        SELECT 1 AS Esito;
        RETURN;
    END

    UPDATE dbo.UTENTI
    SET Pass = CONVERT(char(32), HASHBYTES('MD5', @NuovaPwd), 2),
        LoginErrors = 0
    WHERE IdUtente = @IdUtente;

    SELECT 0 AS Esito;
END
