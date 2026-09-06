-- Palmari aziendali (Samsung XCover gestiti con Knox Manage): anagrafica dal file
-- "Device List" di Knox, collegamento alla SIM (per ICCID o numero), alla filiale
-- (dal tag Knox, quando corrisponde a una filiale sola) e all'uso quotidiano dei
-- driver, che l'app registra in UTENTI_ATTIVITA.Palmare con l'Android ID del
-- dispositivo: quello non sta nel file Knox e si abbina dalla scheda.
-- Scritture solo via AI_PALMARI_*. Idempotente.
USE DeliveryDB;
GO

IF OBJECT_ID('dbo.PALMARI', 'U') IS NULL
CREATE TABLE dbo.PALMARI (
    IdPalmare        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PALMARI PRIMARY KEY,
    Seriale          VARCHAR(30)   NOT NULL CONSTRAINT UQ_PALMARI_Seriale UNIQUE,
    Imei             VARCHAR(20)   NULL,
    Imei2            VARCHAR(20)   NULL,
    Mac              VARCHAR(20)   NULL,
    AndroidId        VARCHAR(32)   NULL,          -- l'identificativo che l'app scrive in UTENTI_ATTIVITA.Palmare
    NomeDevice       NVARCHAR(100) NULL,
    Alias            NVARCHAR(100) NULL,
    Modello          NVARCHAR(60)  NULL,
    Produttore       NVARCHAR(40)  NULL,
    Piattaforma      VARCHAR(20)   NULL,
    VersioneOS       VARCHAR(20)   NULL,
    VersioneAgent    VARCHAR(30)   NULL,
    Firmware         VARCHAR(60)   NULL,
    StatoMdm         VARCHAR(30)   NULL,          -- Enrolled / Unenrolled ... (Knox)
    TipoGestione     VARCHAR(40)   NULL,
    TipoEnrollment   VARCHAR(40)   NULL,
    Organizzazione   NVARCHAR(60)  NULL,
    Profilo          NVARCHAR(120) NULL,
    UtenteMdm        NVARCHAR(50)  NULL,
    Tag              NVARCHAR(50)  NULL,          -- Device Tag di Knox (di solito la filiale)
    NumeroMobile     VARCHAR(20)   NULL,
    ICCID            VARCHAR(32)   NULL,
    EID              VARCHAR(40)   NULL,
    IdSim            INT           NULL CONSTRAINT FK_PALMARI_SIM REFERENCES dbo.SIM (IdSim),
    IdFiliale        INT           NULL,
    Problema         NVARCHAR(100) NULL,
    UltimoComando    NVARCHAR(60)  NULL,
    Roaming          BIT           NULL,
    UltimoContatto   NVARCHAR(20)  NULL,          -- "Last Seen" di Knox, com'e' scritto (21m, 3h, 2d)
    UltimoAggiornamentoMdm DATE    NULL,
    CodiceKiosk      VARCHAR(20)   NULL,
    CodiceUnenroll   VARCHAR(30)   NULL,
    CodiceSblocco    VARCHAR(20)   NULL,
    Stato            VARCHAR(20)   NOT NULL CONSTRAINT DF_PALMARI_Stato DEFAULT ('In uso'),   -- In uso / Scorta / Guasto / Dismesso
    Note             NVARCHAR(500) NULL,
    DataImport       DATETIME      NULL,
    DataCreazione    DATETIME      NOT NULL CONSTRAINT DF_PALMARI_DataCreazione DEFAULT (GETDATE()),
    DataModifica     DATETIME      NULL,
    UtenteModifica   NVARCHAR(50)  NULL
);
GO
IF COL_LENGTH('dbo.PALMARI', 'Email') IS NULL
    ALTER TABLE dbo.PALMARI ADD Email NVARCHAR(100) NULL, Gruppi NVARCHAR(300) NULL, ProfiliAssegnati NVARCHAR(300) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PALMARI_AndroidId') CREATE INDEX IX_PALMARI_AndroidId ON dbo.PALMARI (AndroidId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PALMARI_IdSim') CREATE INDEX IX_PALMARI_IdSim ON dbo.PALMARI (IdSim);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_UTENTI_ATTIVITA_Palmare') CREATE INDEX IX_UTENTI_ATTIVITA_Palmare ON dbo.UTENTI_ATTIVITA (Palmare, data) INCLUDE (idUtente, idFiliale);
