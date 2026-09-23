-- =============================================================
-- Piano della giornata, seconda versione (richiesta di Carlo, 2026-09-23): l'assegnazione e'
-- giro -> driver (GIRI_PIANO.IdDriver, come prima) ma l'ottimizzazione del percorso e' PER DRIVER:
-- tutte le consegne dei suoi giri del giorno in un percorso solo, con partenza e ritorno dalla
-- filiale oppure da casa (UTENTI_GEO: indirizzo e coordinate del driver, geocodificato con HERE
-- dalla pagina). PIANO_DRIVER tiene per (data, driver) le opzioni, la richiesta HERE, km, minuti e
-- la polilinea stradale; PIANO_DRIVER_VARIAZIONI lo storico. AI_HERE_Risposta aggiorna sia
-- PIANO_DRIVER sia (per le richieste vecchie) GIRI_PIANO.
-- =============================================================
IF OBJECT_ID('dbo.PIANO_DRIVER') IS NULL
CREATE TABLE dbo.PIANO_DRIVER (
    IdPianoDriver    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PIANO_DRIVER PRIMARY KEY,
    Data             date NOT NULL,
    IdFiliale        int NOT NULL,
    IdDriver         int NOT NULL,
    PartenzaCasa     bit NOT NULL CONSTRAINT DF_PIANO_DRIVER_PartenzaCasa DEFAULT (0),
    RitornoCasa      bit NOT NULL CONSTRAINT DF_PIANO_DRIVER_RitornoCasa DEFAULT (0),
    IdGeoHereW       int NULL,
    Stato            varchar(20) NULL,          -- NULL, RICHIESTA, IN_CORSO, FATTA, ERRORE
    DaRifare         bit NOT NULL CONSTRAINT DF_PIANO_DRIVER_DaRifare DEFAULT (0),   -- giri o opzioni cambiati dopo il percorso
    NPunti           int NULL,
    NSenzaCoordinate int NULL,
    DistanzaM        int NULL,
    TempoS           int NULL,
    Polilinea        nvarchar(max) NULL,        -- JSON [[lat,lng],...] del tracciato stradale (HERE Routing)
    Errore           nvarchar(500) NULL,
    DataRichiesta    datetime NULL,
    DataRisposta     datetime NULL,
    DataModifica     datetime NOT NULL CONSTRAINT DF_PIANO_DRIVER_DataModifica DEFAULT (GETDATE()),
    Utente           varchar(100) NULL,
    CONSTRAINT UQ_PIANO_DRIVER UNIQUE (Data, IdDriver)
);
GO
IF OBJECT_ID('dbo.PIANO_DRIVER_VARIAZIONI') IS NULL
CREATE TABLE dbo.PIANO_DRIVER_VARIAZIONI (
    IdVariazione  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PIANO_DRIVER_VARIAZIONI PRIMARY KEY,
    IdPianoDriver int NOT NULL,
    DataOra       datetime NOT NULL CONSTRAINT DF_PIANO_DRIVER_VARIAZIONI_DataOra DEFAULT (GETDATE()),
    Utente        varchar(100) NULL,
    Campo         varchar(30) NOT NULL,         -- Giro, Opzioni, Ottimizzazione
    Prima         nvarchar(200) NULL,
    Dopo          nvarchar(200) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PIANO_DRIVER_VARIAZIONI_Piano')
    CREATE INDEX IX_PIANO_DRIVER_VARIAZIONI_Piano ON dbo.PIANO_DRIVER_VARIAZIONI (IdPianoDriver, DataOra);
GO
IF OBJECT_ID('dbo.UTENTI_GEO') IS NULL
CREATE TABLE dbo.UTENTI_GEO (
    IdUtente     int NOT NULL CONSTRAINT PK_UTENTI_GEO PRIMARY KEY,
    Indirizzo    nvarchar(300) NULL,
    Lat          float NULL,
    Lng          float NULL,
    Origine      varchar(20) NULL,              -- HERE (geocodificato), MANUALE
    DataModifica datetime NOT NULL CONSTRAINT DF_UTENTI_GEO_DataModifica DEFAULT (GETDATE()),
    Utente       varchar(100) NULL
);
GO

CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_GEO_Save
    @IdUtente int, @Indirizzo nvarchar(300), @Lat float = NULL, @Lng float = NULL, @Origine varchar(20) = 'HERE', @Utente varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM dbo.UTENTI_GEO WHERE IdUtente = @IdUtente)
        UPDATE dbo.UTENTI_GEO SET Indirizzo = @Indirizzo, Lat = @Lat, Lng = @Lng, Origine = @Origine, DataModifica = GETDATE(), Utente = @Utente WHERE IdUtente = @IdUtente;
    ELSE
        INSERT INTO dbo.UTENTI_GEO (IdUtente, Indirizzo, Lat, Lng, Origine, Utente) VALUES (@IdUtente, @Indirizzo, @Lat, @Lng, @Origine, @Utente);
    -- il percorso di oggi e dei giorni futuri va rifatto se partiva o tornava da casa
    UPDATE dbo.PIANO_DRIVER SET DaRifare = 1 WHERE IdDriver = @IdUtente AND Data >= CAST(GETDATE() AS date) AND Stato = 'FATTA' AND (PartenzaCasa = 1 OR RitornoCasa = 1);
