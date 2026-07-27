-- Editor del menu (pagina /menu): cancellazione di una voce. Le radici si possono
-- eliminare solo dopo aver cancellato le foglie; con la voce vanno via anche i
-- permessi di visibilita' (MENU_ElementiRuoli / MENU_ELEMENTIGRUPPI).
CREATE OR ALTER PROCEDURE dbo.AI_MENU_Del
    @IdMenuElemento int
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE IdMenuElemento = @IdMenuElemento)
    BEGIN SELECT 'Voce di menu inesistente' AS Errore; RETURN; END

    DECLARE @foglie int = (SELECT COUNT(*) FROM dbo.MENU_ELEMENTI WHERE ParentID = @IdMenuElemento);
    IF @foglie > 0
    BEGIN
        SELECT 'La radice ha ' + CONVERT(varchar(9), @foglie)
               + ' fogli' + CASE WHEN @foglie = 1 THEN 'a' ELSE 'e' END
               + ': cancellale prima di eliminare la radice' AS Errore;
        RETURN;
    END

    BEGIN TRAN;
    DELETE FROM dbo.MENU_ElementiRuoli WHERE IdMenuElemento = @IdMenuElemento;
    DELETE FROM dbo.MENU_ELEMENTIGRUPPI WHERE IdMenu = @IdMenuElemento;
    DELETE FROM dbo.MENU_ELEMENTI WHERE IdMenuElemento = @IdMenuElemento;
    COMMIT;

    SELECT 'OK' AS Result;
END
GO
GRANT EXECUTE ON dbo.AI_MENU_Del TO claude;
GO

-- Pagina Gruppi (/gruppi): radici di menu collegate al gruppo (MENU_ELEMENTIGRUPPI).
-- Add: inserisce se non gia' presente (solo voci radice). Del: per chiave della riga.
CREATE OR ALTER PROCEDURE dbo.AI_MENU_ELEMENTIGRUPPI_Add
    @IdGruppo int, @IdMenu int
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI
                   WHERE IdMenuElemento = @IdMenu AND ISNULL(ParentID, 0) = 0)
    BEGIN
        RAISERROR ('Si possono collegare al gruppo solo voci radice del menu', 11, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTIGRUPPI WHERE IdGruppo = @IdGruppo AND IdMenu = @IdMenu)
        INSERT INTO dbo.MENU_ELEMENTIGRUPPI (IdGruppo, IdMenu) VALUES (@IdGruppo, @IdMenu);
END
GO
GRANT EXECUTE ON dbo.AI_MENU_ELEMENTIGRUPPI_Add TO claude;
GO

CREATE OR ALTER PROCEDURE dbo.AI_MENU_ELEMENTIGRUPPI_Del
    @IdMenuElementiGruppi int
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.MENU_ELEMENTIGRUPPI WHERE IdMenuElementiGruppi = @IdMenuElementiGruppi;
END
GO
GRANT EXECUTE ON dbo.AI_MENU_ELEMENTIGRUPPI_Del TO claude;
