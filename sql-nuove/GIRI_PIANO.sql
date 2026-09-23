-- =============================================================
-- Piano della giornata (pagina "Piano della giornata" di Speedy Web): per ogni giorno e giro della
-- filiale, il driver assegnato e l'ottimizzazione del percorso con HERE Waypoints Sequencing.
-- L'ottimizzazione usa le tabelle legacy: GEO_HereW (testata), GEO_HereWReq (i punti: partenza =
-- IdAttivita 0, ritorno = IdAttivita 999999999, in mezzo le spedizioni), GEO_HereWaypoint (la
-- risposta: sequenza, tempo e distanza per punto). La chiamata a HERE la fa lo script Python dello
-- schedulatore (here\here_sequenza.py, workflow GEO-01_HERE), che poi chiama AI_HERE_Risposta.
-- La sequenza finisce in SPED_ATTIVITA.Sequenza (e in PALM_ATTIVITA.Sequenza quando le attivita'
-- saranno sul palmare). Ogni cambio resta in GIRI_PIANO_VARIAZIONI.
-- =============================================================
IF OBJECT_ID('dbo.GIRI_PIANO') IS NULL
CREATE TABLE dbo.GIRI_PIANO (
    IdPiano           int IDENTITY(1,1) NOT NULL CONSTRAINT PK_GIRI_PIANO PRIMARY KEY,
    Data              date NOT NULL,
    IdFiliale         int NOT NULL,
    IdGiro            int NOT NULL,
    IdDriver          int NULL,
    IdGeoHereW        int NULL,                 -- ultima richiesta di ottimizzazione
    Stato             varchar(20) NULL,         -- NULL, RICHIESTA, IN_CORSO, FATTA, ERRORE
    NPunti            int NULL,                 -- spedizioni mandate a HERE
    NSenzaCoordinate  int NULL,                 -- spedizioni del giro rimaste fuori (senza punto)
    DistanzaM         int NULL,
    TempoS            int NULL,
    Errore            nvarchar(500) NULL,
    DataRichiesta     datetime NULL,
    DataRisposta      datetime NULL,
    DataModifica      datetime NOT NULL CONSTRAINT DF_GIRI_PIANO_DataModifica DEFAULT (GETDATE()),
    Utente            varchar(100) NULL,
    CONSTRAINT UQ_GIRI_PIANO UNIQUE (Data, IdGiro)
);
GO
IF OBJECT_ID('dbo.GIRI_PIANO_VARIAZIONI') IS NULL
CREATE TABLE dbo.GIRI_PIANO_VARIAZIONI (
    IdVariazione int IDENTITY(1,1) NOT NULL CONSTRAINT PK_GIRI_PIANO_VARIAZIONI PRIMARY KEY,
    IdPiano      int NOT NULL,
    DataOra      datetime NOT NULL CONSTRAINT DF_GIRI_PIANO_VARIAZIONI_DataOra DEFAULT (GETDATE()),
    Utente       varchar(100) NULL,
    Campo        varchar(30) NOT NULL,          -- Driver, Ottimizzazione
    Prima        nvarchar(200) NULL,
    Dopo         nvarchar(200) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_GIRI_PIANO_VARIAZIONI_Piano')
    CREATE INDEX IX_GIRI_PIANO_VARIAZIONI_Piano ON dbo.GIRI_PIANO_VARIAZIONI (IdPiano, DataOra);
GO

-- La riga del piano per (data, giro): la crea se manca. Torna IdPiano.
CREATE OR ALTER PROCEDURE dbo.AI_PIANO_Riga
    @IdFiliale int, @Data date, @IdGiro int, @Utente varchar(100) = NULL, @IdPiano int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @IdPiano = IdPiano FROM dbo.GIRI_PIANO WHERE Data = @Data AND IdGiro = @IdGiro;
    IF @IdPiano IS NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.GEO_GIRI WHERE IdGiro = @IdGiro AND IdFiliale = @IdFiliale)
        BEGIN
            RAISERROR('Giro inesistente o di un''altra filiale', 16, 1);
            RETURN;
        END
        INSERT INTO dbo.GIRI_PIANO (Data, IdFiliale, IdGiro, Utente) VALUES (@Data, @IdFiliale, @IdGiro, @Utente);
        SET @IdPiano = SCOPE_IDENTITY();
    END
END
GO