END
GO

-- La riga (data, driver): la crea se manca.
CREATE OR ALTER PROCEDURE dbo.AI_PIANO_DriverRiga
    @IdFiliale int, @Data date, @IdDriver int, @Utente varchar(100) = NULL, @Id int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Id = IdPianoDriver FROM dbo.PIANO_DRIVER WHERE Data = @Data AND IdDriver = @IdDriver;
    IF @Id IS NULL
    BEGIN
        INSERT INTO dbo.PIANO_DRIVER (Data, IdFiliale, IdDriver, Utente) VALUES (@Data, @IdFiliale, @IdDriver, @Utente);
        SET @Id = SCOPE_IDENTITY();
    END
END
GO

-- Giro -> driver (NULL = toglie): come prima, ma segna "da rifare" il percorso dei driver toccati.
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
        DECLARE @giro varchar(50) = (SELECT Giro FROM dbo.GEO_GIRI WHERE IdGiro = @IdGiro), @IdPD int;
        IF @IdDriver IS NOT NULL
        BEGIN
            EXEC dbo.AI_PIANO_DriverRiga @IdFiliale, @Data, @IdDriver, @Utente, @IdPD OUTPUT;
            INSERT INTO dbo.PIANO_DRIVER_VARIAZIONI (IdPianoDriver, Utente, Campo, Prima, Dopo) VALUES (@IdPD, @Utente, 'Giro', NULL, 'preso ' + @giro);
        END
        IF @Prima IS NOT NULL
        BEGIN
            SET @IdPD = NULL;
            EXEC dbo.AI_PIANO_DriverRiga @IdFiliale, @Data, @Prima, @Utente, @IdPD OUTPUT;
            INSERT INTO dbo.PIANO_DRIVER_VARIAZIONI (IdPianoDriver, Utente, Campo, Prima, Dopo) VALUES (@IdPD, @Utente, 'Giro', 'tolto ' + @giro, NULL);
        END
        UPDATE dbo.PIANO_DRIVER SET DaRifare = 1, DataModifica = GETDATE()
        WHERE Data = @Data AND Stato = 'FATTA' AND IdDriver IN (ISNULL(@Prima, -1), ISNULL(@IdDriver, -1));
    END
    SELECT p.IdPiano, p.IdDriver, u.Nome AS Driver FROM dbo.GIRI_PIANO p LEFT JOIN dbo.UTENTI u ON u.IdUtente = p.IdDriver WHERE p.IdPiano = @IdPiano;
END
GO

