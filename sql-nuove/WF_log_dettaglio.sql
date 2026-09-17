-- =============================================================
-- Log delle esecuzioni piu' leggibile (2026-09-17, richiesta di Carlo: "non si
-- capisce quale step sta eseguendo, ci vuole tutto quello che e' stato eseguito
-- coi parametri sostituiti, per poterlo rieseguire, e qualche info dell'esito").
--
--   Dettaglio = il testo intero di quello che lo step ha fatto, coi segnaposto
--               gia' sostituiti: la query, il comando e il suo output, i file
--               copiati, la mail (mai la password SMTP). Anche sulle righe di
--               errore, cosi' la query che ha fallito si riprova a mano.
--   DurataMs  = quanto ci ha messo lo step.
-- Il nome e il tipo dello step la pagina li prende da WF_WorkflowStep (IdStep).
-- Stesse modifiche riportate in WF_database.sql per le installazioni nuove.
-- =============================================================
IF COL_LENGTH('dbo.WF_EsecuzioneLog', 'Dettaglio') IS NULL
    ALTER TABLE dbo.WF_EsecuzioneLog ADD Dettaglio NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('dbo.WF_EsecuzioneLog', 'DurataMs') IS NULL
    ALTER TABLE dbo.WF_EsecuzioneLog ADD DurataMs INT NULL;
GO

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

SELECT name, system_type_id FROM sys.columns
WHERE object_id = OBJECT_ID('dbo.WF_EsecuzioneLog') AND name IN ('Dettaglio', 'DurataMs');