-- Driver di un giro per un giorno (NULL = toglie il driver).
CREATE OR ALTER PROCEDURE dbo.AI_PIANO_Driver
    @IdFiliale int, @Data date, @IdGiro int, @IdDriver int = NULL, @Utente varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @IdDriver IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.UTENTI WHERE IdUtente = @IdDriver AND ISNULL(DataFine, '2079-01-01') > GETDATE())
    BEGIN
        RAISERROR('Driver inesistente o cessato', 16, 1);
        RETURN;
    END
    DECLARE @IdPiano int;
    EXEC dbo.AI_PIANO_Riga @IdFiliale, @Data, @IdGiro, @Utente, @IdPiano OUTPUT;
    DECLARE @Prima int = (SELECT IdDriver FROM dbo.GIRI_PIANO WHERE IdPiano = @IdPiano);
    IF ISNULL(@Prima, 0) <> ISNULL(@IdDriver, 0)
    BEGIN
        INSERT INTO dbo.GIRI_PIANO_VARIAZIONI (IdPiano, Utente, Campo, Prima, Dopo)
        VALUES (@IdPiano, @Utente, 'Driver', CAST(@Prima AS varchar(20)), CAST(@IdDriver AS varchar(20)));
        UPDATE dbo.GIRI_PIANO SET IdDriver = @IdDriver, DataModifica = GETDATE(), Utente = @Utente WHERE IdPiano = @IdPiano;
    END
    SELECT p.IdPiano, p.IdDriver, u.Nome AS Driver FROM dbo.GIRI_PIANO p LEFT JOIN dbo.UTENTI u ON u.IdUtente = p.IdDriver WHERE p.IdPiano = @IdPiano;
END
GO

-- Driver predefiniti (GEO_GIRI.IdDriverDefault) sui giri del giorno che hanno spedizioni e nessun driver.
CREATE OR ALTER PROCEDURE dbo.AI_PIANO_DriverPredefiniti
    @IdFiliale int, @Data date, @Utente varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @dal datetime = @Data, @al datetime = DATEADD(day, 1, @Data);
    DECLARE @giri TABLE (IdGiro int, IdDriver int);
    INSERT INTO @giri (IdGiro, IdDriver)
    SELECT g.IdGiro, g.IdDriverDefault
    FROM dbo.GEO_GIRI g
    JOIN dbo.UTENTI u ON u.IdUtente = g.IdDriverDefault AND ISNULL(u.DataFine, '2079-01-01') > GETDATE()
    LEFT JOIN dbo.GIRI_PIANO p ON p.IdGiro = g.IdGiro AND p.Data = @Data
    WHERE g.IdFiliale = @IdFiliale AND g.DataFine IS NULL AND g.IdDriverDefault IS NOT NULL AND p.IdDriver IS NULL
      AND EXISTS (SELECT 1 FROM dbo.SPED_ATTIVITA s WHERE s.IdGiro = g.IdGiro AND s.IdFiliale = @IdFiliale AND s.DataCarico >= @dal AND s.DataCarico < @al);
    DECLARE @IdGiro int, @IdDriver int, @n int = 0;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT IdGiro, IdDriver FROM @giri;
    OPEN c;
    FETCH NEXT FROM c INTO @IdGiro, @IdDriver;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.AI_PIANO_Driver @IdFiliale, @Data, @IdGiro, @IdDriver, @Utente;
        SET @n += 1;
        FETCH NEXT FROM c INTO @IdGiro, @IdDriver;
    END
    CLOSE c; DEALLOCATE c;
    SELECT @n AS Assegnati;
END
GO

