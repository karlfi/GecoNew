-- =============================================================
-- AI_GEO_CreaGiroDaComuni — crea un giro come UNIONE delle geometrie dei comuni
-- selezionati (GEO_COMUNE.SHAPE). Molto piu' rapido e preciso del disegno a mano:
-- i giri sono di fatto insiemi di comuni/CAP, e i comuni hanno gia' lo SHAPE.
-- Riusa GEO_CreaGiro (crea la riga + colore); poi imposta SHAPE = UnionAggregate.
-- Lo SHAPE e' quello usato da GEO_AssegnaGIRI per l'assegnazione (STContains),
-- quindi il giro e' subito assegnabile anche senza vertici in GEO_GIRIVERTICI.
-- @IdComuni: JSON array di interi, es. [2857,2838].
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_GEO_CreaGiroDaComuni
    @Giro      varchar(200),
    @IdFiliale int,
    @Colore    varchar(10) = NULL,
    @IdComuni  nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;

    IF LEN(LTRIM(RTRIM(ISNULL(@Giro, '')))) <= 3
    BEGIN
        RAISERROR('Nome del giro non impostato o troppo corto', 16, 1);
        RETURN;
    END

    DECLARE @ids TABLE (IdComune int);
    INSERT INTO @ids (IdComune) SELECT CAST(value AS int) FROM OPENJSON(@IdComuni);
    IF NOT EXISTS (SELECT 1 FROM @ids)
    BEGIN
        RAISERROR('Nessun comune selezionato', 16, 1);
        RETURN;
    END

    DECLARE @union geometry = (
        SELECT geometry::UnionAggregate(SHAPE)
        FROM GEO_COMUNE
        WHERE IdComune IN (SELECT IdComune FROM @ids) AND SHAPE IS NOT NULL
    );
    IF @union IS NULL
    BEGIN
        RAISERROR('I comuni selezionati non hanno geometria', 16, 1);
        RETURN;
    END
    IF @union.STIsValid() = 0 SET @union = @union.MakeValid();

    -- crea la riga giro (SP legacy) e ne cattura il result set
    CREATE TABLE #g (IdGiro int, IdFiliale int, Giro varchar(200), CAP varchar(20),
                     Belfiore varchar(20), DataModifica smalldatetime, DataFine smalldatetime, colore varchar(20));
    INSERT INTO #g EXEC dbo.GEO_CreaGiro @Giro = @Giro, @IdFiliale = @IdFiliale, @Colore = @Colore;
    DECLARE @IdGiro int = (SELECT TOP 1 IdGiro FROM #g);

    UPDATE GEO_GIRI SET SHAPE = @union WHERE IdGiro = @IdGiro;

    SELECT @IdGiro AS IdGiro;
END
GO

GRANT EXECUTE ON dbo.AI_GEO_CreaGiroDaComuni TO claude;
GO
