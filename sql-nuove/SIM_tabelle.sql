-- Gestione delle SIM aziendali (WindTre): anagrafica, storico delle variazioni
-- di piano/stato e rilevazioni periodiche (consumi, credito) dal portale Wind.
-- Scritture solo via AI_SIM_*: la pagina salva l'anagrafica intera, l'import
-- dei file dell'operatore tocca solo i campi che arrivano da li'.
-- Idempotente. Il collegamento ai palmari oggi e' un testo (Palmare, SerialePalmare):
-- quando ci sara' la tabella dei palmari diventera' una chiave.
USE DeliveryDB;
GO

IF OBJECT_ID('dbo.SIM', 'U') IS NULL
CREATE TABLE dbo.SIM (
    IdSim            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SIM PRIMARY KEY,
    Numero           VARCHAR(20)   NOT NULL CONSTRAINT UQ_SIM_Numero UNIQUE,
    ICCID            VARCHAR(32)   NULL,
    Operatore        VARCHAR(30)   NOT NULL CONSTRAINT DF_SIM_Operatore DEFAULT ('WINDTRE'),
    Prodotto         VARCHAR(50)   NULL,          -- Mobile / Mobile Ricaricabile
    Stato            VARCHAR(20)   NOT NULL CONSTRAINT DF_SIM_Stato DEFAULT ('Attiva'),   -- Attiva / Sospesa / Cessata
    DataAttivazione  DATE          NULL,
    DataCessazione   DATE          NULL,
    PianoTariffario  VARCHAR(100)  NULL,          -- profilo corrente: l'ultima variazione
    IdFiliale        INT           NULL,          -- filiale che la gestisce
    IdUtente         INT           NULL,          -- dipendente a cui e' assegnata (UTENTI)
    AssegnataA       NVARCHAR(100) NULL,          -- oppure un testo (modem, sede, magazzino...)
    Palmare          NVARCHAR(50)  NULL,
    SerialePalmare   NVARCHAR(50)  NULL,
    Note             NVARCHAR(500) NULL,
    DataCreazione    DATETIME      NOT NULL CONSTRAINT DF_SIM_DataCreazione DEFAULT (GETDATE()),
    DataModifica     DATETIME      NULL,
    UtenteModifica   NVARCHAR(50)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SIM_ICCID')
    CREATE INDEX IX_SIM_ICCID ON dbo.SIM (ICCID);
GO

-- ogni cambio di piano o di stato: chi lo ha portato (import o pagina) e da cosa a cosa
IF OBJECT_ID('dbo.SIM_VARIAZIONI', 'U') IS NULL
CREATE TABLE dbo.SIM_VARIAZIONI (
    IdVariazione      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SIM_VARIAZIONI PRIMARY KEY,
    IdSim             INT           NOT NULL CONSTRAINT FK_SIM_VARIAZIONI_SIM REFERENCES dbo.SIM (IdSim) ON DELETE CASCADE,
    Data              DATE          NOT NULL,     -- data della variazione (rilevazione o inserimento)
    PianoTariffario   VARCHAR(100)  NULL,
    Stato             VARCHAR(20)   NULL,
    PianoPrecedente   VARCHAR(100)  NULL,
    StatoPrecedente   VARCHAR(20)   NULL,
    Origine           VARCHAR(30)   NOT NULL,     -- INIZIALE / IMPORT / MANUALE
    Note              NVARCHAR(500) NULL,
    DataRegistrazione DATETIME      NOT NULL CONSTRAINT DF_SIM_VARIAZIONI_Data DEFAULT (GETDATE()),
    Utente            NVARCHAR(50)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SIM_VARIAZIONI_Sim')
    CREATE INDEX IX_SIM_VARIAZIONI_Sim ON dbo.SIM_VARIAZIONI (IdSim, Data);
GO

-- la fotografia periodica dal portale Wind: consumi e credito a una data
IF OBJECT_ID('dbo.SIM_RILEVAZIONI', 'U') IS NULL
CREATE TABLE dbo.SIM_RILEVAZIONI (
    IdRilevazione    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SIM_RILEVAZIONI PRIMARY KEY,
    IdSim            INT           NOT NULL CONSTRAINT FK_SIM_RILEVAZIONI_SIM REFERENCES dbo.SIM (IdSim) ON DELETE CASCADE,
    DataRilevazione  DATE          NOT NULL,
    PianoTariffario  VARCHAR(100)  NULL,
    Stato            VARCHAR(30)   NULL,
    CreditoResiduo   DECIMAL(10,2) NULL,
    GbSoglia         DECIMAL(10,3) NULL,
    GbConsumati      DECIMAL(10,3) NULL,
    GbResidui        DECIMAL(10,3) NULL,
    PercResidua      DECIMAL(6,2)  NULL,
    PeriodoSoglia    VARCHAR(30)   NULL,
    FileOrigine      NVARCHAR(200) NULL,
    DataImport       DATETIME      NOT NULL CONSTRAINT DF_SIM_RILEVAZIONI_Data DEFAULT (GETDATE()),
    CONSTRAINT UQ_SIM_RILEVAZIONI UNIQUE (IdSim, DataRilevazione)
);
GO

-- l'elenco: anagrafica + nomi + ultima rilevazione
CREATE OR ALTER VIEW dbo.V_Sim AS
SELECT s.IdSim, s.Numero, s.ICCID, s.Operatore, s.Prodotto, s.Stato, s.DataAttivazione, s.DataCessazione,
       s.PianoTariffario, s.IdFiliale, f.FILIALE AS Filiale, s.IdUtente, u.Nome AS Dipendente, u.Matricola,
       s.AssegnataA, s.Palmare, s.SerialePalmare, s.Note, s.DataCreazione, s.DataModifica, s.UtenteModifica,
       r.DataRilevazione AS UltimaRilevazione, r.CreditoResiduo, r.GbSoglia, r.GbConsumati, r.GbResidui, r.PercResidua, r.PeriodoSoglia,
       (SELECT COUNT(*) FROM dbo.SIM_VARIAZIONI v WHERE v.IdSim = s.IdSim) AS NumVariazioni
FROM dbo.SIM s
LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = s.IdFiliale
LEFT JOIN dbo.UTENTI u ON u.IdUtente = s.IdUtente
OUTER APPLY (SELECT TOP 1 * FROM dbo.SIM_RILEVAZIONI x WHERE x.IdSim = s.IdSim ORDER BY x.DataRilevazione DESC) r;
GO

-- Salvataggio dalla pagina: tutti i campi. Se piano o stato cambiano, resta traccia in SIM_VARIAZIONI.
CREATE OR ALTER PROCEDURE dbo.AI_SIM_Save
    @IdSim           INT           = NULL OUTPUT,
    @Numero          VARCHAR(20),
    @ICCID           VARCHAR(32)   = NULL,
    @Operatore       VARCHAR(30)   = NULL,
    @Prodotto        VARCHAR(50)   = NULL,
    @Stato           VARCHAR(20)   = NULL,
    @DataAttivazione DATE          = NULL,
    @DataCessazione  DATE          = NULL,
    @PianoTariffario VARCHAR(100)  = NULL,
    @IdFiliale       INT           = NULL,
    @IdUtente        INT           = NULL,
    @AssegnataA      NVARCHAR(100) = NULL,
    @Palmare         NVARCHAR(50)  = NULL,
    @SerialePalmare  NVARCHAR(50)  = NULL,
    @Note            NVARCHAR(500) = NULL,
    @Utente          NVARCHAR(50)  = NULL,
    @NotaVariazione  NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Numero = LTRIM(RTRIM(ISNULL(@Numero, '')));
    IF @Numero = '' BEGIN RAISERROR('AI_SIM_Save: il numero e'' obbligatorio.', 16, 1); RETURN; END
    SET @Stato = ISNULL(NULLIF(LTRIM(RTRIM(@Stato)), ''), 'Attiva');
    SET @Operatore = ISNULL(NULLIF(LTRIM(RTRIM(@Operatore)), ''), 'WINDTRE');
    SET @ICCID = NULLIF(LTRIM(RTRIM(@ICCID)), '');
    SET @PianoTariffario = NULLIF(LTRIM(RTRIM(@PianoTariffario)), '');
    SET @AssegnataA = NULLIF(LTRIM(RTRIM(@AssegnataA)), '');
    SET @Palmare = NULLIF(LTRIM(RTRIM(@Palmare)), '');
    SET @SerialePalmare = NULLIF(LTRIM(RTRIM(@SerialePalmare)), '');
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), '');

    IF @IdSim IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.SIM WHERE Numero = @Numero)
        BEGIN RAISERROR('AI_SIM_Save: il numero %s esiste gia''.', 16, 1, @Numero); RETURN; END
        INSERT INTO dbo.SIM (Numero, ICCID, Operatore, Prodotto, Stato, DataAttivazione, DataCessazione, PianoTariffario,
                             IdFiliale, IdUtente, AssegnataA, Palmare, SerialePalmare, Note, DataModifica, UtenteModifica)
        VALUES (@Numero, @ICCID, @Operatore, @Prodotto, @Stato, @DataAttivazione, @DataCessazione, @PianoTariffario,
                @IdFiliale, @IdUtente, @AssegnataA, @Palmare, @SerialePalmare, @Note, GETDATE(), @Utente);
        SET @IdSim = SCOPE_IDENTITY();
        INSERT INTO dbo.SIM_VARIAZIONI (IdSim, Data, PianoTariffario, Stato, Origine, Note, Utente)
        VALUES (@IdSim, ISNULL(@DataAttivazione, CAST(GETDATE() AS DATE)), @PianoTariffario, @Stato, 'INIZIALE', @NotaVariazione, @Utente);
        RETURN;
    END

    DECLARE @PianoPrima VARCHAR(100), @StatoPrima VARCHAR(20);
    SELECT @PianoPrima = PianoTariffario, @StatoPrima = Stato FROM dbo.SIM WHERE IdSim = @IdSim;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR('AI_SIM_Save: SIM %d inesistente.', 16, 1, @IdSim); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.SIM WHERE Numero = @Numero AND IdSim <> @IdSim)
    BEGIN RAISERROR('AI_SIM_Save: il numero %s appartiene a un''altra SIM.', 16, 1, @Numero); RETURN; END

    UPDATE dbo.SIM
       SET Numero = @Numero, ICCID = @ICCID, Operatore = @Operatore, Prodotto = @Prodotto, Stato = @Stato,
           DataAttivazione = @DataAttivazione, DataCessazione = @DataCessazione, PianoTariffario = @PianoTariffario,
           IdFiliale = @IdFiliale, IdUtente = @IdUtente, AssegnataA = @AssegnataA, Palmare = @Palmare,
           SerialePalmare = @SerialePalmare, Note = @Note, DataModifica = GETDATE(), UtenteModifica = @Utente
     WHERE IdSim = @IdSim;

    IF ISNULL(@PianoPrima, '') <> ISNULL(@PianoTariffario, '') OR ISNULL(@StatoPrima, '') <> ISNULL(@Stato, '')
        INSERT INTO dbo.SIM_VARIAZIONI (IdSim, Data, PianoTariffario, Stato, PianoPrecedente, StatoPrecedente, Origine, Note, Utente)
        VALUES (@IdSim, CAST(GETDATE() AS DATE), @PianoTariffario, @Stato, @PianoPrima, @StatoPrima, 'MANUALE', @NotaVariazione, @Utente);