-- Richiesta di ottimizzazione per un giro del giorno: testata e punti nelle tabelle HERE, stato RICHIESTA sul piano.
CREATE OR ALTER PROCEDURE dbo.AI_HERE_Richiesta
    @IdFiliale int, @Data date, @IdGiro int, @IdUtente int = NULL, @Utente varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Data IS NULL SET @Data = CAST(GETDATE() AS date);
    DECLARE @dal datetime = @Data, @al datetime = DATEADD(day, 1, @Data);
    DECLARE @lat float, @lng float, @nome varchar(200);
    SELECT @lat = Latitude, @lng = Longitude, @nome = FILIALE FROM dbo.FILIALI WHERE IDFILIALE = @IdFiliale;
    IF @lat IS NULL OR @lng IS NULL
    BEGIN
        RAISERROR('La filiale non ha le coordinate (FILIALI.Latitude/Longitude): servono come partenza e ritorno', 16, 1);
        RETURN;
    END
    IF EXISTS (SELECT 1 FROM dbo.GIRI_PIANO WHERE Data = @Data AND IdGiro = @IdGiro AND Stato IN ('RICHIESTA', 'IN_CORSO') AND DataRichiesta > DATEADD(minute, -15, GETDATE()))
    BEGIN
        RAISERROR('C''e'' gia'' un''ottimizzazione in corso per questo giro', 16, 1);
        RETURN;
    END
    DECLARE @n int, @senza int;
    SELECT @n = SUM(CASE WHEN DestinazioneLatitude IS NOT NULL THEN 1 ELSE 0 END), @senza = SUM(CASE WHEN DestinazioneLatitude IS NULL THEN 1 ELSE 0 END)
    FROM dbo.SPED_ATTIVITA WHERE IdFiliale = @IdFiliale AND IdGiro = @IdGiro AND DataCarico >= @dal AND DataCarico < @al;
    IF ISNULL(@n, 0) = 0
    BEGIN
        RAISERROR('Nessuna spedizione con coordinate in questo giro per il giorno scelto', 16, 1);
        RETURN;
    END
    DECLARE @IdPiano int;
    EXEC dbo.AI_PIANO_Riga @IdFiliale, @Data, @IdGiro, @Utente, @IdPiano OUTPUT;

    BEGIN TRAN;
    INSERT INTO dbo.GEO_HereW (Nome, IdFilialeStart, Latitude1, Longitude1, IdFilialeStop, Latitude2, Longitude2, DataInserimento, IdUtente)
    VALUES (CONVERT(varchar(8), @Data, 112) + '_GIRO_' + CAST(@IdGiro AS varchar(10)) + '_' + REPLACE(CONVERT(varchar(5), GETDATE(), 108), ':', ''),
            @IdFiliale, @lat, @lng, @IdFiliale, @lat, @lng, GETDATE(), @IdUtente);
    DECLARE @IdGeoHereW int = SCOPE_IDENTITY();
    INSERT INTO dbo.GEO_HereWReq (IdGeoHereW, IdAttivita, Latitude, Longitude, Indirizzo) VALUES (@IdGeoHereW, 0, @lat, @lng, @nome);
    INSERT INTO dbo.GEO_HereWReq (IdGeoHereW, IdSpedizione, Latitude, Longitude, Indirizzo)
    SELECT @IdGeoHereW, IdSpedizione, DestinazioneLatitude, DestinazioneLongitude,
           LEFT(ISNULL(DestinazioneIndirizzo, '') + ISNULL(' ' + DestinazioneNumeroCivico, '') + ISNULL(', ' + DestinazioneCap, '') + ISNULL(' ' + DestinazioneLocalita, ''), 500)
    FROM dbo.SPED_ATTIVITA
    WHERE IdFiliale = @IdFiliale AND IdGiro = @IdGiro AND DataCarico >= @dal AND DataCarico < @al AND DestinazioneLatitude IS NOT NULL
    ORDER BY IdSpedizione;
    INSERT INTO dbo.GEO_HereWReq (IdGeoHereW, IdAttivita, Latitude, Longitude, Indirizzo) VALUES (@IdGeoHereW, 999999999, @lat, @lng, @nome);
    UPDATE dbo.GIRI_PIANO
       SET IdGeoHereW = @IdGeoHereW, Stato = 'RICHIESTA', NPunti = @n, NSenzaCoordinate = ISNULL(@senza, 0),
           DistanzaM = NULL, TempoS = NULL, Errore = NULL, DataRichiesta = GETDATE(), DataRisposta = NULL,
           DataModifica = GETDATE(), Utente = @Utente
     WHERE IdPiano = @IdPiano;
    INSERT INTO dbo.GIRI_PIANO_VARIAZIONI (IdPiano, Utente, Campo, Prima, Dopo)
    VALUES (@IdPiano, @Utente, 'Ottimizzazione', NULL, 'richiesta: ' + CAST(@n AS varchar(10)) + ' punti (HERE ' + CAST(@IdGeoHereW AS varchar(10)) + ')');
    COMMIT;
    SELECT @IdPiano AS IdPiano, @IdGeoHereW AS IdGeoHereW, @n AS NPunti, ISNULL(@senza, 0) AS NSenzaCoordinate;
END
GO

-- Lo script ha preso in carico la richiesta.
CREATE OR ALTER PROCEDURE dbo.AI_HERE_InCorso
    @IdGeoHereW int
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.GIRI_PIANO SET Stato = 'IN_CORSO', DataModifica = GETDATE() WHERE IdGeoHereW = @IdGeoHereW;
END
GO

