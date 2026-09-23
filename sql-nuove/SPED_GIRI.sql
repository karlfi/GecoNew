-- =============================================================
-- Spedizioni del giorno e giri (pagina "Spedizioni del giorno" di Speedy Web).
-- Assegnazione automatica parametrica (filiale, data di carico, cliente, un giro o tutti, con o
-- senza riassegnazione), assegnazione a mano di un gruppo di spedizioni, spostamento del punto di
-- consegna. La regola e' quella della legacy GEO_AssegnaGIRI (CAP fisso del giro, poi comune fisso,
-- poi il punto dentro l'area; a parita' vince l'IdGiro piu' basso) ma limitata ai giri attivi della
-- filiale della spedizione e senza il vincolo sul cliente Poste e su "oggi". Ogni cambio di giro o
-- di posizione lascia una riga in SPED_GEO_VARIAZIONI. Quando cambia il giro la Sequenza (ordine
-- del percorso ottimizzato) viene azzerata: va ricalcolata.
-- =============================================================
IF OBJECT_ID('dbo.SPED_GEO_VARIAZIONI') IS NULL
CREATE TABLE dbo.SPED_GEO_VARIAZIONI (
    IdVariazione int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SPED_GEO_VARIAZIONI PRIMARY KEY,
    IdSpedizione int NOT NULL,
    DataOra      datetime NOT NULL CONSTRAINT DF_SPED_GEO_VARIAZIONI_DataOra DEFAULT (GETDATE()),
    Utente       varchar(100) NULL,
    Origine      varchar(20) NOT NULL,     -- AUTO (assegnazione automatica), MANUALE, POSIZIONE (giro cambiato spostando il punto)
    Campo        varchar(20) NOT NULL,     -- Giro, Posizione
    Prima        varchar(100) NULL,        -- IdGiro oppure "lat,lng"
    Dopo         varchar(100) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SPED_GEO_VARIAZIONI_Sped')
    CREATE INDEX IX_SPED_GEO_VARIAZIONI_Sped ON dbo.SPED_GEO_VARIAZIONI (IdSpedizione, DataOra);
GO

-- Il giro di un punto di consegna: CAP fisso > comune fisso > area. Se piu' aree contengono il punto vince
-- quella con IdGiro piu' basso, come faceva di fatto la legacy (a HUB le zone PO2020 si sovrappongono ai giri PO-xx).
CREATE OR ALTER FUNCTION dbo.AI_GiroDelPunto(@IdFiliale int, @CAP varchar(5), @Belfiore varchar(5), @Lat float, @Lng float)
RETURNS int
AS
BEGIN
    DECLARE @id int;
    IF @CAP IS NOT NULL
        SELECT TOP 1 @id = IdGiro FROM dbo.GEO_GIRI
        WHERE IdFiliale = @IdFiliale AND DataFine IS NULL AND CAP = @CAP ORDER BY IdGiro;
    IF @id IS NULL AND @Belfiore IS NOT NULL
        SELECT TOP 1 @id = IdGiro FROM dbo.GEO_GIRI
        WHERE IdFiliale = @IdFiliale AND DataFine IS NULL AND Belfiore = @Belfiore ORDER BY IdGiro;
    IF @id IS NULL AND @Lat IS NOT NULL AND @Lng IS NOT NULL
        SELECT TOP 1 @id = IdGiro FROM dbo.GEO_GIRI
        WHERE IdFiliale = @IdFiliale AND DataFine IS NULL AND SHAPE IS NOT NULL
          AND SHAPE.STContains(geometry::Point(@Lng, @Lat, 4326)) = 1
        ORDER BY IdGiro;
    RETURN @id;
END
GO

-- Assegnazione automatica delle spedizioni caricate in un giorno per una filiale.
-- @IdGiro: solo verso quel giro (il tasto "Aggiorna giri di sped" della pagina Giri); @Forza = 1
-- riassegna anche quelle che un giro ce l'hanno gia'. Non toglie mai un giro.
CREATE OR ALTER PROCEDURE dbo.AI_SPED_AssegnaGiri
    @IdFiliale int,
    @Data      date = NULL,
    @IdCliente int = NULL,
    @IdGiro    int = NULL,
    @Forza     bit = 0,
    @Utente    varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Data IS NULL SET @Data = CAST(GETDATE() AS date);
    DECLARE @dal datetime = @Data, @al datetime = DATEADD(day, 1, @Data);
    DECLARE @n TABLE (IdSpedizione int PRIMARY KEY, Prima int NULL, Dopo int NULL);

    INSERT INTO @n (IdSpedizione, Prima, Dopo)
    SELECT s.IdSpedizione, s.IdGiro,
           CASE WHEN @IdGiro IS NULL
                THEN dbo.AI_GiroDelPunto(s.IdFiliale, s.DestinazioneCap, s.Belfiore, s.DestinazioneLatitude, s.DestinazioneLongitude)
                ELSE (SELECT TOP 1 g.IdGiro FROM dbo.GEO_GIRI g
                      WHERE g.IdGiro = @IdGiro AND g.IdFiliale = s.IdFiliale AND g.DataFine IS NULL
                        AND (g.CAP = s.DestinazioneCap OR g.Belfiore = s.Belfiore
                             OR (s.DestinazioneLatitude IS NOT NULL AND g.SHAPE IS NOT NULL
                                 AND g.SHAPE.STContains(geometry::Point(s.DestinazioneLongitude, s.DestinazioneLatitude, 4326)) = 1)))
           END
    FROM dbo.SPED_ATTIVITA s
    WHERE s.IdFiliale = @IdFiliale
      AND s.DataCarico >= @dal AND s.DataCarico < @al
      AND (@IdCliente IS NULL OR s.IdCliente = @IdCliente)
      AND (@Forza = 1 OR s.IdGiro IS NULL);

    DELETE FROM @n WHERE Dopo IS NULL OR Dopo = ISNULL(Prima, 0);

    BEGIN TRAN;
    INSERT INTO dbo.SPED_GEO_VARIAZIONI (IdSpedizione, Utente, Origine, Campo, Prima, Dopo)
    SELECT IdSpedizione, @Utente, 'AUTO', 'Giro', CAST(Prima AS varchar(20)), CAST(Dopo AS varchar(20)) FROM @n;
    UPDATE s SET IdGiro = n.Dopo, Sequenza = NULL
    FROM dbo.SPED_ATTIVITA s JOIN @n n ON n.IdSpedizione = s.IdSpedizione;
    COMMIT;

    SELECT (SELECT COUNT(*) FROM @n) AS Assegnate,
           COUNT(*) AS Totale,
           SUM(CASE WHEN IdGiro IS NULL THEN 1 ELSE 0 END) AS SenzaGiro,
           SUM(CASE WHEN DestinazioneLatitude IS NULL THEN 1 ELSE 0 END) AS SenzaCoordinate
    FROM dbo.SPED_ATTIVITA
    WHERE IdFiliale = @IdFiliale AND DataCarico >= @dal AND DataCarico < @al
      AND (@IdCliente IS NULL OR IdCliente = @IdCliente);
END
GO

-- Assegnazione a mano: un gruppo di spedizioni della filiale a un giro (NULL = toglie il giro).
CREATE OR ALTER PROCEDURE dbo.AI_SPED_Giro
    @IdFiliale    int,
    @IdSpedizioni nvarchar(max),           -- JSON [35459932, 35459933]
    @IdGiro       int = NULL,
    @Utente       varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @IdGiro IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.GEO_GIRI WHERE IdGiro = @IdGiro AND IdFiliale = @IdFiliale AND DataFine IS NULL)
    BEGIN
        RAISERROR('Giro inesistente, chiuso o di un''altra filiale', 16, 1);
        RETURN;
    END
    DECLARE @n TABLE (IdSpedizione int PRIMARY KEY, Prima int NULL);
    INSERT INTO @n (IdSpedizione, Prima)
    SELECT s.IdSpedizione, s.IdGiro
    FROM dbo.SPED_ATTIVITA s
    WHERE s.IdFiliale = @IdFiliale
      AND s.IdSpedizione IN (SELECT CAST(value AS int) FROM OPENJSON(@IdSpedizioni))
      AND ISNULL(s.IdGiro, 0) <> ISNULL(@IdGiro, 0);

    BEGIN TRAN;
    INSERT INTO dbo.SPED_GEO_VARIAZIONI (IdSpedizione, Utente, Origine, Campo, Prima, Dopo)
    SELECT IdSpedizione, @Utente, 'MANUALE', 'Giro', CAST(Prima AS varchar(20)), CAST(@IdGiro AS varchar(20)) FROM @n;
    UPDATE s SET IdGiro = @IdGiro, Sequenza = NULL
    FROM dbo.SPED_ATTIVITA s JOIN @n n ON n.IdSpedizione = s.IdSpedizione;
    COMMIT;
    SELECT COUNT(*) AS Cambiate FROM @n;
