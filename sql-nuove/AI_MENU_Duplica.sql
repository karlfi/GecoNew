-- Editor del menu (pagina /menu): funzione "Duplica". Crea una nuova voce uguale
-- a quella indicata con il testo "<Testo> copia N" (primo N libero tra i fratelli,
-- cosi' le duplicazioni ripetute non si sovrappongono) e ne copia i permessi di
-- visibilita' (MENU_ElementiRuoli e MENU_ELEMENTIGRUPPI). Con @ConFoglie=1, per le
-- voci radice, duplica anche tutte le foglie dirette (nomi invariati) coi permessi.
CREATE OR ALTER PROCEDURE dbo.AI_MENU_Duplica
    @IdMenuElemento int,
    @ConFoglie bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Testo varchar(255), @Parent int;
    SELECT @Testo = ISNULL(Text, ''), @Parent = ISNULL(ParentID, 0)
    FROM dbo.MENU_ELEMENTI WHERE IdMenuElemento = @IdMenuElemento;
    IF @@ROWCOUNT = 0
    BEGIN SELECT CAST(NULL AS int) AS Id, 'Voce di menu inesistente' AS Errore; RETURN; END

    -- "<Testo> copia N": primo N libero tra i fratelli
    DECLARE @n int = 1, @suffisso varchar(20) = ' copia 1';
    WHILE EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI
                  WHERE ISNULL(ParentID, 0) = @Parent
                    AND Text = LEFT(@Testo, 255 - LEN(@suffisso)) + @suffisso)
    BEGIN
        SET @n += 1;
        SET @suffisso = ' copia ' + CONVERT(varchar(9), @n);
    END
    DECLARE @NuovoTesto varchar(255) = LEFT(@Testo, 255 - LEN(@suffisso)) + @suffisso;

    BEGIN TRAN;

    INSERT INTO dbo.MENU_ELEMENTI (ParentID, Text, Descrizione, Videata, Link, Parametri,
                                   NavigateUrl, Sorting, ToolTip, Disabled, Icon, Popup, CodFamiglia)
    SELECT ParentID, @NuovoTesto, Descrizione, Videata, Link, Parametri,
           NavigateUrl, Sorting, ToolTip, Disabled, Icon, Popup, CodFamiglia
    FROM dbo.MENU_ELEMENTI WHERE IdMenuElemento = @IdMenuElemento;
    DECLARE @NuovoId int = SCOPE_IDENTITY();

    -- stessa visibilita' dell'originale
    INSERT INTO dbo.MENU_ElementiRuoli (IdMenuElemento, IdRuolo)
    SELECT @NuovoId, IdRuolo FROM dbo.MENU_ElementiRuoli WHERE IdMenuElemento = @IdMenuElemento;
    INSERT INTO dbo.MENU_ELEMENTIGRUPPI (IdMenu, IdGruppo)
    SELECT @NuovoId, IdGruppo FROM dbo.MENU_ELEMENTIGRUPPI WHERE IdMenu = @IdMenuElemento;

    DECLARE @Foglie int = 0;
    IF @ConFoglie = 1
    BEGIN
        -- MERGE su 1=0: unico modo per catturare la mappa vecchio->nuovo id
        -- in un insert multiplo (OUTPUT con riferimento alla sorgente)
        DECLARE @map TABLE (VecchioId int, NuovoId int);
        MERGE dbo.MENU_ELEMENTI AS t
        USING (SELECT * FROM dbo.MENU_ELEMENTI WHERE ParentID = @IdMenuElemento) AS s
        ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (ParentID, Text, Descrizione, Videata, Link, Parametri,
                    NavigateUrl, Sorting, ToolTip, Disabled, Icon, Popup, CodFamiglia)
            VALUES (@NuovoId, s.Text, s.Descrizione, s.Videata, s.Link, s.Parametri,
                    s.NavigateUrl, s.Sorting, s.ToolTip, s.Disabled, s.Icon, s.Popup, s.CodFamiglia)
        OUTPUT s.IdMenuElemento, inserted.IdMenuElemento INTO @map (VecchioId, NuovoId);
        SET @Foglie = @@ROWCOUNT;

        INSERT INTO dbo.MENU_ElementiRuoli (IdMenuElemento, IdRuolo)
        SELECT m.NuovoId, r.IdRuolo FROM @map m
        INNER JOIN dbo.MENU_ElementiRuoli r ON r.IdMenuElemento = m.VecchioId;
        INSERT INTO dbo.MENU_ELEMENTIGRUPPI (IdMenu, IdGruppo)
        SELECT m.NuovoId, g.IdGruppo FROM @map m
        INNER JOIN dbo.MENU_ELEMENTIGRUPPI g ON g.IdMenu = m.VecchioId;
    END

    COMMIT;

    SELECT @NuovoId AS Id, @NuovoTesto AS Testo, @Foglie AS Foglie;
END
GO
GRANT EXECUTE ON dbo.AI_MENU_Duplica TO claude;