GO

-- cosa e' cambiato su un palmare (SIM, filiale, tag, stato, Android ID...): da import o dalla pagina
IF OBJECT_ID('dbo.PALMARI_VARIAZIONI', 'U') IS NULL
CREATE TABLE dbo.PALMARI_VARIAZIONI (
    IdVariazione      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PALMARI_VARIAZIONI PRIMARY KEY,
    IdPalmare         INT           NOT NULL CONSTRAINT FK_PALMARI_VARIAZIONI REFERENCES dbo.PALMARI (IdPalmare) ON DELETE CASCADE,
    Data              DATE          NOT NULL,
    Campo             VARCHAR(30)   NOT NULL,
    Prima             NVARCHAR(200) NULL,
    Dopo              NVARCHAR(200) NULL,
    Origine           VARCHAR(30)   NOT NULL,     -- INIZIALE / IMPORT / MANUALE
    Utente            NVARCHAR(50)  NULL,
    DataRegistrazione DATETIME      NOT NULL CONSTRAINT DF_PALMARI_VARIAZIONI_Data DEFAULT (GETDATE())
);
GO

-- dove stava il palmare: la "Last Location" di ogni export Knox (una riga per istante),
-- e in futuro altre fonti (Origine)
IF OBJECT_ID('dbo.PALMARI_POSIZIONI', 'U') IS NULL
CREATE TABLE dbo.PALMARI_POSIZIONI (
    IdPosizione   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PALMARI_POSIZIONI PRIMARY KEY,
    IdPalmare     INT           NOT NULL CONSTRAINT FK_PALMARI_POSIZIONI REFERENCES dbo.PALMARI (IdPalmare) ON DELETE CASCADE,
    DataOra       DATETIME      NOT NULL,          -- ora locale, com'e' nel file
    Latitudine    DECIMAL(9,6)  NOT NULL,
    Longitudine   DECIMAL(9,6)  NOT NULL,
    Origine       VARCHAR(20)   NOT NULL CONSTRAINT DF_PALMARI_POSIZIONI_Origine DEFAULT ('KNOX'),
    FileOrigine   NVARCHAR(200) NULL,
    DataImport    DATETIME      NOT NULL CONSTRAINT DF_PALMARI_POSIZIONI_Data DEFAULT (GETDATE()),
    CONSTRAINT UQ_PALMARI_POSIZIONI UNIQUE (IdPalmare, Origine, DataOra)
);
GO

-- una posizione: si aggiunge solo se per quell'istante non c'e' gia'
CREATE OR ALTER PROCEDURE dbo.AI_PALMARI_POSIZIONE_Save
    @IdPalmare   INT,
    @DataOra     DATETIME,
    @Latitudine  DECIMAL(9,6),
    @Longitudine DECIMAL(9,6),
    @Origine     VARCHAR(20)   = 'KNOX',
    @FileOrigine NVARCHAR(200) = NULL,
    @Nuova       BIT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Nuova = 0;
    IF NOT EXISTS (SELECT 1 FROM dbo.PALMARI WHERE IdPalmare = @IdPalmare) BEGIN RAISERROR('AI_PALMARI_POSIZIONE_Save: palmare %d inesistente.', 16, 1, @IdPalmare); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.PALMARI_POSIZIONI WHERE IdPalmare = @IdPalmare AND Origine = @Origine AND DataOra = @DataOra) RETURN;
    INSERT INTO dbo.PALMARI_POSIZIONI (IdPalmare, DataOra, Latitudine, Longitudine, Origine, FileOrigine)
    VALUES (@IdPalmare, @DataOra, @Latitudine, @Longitudine, @Origine, @FileOrigine);
    SET @Nuova = 1;
END
GO

