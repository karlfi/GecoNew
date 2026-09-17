/* ============================================================================
   Workflow Orchestrator - Database completo (modulo WF_) - MSSQL 2016+/2019
   ----------------------------------------------------------------------------
   FILE UNICO E RIESEGUIBILE: lancialo per intero per installare/aggiornare.
   Convenzione: tutti gli oggetti hanno prefisso WF_ (tabelle, vista, tipo TVP,
   vincoli, indici, stored procedure WF_usp_*).

   COMPATIBILITÀ: scritto per girare anche a database COMPATIBILITY_LEVEL 100
   (SQL 2008). NON usa OPENJSON (richiede 130) né TRY_CONVERT (richiede 110).
   Gli step vengono passati alla SP via Table-Valued Parameter (WF_udt_StepList).
   ISJSON nelle CHECK e i JSON salvati come testo funzionano a qualsiasi compat.

   Cosa fa una riesecuzione ("aggiorno tutto"):
     - Tabelle / Tipo TVP: creati solo se assenti. I dati NON vengono toccati.
       Modifiche STRUTTURALI richiedono migrazione manuale (ALTER).
     - Lookup tipi (WF_TipoStep): MERGE con UPDATE -> descrizioni sempre allineate.
     - Indici: creati solo se assenti.
     - Vista e Stored Procedure: CREATE OR ALTER -> sempre riallineate.

   Sottopassi (NSottopassi) = adjacency list su WF_WorkflowStep.IdStepPadre.
   ========================================================================== */
USE DeliveryDB;    -- <<< stesso DB di Speedy Web (TWEB). Unica riga da cambiare per un altro DB.
                   --     (fino al 2026-09 il modulo viveva su NotificheDB: vedi migra_da_NotificheDB.sql)
GO


/* ##########################################################################
   1) TABELLE
   ######################################################################## */

/* ---------- Lookup dei tipi di mattoncino (estendibile senza ALTER) -------- */
IF OBJECT_ID('dbo.WF_TipoStep') IS NULL
CREATE TABLE dbo.WF_TipoStep (
    Codice       NVARCHAR(50)  NOT NULL CONSTRAINT PK_WF_TipoStep PRIMARY KEY,
    Descrizione  NVARCHAR(255) NULL,
    SupportaSottopassi BIT NOT NULL CONSTRAINT DF_WF_TipoStep_Sub DEFAULT 0,
    Attivo       BIT NOT NULL CONSTRAINT DF_WF_TipoStep_Attivo DEFAULT 1
);
GO

/* ---------- Workflow = sezione [ComandoBase] del file step ----------------- */
IF OBJECT_ID('dbo.WF_Workflow') IS NULL
CREATE TABLE dbo.WF_Workflow (
    IdWorkflow            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_Workflow PRIMARY KEY,
    Nome                  NVARCHAR(255)  NOT NULL,   -- nome logico / nome del file step
    Descrizione           NVARCHAR(1000) NULL,

    /* parametri globali [ComandoBase] mappati esplicitamente */
    NStepDichiarati       INT            NULL,        -- NStep nel file (ridondante, per fedeltà)
    DirectoryOutput       NVARCHAR(500)  NULL,
    NomeFileLog           NVARCHAR(500)  NULL,
    NomeFileLogResult     NVARCHAR(500)  NULL,
    PausaTraStepMS        INT            NOT NULL CONSTRAINT DF_WF_Workflow_Pausa DEFAULT 0,
    ApriDirectoryFinale   BIT            NOT NULL CONSTRAINT DF_WF_Workflow_ApriDir DEFAULT 0,
    LoggaInizioOperazione BIT            NOT NULL CONSTRAINT DF_WF_Workflow_LogInizio DEFAULT 1,
    VariabiliGlobali      NVARCHAR(MAX)  NULL,        -- JSON array di nomi: ["IdAgenzia","Ambito"]

    /* catch-all: qualunque chiave di [ComandoBase] non modellata sopra */
    ParametriExtra        NVARCHAR(MAX)  NULL,        -- JSON oggetto

    /* tracciabilità migrazione dal legacy */
    FileOrigine           NVARCHAR(500)  NULL,
    HashOrigine           VARBINARY(32)  NULL,        -- SHA-256 del file, anti-doppione in import
    Attivo                BIT            NOT NULL CONSTRAINT DF_WF_Workflow_Attivo DEFAULT 1,
    DataCreazione         DATETIME2(0)   NOT NULL CONSTRAINT DF_WF_Workflow_DtCre DEFAULT SYSUTCDATETIME(),
    DataModifica          DATETIME2(0)   NOT NULL CONSTRAINT DF_WF_Workflow_DtMod DEFAULT SYSUTCDATETIME(),

    CONSTRAINT UQ_WF_Workflow_Nome UNIQUE (Nome),
    CONSTRAINT CK_WF_Workflow_VarGlob CHECK (VariabiliGlobali IS NULL OR ISJSON(VariabiliGlobali) = 1),
    CONSTRAINT CK_WF_Workflow_Extra   CHECK (ParametriExtra   IS NULL OR ISJSON(ParametriExtra)   = 1)
);
GO

/* ---------- Step = sezioni [StepN] e [StepN_SottopassoM] ------------------- */
IF OBJECT_ID('dbo.WF_WorkflowStep') IS NULL
CREATE TABLE dbo.WF_WorkflowStep (
    IdStep        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_WorkflowStep PRIMARY KEY,
    IdWorkflow    INT           NOT NULL,
    IdStepPadre   INT           NULL,            -- NULL = step radice; valorizzato = sottopasso
    Ordine        INT           NOT NULL,        -- numero step (radice) o numero sottopasso
    NomeSezione   NVARCHAR(120) NOT NULL,        -- es. "Step1", "Step1_Sottopasso2" (fedeltà/debug)
    Tipo          NVARCHAR(50)  NOT NULL,
    EsciSuErrore  BIT           NOT NULL CONSTRAINT DF_WF_Step_EsciErr DEFAULT 0,
    EseguiPasso   BIT           NOT NULL CONSTRAINT DF_WF_Step_Esegui  DEFAULT 1,
    -- 0 = step disabilitato nel legacy via [StepNO<n>] (config conservata, non eseguita)
    Attivo        BIT           NOT NULL CONSTRAINT DF_WF_Step_Attivo  DEFAULT 1,

    /* parametri dinamici specifici del tipo (il "JSONB" richiesto).
       Contiene anche le sotto-strutture NON eseguibili: campiFissi[],
       campiLookup[], campiCombo[], primaRiga[] ecc. */
    Parametri     NVARCHAR(MAX) NOT NULL CONSTRAINT DF_WF_Step_Param DEFAULT N'{}',

    DataCreazione DATETIME2(0)  NOT NULL CONSTRAINT DF_WF_Step_DtCre DEFAULT SYSUTCDATETIME(),

    CONSTRAINT FK_WF_Step_Workflow FOREIGN KEY (IdWorkflow)
        REFERENCES dbo.WF_Workflow(IdWorkflow) ON DELETE CASCADE,
    CONSTRAINT FK_WF_Step_Padre FOREIGN KEY (IdStepPadre)
        REFERENCES dbo.WF_WorkflowStep(IdStep),  -- self-FK NO ACTION (no cascade => niente cicli DDL)
    CONSTRAINT FK_WF_Step_Tipo  FOREIGN KEY (Tipo)
        REFERENCES dbo.WF_TipoStep(Codice),
    CONSTRAINT CK_WF_Step_Param  CHECK (ISJSON(Parametri) = 1)
);
GO