-- Partenza e ritorno da casa (1) o dalla filiale (0).
CREATE OR ALTER PROCEDURE dbo.AI_PIANO_DriverOpzioni
    @IdFiliale int, @Data date, @IdDriver int, @PartenzaCasa bit, @RitornoCasa bit, @Utente varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Id int;
    EXEC dbo.AI_PIANO_DriverRiga @IdFiliale, @Data, @IdDriver, @Utente, @Id OUTPUT;
    DECLARE @p0 bit, @r0 bit;
    SELECT @p0 = PartenzaCasa, @r0 = RitornoCasa FROM dbo.PIANO_DRIVER WHERE IdPianoDriver = @Id;
    IF @p0 <> @PartenzaCasa OR @r0 <> @RitornoCasa
    BEGIN
        INSERT INTO dbo.PIANO_DRIVER_VARIAZIONI (IdPianoDriver, Utente, Campo, Prima, Dopo)
        VALUES (@Id, @Utente, 'Opzioni',
                'parte ' + CASE WHEN @p0 = 1 THEN 'da casa' ELSE 'dalla filiale' END + ', torna ' + CASE WHEN @r0 = 1 THEN 'a casa' ELSE 'in filiale' END,
                'parte ' + CASE WHEN @PartenzaCasa = 1 THEN 'da casa' ELSE 'dalla filiale' END + ', torna ' + CASE WHEN @RitornoCasa = 1 THEN 'a casa' ELSE 'in filiale' END);
        UPDATE dbo.PIANO_DRIVER SET PartenzaCasa = @PartenzaCasa, RitornoCasa = @RitornoCasa, DaRifare = CASE WHEN Stato = 'FATTA' THEN 1 ELSE DaRifare END,
               DataModifica = GETDATE(), Utente = @Utente WHERE IdPianoDriver = @Id;
    END
    SELECT IdPianoDriver, PartenzaCasa, RitornoCasa, DaRifare FROM dbo.PIANO_DRIVER WHERE IdPianoDriver = @Id;
END
GO