-- l'elenco: palmare + SIM + filiale + ultimo uso registrato dall'app + ultima posizione
CREATE OR ALTER VIEW dbo.V_Palmari AS
SELECT p.*,
       f.FILIALE AS Filiale,
       pos.DataOra AS PosizioneData, pos.Latitudine AS PosizioneLat, pos.Longitudine AS PosizioneLng,
       pr.latitude AS AppLat, pr.longitude AS AppLng,
       s.Numero AS SimNumero, s.PianoTariffario AS SimPiano, s.Stato AS SimStato, s.PercResidua AS SimPercResidua, s.UltimaRilevazione AS SimRilevazione,
       u.data AS UltimoUso, u.idUtente AS UltimoIdUtente, ut.Nome AS UltimoDriver, fu.FILIALE AS UltimaFiliale,
       (SELECT COUNT(DISTINCT a.data) FROM dbo.UTENTI_ATTIVITA a WHERE a.Palmare = p.AndroidId AND a.data >= DATEADD(day, -30, CAST(GETDATE() AS DATE))) AS GiorniUso30,
       pr.datainserimento AS UltimoEventoApp, pr.appVersion AS VersioneApp
FROM dbo.PALMARI p
LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = p.IdFiliale
LEFT JOIN dbo.V_Sim s ON s.IdSim = p.IdSim
OUTER APPLY (SELECT TOP 1 a.data, a.idUtente, a.idFiliale FROM dbo.UTENTI_ATTIVITA a WHERE p.AndroidId IS NOT NULL AND a.Palmare = p.AndroidId ORDER BY a.data DESC, a.idAttivita DESC) u
LEFT JOIN dbo.UTENTI ut ON ut.IdUtente = u.idUtente
LEFT JOIN dbo.FILIALI fu ON fu.IDFILIALE = u.idFiliale
OUTER APPLY (SELECT TOP 1 r.datainserimento, r.appVersion, r.latitude, r.longitude FROM dbo.PALM_RAW r WHERE p.AndroidId IS NOT NULL AND r.imei = p.AndroidId ORDER BY r.id DESC) pr
OUTER APPLY (SELECT TOP 1 x.DataOra, x.Latitudine, x.Longitudine FROM dbo.PALMARI_POSIZIONI x WHERE x.IdPalmare = p.IdPalmare ORDER BY x.DataOra DESC) pos;
GO

