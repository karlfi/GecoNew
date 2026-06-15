
CREATE TRIGGER [dbo].[TR_UP_UTENTI] 
   ON  [dbo].[UTENTI]
   AFTER UPDATE
AS 
BEGIN
   SET NOCOUNT ON;

    BEGIN TRY
        -- Verifica se i soli campi modificati sono DataUltimoAccesso e LoginErrors
        IF EXISTS (
            SELECT 1
            FROM inserted INS
            JOIN deleted DEL ON INS.IdUtente = DEL.IdUtente
            WHERE 
                (INS.DataUltimoAccesso <> DEL.DataUltimoAccesso OR INS.LoginErrors <> DEL.LoginErrors) -- Cambiamenti solo su questi campi
                AND 
                (INS.IdUtente = DEL.IdUtente AND 
                 (ISNULL(INS.DataUltimoAccesso, '') <> ISNULL(DEL.DataUltimoAccesso, '') OR 
                  ISNULL(INS.LoginErrors, 0) <> ISNULL(DEL.LoginErrors, 0)))
        )
        BEGIN
            -- Se solo DataUltimoAccesso o LoginErrors sono cambiati, termina il trigger senza fare nulla
            RETURN;
        END

        -- Altrimenti, registra il cambiamento come di consueto
        INSERT INTO [LogTabelle] (Tabella, Operatore, TipoOperazione, Record, IdTabella)
        SELECT 
            'UTENTI', 
            SUSER_NAME(), 
            'UPDATE', 
            (SELECT * FROM inserted INS 
             FOR XML RAW('UTENTI'), ELEMENTS, TYPE),
            INS.IdUtente
        FROM 
            inserted INS;
    END TRY
    BEGIN CATCH
        -- Gestione degli errori
        --DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        --PRINT @ErrorMessage;  -- O inserisci in una tabella di log degli errori
    END CATCH;

END