/* ##########################################################################
   2) TIPO TVP per il passaggio degli step alla SP di import
      (Per modificarne le colonne: droppare prima le SP che lo usano,
       poi il tipo, poi rieseguire.)
   ######################################################################## */
IF TYPE_ID('dbo.WF_udt_StepList') IS NULL
CREATE TYPE dbo.WF_udt_StepList AS TABLE (
    TempId       INT           NOT NULL PRIMARY KEY,
    ParentTempId INT           NULL,
    Ordine       INT           NOT NULL,
    NomeSezione  NVARCHAR(120) NOT NULL,
    Tipo         NVARCHAR(50)  NOT NULL,
    EsciSuErrore BIT           NOT NULL,
    EseguiPasso  BIT           NOT NULL,
    Attivo       BIT           NOT NULL,
    Parametri    NVARCHAR(MAX) NOT NULL
);
GO


/* ##########################################################################
   3) SEED DEI TIPI (MERGE: inserisce i nuovi, aggiorna le descrizioni)
   ######################################################################## */
MERGE dbo.WF_TipoStep AS t
USING (VALUES
    ('EXPORTTXT',            'Esporta query su file di testo (campi fissi/delimitato)', 0),
    ('EXPORTXLS',            'Esporta query su file Excel',                              0),
    ('EXPORTXLSFROMTEMPLATE','Esporta query su Excel a partire da un template',          0),
    ('GENERAREPORT',         'Genera report FastReport (PDF)',                           0),
    ('COMPRIMIFILE',         'Comprime/decomprime file (zip)',                           0),
    ('APRIMAIL',             'Compila/invia e-mail',                                     0),
    ('COPYFILE',             'Copia/sposta file',                                        0),
    ('ESEGUIQUERY',          'Esegue query SQL, con eventuali sottopassi per record',    1),
    ('ESEGUISHELL',          'Esegue un programma esterno',                              0),
    ('IMPORTTXT',            'Importa file di testo su tabella',                         0),
    ('IMPORTXLS',            'Importa file Excel su tabella',                            0),
    ('STAMPADOCUMENTO',      'Stampa/apre un documento',                                 0),
    ('SPLITPDF',             'Divide PDF in più file',                                   0),
    ('SFOGLIADIR',           'Sfoglia directory, con eventuali sottopassi per file',     1),
    ('TRASFERISCIFTP',       'Download/Upload/Rename via FTP',                           0),
    ('EXPORTPDF',            'Estrae/spezza PDF per record',                             0),
    ('SFOGLIAMAIL',          'Sfoglia casella POP, con eventuali sottopassi per mail',   1)
) AS s(Codice, Descrizione, SupportaSottopassi)
ON t.Codice = s.Codice
WHEN MATCHED THEN
    UPDATE SET Descrizione = s.Descrizione, SupportaSottopassi = s.SupportaSottopassi
WHEN NOT MATCHED THEN
    INSERT (Codice, Descrizione, SupportaSottopassi)
    VALUES (s.Codice, s.Descrizione, s.SupportaSottopassi);
GO


/* ##########################################################################
   4) INDICI (creati solo se assenti)
   ######################################################################## */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UX_WF_Step_Ordine' AND object_id = OBJECT_ID('dbo.WF_WorkflowStep'))
    CREATE UNIQUE INDEX UX_WF_Step_Ordine
        ON dbo.WF_WorkflowStep (IdWorkflow, IdStepPadre, Ordine);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_WF_Step_Padre' AND object_id = OBJECT_ID('dbo.WF_WorkflowStep'))
    CREATE INDEX IX_WF_Step_Padre
        ON dbo.WF_WorkflowStep (IdStepPadre) WHERE IdStepPadre IS NOT NULL;
GO


/* ##########################################################################
   5) VISTA: albero (step + sottopassi) in ordine di esecuzione
   ######################################################################## */
CREATE OR ALTER VIEW dbo.WF_vw_WorkflowStepAlbero AS
WITH Albero AS (
    SELECT s.IdStep, s.IdWorkflow, s.IdStepPadre, s.Ordine, s.NomeSezione,
           s.Tipo, s.EsciSuErrore, s.EseguiPasso, s.Attivo, s.Parametri,
           0 AS Livello,
           CAST(RIGHT('0000' + CAST(s.Ordine AS VARCHAR(4)), 4) AS VARCHAR(900)) AS Percorso
    FROM dbo.WF_WorkflowStep s
    WHERE s.IdStepPadre IS NULL
    UNION ALL
    SELECT s.IdStep, s.IdWorkflow, s.IdStepPadre, s.Ordine, s.NomeSezione,
           s.Tipo, s.EsciSuErrore, s.EseguiPasso, s.Attivo, s.Parametri,
           a.Livello + 1,
           -- CAST esplicito: anchor e ramo ricorsivo devono avere lo STESSO tipo/lunghezza
           CAST(a.Percorso + '.' + RIGHT('0000' + CAST(s.Ordine AS VARCHAR(4)), 4) AS VARCHAR(900))
    FROM dbo.WF_WorkflowStep s
    JOIN Albero a ON s.IdStepPadre = a.IdStep
)
SELECT * FROM Albero;
GO
-- Esempio: SELECT * FROM dbo.WF_vw_WorkflowStepAlbero WHERE IdWorkflow = 1 ORDER BY Percorso;