-- Salvataggio dalla pagina: tutti i campi. Le variazioni sui campi che contano restano in PALMARI_VARIAZIONI.
CREATE OR ALTER PROCEDURE dbo.AI_PALMARI_Save
    @IdPalmare  INT           = NULL OUTPUT,
    @Seriale    VARCHAR(30),
    @Imei       VARCHAR(20)   = NULL,
    @Imei2      VARCHAR(20)   = NULL,
    @Mac        VARCHAR(20)   = NULL,
    @AndroidId  VARCHAR(32)   = NULL,
    @NomeDevice NVARCHAR(100) = NULL,
    @Alias      NVARCHAR(100) = NULL,
    @Modello    NVARCHAR(60)  = NULL,
    @Produttore NVARCHAR(40)  = NULL,
    @Tag        NVARCHAR(50)  = NULL,
    @NumeroMobile VARCHAR(20) = NULL,
    @ICCID      VARCHAR(32)   = NULL,
    @IdSim      INT           = NULL,
    @IdFiliale  INT           = NULL,
    @Stato      VARCHAR(20)   = NULL,
    @Note       NVARCHAR(500) = NULL,
    @Utente     NVARCHAR(50)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Seriale = LTRIM(RTRIM(ISNULL(@Seriale, '')));
    IF @Seriale = '' BEGIN RAISERROR('AI_PALMARI_Save: il seriale e'' obbligatorio.', 16, 1); RETURN; END
    SET @AndroidId = LOWER(NULLIF(LTRIM(RTRIM(@AndroidId)), ''));
    SET @Stato = ISNULL(NULLIF(LTRIM(RTRIM(@Stato)), ''), 'In uso');
    SET @Tag = NULLIF(LTRIM(RTRIM(@Tag)), ''); SET @Note = NULLIF(LTRIM(RTRIM(@Note)), ''); SET @Alias = NULLIF(LTRIM(RTRIM(@Alias)), '');
    SET @ICCID = NULLIF(LTRIM(RTRIM(@ICCID)), ''); SET @NumeroMobile = NULLIF(LTRIM(RTRIM(@NumeroMobile)), '');
    IF @AndroidId IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.PALMARI WHERE AndroidId = @AndroidId AND IdPalmare <> ISNULL(@IdPalmare, -1))
    BEGIN RAISERROR('AI_PALMARI_Save: l''Android ID %s e'' gia'' abbinato a un altro palmare.', 16, 1, @AndroidId); RETURN; END

    DECLARE @Oggi DATE = CAST(GETDATE() AS DATE);
    IF @IdPalmare IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.PALMARI WHERE Seriale = @Seriale)
        BEGIN RAISERROR('AI_PALMARI_Save: il seriale %s esiste gia''.', 16, 1, @Seriale); RETURN; END
        INSERT INTO dbo.PALMARI (Seriale, Imei, Imei2, Mac, AndroidId, NomeDevice, Alias, Modello, Produttore, Tag, NumeroMobile, ICCID,
                                 IdSim, IdFiliale, Stato, Note, DataModifica, UtenteModifica)
        VALUES (@Seriale, @Imei, @Imei2, @Mac, @AndroidId, @NomeDevice, @Alias, @Modello, @Produttore, @Tag, @NumeroMobile, @ICCID,
                @IdSim, @IdFiliale, @Stato, @Note, GETDATE(), @Utente);
        SET @IdPalmare = SCOPE_IDENTITY();
        INSERT INTO dbo.PALMARI_VARIAZIONI (IdPalmare, Data, Campo, Prima, Dopo, Origine, Utente) VALUES (@IdPalmare, @Oggi, 'Creazione', NULL, @Seriale, 'INIZIALE', @Utente);
        RETURN;
    END

    DECLARE @p TABLE (AndroidId VARCHAR(32), Tag NVARCHAR(50), IdSim INT, IdFiliale INT, Stato VARCHAR(20));
    INSERT INTO @p SELECT AndroidId, Tag, IdSim, IdFiliale, Stato FROM dbo.PALMARI WHERE IdPalmare = @IdPalmare;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR('AI_PALMARI_Save: palmare %d inesistente.', 16, 1, @IdPalmare); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.PALMARI WHERE Seriale = @Seriale AND IdPalmare <> @IdPalmare)
    BEGIN RAISERROR('AI_PALMARI_Save: il seriale %s appartiene a un altro palmare.', 16, 1, @Seriale); RETURN; END

    UPDATE dbo.PALMARI
       SET Seriale = @Seriale, Imei = @Imei, Imei2 = @Imei2, Mac = @Mac, AndroidId = @AndroidId, NomeDevice = @NomeDevice, Alias = @Alias,
           Modello = @Modello, Produttore = @Produttore, Tag = @Tag, NumeroMobile = @NumeroMobile, ICCID = @ICCID, IdSim = @IdSim,
           IdFiliale = @IdFiliale, Stato = @Stato, Note = @Note, DataModifica = GETDATE(), UtenteModifica = @Utente
     WHERE IdPalmare = @IdPalmare;

    INSERT INTO dbo.PALMARI_VARIAZIONI (IdPalmare, Data, Campo, Prima, Dopo, Origine, Utente)
    SELECT @IdPalmare, @Oggi, x.Campo, x.Prima, x.Dopo, 'MANUALE', @Utente
    FROM @p p CROSS APPLY (VALUES
        ('AndroidId', p.AndroidId, @AndroidId),
        ('Tag', p.Tag, @Tag),
        ('IdSim', CAST(p.IdSim AS NVARCHAR(20)), CAST(@IdSim AS NVARCHAR(20))),
        ('IdFiliale', CAST(p.IdFiliale AS NVARCHAR(20)), CAST(@IdFiliale AS NVARCHAR(20))),
        ('Stato', p.Stato, @Stato)) x (Campo, Prima, Dopo)
    WHERE ISNULL(x.Prima, '') <> ISNULL(x.Dopo, '');
END
GO