-- Richiesta di ottimizzazione per un driver: tutte le consegne con coordinate dei suoi giri del giorno,
-- partenza e ritorno da casa (UTENTI_GEO) o dalla filiale.
CREATE OR ALTER PROCEDURE dbo.AI_HERE_RichiestaDriver
    @IdFiliale int, @Data date, @IdDriver int, @IdUtente int = NULL, @Utente varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Data IS NULL SET @Data = CAST(GETDATE() AS date);
    DECLARE @dal datetime = @Data, @al datetime = DATEADD(day, 1, @Data);
    DECLARE @Id int;
    EXEC dbo.AI_PIANO_DriverRiga @IdFiliale, @Data, @IdDriver, @Utente, @Id OUTPUT;
    IF EXISTS (SELECT 1 FROM dbo.PIANO_DRIVER WHERE IdPianoDriver = @Id AND Stato IN ('RICHIESTA', 'IN_CORSO') AND DataRichiesta > DATEADD(minute, -15, GETDATE()))
    BEGIN
        RAISERROR('C''e'' gia'' un''ottimizzazione in corso per questo driver', 16, 1);
        RETURN;
    END
    DECLARE @flat float, @flng float, @fnome varchar(200), @pc bit, @rc bit, @clat float, @clng float, @cind nvarchar(300), @driver varchar(100);
    SELECT @flat = Latitude, @flng = Longitude, @fnome = FILIALE FROM dbo.FILIALI WHERE IDFILIALE = @IdFiliale;
    SELECT @pc = PartenzaCasa, @rc = RitornoCasa FROM dbo.PIANO_DRIVER WHERE IdPianoDriver = @Id;
    SELECT @clat = g.Lat, @clng = g.Lng, @cind = g.Indirizzo FROM dbo.UTENTI_GEO g WHERE g.IdUtente = @IdDriver;
    SELECT @driver = Nome FROM dbo.UTENTI WHERE IdUtente = @IdDriver;
    IF (@pc = 1 OR @rc = 1) AND (@clat IS NULL OR @clng IS NULL)
    BEGIN
        RAISERROR('Il driver parte o torna da casa ma l''indirizzo di casa non ha le coordinate: impostalo dal menu del driver', 16, 1);
        RETURN;
    END
    IF (@pc = 0 OR @rc = 0) AND (@flat IS NULL OR @flng IS NULL)
    BEGIN
        RAISERROR('La filiale non ha le coordinate (FILIALI.Latitude/Longitude)', 16, 1);
        RETURN;
    END
    DECLARE @n int, @senza int;
    SELECT @n = SUM(CASE WHEN s.DestinazioneLatitude IS NOT NULL THEN 1 ELSE 0 END), @senza = SUM(CASE WHEN s.DestinazioneLatitude IS NULL THEN 1 ELSE 0 END)
    FROM dbo.SPED_ATTIVITA s
    WHERE s.IdFiliale = @IdFiliale AND s.DataCarico >= @dal AND s.DataCarico < @al
      AND s.IdGiro IN (SELECT IdGiro FROM dbo.GIRI_PIANO WHERE Data = @Data AND IdDriver = @IdDriver);
    IF ISNULL(@n, 0) = 0
    BEGIN
        RAISERROR('Il driver non ha consegne con coordinate per il giorno scelto', 16, 1);
        RETURN;
    END
    DECLARE @slat float = CASE WHEN @pc = 1 THEN @clat ELSE @flat END, @slng float = CASE WHEN @pc = 1 THEN @clng ELSE @flng END,
            @elat float = CASE WHEN @rc = 1 THEN @clat ELSE @flat END, @elng float = CASE WHEN @rc = 1 THEN @clng ELSE @flng END;
    BEGIN TRAN;
    INSERT INTO dbo.GEO_HereW (Nome, IdFilialeStart, Latitude1, Longitude1, IdFilialeStop, Latitude2, Longitude2, DataInserimento, IdUtente)
    VALUES (CONVERT(varchar(8), @Data, 112) + '_DRIVER_' + CAST(@IdDriver AS varchar(10)) + '_' + REPLACE(CONVERT(varchar(5), GETDATE(), 108), ':', ''),
            @IdFiliale, @slat, @slng, @IdFiliale, @elat, @elng, GETDATE(), @IdUtente);
    DECLARE @IdGeoHereW int = SCOPE_IDENTITY();
    INSERT INTO dbo.GEO_HereWReq (IdGeoHereW, IdAttivita, Latitude, Longitude, Indirizzo)
    VALUES (@IdGeoHereW, 0, @slat, @slng, CASE WHEN @pc = 1 THEN 'Casa: ' + LEFT(ISNULL(@cind, ''), 480) ELSE @fnome END);
    INSERT INTO dbo.GEO_HereWReq (IdGeoHereW, IdSpedizione, Latitude, Longitude, Indirizzo)
    SELECT @IdGeoHereW, s.IdSpedizione, s.DestinazioneLatitude, s.DestinazioneLongitude,
           LEFT(ISNULL(s.DestinazioneIndirizzo, '') + ISNULL(' ' + s.DestinazioneNumeroCivico, '') + ISNULL(', ' + s.DestinazioneCap, '') + ISNULL(' ' + s.DestinazioneLocalita, ''), 500)
    FROM dbo.SPED_ATTIVITA s
    WHERE s.IdFiliale = @IdFiliale AND s.DataCarico >= @dal AND s.DataCarico < @al AND s.DestinazioneLatitude IS NOT NULL
      AND s.IdGiro IN (SELECT IdGiro FROM dbo.GIRI_PIANO WHERE Data = @Data AND IdDriver = @IdDriver)
    ORDER BY s.IdGiro, s.IdSpedizione;
    INSERT INTO dbo.GEO_HereWReq (IdGeoHereW, IdAttivita, Latitude, Longitude, Indirizzo)
    VALUES (@IdGeoHereW, 999999999, @elat, @elng, CASE WHEN @rc = 1 THEN 'Casa: ' + LEFT(ISNULL(@cind, ''), 480) ELSE @fnome END);
    UPDATE dbo.PIANO_DRIVER
       SET IdGeoHereW = @IdGeoHereW, Stato = 'RICHIESTA', DaRifare = 0, NPunti = @n, NSenzaCoordinate = ISNULL(@senza, 0),
           DistanzaM = NULL, TempoS = NULL, Polilinea = NULL, Errore = NULL, DataRichiesta = GETDATE(), DataRisposta = NULL,
           DataModifica = GETDATE(), Utente = @Utente
     WHERE IdPianoDriver = @Id;
    INSERT INTO dbo.PIANO_DRIVER_VARIAZIONI (IdPianoDriver, Utente, Campo, Prima, Dopo)
    VALUES (@Id, @Utente, 'Ottimizzazione', NULL, 'richiesta: ' + CAST(@n AS varchar(10)) + ' consegne (HERE ' + CAST(@IdGeoHereW AS varchar(10)) + ')');
    COMMIT;
    SELECT @Id AS IdPianoDriver, @IdGeoHereW AS IdGeoHereW, @n AS NPunti, ISNULL(@senza, 0) AS NSenzaCoordinate;