/* ##########################################################################
   6) STORED PROCEDURE (scritture SOLO da qui)
   ######################################################################## */

/* ----------------------------------------------------------------------------
   WF_usp_Workflow_Import
   Importa un intero file step (header [ComandoBase] + albero degli step) in
   transazione. Gli step arrivano come Table-Valued Parameter (lista piatta con
   TempId/ParentTempId): l'inserimento procede per livelli e mappa TempId
   applicativo -> IdStep reale via MERGE/OUTPUT, gestendo profondità arbitraria.
   @SovrascriviSeEsiste = 1 -> rimpiazza un Workflow con lo stesso Nome (re-import).
   VariabiliGlobali/ParametriExtra arrivano già serializzati come JSON (testo).
   Vedi src/parser/persist.ts.
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Workflow_Import
    @Nome                  NVARCHAR(255),
    @NStepDichiarati       INT           = NULL,
    @DirectoryOutput       NVARCHAR(500) = NULL,
    @NomeFileLog           NVARCHAR(500) = NULL,
    @NomeFileLogResult     NVARCHAR(500) = NULL,
    @PausaTraStepMS        INT           = 0,
    @ApriDirectoryFinale   BIT           = 0,
    @LoggaInizioOperazione BIT           = 1,
    @VariabiliGlobali      NVARCHAR(MAX) = NULL,   -- JSON array (testo)
    @ParametriExtra        NVARCHAR(MAX) = NULL,   -- JSON object (testo)
    @FileOrigine           NVARCHAR(500) = NULL,
    @HashOrigine           VARBINARY(32) = NULL,
    @SovrascriviSeEsiste   BIT           = 0,
    @Steps                 dbo.WF_udt_StepList READONLY,
    @IdWorkflow            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRAN;

        IF @SovrascriviSeEsiste = 1
        BEGIN
            DECLARE @IdEsistente INT =
                (SELECT IdWorkflow FROM dbo.WF_Workflow WHERE Nome = @Nome);
            IF @IdEsistente IS NOT NULL
            BEGIN
                DELETE FROM dbo.WF_WorkflowStep WHERE IdWorkflow = @IdEsistente;
                DELETE FROM dbo.WF_Workflow     WHERE IdWorkflow = @IdEsistente;
            END
        END

        /* ---- header [ComandoBase] ---- */
        INSERT INTO dbo.WF_Workflow
            (Nome, NStepDichiarati, DirectoryOutput, NomeFileLog, NomeFileLogResult,
             PausaTraStepMS, ApriDirectoryFinale, LoggaInizioOperazione,
             VariabiliGlobali, ParametriExtra, FileOrigine, HashOrigine)
        VALUES
            (@Nome, @NStepDichiarati, @DirectoryOutput, @NomeFileLog, @NomeFileLogResult,
             ISNULL(@PausaTraStepMS, 0), ISNULL(@ApriDirectoryFinale, 0),
             ISNULL(@LoggaInizioOperazione, 1),
             @VariabiliGlobali, @ParametriExtra, @FileOrigine, @HashOrigine);

        SET @IdWorkflow = SCOPE_IDENTITY();

        /* ---- copia locale del TVP (per il loop) ---- */
        DECLARE @StepsLocal TABLE (
            TempId       INT PRIMARY KEY,
            ParentTempId INT NULL,
            Ordine       INT,
            NomeSezione  NVARCHAR(120),
            Tipo         NVARCHAR(50),
            EsciSuErrore BIT,
            EseguiPasso  BIT,
            Attivo       BIT,
            Parametri    NVARCHAR(MAX)
        );
        INSERT INTO @StepsLocal
            (TempId, ParentTempId, Ordine, NomeSezione, Tipo,
             EsciSuErrore, EseguiPasso, Attivo, Parametri)
        SELECT TempId, ParentTempId, Ordine, NomeSezione, Tipo,
               EsciSuErrore, EseguiPasso, Attivo, ISNULL(Parametri, N'{}')
        FROM @Steps;

        /* mappa TempId(applicativo) -> IdStep(reale) */
        DECLARE @Map TABLE (TempId INT PRIMARY KEY, IdStep INT);
        DECLARE @Inseriti INT = 1;

        /* inserimento per livelli: ogni giro inserisce gli step il cui padre
           è già mappato (o radice). Si ferma quando tutti sono inseriti. */
        WHILE EXISTS (SELECT 1 FROM @StepsLocal s
                      WHERE NOT EXISTS (SELECT 1 FROM @Map m WHERE m.TempId = s.TempId))
        BEGIN
            MERGE dbo.WF_WorkflowStep AS tgt
            USING (
                SELECT s.TempId, s.Ordine, s.NomeSezione, s.Tipo,
                       s.EsciSuErrore, s.EseguiPasso, s.Attivo, s.Parametri,
                       pm.IdStep AS IdStepPadre
                FROM @StepsLocal s
                LEFT JOIN @Map pm ON pm.TempId = s.ParentTempId
                WHERE NOT EXISTS (SELECT 1 FROM @Map m WHERE m.TempId = s.TempId)
                  AND (s.ParentTempId IS NULL OR pm.IdStep IS NOT NULL)
            ) AS src
            ON 1 = 0   -- forza sempre l'INSERT (pattern MERGE per usare OUTPUT su colonne sorgente)
            WHEN NOT MATCHED THEN
                INSERT (IdWorkflow, IdStepPadre, Ordine, NomeSezione, Tipo,
                        EsciSuErrore, EseguiPasso, Attivo, Parametri)
                VALUES (@IdWorkflow, src.IdStepPadre, src.Ordine, src.NomeSezione, src.Tipo,
                        src.EsciSuErrore, src.EseguiPasso, src.Attivo, src.Parametri)
            OUTPUT src.TempId, inserted.IdStep INTO @Map (TempId, IdStep);

            SET @Inseriti = @@ROWCOUNT;
            IF @Inseriti = 0   -- restano step ma nessuno inseribile => orfano o ciclo
                RAISERROR('WF_usp_Workflow_Import: sottopassi orfani o ciclo nei parentTempId.', 16, 1);
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE(),
                @sev INT = ERROR_SEVERITY(),
                @sta INT = ERROR_STATE();
        RAISERROR(@msg, @sev, @sta);
    END CATCH
