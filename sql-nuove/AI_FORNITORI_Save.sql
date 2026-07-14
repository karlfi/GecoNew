-- Upsert generato dallo schema di [FORNITORI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_FORNITORI_Save
    @ID int = NULL,
    @Fornitore varchar(255) = NULL,
    @Tipo int = NULL,
    @CPCODICE varchar(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @ID IS NULL OR @ID = 0
    BEGIN
        INSERT INTO [FORNITORI] ([Fornitore], [Tipo], [CPCODICE])
        VALUES (@Fornitore, @Tipo, @CPCODICE);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [FORNITORI] SET
            [Fornitore] = @Fornitore,
            [Tipo] = @Tipo,
            [CPCODICE] = @CPCODICE
        WHERE [ID] = @ID;
        SELECT @ID AS id;
    END
END
