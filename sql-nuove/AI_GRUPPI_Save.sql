-- Upsert generato dallo schema di [GRUPPI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_GRUPPI_Save
    @IdGruppo int = NULL,
    @Gruppo varchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdGruppo IS NULL OR @IdGruppo = 0
    BEGIN
        INSERT INTO [GRUPPI] ([Gruppo])
        VALUES (@Gruppo);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [GRUPPI] SET
            [Gruppo] = @Gruppo
        WHERE [IdGruppo] = @IdGruppo;
        SELECT @IdGruppo AS id;
    END
END