END
GO

/* ----------------------------------------------------------------------------
   WF_usp_Step_UpdateParametri
   Aggiorna i parametri (JSON) e i flag di un singolo step. Usata dall'editor.
   I parametri NULL non vengono modificati (COALESCE sul valore corrente).
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Step_UpdateParametri
    @IdStep       INT,
    @Parametri    NVARCHAR(MAX),
    @EsciSuErrore BIT           = NULL,
    @EseguiPasso  BIT           = NULL,
    @Attivo       BIT           = NULL,
    @Tipo         NVARCHAR(50)  = NULL,
    @NomeSezione  NVARCHAR(120) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@Parametri) <> 1
        RAISERROR('WF_usp_Step_UpdateParametri: @Parametri non è JSON valido.', 16, 1);
    IF @Tipo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.WF_TipoStep WHERE Codice = @Tipo)
        RAISERROR('WF_usp_Step_UpdateParametri: Tipo "%s" inesistente.', 16, 1, @Tipo);

    UPDATE dbo.WF_WorkflowStep
       SET Parametri    = @Parametri,
           EsciSuErrore = ISNULL(@EsciSuErrore, EsciSuErrore),
           EseguiPasso  = ISNULL(@EseguiPasso,  EseguiPasso),
           Attivo       = ISNULL(@Attivo,       Attivo),
           Tipo         = ISNULL(@Tipo,         Tipo),
           NomeSezione  = ISNULL(@NomeSezione,  NomeSezione)
     WHERE IdStep = @IdStep;

    IF @@ROWCOUNT = 0
        RAISERROR('WF_usp_Step_UpdateParametri: IdStep %d inesistente.', 16, 1, @IdStep);
END
GO

/* ----------------------------------------------------------------------------
   WF_usp_Step_Insert
   Aggiunge uno step (radice se @IdStepPadre NULL, altrimenti sottopasso) in
   coda ai fratelli (Ordine = max+1). Restituisce il nuovo IdStep.
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Step_Insert
    @IdWorkflow  INT,
    @IdStepPadre INT           = NULL,
    @Tipo        NVARCHAR(50),
    @NomeSezione NVARCHAR(120) = NULL,
    @IdStep      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.WF_TipoStep WHERE Codice = @Tipo)
        RAISERROR('WF_usp_Step_Insert: Tipo "%s" inesistente.', 16, 1, @Tipo);
    IF @IdStepPadre IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.WF_WorkflowStep
        WHERE IdStep = @IdStepPadre AND IdWorkflow = @IdWorkflow)
        RAISERROR('WF_usp_Step_Insert: IdStepPadre non valido per il workflow.', 16, 1);

    DECLARE @Ordine INT = (
        SELECT ISNULL(MAX(Ordine), 0) + 1 FROM dbo.WF_WorkflowStep
        WHERE IdWorkflow = @IdWorkflow
          AND ((@IdStepPadre IS NULL AND IdStepPadre IS NULL) OR IdStepPadre = @IdStepPadre));

    DECLARE @Sez NVARCHAR(120) = ISNULL(@NomeSezione,
        CASE WHEN @IdStepPadre IS NULL THEN CONCAT('Step', @Ordine)
             ELSE CONCAT('Sottopasso', @Ordine) END);

    INSERT INTO dbo.WF_WorkflowStep
        (IdWorkflow, IdStepPadre, Ordine, NomeSezione, Tipo, Parametri)
    VALUES (@IdWorkflow, @IdStepPadre, @Ordine, @Sez, @Tipo, N'{}');

    SET @IdStep = SCOPE_IDENTITY();
END
GO

/* ----------------------------------------------------------------------------
   WF_usp_Step_Delete
   Elimina uno step e tutti i suoi discendenti (sottopassi a qualsiasi livello).
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Step_Delete
    @IdStep INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @ToDel TABLE (IdStep INT PRIMARY KEY);
        ;WITH D AS (
            SELECT IdStep FROM dbo.WF_WorkflowStep WHERE IdStep = @IdStep
            UNION ALL
            SELECT s.IdStep FROM dbo.WF_WorkflowStep s JOIN D ON s.IdStepPadre = D.IdStep
        )
        INSERT INTO @ToDel SELECT IdStep FROM D;

        -- DELETE massiva set-based: l'intero sottoalbero esce insieme => self-FK ok
        DELETE FROM dbo.WF_WorkflowStep WHERE IdStep IN (SELECT IdStep FROM @ToDel);
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @m NVARCHAR(2048) = ERROR_MESSAGE(), @s INT = ERROR_SEVERITY(), @t INT = ERROR_STATE();
        RAISERROR(@m, @s, @t);
    END CATCH
END
GO

/* ----------------------------------------------------------------------------
   WF_usp_Step_Sposta
   Sposta uno step su/giù scambiando l'Ordine con il fratello adiacente.
   @Direzione: 'su' | 'giu'. No-op se è già all'estremo.
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Step_Sposta
    @IdStep    INT,
    @Direzione NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Direzione NOT IN ('su', 'giu')
        RAISERROR('WF_usp_Step_Sposta: @Direzione deve essere "su" o "giu".', 16, 1);

    DECLARE @IdWorkflow INT, @IdPadre INT, @Ordine INT;
    SELECT @IdWorkflow = IdWorkflow, @IdPadre = IdStepPadre, @Ordine = Ordine
    FROM dbo.WF_WorkflowStep WHERE IdStep = @IdStep;
    IF @IdWorkflow IS NULL
        RAISERROR('WF_usp_Step_Sposta: IdStep %d inesistente.', 16, 1, @IdStep);

    DECLARE @IdAltro INT, @OrdAltro INT;
    IF @Direzione = 'su'
        SELECT TOP 1 @IdAltro = IdStep, @OrdAltro = Ordine FROM dbo.WF_WorkflowStep
         WHERE IdWorkflow = @IdWorkflow
           AND ((@IdPadre IS NULL AND IdStepPadre IS NULL) OR IdStepPadre = @IdPadre)
           AND Ordine < @Ordine ORDER BY Ordine DESC;
    ELSE
        SELECT TOP 1 @IdAltro = IdStep, @OrdAltro = Ordine FROM dbo.WF_WorkflowStep
         WHERE IdWorkflow = @IdWorkflow
           AND ((@IdPadre IS NULL AND IdStepPadre IS NULL) OR IdStepPadre = @IdPadre)
           AND Ordine > @Ordine ORDER BY Ordine ASC;

    IF @IdAltro IS NULL RETURN;  -- già all'estremo

    -- swap atomico in una sola UPDATE: nessuna collisione sull'indice unico
    UPDATE dbo.WF_WorkflowStep
       SET Ordine = CASE IdStep WHEN @IdStep THEN @OrdAltro WHEN @IdAltro THEN @Ordine END
     WHERE IdStep IN (@IdStep, @IdAltro);
END
GO


/* ##########################################################################
   7) SCHEDULAZIONE & ESECUZIONE (rispecchia PLAN_Master/Detail/StepSchedulati)
   ######################################################################## */