END
GO

-- Import dai file dell'operatore: tocca solo i campi che arrivano da li' (chi la
-- gestisce, a chi e' assegnata, note restano com'erano). Nuova se il numero manca.
-- @Esito: NUOVA / AGGIORNATA / INVARIATA.
CREATE OR ALTER PROCEDURE dbo.AI_SIM_Import
    @Numero          VARCHAR(20),
    @ICCID           VARCHAR(32)   = NULL,
    @Prodotto        VARCHAR(50)   = NULL,
    @Stato           VARCHAR(20)   = NULL,
    @DataAttivazione DATE          = NULL,
    @PianoTariffario VARCHAR(100)  = NULL,
    @DataVariazione  DATE          = NULL,     -- data del file (rilevazione); default oggi
    @FileOrigine     NVARCHAR(200) = NULL,
    @Utente          NVARCHAR(50)  = NULL,
    @IdSim           INT           = NULL OUTPUT,
    @Esito           VARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Numero = LTRIM(RTRIM(ISNULL(@Numero, '')));
    IF @Numero = '' BEGIN RAISERROR('AI_SIM_Import: numero mancante.', 16, 1); RETURN; END
    SET @ICCID = NULLIF(LTRIM(RTRIM(@ICCID)), '');
    SET @Prodotto = NULLIF(LTRIM(RTRIM(@Prodotto)), '');
    SET @Stato = NULLIF(LTRIM(RTRIM(@Stato)), '');
    SET @PianoTariffario = NULLIF(LTRIM(RTRIM(@PianoTariffario)), '');
    SET @DataVariazione = ISNULL(@DataVariazione, CAST(GETDATE() AS DATE));

    SELECT @IdSim = IdSim FROM dbo.SIM WHERE Numero = @Numero;
    IF @IdSim IS NULL
    BEGIN
        INSERT INTO dbo.SIM (Numero, ICCID, Prodotto, Stato, DataAttivazione, PianoTariffario, DataModifica, UtenteModifica)
        VALUES (@Numero, @ICCID, @Prodotto, ISNULL(@Stato, 'Attiva'), @DataAttivazione, @PianoTariffario, GETDATE(), @Utente);
        SET @IdSim = SCOPE_IDENTITY();
        INSERT INTO dbo.SIM_VARIAZIONI (IdSim, Data, PianoTariffario, Stato, Origine, Note, Utente)
        VALUES (@IdSim, ISNULL(@DataAttivazione, @DataVariazione), @PianoTariffario, ISNULL(@Stato, 'Attiva'), 'INIZIALE', @FileOrigine, @Utente);
        SET @Esito = 'NUOVA';
        RETURN;
    END

    DECLARE @PianoPrima VARCHAR(100), @StatoPrima VARCHAR(20), @IccidPrima VARCHAR(32), @ProdPrima VARCHAR(50), @DataPrima DATE;
    SELECT @PianoPrima = PianoTariffario, @StatoPrima = Stato, @IccidPrima = ICCID, @ProdPrima = Prodotto, @DataPrima = DataAttivazione
      FROM dbo.SIM WHERE IdSim = @IdSim;
    DECLARE @CambiaProfilo BIT = CASE WHEN (@PianoTariffario IS NOT NULL AND ISNULL(@PianoPrima, '') <> @PianoTariffario)
                                        OR (@Stato IS NOT NULL AND ISNULL(@StatoPrima, '') <> @Stato) THEN 1 ELSE 0 END;
    DECLARE @CambiaAnag BIT = CASE WHEN (@ICCID IS NOT NULL AND ISNULL(@IccidPrima, '') <> @ICCID)
                                     OR (@Prodotto IS NOT NULL AND ISNULL(@ProdPrima, '') <> @Prodotto)
                                     OR (@DataAttivazione IS NOT NULL AND ISNULL(@DataPrima, '19000101') <> @DataAttivazione) THEN 1 ELSE 0 END;
    IF @CambiaProfilo = 0 AND @CambiaAnag = 0 BEGIN SET @Esito = 'INVARIATA'; RETURN; END

    UPDATE dbo.SIM
       SET ICCID = ISNULL(@ICCID, ICCID), Prodotto = ISNULL(@Prodotto, Prodotto), Stato = ISNULL(@Stato, Stato),
           DataAttivazione = ISNULL(@DataAttivazione, DataAttivazione), PianoTariffario = ISNULL(@PianoTariffario, PianoTariffario),
           DataModifica = GETDATE(), UtenteModifica = @Utente
     WHERE IdSim = @IdSim;
    IF @CambiaProfilo = 1
        INSERT INTO dbo.SIM_VARIAZIONI (IdSim, Data, PianoTariffario, Stato, PianoPrecedente, StatoPrecedente, Origine, Note, Utente)
        VALUES (@IdSim, @DataVariazione, ISNULL(@PianoTariffario, @PianoPrima), ISNULL(@Stato, @StatoPrima), @PianoPrima, @StatoPrima, 'IMPORT', @FileOrigine, @Utente);
    SET @Esito = 'AGGIORNATA';
