-- =============================================================
-- AI_UTENTI_Del — cancella una scheda utente, ma solo se non ha lasciato
-- traccia da nessuna parte.
--
-- Serve per le schede nate per sbaglio (una doppia, una prova) e cancellarle
-- e' l'unico modo di farle sparire dagli elenchi. E' irreversibile, quindi si
-- rifiuta se qualsiasi tabella del database fa riferimento a quell'IdUtente
-- (giornate di presenza, mezzi, gruppi, profili...) o se l'utente e' mai
-- entrato nell'applicazione. LOG_CALL non conta: e' solo il registro delle
-- pagine aperte.
--
-- Con @Conferma = 0 (default) non cancella: dice solo se si potrebbe e, se no,
-- dove sta la traccia che lo impedisce.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_Del
    @IdUtente int,
    @Conferma bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.UTENTI WHERE IdUtente = @IdUtente)
    BEGIN
        RAISERROR('Utente %d inesistente', 16, 1, @IdUtente);
        RETURN;
    END

    -- tutte le colonne del database che si chiamano IdUtente, tranne quelle
    -- della scheda stessa e del registro delle pagine
    DECLARE @tracce TABLE (Tabella sysname, Righe int);
    DECLARE @t sysname, @c sysname, @sql nvarchar(max), @n int;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT c.TABLE_NAME, c.COLUMN_NAME
        FROM INFORMATION_SCHEMA.COLUMNS c
        JOIN INFORMATION_SCHEMA.TABLES t ON t.TABLE_NAME = c.TABLE_NAME AND t.TABLE_TYPE = 'BASE TABLE'
        WHERE c.COLUMN_NAME = 'IdUtente' AND c.TABLE_NAME NOT IN ('UTENTI', 'LOG_CALL');
    OPEN cur;
    FETCH NEXT FROM cur INTO @t, @c;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'SELECT @n = COUNT(*) FROM ' + QUOTENAME(@t) + N' WHERE ' + QUOTENAME(@c) + N' = @id';
        EXEC sp_executesql @sql, N'@id int, @n int OUTPUT', @id = @IdUtente, @n = @n OUTPUT;
        IF @n > 0 INSERT INTO @tracce VALUES (@t, @n);
        FETCH NEXT FROM cur INTO @t, @c;
    END
    CLOSE cur; DEALLOCATE cur;

    IF EXISTS (SELECT 1 FROM dbo.UTENTI WHERE IdUtente = @IdUtente AND DataUltimoAccesso IS NOT NULL)
        INSERT INTO @tracce VALUES ('UTENTI.DataUltimoAccesso (e'' entrato nell''applicazione)', 1);

    IF EXISTS (SELECT 1 FROM @tracce)
    BEGIN
        SELECT 0 AS Cancellabile, Tabella, Righe FROM @tracce;
        RETURN;
    END

    IF @Conferma = 1
        DELETE FROM dbo.UTENTI WHERE IdUtente = @IdUtente;

    SELECT 1 AS Cancellabile, CASE WHEN @Conferma = 1 THEN 'cancellata' ELSE 'si puo'' cancellare' END AS Tabella, 0 AS Righe;
END
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.AI_UTENTI_Del TO claude');
GO
