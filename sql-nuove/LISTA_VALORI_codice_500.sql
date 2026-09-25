-- LISTA_VALORI.Codice da varchar(50) a varchar(500), come Valore (richiesta di Carlo, 24/09/2026):
-- il token GitHub fine-grained (~93 caratteri, per OPS-02_AGGIORNA_DA_GITHUB) veniva troncato a 50
-- in silenzio. Nessun indice ne' vista con schemabinding sulla colonna (solo una statistica automatica,
-- che non blocca); la tabella la leggono AI_LISTA_VALORI_Save, ElencoListaValori, import_imile e
-- AI_MEZZI_FOTO_Save. Anche il parametro @Codice di AI_LISTA_VALORI_Save passa a 500, altrimenti
-- sarebbe lui a troncare. Idempotente.
IF COL_LENGTH('dbo.LISTA_VALORI', 'Codice') < 500
    ALTER TABLE dbo.LISTA_VALORI ALTER COLUMN Codice varchar(500) COLLATE Latin1_General_CI_AS NULL;
GO

-- Upsert generato dallo schema di [LISTA_VALORI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_LISTA_VALORI_Save
    @IdListaValori int = NULL,
    @Lista varchar(50) = NULL,
    @Valore varchar(500) = NULL,
    @Codice varchar(500) = NULL,
    @Ordine int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdListaValori IS NULL OR @IdListaValori = 0
    BEGIN
        INSERT INTO [LISTA_VALORI] ([Lista], [Valore], [Codice], [Ordine])
        VALUES (@Lista, @Valore, @Codice, @Ordine);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [LISTA_VALORI] SET
            [Lista] = @Lista,
            [Valore] = @Valore,
            [Codice] = @Codice,
            [Ordine] = @Ordine
        WHERE [IdListaValori] = @IdListaValori;
        SELECT @IdListaValori AS id;
    END
END
GO
