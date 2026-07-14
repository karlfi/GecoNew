-- Upsert generato dallo schema di [LISTA_VALORI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_LISTA_VALORI_Save
    @IdListaValori int = NULL,
    @Lista varchar(50) = NULL,
    @Valore varchar(500) = NULL,
    @Codice varchar(50) = NULL,
    @Ordine int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdListaValori IS NULL OR @IdListaValori = 0
    BEGIN
        INSERT INTO [LISTA_VALORI] ([Lista], [Valore], [Codice], [Ordine])
        VALUES (@Lista, @Valore, @Codice, @Ordine);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [LISTA_VALORI] SET
            [Lista] = @Lista,
            [Valore] = @Valore,
            [Codice] = @Codice,
            [Ordine] = @Ordine
        WHERE [IdListaValori] = @IdListaValori;
        SELECT @IdListaValori AS id;
    END
END
