-- RAISERROR con severita' 16 dentro una stored NON ferma l'esecuzione: le
-- istruzioni dopo vengono eseguite lo stesso (cosi' un nome vuoto veniva
-- rifiutato... e inserito). Qui ogni controllo e' seguito da RETURN.
-- Contiene anche WF_usp_Workflow_Salva (testata scritta dalla pagina: nuovo
-- workflow vuoto o modifica; gli step si aggiungono dopo con WF_usp_Step_Insert).
USE DeliveryDB;
GO
CREATE OR ALTER PROCEDURE dbo.WF_usp_Workflow_Salva
    @IdWorkflow            INT            = NULL OUTPUT,
    @Nome                  NVARCHAR(255),
    @Descrizione           NVARCHAR(1000) = NULL,
    @DirectoryOutput       NVARCHAR(500)  = NULL,
    @NomeFileLog           NVARCHAR(500)  = NULL,
    @NomeFileLogResult     NVARCHAR(500)  = NULL,
    @PausaTraStepMS        INT            = NULL,
    @ApriDirectoryFinale   BIT            = NULL,
    @LoggaInizioOperazione BIT            = NULL,
    @VariabiliGlobali      NVARCHAR(MAX)  = NULL,   -- JSON array (testo)
    @Attivo                BIT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Nome = LTRIM(RTRIM(ISNULL(@Nome, '')));
    IF @Nome = ''
    BEGIN
        RAISERROR('WF_usp_Workflow_Salva: il nome del workflow e'' obbligatorio.', 16, 1);
        RETURN;
    END
    IF @VariabiliGlobali IS NOT NULL AND ISJSON(@VariabiliGlobali) <> 1
    BEGIN
        RAISERROR('WF_usp_Workflow_Salva: @VariabiliGlobali non e'' JSON valido.', 16, 1);
        RETURN;
    END
    IF @IdWorkflow IS NULL
    BEGIN
        INSERT INTO dbo.WF_Workflow
            (Nome, Descrizione, DirectoryOutput, NomeFileLog, NomeFileLogResult, PausaTraStepMS,
             ApriDirectoryFinale, LoggaInizioOperazione, VariabiliGlobali, ParametriExtra, Attivo)
        VALUES
            (@Nome, @Descrizione, @DirectoryOutput, @NomeFileLog, @NomeFileLogResult, ISNULL(@PausaTraStepMS, 0),
             ISNULL(@ApriDirectoryFinale, 0), ISNULL(@LoggaInizioOperazione, 1), ISNULL(@VariabiliGlobali, N'[]'), N'{}', ISNULL(@Attivo, 1));
        SET @IdWorkflow = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.WF_Workflow
           SET Nome = @Nome, Descrizione = @Descrizione, DirectoryOutput = @DirectoryOutput,
               NomeFileLog = @NomeFileLog, NomeFileLogResult = @NomeFileLogResult,
               PausaTraStepMS = ISNULL(@PausaTraStepMS, PausaTraStepMS),
               ApriDirectoryFinale = ISNULL(@ApriDirectoryFinale, ApriDirectoryFinale),
               LoggaInizioOperazione = ISNULL(@LoggaInizioOperazione, LoggaInizioOperazione),
               VariabiliGlobali = ISNULL(@VariabiliGlobali, VariabiliGlobali),
               Attivo = ISNULL(@Attivo, Attivo),
               DataModifica = SYSUTCDATETIME()
         WHERE IdWorkflow = @IdWorkflow;
        IF @@ROWCOUNT = 0 RAISERROR('WF_usp_Workflow_Salva: workflow %d inesistente.', 16, 1, @IdWorkflow);
    END
END
GO

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
    BEGIN
        RAISERROR('WF_usp_Esecuzione_Crea: @Parametri non e'' JSON valido.', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.WF_Workflow WHERE IdWorkflow = @IdWorkflow)
    BEGIN
        RAISERROR('WF_usp_Esecuzione_Crea: Workflow %d inesistente.', 16, 1, @IdWorkflow);
        RETURN;
    END
    INSERT INTO dbo.WF_Esecuzione
        (IdPianificazione, IdDettaglio, IdWorkflow, Parametri, DataOraPrevista,
         Stato, Origine, GruppoConcorrenza, NomeUtente)
    VALUES
        (@IdPianificazione, @IdDettaglio, @IdWorkflow, @Parametri,
         ISNULL(@DataOraPrevista, SYSUTCDATETIME()), 0, @Origine, @GruppoConcorrenza, @NomeUtente);
    SET @IdEsecuzione = SCOPE_IDENTITY();
END
GO

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
    BEGIN
        RAISERROR('WF_usp_Pianificazione_Salva: @Parametri non e'' JSON valido.', 16, 1);
        RETURN;
    END
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
    BEGIN
        RAISERROR('WF_usp_Dettaglio_Salva: TipoRicorrenza deve essere CRON o ONESHOT.', 16, 1);
        RETURN;
    END
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