/* ---------- Lookup stati esecuzione (codici allineati al legacy) ----------- */
IF OBJECT_ID('dbo.WF_StatoEsecuzione') IS NULL
CREATE TABLE dbo.WF_StatoEsecuzione (
    Codice      INT          NOT NULL CONSTRAINT PK_WF_StatoEsecuzione PRIMARY KEY,
    Nome        NVARCHAR(30) NOT NULL,
    Descrizione NVARCHAR(100) NULL
);
GO
MERGE dbo.WF_StatoEsecuzione AS t
USING (VALUES
    (0, 'PIANIFICATA',   'Occorrenza prevista, non ancora eseguita'),
    (1, 'IN_ESECUZIONE', 'In corso'),
    (2, 'ESEGUITA',      'Completata con successo'),
    (3, 'ERRORE',        'Terminata con errore'),
    (4, 'ANNULLATA',     'Annullata manualmente'),
    (5, 'SALTATA',       'Saltata (festivo / pianificazione sospesa)')
) AS s(Codice, Nome, Descrizione)
ON t.Codice = s.Codice
WHEN MATCHED THEN UPDATE SET Nome = s.Nome, Descrizione = s.Descrizione
WHEN NOT MATCHED THEN INSERT (Codice, Nome, Descrizione) VALUES (s.Codice, s.Nome, s.Descrizione);
GO

/* ---------- Master della pianificazione (la regola, per workflow) ---------- */
IF OBJECT_ID('dbo.WF_PianificazioneMaster') IS NULL
CREATE TABLE dbo.WF_PianificazioneMaster (
    IdPianificazione  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_PianMaster PRIMARY KEY,
    IdWorkflow        INT           NOT NULL,
    Descrizione       NVARCHAR(100) NULL,
    Parametri         NVARCHAR(MAX) NULL,           -- JSON, override sul workflow
    GruppoConcorrenza NVARCHAR(50)  NULL,           -- mutua esclusione (un run alla volta nel gruppo)
    Note              NVARCHAR(MAX) NULL,
    OrizzonteGiorni   INT           NOT NULL CONSTRAINT DF_WF_PianMaster_Oriz DEFAULT 30,
    DataOraFinale     DATETIME2(0)  NULL,           -- fine validità della regola
    Sospesa           BIT           NOT NULL CONSTRAINT DF_WF_PianMaster_Sosp DEFAULT 0,
    Attiva            BIT           NOT NULL CONSTRAINT DF_WF_PianMaster_Att DEFAULT 1,
    DataCreazione     DATETIME2(0)  NOT NULL CONSTRAINT DF_WF_PianMaster_DtCre DEFAULT SYSUTCDATETIME(),
    DataModifica      DATETIME2(0)  NOT NULL CONSTRAINT DF_WF_PianMaster_DtMod DEFAULT SYSUTCDATETIME(),
    DataCancellazione DATETIME2(0)  NULL,           -- soft-delete
    CONSTRAINT FK_WF_PianMaster_Workflow FOREIGN KEY (IdWorkflow)
        REFERENCES dbo.WF_Workflow(IdWorkflow),
    CONSTRAINT CK_WF_PianMaster_Param CHECK (Parametri IS NULL OR ISJSON(Parametri) = 1)
);
GO

/* ---------- Dettaglio: righe di ricorrenza (cron / one-shot) --------------- */
IF OBJECT_ID('dbo.WF_PianificazioneDettaglio') IS NULL
CREATE TABLE dbo.WF_PianificazioneDettaglio (
    IdDettaglio      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_PianDettaglio PRIMARY KEY,
    IdPianificazione INT           NOT NULL,
    TipoRicorrenza   NVARCHAR(10)  NOT NULL,        -- 'CRON' | 'ONESHOT'
    CronExpr         NVARCHAR(120) NULL,            -- se CRON
    DataOraSingola   DATETIME2(0)  NULL,            -- se ONESHOT
    DataOraIniziale  DATETIME2(0)  NULL,            -- inizio validità di questa riga
    Priorita         INT           NOT NULL CONSTRAINT DF_WF_PianDet_Prio DEFAULT 0,
    Parametri        NVARCHAR(MAX) NULL,
    Attiva           BIT           NOT NULL CONSTRAINT DF_WF_PianDet_Att DEFAULT 1,
    CONSTRAINT FK_WF_PianDet_Master FOREIGN KEY (IdPianificazione)
        REFERENCES dbo.WF_PianificazioneMaster(IdPianificazione) ON DELETE CASCADE,
    CONSTRAINT CK_WF_PianDet_Tipo CHECK (TipoRicorrenza IN ('CRON', 'ONESHOT')),
    CONSTRAINT CK_WF_PianDet_Param CHECK (Parametri IS NULL OR ISJSON(Parametri) = 1)
);
GO