-- La risposta di HERE (o l'errore): punti in GEO_HereWaypoint, Sequenza sulle spedizioni, piano aggiornato.
-- @Waypoints: JSON [{"idReq":843,"seq":1,"tempo":120,"distanza":950,"arrivo":"2026-09-24T07:12:00","partenza":"..."}, ...]
-- (idReq = GEO_HereWReq.IdGeoHereReq; seq parte da 0 con la partenza e finisce col ritorno).
CREATE OR ALTER PROCEDURE dbo.AI_HERE_Risposta
    @IdGeoHereW int,
    @Waypoints  nvarchar(max) = NULL,
    @DistanzaM  int = NULL,
    @TempoS     int = NULL,
    @Errore     nvarchar(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @IdPiano int = (SELECT TOP 1 IdPiano FROM dbo.GIRI_PIANO WHERE IdGeoHereW = @IdGeoHereW);
    IF @Errore IS NOT NULL
    BEGIN
        UPDATE dbo.GEO_HereW SET DataRisposta = GETDATE() WHERE IdGeoHereW = @IdGeoHereW;
        UPDATE dbo.GIRI_PIANO SET Stato = 'ERRORE', Errore = LEFT(@Errore, 500), DataRisposta = GETDATE(), DataModifica = GETDATE() WHERE IdPiano = @IdPiano;
        INSERT INTO dbo.GIRI_PIANO_VARIAZIONI (IdPiano, Campo, Prima, Dopo) SELECT @IdPiano, 'Ottimizzazione', NULL, 'errore: ' + LEFT(@Errore, 180) WHERE @IdPiano IS NOT NULL;
        RETURN;
    END
    DECLARE @w TABLE (IdReq int PRIMARY KEY, Seq int, Tempo int, Distanza int, Arrivo datetime NULL, Partenza datetime NULL);
    INSERT INTO @w (IdReq, Seq, Tempo, Distanza, Arrivo, Partenza)
    SELECT CAST(JSON_VALUE(value, '$.idReq') AS int), CAST(JSON_VALUE(value, '$.seq') AS int),
           CAST(JSON_VALUE(value, '$.tempo') AS int), CAST(JSON_VALUE(value, '$.distanza') AS int),
           TRY_CAST(JSON_VALUE(value, '$.arrivo') AS datetime), TRY_CAST(JSON_VALUE(value, '$.partenza') AS datetime)
    FROM OPENJSON(@Waypoints);
    IF NOT EXISTS (SELECT 1 FROM @w)
    BEGIN
        RAISERROR('Risposta HERE senza punti', 16, 1);
        RETURN;
    END
    BEGIN TRAN;
    DELETE FROM dbo.GEO_HereWaypoint WHERE IdHereReq = CAST(@IdGeoHereW AS varchar(50));
    INSERT INTO dbo.GEO_HereWaypoint (Sequenza, IdApi, TempoViaggio, Distanza, DataArrivo, DataPartenza, IdHereReq)
    SELECT Seq, IdReq, Tempo, Distanza, Arrivo, Partenza, CAST(@IdGeoHereW AS varchar(50)) FROM @w ORDER BY Seq;
    -- la sequenza delle consegne: 1..n sulle sole spedizioni, nell'ordine di HERE
    ;WITH o AS (
        SELECT r.IdSpedizione, ROW_NUMBER() OVER (ORDER BY w.Seq) AS Ordine
        FROM @w w JOIN dbo.GEO_HereWReq r ON r.IdGeoHereReq = w.IdReq
        WHERE r.IdGeoHereW = @IdGeoHereW AND r.IdSpedizione IS NOT NULL
    )
    UPDATE s SET Sequenza = o.Ordine FROM dbo.SPED_ATTIVITA s JOIN o ON o.IdSpedizione = s.IdSpedizione;
    ;WITH o AS (
        SELECT r.IdAttivita, ROW_NUMBER() OVER (ORDER BY w.Seq) AS Ordine
        FROM @w w JOIN dbo.GEO_HereWReq r ON r.IdGeoHereReq = w.IdReq
        WHERE r.IdGeoHereW = @IdGeoHereW AND r.IdAttivita IS NOT NULL AND r.IdAttivita NOT IN (0, 999999999)
    )
    UPDATE p SET Sequenza = o.Ordine FROM dbo.PALM_ATTIVITA p JOIN o ON o.IdAttivita = p.IdAttivita;
    UPDATE dbo.GEO_HereW SET DataRisposta = GETDATE() WHERE IdGeoHereW = @IdGeoHereW;
    UPDATE dbo.GIRI_PIANO SET Stato = 'FATTA', DistanzaM = @DistanzaM, TempoS = @TempoS, Errore = NULL, DataRisposta = GETDATE(), DataModifica = GETDATE()
     WHERE IdPiano = @IdPiano;
    INSERT INTO dbo.GIRI_PIANO_VARIAZIONI (IdPiano, Campo, Prima, Dopo)
    SELECT @IdPiano, 'Ottimizzazione', NULL, 'fatta: ' + CAST(ISNULL(@DistanzaM, 0) / 1000 AS varchar(10)) + ' km, ' + CAST(ISNULL(@TempoS, 0) / 60 AS varchar(10)) + ' min'
    WHERE @IdPiano IS NOT NULL;
    COMMIT;
    SELECT @IdPiano AS IdPiano;
END
GO
