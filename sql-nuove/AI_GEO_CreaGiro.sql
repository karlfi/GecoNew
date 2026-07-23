-- =============================================================
-- AI_GEO_CreaGiro — crea un giro con i suoi vertici in un colpo solo (atomico).
-- Replica il flusso della videata legacy "Creazione giri su Mappa":
--   1. GEO_CreaGiro   (crea la riga GEO_GIRI, colore casuale se vuoto)
--   2. inserisce i vertici in GEO_GIRIVERTICI  (l'unico INSERT grezzo del legacy)
--   3. GEO_AllineaGiri (costruisce lo SHAPE poligonale, chiude e valida l'anello)
-- I vertici arrivano come JSON ordinato: [{"lat":..,"lng":..}, ...]; l'ordine
-- del poligono e' preservato da [key] di OPENJSON (GEO_AllineaGiri ordina per
-- IdVertice, che l'insert assegna nell'ordine dei vertici).
-- Nessuna logica duplicata: riusa le due SP legacy. Prefisso AI_.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_GEO_CreaGiro
    @Giro     varchar(200),
    @IdFiliale int,
    @Colore   varchar(10) = NULL,
    @Vertici  nvarchar(max)              -- JSON: [{"lat":43.7,"lng":11.2}, ...]
AS
BEGIN
    SET NOCOUNT ON;

    IF LEN(LTRIM(RTRIM(ISNULL(@Giro, '')))) <= 3
    BEGIN
        RAISERROR('Nome del giro non impostato o troppo corto', 16, 1);
        RETURN;
    END
    IF ISNULL(@Vertici, '') = '' OR (SELECT COUNT(*) FROM OPENJSON(@Vertici)) < 3
    BEGIN
        RAISERROR('Servono almeno 3 punti per definire l''area del giro', 16, 1);
        RETURN;
    END

    -- 1. crea il giro (SP legacy). Ne catturo il result set per non farlo trapelare.
    CREATE TABLE #g (IdGiro int, IdFiliale int, Giro varchar(200), CAP varchar(20),
                     Belfiore varchar(20), DataModifica smalldatetime, DataFine smalldatetime, colore varchar(20));
    INSERT INTO #g EXEC dbo.GEO_CreaGiro @Giro = @Giro, @IdFiliale = @IdFiliale, @Colore = @Colore;
    DECLARE @IdGiro int = (SELECT TOP 1 IdGiro FROM #g);

    -- 2. vertici (ordine preservato da [key])
    INSERT INTO GEO_GIRIVERTICI (IdGiro, Latitude, Longitude, Sequenza, DataModifica)
    SELECT @IdGiro,
           CAST(JSON_VALUE(value, '$.lat') AS float),
           CAST(JSON_VALUE(value, '$.lng') AS float),
           CAST([key] AS int),
           GETDATE()
    FROM OPENJSON(@Vertici)
    ORDER BY CAST([key] AS int);

    -- 3. costruisce lo SHAPE (SP legacy)
    EXEC dbo.GEO_AllineaGiri @IdGiro;

    SELECT @IdGiro AS IdGiro;
END
GO

GRANT EXECUTE ON dbo.AI_GEO_CreaGiro TO claude;
GO