/* ---------- Esecuzioni: occorrenze previste + storico (≈ StepSchedulati) --- */
IF OBJECT_ID('dbo.WF_Esecuzione') IS NULL
CREATE TABLE dbo.WF_Esecuzione (
    IdEsecuzione      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_Esecuzione PRIMARY KEY,
    IdPianificazione  INT           NULL,           -- NULL se lancio ad-hoc (API/MANUALE)
    IdDettaglio       INT           NULL,
    IdWorkflow        INT           NOT NULL,
    Parametri         NVARCHAR(MAX) NULL,
    DataOraPrevista   DATETIME2(0)  NOT NULL,        -- spostabile = "muovi l'occorrenza"
    Stato             INT           NOT NULL CONSTRAINT DF_WF_Esec_Stato DEFAULT 0,
    Origine           NVARCHAR(15)  NOT NULL CONSTRAINT DF_WF_Esec_Orig DEFAULT 'SCHEDULER',
    GruppoConcorrenza NVARCHAR(50)  NULL,
    Festivo           BIT           NOT NULL CONSTRAINT DF_WF_Esec_Fest DEFAULT 0,
    InizioUtc         DATETIME2(0)  NULL,
    FineUtc           DATETIME2(0)  NULL,
    MachineName       NVARCHAR(64)  NULL,            -- quale istanza engine l'ha eseguita
    NomeUtente        NVARCHAR(128) NULL,
    Avanzamento       INT           NOT NULL CONSTRAINT DF_WF_Esec_Avz DEFAULT 0,
    Esito             NVARCHAR(MAX) NULL,
    DataCreazione     DATETIME2(0)  NOT NULL CONSTRAINT DF_WF_Esec_DtCre DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_WF_Esec_Workflow FOREIGN KEY (IdWorkflow)
        REFERENCES dbo.WF_Workflow(IdWorkflow),
    CONSTRAINT FK_WF_Esec_Pian FOREIGN KEY (IdPianificazione)
        REFERENCES dbo.WF_PianificazioneMaster(IdPianificazione),
    CONSTRAINT FK_WF_Esec_Det FOREIGN KEY (IdDettaglio)
        REFERENCES dbo.WF_PianificazioneDettaglio(IdDettaglio),
    CONSTRAINT FK_WF_Esec_Stato FOREIGN KEY (Stato)
        REFERENCES dbo.WF_StatoEsecuzione(Codice),
    CONSTRAINT CK_WF_Esec_Param CHECK (Parametri IS NULL OR ISJSON(Parametri) = 1),
    CONSTRAINT CK_WF_Esec_Orig CHECK (Origine IN ('SCHEDULER', 'API', 'MANUALE'))
);
GO
-- anti-doppione sulle occorrenze materializzate da una stessa riga di ricorrenza
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_WF_Esec_Occorrenza'
               AND object_id = OBJECT_ID('dbo.WF_Esecuzione'))
    CREATE UNIQUE INDEX UX_WF_Esec_Occorrenza
        ON dbo.WF_Esecuzione (IdDettaglio, DataOraPrevista) WHERE IdDettaglio IS NOT NULL;
GO
-- poll dello scheduler: stato + quando
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WF_Esec_StatoData'
               AND object_id = OBJECT_ID('dbo.WF_Esecuzione'))
    CREATE INDEX IX_WF_Esec_StatoData ON dbo.WF_Esecuzione (Stato, DataOraPrevista);
GO