END
GO

-- Punto di consegna spostato (o messo, se mancava) dalla mappa; con @Riassegna = 1 il giro segue il punto nuovo.
CREATE OR ALTER PROCEDURE dbo.AI_SPED_Posizione
    @IdSpedizione int,
    @Lat          float,
    @Lng          float,
    @Riassegna    bit = 1,
    @Utente       varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Lat IS NULL OR @Lng IS NULL OR @Lat NOT BETWEEN -90 AND 90 OR @Lng NOT BETWEEN -180 AND 180
    BEGIN
        RAISERROR('Coordinate non valide', 16, 1);
        RETURN;
    END
    DECLARE @IdFiliale int, @CAP varchar(5), @Belfiore varchar(5), @Lat0 float, @Lng0 float, @Giro0 int, @Giro1 int;
    SELECT @IdFiliale = IdFiliale, @CAP = DestinazioneCap, @Belfiore = Belfiore,
           @Lat0 = DestinazioneLatitude, @Lng0 = DestinazioneLongitude, @Giro0 = IdGiro
    FROM dbo.SPED_ATTIVITA WHERE IdSpedizione = @IdSpedizione;
    IF @IdFiliale IS NULL
    BEGIN
        RAISERROR('Spedizione inesistente', 16, 1);
        RETURN;
    END

    BEGIN TRAN;
    INSERT INTO dbo.SPED_GEO_VARIAZIONI (IdSpedizione, Utente, Origine, Campo, Prima, Dopo)
    VALUES (@IdSpedizione, @Utente, 'MANUALE', 'Posizione',
            CASE WHEN @Lat0 IS NULL THEN NULL ELSE CONVERT(varchar(20), CAST(@Lat0 AS decimal(10, 6))) + ',' + CONVERT(varchar(20), CAST(@Lng0 AS decimal(10, 6))) END,
            CONVERT(varchar(20), CAST(@Lat AS decimal(10, 6))) + ',' + CONVERT(varchar(20), CAST(@Lng AS decimal(10, 6))));
    UPDATE dbo.SPED_ATTIVITA SET DestinazioneLatitude = @Lat, DestinazioneLongitude = @Lng WHERE IdSpedizione = @IdSpedizione;
    IF @Riassegna = 1
    BEGIN
        SET @Giro1 = dbo.AI_GiroDelPunto(@IdFiliale, @CAP, @Belfiore, @Lat, @Lng);
        IF @Giro1 IS NOT NULL AND ISNULL(@Giro0, 0) <> @Giro1
        BEGIN
            INSERT INTO dbo.SPED_GEO_VARIAZIONI (IdSpedizione, Utente, Origine, Campo, Prima, Dopo)
            VALUES (@IdSpedizione, @Utente, 'POSIZIONE', 'Giro', CAST(@Giro0 AS varchar(20)), CAST(@Giro1 AS varchar(20)));
            UPDATE dbo.SPED_ATTIVITA SET IdGiro = @Giro1, Sequenza = NULL WHERE IdSpedizione = @IdSpedizione;
        END
    END
    COMMIT;
    SELECT s.IdSpedizione, s.DestinazioneLatitude AS Lat, s.DestinazioneLongitude AS Lng, s.IdGiro, g.Giro, g.Colore
    FROM dbo.SPED_ATTIVITA s LEFT JOIN dbo.GEO_GIRI g ON g.IdGiro = s.IdGiro
    WHERE s.IdSpedizione = @IdSpedizione;
END
GO