END
GO

-- Una rilevazione (consumi/credito a una data): se per quella data c'e' gia', si sostituisce.
CREATE OR ALTER PROCEDURE dbo.AI_SIM_RILEVAZIONE_Save
    @IdSim           INT,
    @DataRilevazione DATE,
    @PianoTariffario VARCHAR(100)  = NULL,
    @Stato           VARCHAR(30)   = NULL,
    @CreditoResiduo  DECIMAL(10,2) = NULL,
    @GbSoglia        DECIMAL(10,3) = NULL,
    @GbConsumati     DECIMAL(10,3) = NULL,
    @GbResidui       DECIMAL(10,3) = NULL,
    @PercResidua     DECIMAL(6,2)  = NULL,
    @PeriodoSoglia   VARCHAR(30)   = NULL,
    @FileOrigine     NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.SIM WHERE IdSim = @IdSim) BEGIN RAISERROR('AI_SIM_RILEVAZIONE_Save: SIM %d inesistente.', 16, 1, @IdSim); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.SIM_RILEVAZIONI WHERE IdSim = @IdSim AND DataRilevazione = @DataRilevazione)
        UPDATE dbo.SIM_RILEVAZIONI
           SET PianoTariffario = @PianoTariffario, Stato = @Stato, CreditoResiduo = @CreditoResiduo, GbSoglia = @GbSoglia,
               GbConsumati = @GbConsumati, GbResidui = @GbResidui, PercResidua = @PercResidua, PeriodoSoglia = @PeriodoSoglia,
               FileOrigine = @FileOrigine, DataImport = GETDATE()
         WHERE IdSim = @IdSim AND DataRilevazione = @DataRilevazione;
    ELSE
        INSERT INTO dbo.SIM_RILEVAZIONI (IdSim, DataRilevazione, PianoTariffario, Stato, CreditoResiduo, GbSoglia, GbConsumati, GbResidui, PercResidua, PeriodoSoglia, FileOrigine)
        VALUES (@IdSim, @DataRilevazione, @PianoTariffario, @Stato, @CreditoResiduo, @GbSoglia, @GbConsumati, @GbResidui, @PercResidua, @PeriodoSoglia, @FileOrigine);
END
GO

CREATE OR ALTER PROCEDURE dbo.AI_SIM_Del
    @IdSim INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.SIM WHERE IdSim = @IdSim;   -- variazioni e rilevazioni a cascata
    IF @@ROWCOUNT = 0 RAISERROR('AI_SIM_Del: SIM %d inesistente.', 16, 1, @IdSim);
END
GO

-- voce di menu (webapp, campo Link) sotto Test - Sviluppo
IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/sim')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1229, @Text = 'SIM aziendali',
        @Descrizione = 'Anagrafica delle SIM, piani tariffari, variazioni e rilevazioni Wind',
        @Link = '/sim', @Sorting = 15;
GO
