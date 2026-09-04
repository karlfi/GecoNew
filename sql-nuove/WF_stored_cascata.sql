-- Schedulatore: le stored che cancellano o rimpiazzano, riviste per convivere
-- con pianificazioni e storico (le FK di WF_PianificazioneMaster, WF_Esecuzione
-- e WF_EsecuzioneLog verso workflow e step non sono a cascata).
--   * Workflow_Import con @SovrascriviSeEsiste: riscrive SUL POSTO (stesso
--     IdWorkflow): testata aggiornata, step rifatti; pianificazioni e storico restano.
--   * Workflow_Delete: cascata esplicita (esecuzioni col log, pianificazioni con
--     le ricorrenze, step, workflow). La pagina lo dice prima di confermare.
--   * Step_Delete / Import: il log delle vecchie esecuzioni resta ma perde il
--     riferimento allo step (IdStep = NULL), il testo del messaggio basta.
--   * Dettaglio_Elimina: le esecuzioni gia' fatte di quella ricorrenza restano
--     nello storico agganciate alla pianificazione, non piu' alla ricorrenza.
USE DeliveryDB;
GO

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

        DECLARE @IdEsistente INT = (SELECT IdWorkflow FROM dbo.WF_Workflow WHERE Nome = @Nome);
        IF @IdEsistente IS NOT NULL AND @SovrascriviSeEsiste = 1
        BEGIN
            /* stesso workflow, contenuto nuovo: testata aggiornata, step rifatti */
            UPDATE dbo.WF_Workflow
               SET NStepDichiarati = @NStepDichiarati, DirectoryOutput = @DirectoryOutput,
                   NomeFileLog = @NomeFileLog, NomeFileLogResult = @NomeFileLogResult,
                   PausaTraStepMS = ISNULL(@PausaTraStepMS, 0),
                   ApriDirectoryFinale = ISNULL(@ApriDirectoryFinale, 0),
                   LoggaInizioOperazione = ISNULL(@LoggaInizioOperazione, 1),
                   VariabiliGlobali = @VariabiliGlobali, ParametriExtra = @ParametriExtra,
                   FileOrigine = @FileOrigine, HashOrigine = @HashOrigine,
                   DataModifica = SYSUTCDATETIME()
             WHERE IdWorkflow = @IdEsistente;
            UPDATE l SET l.IdStep = NULL
              FROM dbo.WF_EsecuzioneLog l JOIN dbo.WF_WorkflowStep s ON s.IdStep = l.IdStep
             WHERE s.IdWorkflow = @IdEsistente;
            DELETE FROM dbo.WF_WorkflowStep WHERE IdWorkflow = @IdEsistente;
            SET @IdWorkflow = @IdEsistente;
        END
        ELSE
        BEGIN
            /* nuovo (se il nome esiste gia' salta la UNIQUE: e' l'errore giusto) */
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
        END

        /* ---- step: dal TVP (id provvisori) alle righe vere, per livelli ---- */
        DECLARE @StepsLocal TABLE (
            TempId INT PRIMARY KEY, ParentTempId INT NULL, Ordine INT, NomeSezione NVARCHAR(120),
            Tipo NVARCHAR(50), EsciSuErrore BIT, EseguiPasso BIT, Attivo BIT, Parametri NVARCHAR(MAX));
        INSERT INTO @StepsLocal
            (TempId, ParentTempId, Ordine, NomeSezione, Tipo, EsciSuErrore, EseguiPasso, Attivo, Parametri)
        SELECT TempId, ParentTempId, Ordine, NomeSezione, Tipo, EsciSuErrore, EseguiPasso, Attivo, ISNULL(Parametri, N'{}')
        FROM @Steps;
        DECLARE @Map TABLE (TempId INT PRIMARY KEY, IdStep INT);
        DECLARE @Inseriti INT = 1;
        WHILE EXISTS (SELECT 1 FROM @StepsLocal s WHERE NOT EXISTS (SELECT 1 FROM @Map m WHERE m.TempId = s.TempId))
        BEGIN
            MERGE dbo.WF_WorkflowStep AS tgt
            USING (
                SELECT s.TempId, s.Ordine, s.NomeSezione, s.Tipo, s.EsciSuErrore, s.EseguiPasso, s.Attivo, s.Parametri,
                       pm.IdStep AS IdStepPadre
                FROM @StepsLocal s
                LEFT JOIN @Map pm ON pm.TempId = s.ParentTempId
                WHERE NOT EXISTS (SELECT 1 FROM @Map m WHERE m.TempId = s.TempId)
                  AND (s.ParentTempId IS NULL OR pm.IdStep IS NOT NULL)
            ) AS src
            ON 1 = 0   -- sempre INSERT: il MERGE serve per l'OUTPUT delle colonne sorgente
            WHEN NOT MATCHED THEN
                INSERT (IdWorkflow, IdStepPadre, Ordine, NomeSezione, Tipo, EsciSuErrore, EseguiPasso, Attivo, Parametri)
                VALUES (@IdWorkflow, src.IdStepPadre, src.Ordine, src.NomeSezione, src.Tipo,
                        src.EsciSuErrore, src.EseguiPasso, src.Attivo, src.Parametri)
            OUTPUT src.TempId, inserted.IdStep INTO @Map (TempId, IdStep);
            SET @Inseriti = @@ROWCOUNT;
            IF @Inseriti = 0
                RAISERROR('WF_usp_Workflow_Import: sottopassi orfani o ciclo nei parentTempId.', 16, 1);
        END
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE(), @sev INT = ERROR_SEVERITY(), @sta INT = ERROR_STATE();
        RAISERROR(@msg, @sev, @sta);
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.WF_usp_Workflow_Delete
    @IdWorkflow INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE FROM dbo.WF_Esecuzione           WHERE IdWorkflow = @IdWorkflow;   -- il log va via a cascata
        DELETE FROM dbo.WF_PianificazioneMaster WHERE IdWorkflow = @IdWorkflow;   -- le ricorrenze a cascata
        DELETE FROM dbo.WF_WorkflowStep         WHERE IdWorkflow = @IdWorkflow;
        DELETE FROM dbo.WF_Workflow             WHERE IdWorkflow = @IdWorkflow;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE(), @sev INT = ERROR_SEVERITY(), @sta INT = ERROR_STATE();
        RAISERROR(@msg, @sev, @sta);
    END CATCH
END
GO

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
        UPDATE dbo.WF_EsecuzioneLog SET IdStep = NULL WHERE IdStep IN (SELECT IdStep FROM @ToDel);
        -- tutto il sottoalbero in una DELETE sola: la self-FK e' verificata a fine istruzione
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

CREATE OR ALTER PROCEDURE dbo.WF_usp_Dettaglio_Elimina
    @IdDettaglio INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE FROM dbo.WF_Esecuzione WHERE IdDettaglio = @IdDettaglio AND Stato = 0;   -- le future
        UPDATE dbo.WF_Esecuzione SET IdDettaglio = NULL WHERE IdDettaglio = @IdDettaglio; -- lo storico resta
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
