-- Upsert generato dallo schema di [MEZZI_NOTE] (manutenzioni mezzi).
-- Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_MEZZI_NOTE_Save
    @IdMezzoNota int = NULL,
    @IdMezzo int = NULL,
    @IdUtente int = NULL,
    @IdDipendenteSpeedy int = NULL,
    @data smalldatetime = NULL,
    @datainserimento smalldatetime = NULL,
    @note varchar(150) = NULL,
    @utente varchar(50) = NULL,
    @DataFine smalldatetime = NULL,
    @IdFornitore int = NULL,
    @Fornitore varchar(250) = NULL,
    @ImportoPreventivo float = NULL,
    @DataFattura date = NULL,
    @Seriale int = NULL,
    @DataInizioFermo date = NULL,
    @DataFineFermo date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdMezzoNota IS NULL OR @IdMezzoNota = 0
    BEGIN
        INSERT INTO [MEZZI_NOTE] ([IdMezzo], [IdUtente], [IdDipendenteSpeedy], [data],
            [datainserimento], [note], [utente], [DataFine], [IdFornitore], [Fornitore],
            [ImportoPreventivo], [DataFattura], [Seriale], [DataInizioFermo], [DataFineFermo])
        VALUES (@IdMezzo, @IdUtente, @IdDipendenteSpeedy, @data,
            ISNULL(@datainserimento, GETDATE()), @note, @utente, @DataFine, @IdFornitore, @Fornitore,
            @ImportoPreventivo, @DataFattura, @Seriale, @DataInizioFermo, @DataFineFermo);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [MEZZI_NOTE] SET
            [IdMezzo] = @IdMezzo,
            [IdUtente] = @IdUtente,
            [IdDipendenteSpeedy] = @IdDipendenteSpeedy,
            [data] = @data,
            [datainserimento] = @datainserimento,
            [note] = @note,
            [utente] = @utente,
            [DataFine] = @DataFine,
            [IdFornitore] = @IdFornitore,
            [Fornitore] = @Fornitore,
            [ImportoPreventivo] = @ImportoPreventivo,
            [DataFattura] = @DataFattura,
            [Seriale] = @Seriale,
            [DataInizioFermo] = @DataInizioFermo,
            [DataFineFermo] = @DataFineFermo
        WHERE [IdMezzoNota] = @IdMezzoNota;
        SELECT @IdMezzoNota AS id;
    END
END
