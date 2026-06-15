-- Upsert generato dallo schema di [INTERROGAZIONI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_INTERROGAZIONI_Save
    @IdQuery int = NULL,
    @Titolo varchar(500) = NULL,
    @Descrizione varchar(5000) = NULL,
    @Query varchar(5000) = NULL,
    @SqlSelect varchar(5000) = NULL,
    @SqlFrom varchar(5000) = NULL,
    @SqlWhere varchar(5000) = NULL,
    @SqlGroup varchar(5000) = NULL,
    @SqlOrder varchar(5000) = NULL,
    @Alias varchar(5000) = NULL,
    @Visibilita int = NULL,
    @Parametri varchar(250) = NULL,
    @CanSee varchar(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdQuery IS NULL OR @IdQuery = 0
    BEGIN
        INSERT INTO [INTERROGAZIONI] ([Titolo], [Descrizione], [Query], [SqlSelect], [SqlFrom], [SqlWhere], [SqlGroup], [SqlOrder], [Alias], [Visibilita], [Parametri], [CanSee])
        VALUES (@Titolo, @Descrizione, @Query, @SqlSelect, @SqlFrom, @SqlWhere, @SqlGroup, @SqlOrder, @Alias, @Visibilita, @Parametri, @CanSee);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [INTERROGAZIONI] SET
            [Titolo] = @Titolo,
            [Descrizione] = @Descrizione,
            [Query] = @Query,
            [SqlSelect] = @SqlSelect,
            [SqlFrom] = @SqlFrom,
            [SqlWhere] = @SqlWhere,
            [SqlGroup] = @SqlGroup,
            [SqlOrder] = @SqlOrder,
            [Alias] = @Alias,
            [Visibilita] = @Visibilita,
            [Parametri] = @Parametri,
            [CanSee] = @CanSee
        WHERE [IdQuery] = @IdQuery;
        SELECT @IdQuery AS id;
    END
END

