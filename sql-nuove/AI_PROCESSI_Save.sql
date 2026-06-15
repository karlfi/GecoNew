-- Upsert generato dallo schema di [PROCESSI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_PROCESSI_Save
    @IdProcesso int = NULL,
    @Processo varchar(50) = NULL,
    @GiorniSLA int = NULL,
    @CodFamiglia varchar(5) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdProcesso IS NULL OR @IdProcesso = 0
    BEGIN
        INSERT INTO [PROCESSI] ([Processo], [GiorniSLA], [CodFamiglia])
        VALUES (@Processo, @GiorniSLA, @CodFamiglia);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [PROCESSI] SET
            [Processo] = @Processo,
            [GiorniSLA] = @GiorniSLA,
            [CodFamiglia] = @CodFamiglia
        WHERE [IdProcesso] = @IdProcesso;
        SELECT @IdProcesso AS id;
    END
END

