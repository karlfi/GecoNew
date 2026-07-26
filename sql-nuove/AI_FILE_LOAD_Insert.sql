-- Accettazione da file (pagina /accettazione-file): staging del file caricato dal
-- browser nella tabella FILE_LOAD (una riga per riga di file, chiave DocID+NomeFile),
-- che e' il formato atteso dalla stored legacy dbo.LoadFromFile.
-- @Righe e' un array JSON di stringhe; l'ORDER BY sulla key preserva l'ordine
-- del file (l'identity IdFileLoad determina il numero di riga in LoadFromFile).
CREATE OR ALTER PROCEDURE dbo.AI_FILE_LOAD_Insert
    @DocID varchar(50),
    @NomeFile varchar(250),
    @Righe nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.FILE_LOAD (DocID, NomeFile, Testo, DataLoad)
    SELECT @DocID, @NomeFile, LEFT(j.value, 4000), GETDATE()
    FROM OPENJSON(@Righe) j
    ORDER BY CAST(j.[key] AS int);
    SELECT @@ROWCOUNT AS righe;
END
GO
GRANT EXECUTE ON dbo.AI_FILE_LOAD_Insert TO claude;
GRANT EXECUTE ON dbo.ElencoClienti TO claude;
GRANT EXECUTE ON dbo.ElencoFamiglie TO claude;
GRANT EXECUTE ON dbo.LoadFromFile TO claude;
