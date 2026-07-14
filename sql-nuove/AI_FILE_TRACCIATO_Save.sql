-- Upsert generato dallo schema di [FILE_TRACCIATO]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_FILE_TRACCIATO_Save
    @IdTracciato int = NULL,
    @Tracciato varchar(50) = NULL,
    @IdUtente int = NULL,
    @IdCliente int = NULL,
    @Separatore varchar(50) = NULL,
    @ColonneTotali int = NULL,
    @infoTracciato varchar(250) = NULL,
    @RigheIntestazione int = NULL,
    @RigheFooter int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdTracciato IS NULL OR @IdTracciato = 0
    BEGIN
        INSERT INTO [FILE_TRACCIATO] ([Tracciato], [IdUtente], [IdCliente], [Separatore], [ColonneTotali], [infoTracciato], [RigheIntestazione], [RigheFooter])
        VALUES (@Tracciato, @IdUtente, @IdCliente, @Separatore, @ColonneTotali, @infoTracciato, @RigheIntestazione, @RigheFooter);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [FILE_TRACCIATO] SET
            [Tracciato] = @Tracciato,
            [IdUtente] = @IdUtente,
            [IdCliente] = @IdCliente,
            [Separatore] = @Separatore,
            [ColonneTotali] = @ColonneTotali,
            [infoTracciato] = @infoTracciato,
            [RigheIntestazione] = @RigheIntestazione,
            [RigheFooter] = @RigheFooter
        WHERE [IdTracciato] = @IdTracciato;
        SELECT @IdTracciato AS id;
    END
END