-- Import dal file Knox: tocca solo i campi che arrivano da li'. Nuovo se il seriale manca.
-- La SIM si aggancia per ICCID o per numero; la filiale (@IdFiliale) la propone l'API dal tag,
-- e si scrive solo se il palmare non ne ha gia' una. @Esito: NUOVO / AGGIORNATO / INVARIATO.
CREATE OR ALTER PROCEDURE dbo.AI_PALMARI_Import
    @Seriale        VARCHAR(30),
    @Imei           VARCHAR(20)   = NULL,
    @Imei2          VARCHAR(20)   = NULL,
    @Mac            VARCHAR(20)   = NULL,
    @NomeDevice     NVARCHAR(100) = NULL,
    @Alias          NVARCHAR(100) = NULL,
    @Modello        NVARCHAR(60)  = NULL,
    @Produttore     NVARCHAR(40)  = NULL,
    @Piattaforma    VARCHAR(20)   = NULL,
    @VersioneOS     VARCHAR(20)   = NULL,
    @VersioneAgent  VARCHAR(30)   = NULL,
    @Firmware       VARCHAR(60)   = NULL,
    @StatoMdm       VARCHAR(30)   = NULL,
    @TipoGestione   VARCHAR(40)   = NULL,
    @TipoEnrollment VARCHAR(40)   = NULL,
    @Organizzazione NVARCHAR(60)  = NULL,
    @Profilo        NVARCHAR(120) = NULL,
    @UtenteMdm      NVARCHAR(50)  = NULL,
    @Tag            NVARCHAR(50)  = NULL,
    @NumeroMobile   VARCHAR(20)   = NULL,
    @ICCID          VARCHAR(32)   = NULL,
    @EID            VARCHAR(40)   = NULL,
    @Problema       NVARCHAR(100) = NULL,
    @UltimoComando  NVARCHAR(60)  = NULL,
    @Roaming        BIT           = NULL,
    @UltimoContatto NVARCHAR(20)  = NULL,
    @UltimoAggiornamentoMdm DATE  = NULL,
    @CodiceKiosk    VARCHAR(20)   = NULL,
    @CodiceUnenroll VARCHAR(30)   = NULL,
    @CodiceSblocco  VARCHAR(20)   = NULL,
    @Email          NVARCHAR(100) = NULL,
    @Gruppi         NVARCHAR(300) = NULL,
    @ProfiliAssegnati NVARCHAR(300) = NULL,
    @IdFiliale      INT           = NULL,
    @Utente         NVARCHAR(50)  = NULL,
    @IdPalmare      INT           = NULL OUTPUT,
    @Esito          VARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Seriale = LTRIM(RTRIM(ISNULL(@Seriale, '')));
    IF @Seriale = '' BEGIN RAISERROR('AI_PALMARI_Import: seriale mancante.', 16, 1); RETURN; END
    SET @ICCID = NULLIF(LTRIM(RTRIM(@ICCID)), ''); SET @NumeroMobile = NULLIF(LTRIM(RTRIM(@NumeroMobile)), ''); SET @Tag = NULLIF(LTRIM(RTRIM(@Tag)), '');
    DECLARE @Oggi DATE = CAST(GETDATE() AS DATE);
    DECLARE @IdSim INT = (SELECT TOP 1 IdSim FROM dbo.SIM WHERE (@ICCID IS NOT NULL AND ICCID = @ICCID) OR (@NumeroMobile IS NOT NULL AND Numero = @NumeroMobile) ORDER BY CASE WHEN ICCID = @ICCID THEN 0 ELSE 1 END);

    SELECT @IdPalmare = IdPalmare FROM dbo.PALMARI WHERE Seriale = @Seriale;
    IF @IdPalmare IS NULL
    BEGIN
        INSERT INTO dbo.PALMARI (Seriale, Imei, Imei2, Mac, NomeDevice, Alias, Modello, Produttore, Piattaforma, VersioneOS, VersioneAgent, Firmware,
                                 StatoMdm, TipoGestione, TipoEnrollment, Organizzazione, Profilo, UtenteMdm, Tag, NumeroMobile, ICCID, EID, IdSim, IdFiliale,
                                 Problema, UltimoComando, Roaming, UltimoContatto, UltimoAggiornamentoMdm, CodiceKiosk, CodiceUnenroll, CodiceSblocco,
                                 Email, Gruppi, ProfiliAssegnati, DataImport, DataModifica, UtenteModifica)
        VALUES (@Seriale, @Imei, @Imei2, @Mac, @NomeDevice, @Alias, @Modello, @Produttore, @Piattaforma, @VersioneOS, @VersioneAgent, @Firmware,
                @StatoMdm, @TipoGestione, @TipoEnrollment, @Organizzazione, @Profilo, @UtenteMdm, @Tag, @NumeroMobile, @ICCID, @EID, @IdSim, @IdFiliale,
                @Problema, @UltimoComando, @Roaming, @UltimoContatto, @UltimoAggiornamentoMdm, @CodiceKiosk, @CodiceUnenroll, @CodiceSblocco,
                @Email, @Gruppi, @ProfiliAssegnati, GETDATE(), GETDATE(), @Utente);
        SET @IdPalmare = SCOPE_IDENTITY();
        INSERT INTO dbo.PALMARI_VARIAZIONI (IdPalmare, Data, Campo, Prima, Dopo, Origine, Utente) VALUES (@IdPalmare, @Oggi, 'Creazione', NULL, @Seriale, 'INIZIALE', @Utente);
        SET @Esito = 'NUOVO';
        RETURN;
    END

    DECLARE @p TABLE (ICCID VARCHAR(32), IdSim INT, Tag NVARCHAR(50), StatoMdm VARCHAR(30), UtenteMdm NVARCHAR(50), Profilo NVARCHAR(120), NumeroMobile VARCHAR(20), IdFiliale INT);
    INSERT INTO @p SELECT ICCID, IdSim, Tag, StatoMdm, UtenteMdm, Profilo, NumeroMobile, IdFiliale FROM dbo.PALMARI WHERE IdPalmare = @IdPalmare;
    -- filiale: dal tag se il palmare non ne ha una, o se il tag e' cambiato e il nuovo tag ne indica una
    DECLARE @IdFilialeNuova INT = (SELECT CASE WHEN @Tag IS NOT NULL AND ISNULL(Tag, '') <> @Tag AND @IdFiliale IS NOT NULL THEN @IdFiliale ELSE ISNULL(IdFiliale, @IdFiliale) END FROM @p);
    DECLARE @IdSimNuova INT = ISNULL(@IdSim, (SELECT IdSim FROM @p));   -- senza ICCID nel file la SIM resta quella che c'e'
    IF @ICCID IS NOT NULL AND @IdSim IS NULL SET @IdSimNuova = NULL;      -- ICCID nuovo ma sconosciuto: la SIM di prima non e' piu' quella

    UPDATE dbo.PALMARI
       SET Imei = ISNULL(@Imei, Imei), Imei2 = ISNULL(@Imei2, Imei2), Mac = ISNULL(@Mac, Mac), NomeDevice = ISNULL(@NomeDevice, NomeDevice),
           Alias = ISNULL(@Alias, Alias), Modello = ISNULL(@Modello, Modello), Produttore = ISNULL(@Produttore, Produttore),
           Piattaforma = ISNULL(@Piattaforma, Piattaforma), VersioneOS = ISNULL(@VersioneOS, VersioneOS), VersioneAgent = ISNULL(@VersioneAgent, VersioneAgent),
           Firmware = ISNULL(@Firmware, Firmware), StatoMdm = ISNULL(@StatoMdm, StatoMdm), TipoGestione = ISNULL(@TipoGestione, TipoGestione),
           TipoEnrollment = ISNULL(@TipoEnrollment, TipoEnrollment), Organizzazione = ISNULL(@Organizzazione, Organizzazione), Profilo = ISNULL(@Profilo, Profilo),
           UtenteMdm = ISNULL(@UtenteMdm, UtenteMdm), Tag = ISNULL(@Tag, Tag), NumeroMobile = ISNULL(@NumeroMobile, NumeroMobile),
           ICCID = ISNULL(@ICCID, ICCID), EID = ISNULL(@EID, EID), IdSim = @IdSimNuova, IdFiliale = @IdFilialeNuova,
           Problema = @Problema, UltimoComando = ISNULL(@UltimoComando, UltimoComando), Roaming = ISNULL(@Roaming, Roaming),
           UltimoContatto = ISNULL(@UltimoContatto, UltimoContatto), UltimoAggiornamentoMdm = ISNULL(@UltimoAggiornamentoMdm, UltimoAggiornamentoMdm),
           CodiceKiosk = ISNULL(@CodiceKiosk, CodiceKiosk), CodiceUnenroll = ISNULL(@CodiceUnenroll, CodiceUnenroll), CodiceSblocco = ISNULL(@CodiceSblocco, CodiceSblocco),
           Email = ISNULL(@Email, Email), Gruppi = ISNULL(@Gruppi, Gruppi), ProfiliAssegnati = ISNULL(@ProfiliAssegnati, ProfiliAssegnati),
           DataImport = GETDATE()
     WHERE IdPalmare = @IdPalmare;

    INSERT INTO dbo.PALMARI_VARIAZIONI (IdPalmare, Data, Campo, Prima, Dopo, Origine, Utente)
    SELECT @IdPalmare, @Oggi, x.Campo, x.Prima, x.Dopo, 'IMPORT', @Utente
    FROM @p p CROSS APPLY (VALUES
        ('ICCID', p.ICCID, ISNULL(@ICCID, p.ICCID)),
        ('IdSim', CAST(p.IdSim AS NVARCHAR(20)), CAST(@IdSimNuova AS NVARCHAR(20))),
        ('Tag', p.Tag, ISNULL(@Tag, p.Tag)),
        ('StatoMdm', p.StatoMdm, ISNULL(@StatoMdm, p.StatoMdm)),
        ('UtenteMdm', p.UtenteMdm, ISNULL(@UtenteMdm, p.UtenteMdm)),
        ('Profilo', p.Profilo, ISNULL(@Profilo, p.Profilo)),
        ('NumeroMobile', p.NumeroMobile, ISNULL(@NumeroMobile, p.NumeroMobile)),
        ('IdFiliale', CAST(p.IdFiliale AS NVARCHAR(20)), CAST(@IdFilialeNuova AS NVARCHAR(20)))) x (Campo, Prima, Dopo)
    WHERE ISNULL(x.Prima, '') <> ISNULL(x.Dopo, '');
    SET @Esito = CASE WHEN @@ROWCOUNT > 0 THEN 'AGGIORNATO' ELSE 'INVARIATO' END;
