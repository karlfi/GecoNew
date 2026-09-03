-- =============================================================
-- AI_MEZZI_AssegnaDriver — sposta un mezzo da un driver a un altro.
--
-- Serve quando lo stesso dipendente ha due schede (un rapporto chiuso e uno
-- nuovo) e il mezzo e' rimasto agganciato a quella sbagliata: il palmare e le
-- giornate di presenza guardano MEZZI.IdUtente, quindi il mezzo deve stare
-- sulla scheda attiva. Con @IdUtente NULL il mezzo resta senza driver.
-- Restituisce com'era e com'e', cosi' chi lo lancia vede cosa ha spostato.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_MEZZI_AssegnaDriver
    @IdMezzo  int,
    @IdUtente int = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.MEZZI WHERE IdMezzo = @IdMezzo)
    BEGIN
        RAISERROR('Mezzo %d inesistente', 16, 1, @IdMezzo);
        RETURN;
    END
    IF @IdUtente IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.UTENTI WHERE IdUtente = @IdUtente)
    BEGIN
        RAISERROR('Utente %d inesistente', 16, 1, @IdUtente);
        RETURN;
    END

    DECLARE @Prima int;
    SELECT @Prima = IdUtente FROM dbo.MEZZI WHERE IdMezzo = @IdMezzo;

    UPDATE dbo.MEZZI SET IdUtente = @IdUtente WHERE IdMezzo = @IdMezzo;

    SELECT m.IdMezzo, m.Targa, @Prima AS DriverPrima, m.IdUtente AS DriverDopo, u.Nome AS NomeDopo
    FROM dbo.MEZZI m LEFT JOIN dbo.UTENTI u ON u.IdUtente = m.IdUtente
    WHERE m.IdMezzo = @IdMezzo;
END
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.AI_MEZZI_AssegnaDriver TO claude');
GO
