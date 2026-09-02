-- =============================================================
-- AI_UTENTI_Stato_Save - cambia lo stato di archiviazione del dipendente
-- dalla griglia "Elenco Dipendenti".
--
-- I valori ammessi sono solo i quattro usati in azienda; qualsiasi altra cosa
-- viene rifiutata qui, cosi' la colonna non si sporca anche se la chiamata
-- arrivasse da fuori la pagina. Lo stato vuoto e' ammesso: e' la condizione
-- della maggior parte delle schede (non ancora classificate).
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_Stato_Save
    @IdUtente int,
    @Stato varchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @Stato = NULLIF(LTRIM(RTRIM(ISNULL(@Stato, ''))), '');

    IF @Stato IS NOT NULL AND @Stato NOT IN ('SI', 'da archiviare', 'da togliere', 'CESSATO')
    BEGIN
        RAISERROR('Stato "%s" non ammesso: usare SI, da archiviare, da togliere o CESSATO', 16, 1, @Stato);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.UTENTI WHERE IdUtente = @IdUtente)
    BEGIN
        RAISERROR('Utente %d inesistente', 16, 1, @IdUtente);
        RETURN;
    END

    UPDATE dbo.UTENTI SET Stato = @Stato WHERE IdUtente = @IdUtente;

    SELECT @IdUtente AS IdUtente, @Stato AS Stato;
END
GO
-- il grant serve solo dove esiste l'utente "claude" (vecchio server): su BLUE
-- l'applicazione entra con twebaccount, che e' dbo e non ne ha bisogno
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.AI_UTENTI_Stato_Save TO claude');
GO