/* ---------- Log riga-per-riga di un'esecuzione ----------------------------- */
IF OBJECT_ID('dbo.WF_EsecuzioneLog') IS NULL
CREATE TABLE dbo.WF_EsecuzioneLog (
    IdLog        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_EsecLog PRIMARY KEY,
    IdEsecuzione INT           NOT NULL,
    IdStep       INT           NULL,
    Sequenza     INT           NOT NULL,
    Livello      NVARCHAR(10)  NOT NULL CONSTRAINT DF_WF_EsecLog_Liv DEFAULT 'INFO',
    Messaggio    NVARCHAR(MAX) NULL,           -- una riga: cosa e' successo e l'esito
    NumRecord    INT           NULL,
    Dettaglio    NVARCHAR(MAX) NULL,           -- il testo intero eseguito, coi parametri sostituiti (query, comando, file, mail)
    DurataMs     INT           NULL,
    TimestampUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_WF_EsecLog_Ts DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_WF_EsecLog_Esec FOREIGN KEY (IdEsecuzione)
        REFERENCES dbo.WF_Esecuzione(IdEsecuzione) ON DELETE CASCADE,
    CONSTRAINT FK_WF_EsecLog_Step FOREIGN KEY (IdStep)
        REFERENCES dbo.WF_WorkflowStep(IdStep),
    CONSTRAINT CK_WF_EsecLog_Liv CHECK (Livello IN ('INFO', 'WARN', 'ERRORE'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WF_EsecLog_Esec'
               AND object_id = OBJECT_ID('dbo.WF_EsecuzioneLog'))
    CREATE INDEX IX_WF_EsecLog_Esec ON dbo.WF_EsecuzioneLog (IdEsecuzione, Sequenza);
GO

/* ---------- Vista storico esecuzioni (per la UI) -------------------------- */
CREATE OR ALTER VIEW dbo.WF_vw_Esecuzione AS
SELECT e.IdEsecuzione, e.IdWorkflow, w.Nome AS NomeWorkflow,
       e.IdPianificazione, e.IdDettaglio, e.DataOraPrevista,
       e.Stato, st.Nome AS StatoNome, e.Origine, e.GruppoConcorrenza,
       e.InizioUtc, e.FineUtc, e.MachineName, e.NomeUtente, e.Avanzamento,
       e.Esito, e.Parametri, e.DataCreazione
FROM dbo.WF_Esecuzione e
JOIN dbo.WF_Workflow w        ON w.IdWorkflow = e.IdWorkflow
JOIN dbo.WF_StatoEsecuzione st ON st.Codice = e.Stato;
GO


/* ##########################################################################
   8) SP DI ESECUZIONE (lifecycle del run; usate da engine e API)
   ######################################################################## */

/* Crea un'esecuzione (ad-hoc da API/MANUALE, o materializzata). Stato iniziale 0. */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Crea
    @IdWorkflow        INT,
    @Origine           NVARCHAR(15)  = 'MANUALE',
    @Parametri         NVARCHAR(MAX) = NULL,
    @DataOraPrevista   DATETIME2(0)  = NULL,
    @GruppoConcorrenza NVARCHAR(50)  = NULL,
    @NomeUtente        NVARCHAR(128) = NULL,
    @IdPianificazione  INT           = NULL,
    @IdDettaglio       INT           = NULL,
    @IdEsecuzione      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Parametri IS NOT NULL AND ISJSON(@Parametri) <> 1
        RAISERROR('WF_usp_Esecuzione_Crea: @Parametri non è JSON valido.', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM dbo.WF_Workflow WHERE IdWorkflow = @IdWorkflow)
        RAISERROR('WF_usp_Esecuzione_Crea: Workflow %d inesistente.', 16, 1, @IdWorkflow);

    INSERT INTO dbo.WF_Esecuzione
        (IdPianificazione, IdDettaglio, IdWorkflow, Parametri, DataOraPrevista,
         Stato, Origine, GruppoConcorrenza, NomeUtente)
    VALUES
        (@IdPianificazione, @IdDettaglio, @IdWorkflow, @Parametri,
         ISNULL(@DataOraPrevista, SYSUTCDATETIME()), 0, @Origine, @GruppoConcorrenza, @NomeUtente);

    SET @IdEsecuzione = SCOPE_IDENTITY();
END
GO

/* Segna l'inizio del run (Stato -> IN_ESECUZIONE). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Inizia
    @IdEsecuzione INT,
    @MachineName  NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.WF_Esecuzione
       SET Stato = 1, InizioUtc = SYSUTCDATETIME(),
           MachineName = ISNULL(@MachineName, MachineName), Avanzamento = 0
     WHERE IdEsecuzione = @IdEsecuzione;
    IF @@ROWCOUNT = 0
        RAISERROR('WF_usp_Esecuzione_Inizia: IdEsecuzione %d inesistente.', 16, 1, @IdEsecuzione);
END
GO

/* Chiude il run con esito (2=ESEGUITA, 3=ERRORE, ...). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Termina
    @IdEsecuzione INT,
    @Stato        INT,
    @Esito        NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.WF_StatoEsecuzione WHERE Codice = @Stato)
        RAISERROR('WF_usp_Esecuzione_Termina: Stato %d inesistente.', 16, 1, @Stato);
    UPDATE dbo.WF_Esecuzione
       SET Stato = @Stato, FineUtc = SYSUTCDATETIME(), Esito = @Esito,
           Avanzamento = CASE WHEN @Stato = 2 THEN 100 ELSE Avanzamento END
     WHERE IdEsecuzione = @IdEsecuzione;
    IF @@ROWCOUNT = 0
        RAISERROR('WF_usp_Esecuzione_Termina: IdEsecuzione %d inesistente.', 16, 1, @IdEsecuzione);
END
GO

/* Aggiorna l'avanzamento (%). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Avanzamento
    @IdEsecuzione INT,
    @Avanzamento  INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.WF_Esecuzione SET Avanzamento = @Avanzamento WHERE IdEsecuzione = @IdEsecuzione;
END
GO

/* Annulla manualmente un'esecuzione pianificata o in corso. */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Annulla
    @IdEsecuzione INT,
    @NomeUtente   NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.WF_Esecuzione
       SET Stato = 4, FineUtc = SYSUTCDATETIME(),
           Esito = CONCAT('Annullata da ', ISNULL(@NomeUtente, '?'))
     WHERE IdEsecuzione = @IdEsecuzione AND Stato IN (0, 1);
    IF @@ROWCOUNT = 0
        RAISERROR('WF_usp_Esecuzione_Annulla: esecuzione inesistente o non annullabile.', 16, 1);
END
GO

/* Aggiunge una riga di log all'esecuzione (numerazione Sequenza automatica). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_EsecuzioneLog_Add
    @IdEsecuzione INT,
    @IdStep       INT           = NULL,
    @Livello      NVARCHAR(10)  = 'INFO',
    @Messaggio    NVARCHAR(MAX) = NULL,
    @NumRecord    INT           = NULL,
    @Dettaglio    NVARCHAR(MAX) = NULL,
    @DurataMs     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @seq INT = (SELECT ISNULL(MAX(Sequenza), 0) + 1
                        FROM dbo.WF_EsecuzioneLog WHERE IdEsecuzione = @IdEsecuzione);
    INSERT INTO dbo.WF_EsecuzioneLog (IdEsecuzione, IdStep, Sequenza, Livello, Messaggio, NumRecord, Dettaglio, DurataMs)
    VALUES (@IdEsecuzione, @IdStep, @seq, @Livello, @Messaggio, @NumRecord, @Dettaglio, @DurataMs);
END
GO


/* ##########################################################################
   9) SP DELLO SCHEDULER (materializzazione occorrenze + claim)
   ######################################################################## */

/* Inserisce una occorrenza PIANIFICATA se non esiste gia (idempotente sulla
   coppia IdDettaglio + DataOraPrevista). Chiamata dallo scheduler (Node calcola
   le date dal cron). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Pianifica
    @IdPianificazione  INT,
    @IdDettaglio       INT,
    @IdWorkflow        INT,
    @DataOraPrevista   DATETIME2(0),
    @GruppoConcorrenza NVARCHAR(50)  = NULL,
    @Parametri         NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.WF_Esecuzione
                   WHERE IdDettaglio = @IdDettaglio AND DataOraPrevista = @DataOraPrevista)
        INSERT INTO dbo.WF_Esecuzione
            (IdPianificazione, IdDettaglio, IdWorkflow, Parametri, DataOraPrevista,
             Stato, Origine, GruppoConcorrenza)
        VALUES
            (@IdPianificazione, @IdDettaglio, @IdWorkflow, @Parametri, @DataOraPrevista,
             0, 'SCHEDULER', @GruppoConcorrenza);
END
GO

/* Prende atomicamente la prossima occorrenza scaduta eseguibile e la porta
   IN_ESECUZIONE. Rispetta i gruppi di concorrenza (un run alla volta per gruppo)
   e salta le pianificazioni sospese. Serializzata via sp_getapplock per essere
   sicura anche con piu istanze scheduler. Restituisce la riga presa (o vuoto). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Claim
    @MachineName NVARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @IdEsecuzione INT = NULL;
    BEGIN TRY
        BEGIN TRAN;
        EXEC sp_getapplock @Resource = 'WF_Esecuzione_Claim',
                           @LockMode = 'Exclusive', @LockOwner = 'Transaction';

        ;WITH cte AS (
            SELECT TOP 1 e.IdEsecuzione
            FROM dbo.WF_Esecuzione e
            WHERE e.Stato = 0
              AND e.DataOraPrevista <= SYSUTCDATETIME()
              AND (e.GruppoConcorrenza IS NULL OR NOT EXISTS (
                    SELECT 1 FROM dbo.WF_Esecuzione g
                    WHERE g.Stato = 1 AND g.GruppoConcorrenza = e.GruppoConcorrenza))
              AND NOT EXISTS (
                    SELECT 1 FROM dbo.WF_PianificazioneMaster m
                    WHERE m.IdPianificazione = e.IdPianificazione AND m.Sospesa = 1)
            ORDER BY e.DataOraPrevista, e.IdEsecuzione
        )
        UPDATE e
           SET e.Stato = 1, e.InizioUtc = SYSUTCDATETIME(), e.MachineName = @MachineName,
               @IdEsecuzione = e.IdEsecuzione
        FROM dbo.WF_Esecuzione e
        JOIN cte ON cte.IdEsecuzione = e.IdEsecuzione;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @m NVARCHAR(2048) = ERROR_MESSAGE(), @s INT = ERROR_SEVERITY(), @t INT = ERROR_STATE();
        RAISERROR(@m, @s, @t);
    END CATCH

    SELECT IdEsecuzione, IdWorkflow, Parametri, GruppoConcorrenza
    FROM dbo.WF_Esecuzione WHERE IdEsecuzione = @IdEsecuzione;
END
GO


/* ##########################################################################
   10) SP DI GESTIONE PIANIFICAZIONI (per la UI)
   ######################################################################## */

/* Upsert del master: se @IdPianificazione è NULL inserisce, altrimenti aggiorna. */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Pianificazione_Salva
    @IdPianificazione  INT           = NULL OUTPUT,
    @IdWorkflow        INT,
    @Descrizione       NVARCHAR(100) = NULL,
    @Parametri         NVARCHAR(MAX) = NULL,
    @GruppoConcorrenza NVARCHAR(50)  = NULL,
    @Note              NVARCHAR(MAX) = NULL,
    @OrizzonteGiorni   INT           = 30,
    @DataOraFinale     DATETIME2(0)  = NULL,
    @Sospesa           BIT           = 0,
    @Attiva            BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @Parametri IS NOT NULL AND ISJSON(@Parametri) <> 1
        RAISERROR('WF_usp_Pianificazione_Salva: @Parametri non è JSON valido.', 16, 1);

    IF @IdPianificazione IS NULL
    BEGIN
        INSERT INTO dbo.WF_PianificazioneMaster
            (IdWorkflow, Descrizione, Parametri, GruppoConcorrenza, Note,
             OrizzonteGiorni, DataOraFinale, Sospesa, Attiva)
        VALUES
            (@IdWorkflow, @Descrizione, @Parametri, @GruppoConcorrenza, @Note,
             ISNULL(@OrizzonteGiorni, 30), @DataOraFinale, ISNULL(@Sospesa, 0), ISNULL(@Attiva, 1));
        SET @IdPianificazione = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE dbo.WF_PianificazioneMaster
           SET Descrizione = @Descrizione, Parametri = @Parametri,
               GruppoConcorrenza = @GruppoConcorrenza, Note = @Note,
               OrizzonteGiorni = ISNULL(@OrizzonteGiorni, OrizzonteGiorni),
               DataOraFinale = @DataOraFinale,
               Sospesa = ISNULL(@Sospesa, Sospesa), Attiva = ISNULL(@Attiva, Attiva),
               DataModifica = SYSUTCDATETIME()
         WHERE IdPianificazione = @IdPianificazione;
END
GO

/* Soft-delete del master + rimozione delle occorrenze future ancora pianificate. */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Pianificazione_Elimina
    @IdPianificazione INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE FROM dbo.WF_Esecuzione
         WHERE IdPianificazione = @IdPianificazione AND Stato = 0;  -- solo le future
        UPDATE dbo.WF_PianificazioneMaster
           SET Attiva = 0, DataCancellazione = SYSUTCDATETIME()
         WHERE IdPianificazione = @IdPianificazione;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @m NVARCHAR(2048) = ERROR_MESSAGE(), @s INT = ERROR_SEVERITY(), @t INT = ERROR_STATE();
        RAISERROR(@m, @s, @t);
    END CATCH
END
GO

/* Upsert di una riga di ricorrenza (cron / one-shot). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Dettaglio_Salva
    @IdDettaglio      INT           = NULL OUTPUT,
    @IdPianificazione INT,
    @TipoRicorrenza   NVARCHAR(10),
    @CronExpr         NVARCHAR(120) = NULL,
    @DataOraSingola   DATETIME2(0)  = NULL,
    @Priorita         INT           = 0,
    @Attiva           BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @TipoRicorrenza NOT IN ('CRON', 'ONESHOT')
        RAISERROR('WF_usp_Dettaglio_Salva: TipoRicorrenza deve essere CRON o ONESHOT.', 16, 1);

    IF @IdDettaglio IS NULL
    BEGIN
        INSERT INTO dbo.WF_PianificazioneDettaglio
            (IdPianificazione, TipoRicorrenza, CronExpr, DataOraSingola, Priorita, Attiva)
        VALUES
            (@IdPianificazione, @TipoRicorrenza, @CronExpr, @DataOraSingola, ISNULL(@Priorita, 0), ISNULL(@Attiva, 1));
        SET @IdDettaglio = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE dbo.WF_PianificazioneDettaglio
           SET TipoRicorrenza = @TipoRicorrenza, CronExpr = @CronExpr,
               DataOraSingola = @DataOraSingola, Priorita = ISNULL(@Priorita, Priorita),
               Attiva = ISNULL(@Attiva, Attiva)
         WHERE IdDettaglio = @IdDettaglio;
END
GO

/* Elimina una riga di ricorrenza + le sue occorrenze future ancora pianificate. */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Dettaglio_Elimina
    @IdDettaglio INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE FROM dbo.WF_Esecuzione WHERE IdDettaglio = @IdDettaglio AND Stato = 0;
        DELETE FROM dbo.WF_PianificazioneDettaglio WHERE IdDettaglio = @IdDettaglio;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @m NVARCHAR(2048) = ERROR_MESSAGE(), @s INT = ERROR_SEVERITY(), @t INT = ERROR_STATE();
        RAISERROR(@m, @s, @t);
    END CATCH
END
GO

/* ----------------------------------------------------------------------------
   WF_usp_Workflow_Delete
   Elimina un workflow e tutti i suoi step/sottopassi. La DELETE massiva sugli
   step è set-based e soddisfa la self-FK; poi elimina l'header.
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Workflow_Delete
    @IdWorkflow INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE FROM dbo.WF_WorkflowStep WHERE IdWorkflow = @IdWorkflow;
        DELETE FROM dbo.WF_Workflow     WHERE IdWorkflow = @IdWorkflow;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE(),
                @sev INT = ERROR_SEVERITY(),
                @sta INT = ERROR_STATE();
        RAISERROR(@msg, @sev, @sta);
    END CATCH
END
GO