END
GO

CREATE OR ALTER PROCEDURE dbo.AI_PALMARI_Del
    @IdPalmare INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.PALMARI WHERE IdPalmare = @IdPalmare;
    IF @@ROWCOUNT = 0 RAISERROR('AI_PALMARI_Del: palmare %d inesistente.', 16, 1, @IdPalmare);
END
GO

-- la SIM mostra il palmare che la monta (dalla tabella PALMARI, non piu' solo dal testo)
CREATE OR ALTER VIEW dbo.V_Sim AS
SELECT s.IdSim, s.Numero, s.ICCID, s.Operatore, s.Prodotto, s.Stato, s.DataAttivazione, s.DataCessazione,
       s.PianoTariffario, s.IdFiliale, f.FILIALE AS Filiale, s.IdUtente, u.Nome AS Dipendente, u.Matricola,
       s.AssegnataA, s.Palmare, s.SerialePalmare, s.Note, s.DataCreazione, s.DataModifica, s.UtenteModifica,
       r.DataRilevazione AS UltimaRilevazione, r.CreditoResiduo, r.GbSoglia, r.GbConsumati, r.GbResidui, r.PercResidua, r.PeriodoSoglia,
       (SELECT COUNT(*) FROM dbo.SIM_VARIAZIONI v WHERE v.IdSim = s.IdSim) AS NumVariazioni,
       pm.IdPalmare, pm.Seriale AS PalmareSeriale, pm.NomeDevice AS PalmareNome, pm.Tag AS PalmareTag
FROM dbo.SIM s
LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = s.IdFiliale
LEFT JOIN dbo.UTENTI u ON u.IdUtente = s.IdUtente
OUTER APPLY (SELECT TOP 1 * FROM dbo.SIM_RILEVAZIONI x WHERE x.IdSim = s.IdSim ORDER BY x.DataRilevazione DESC) r
OUTER APPLY (SELECT TOP 1 IdPalmare, Seriale, NomeDevice, Tag FROM dbo.PALMARI p WHERE p.IdSim = s.IdSim ORDER BY p.DataModifica DESC) pm;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/palmari')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1229, @Text = 'Palmari',
        @Descrizione = 'Palmari aziendali (Knox): dispositivi, SIM, filiale e uso quotidiano dei driver',
        @Link = '/palmari', @Sorting = 16;
GO
