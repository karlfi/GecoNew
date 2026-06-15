-- Upsert generato dallo schema di [SPED_WORKFLOW]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_SPED_WORKFLOW_Save
    @IdWorkflow int = NULL,
    @IdAzione int = NULL,
    @Stato_Inizio varchar(50) = NULL,
    @Stato_Fine varchar(50) = NULL,
    @GiorniSLA int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdWorkflow IS NULL OR @IdWorkflow = 0
    BEGIN
        INSERT INTO [SPED_WORKFLOW] ([IdAzione], [Stato_Inizio], [Stato_Fine], [GiorniSLA])
        VALUES (@IdAzione, @Stato_Inizio, @Stato_Fine, @GiorniSLA);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [SPED_WORKFLOW] SET
            [IdAzione] = @IdAzione,
            [Stato_Inizio] = @Stato_Inizio,
            [Stato_Fine] = @Stato_Fine,
            [GiorniSLA] = @GiorniSLA
        WHERE [IdWorkflow] = @IdWorkflow;
        SELECT @IdWorkflow AS id;
    END
END