END
GO

CREATE OR ALTER PROCEDURE dbo.AI_HERE_InCorso
    @IdGeoHereW int
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.GIRI_PIANO SET Stato = 'IN_CORSO', DataModifica = GETDATE() WHERE IdGeoHereW = @IdGeoHereW;
    UPDATE dbo.PIANO_DRIVER SET Stato = 'IN_CORSO', DataModifica = GETDATE() WHERE IdGeoHereW = @IdGeoHereW;
END
GO

-- La risposta di HERE (o l'errore): punti in GEO_HereWaypoint, Sequenza sulle spedizioni, piano aggiornato
-- (PIANO_DRIVER per le richieste per driver, GIRI_PIANO per quelle vecchie per giro), polilinea stradale.
CREATE OR ALTER PROCEDURE dbo.AI_HERE_Risposta
    @IdGeoHereW int,
    @Waypoints  nvarchar(max) = NULL,
    @DistanzaM  int = NULL,
    @TempoS     int = NULL,
    @Polilinea  nvarchar(max) = NULL,
    @Errore     nvarchar(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @IdPiano int = (SELECT TOP 1 IdPiano FROM dbo.GIRI_PIANO WHERE IdGeoHereW = @IdGeoHereW);
    DECLARE @IdPD int = (SELECT TOP 1 IdPianoDriver FROM dbo.PIANO_DRIVER WHERE IdGeoHereW = @IdGeoHereW);
    IF @Errore IS NOT NULL
    BEGIN
        UPDATE dbo.GEO_HereW SET DataRisposta = GETDATE() WHERE IdGeoHereW = @IdGeoHereW;
        UPDATE dbo.GIRI_PIANO SET Stato = 'ERRORE', Errore = LEFT(@Errore, 500), DataRisposta = GETDATE(), DataModifica = GETDATE() WHERE IdPiano = @IdPiano;
        UPDATE dbo.PIANO_DRIVER SET Stato = 'ERRORE', Errore = LEFT(@Errore, 500), DataRisposta = GETDATE(), DataModifica = GETDATE() WHERE IdPianoDriver = @IdPD;
        INSERT INTO dbo.GIRI_PIANO_VARIAZIONI (IdPiano, Campo, Prima, Dopo) SELECT @IdPiano, 'Ottimizzazione', NULL, 'errore: ' + LEFT(@Errore, 180) WHERE @IdPiano IS NOT NULL;
        INSERT INTO dbo.PIANO_DRIVER_VARIAZIONI (IdPianoDriver, Campo, Prima, Dopo) SELECT @IdPD, 'Ottimizzazione', NULL, 'errore: ' + LEFT(@Errore, 180) WHERE @IdPD IS NOT NULL;
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
    DECLARE @esito nvarchar(200) = 'fatta: ' + CAST(ISNULL(@DistanzaM, 0) / 1000 AS varchar(10)) + ' km, ' + CAST(ISNULL(@TempoS, 0) / 60 AS varchar(10)) + ' min';
    UPDATE dbo.GIRI_PIANO SET Stato = 'FATTA', DistanzaM = @DistanzaM, TempoS = @TempoS, Errore = NULL, DataRisposta = GETDATE(), DataModifica = GETDATE() WHERE IdPiano = @IdPiano;
    UPDATE dbo.PIANO_DRIVER SET Stato = 'FATTA', DaRifare = 0, DistanzaM = @DistanzaM, TempoS = @TempoS, Polilinea = @Polilinea, Errore = NULL, DataRisposta = GETDATE(), DataModifica = GETDATE() WHERE IdPianoDriver = @IdPD;
    INSERT INTO dbo.GIRI_PIANO_VARIAZIONI (IdPiano, Campo, Prima, Dopo) SELECT @IdPiano, 'Ottimizzazione', NULL, @esito WHERE @IdPiano IS NOT NULL;
    INSERT INTO dbo.PIANO_DRIVER_VARIAZIONI (IdPianoDriver, Campo, Prima, Dopo) SELECT @IdPD, 'Ottimizzazione', NULL, @esito WHERE @IdPD IS NOT NULL;
    COMMIT;
    SELECT @IdPD AS IdPianoDriver, @IdPiano AS IdPiano;
END
GO
