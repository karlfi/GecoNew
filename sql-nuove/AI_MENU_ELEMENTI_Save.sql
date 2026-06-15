-- Upsert generato dallo schema di [MENU_ELEMENTI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_MENU_ELEMENTI_Save
    @IdMenuElemento int = NULL,
    @ParentID int = NULL,
    @Text varchar(255) = NULL,
    @Descrizione varchar(255) = NULL,
    @Videata varchar(50) = NULL,
    @Link varchar(4000) = NULL,
    @Parametri varchar(max) = NULL,
    @NavigateUrl varchar(255) = NULL,
    @Sorting int = NULL,
    @ToolTip varchar(250) = NULL,
    @Disabled int = NULL,
    @Icon varchar(250) = NULL,
    @Popup int = NULL,
    @CodFamiglia varchar(1) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdMenuElemento IS NULL OR @IdMenuElemento = 0
    BEGIN
        INSERT INTO [MENU_ELEMENTI] ([ParentID], [Text], [Descrizione], [Videata], [Link], [Parametri], [NavigateUrl], [Sorting], [ToolTip], [Disabled], [Icon], [Popup], [CodFamiglia])
        VALUES (@ParentID, @Text, @Descrizione, @Videata, @Link, @Parametri, @NavigateUrl, @Sorting, @ToolTip, @Disabled, @Icon, @Popup, @CodFamiglia);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [MENU_ELEMENTI] SET
            [ParentID] = @ParentID,
            [Text] = @Text,
            [Descrizione] = @Descrizione,
            [Videata] = @Videata,
            [Link] = @Link,
            [Parametri] = @Parametri,
            [NavigateUrl] = @NavigateUrl,
            [Sorting] = @Sorting,
            [ToolTip] = @ToolTip,
            [Disabled] = @Disabled,
            [Icon] = @Icon,
            [Popup] = @Popup,
            [CodFamiglia] = @CodFamiglia
        WHERE [IdMenuElemento] = @IdMenuElemento;
        SELECT @IdMenuElemento AS id;
    END
END

