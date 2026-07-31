-- Upsert generato dallo schema di [MEZZI_SINISTRI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_MEZZI_SINISTRI_Save
    @IdMezzoSinistro int = NULL,
    @IdUtente int = NULL,
    @IdDipendenteSpeedy int = NULL,
    @idMezzo int = NULL,
    @ap int = NULL,
    @data date = NULL,
    @sanzione varchar(50) = NULL,
    @note varchar(255) = NULL,
    @Controllati int = NULL,
    @targa varchar(10) = NULL,
    @DataCancellazione date = NULL,
    @IdFornitore int = NULL,
    @ValoreRiparazione float = NULL,
    @ValoreRimborso float = NULL,
    @ValoreFranchigia float = NULL,
    @Riferimento varchar(250) = NULL,
    @DataSanzioneApp date = NULL,
    @DataFatturaRiparazione date = NULL,
    @DataRichiestaFranchigia date = NULL,
    @DataIncassoRimborso date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdMezzoSinistro IS NULL OR @IdMezzoSinistro = 0
    BEGIN
        INSERT INTO [MEZZI_SINISTRI] ([IdUtente], [IdDipendenteSpeedy], [idMezzo], [ap], [data],
            [sanzione], [note], [Controllati], [targa], [DataCancellazione], [IdFornitore],
            [ValoreRiparazione], [ValoreRimborso], [ValoreFranchigia], [Riferimento],
            [DataSanzioneApp], [DataFatturaRiparazione], [DataRichiestaFranchigia], [DataIncassoRimborso])
        VALUES (@IdUtente, @IdDipendenteSpeedy, @idMezzo, @ap, @data,
            @sanzione, @note, @Controllati, @targa, @DataCancellazione, @IdFornitore,
            @ValoreRiparazione, @ValoreRimborso, @ValoreFranchigia, @Riferimento,
            @DataSanzioneApp, @DataFatturaRiparazione, @DataRichiestaFranchigia, @DataIncassoRimborso);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [MEZZI_SINISTRI] SET
            [IdUtente] = @IdUtente,
            [IdDipendenteSpeedy] = @IdDipendenteSpeedy,
            [idMezzo] = @idMezzo,
            [ap] = @ap,
            [data] = @data,
            [sanzione] = @sanzione,
            [note] = @note,
            [Controllati] = @Controllati,
            [targa] = @targa,
            [DataCancellazione] = @DataCancellazione,
            [IdFornitore] = @IdFornitore,
            [ValoreRiparazione] = @ValoreRiparazione,
            [ValoreRimborso] = @ValoreRimborso,
            [ValoreFranchigia] = @ValoreFranchigia,
            [Riferimento] = @Riferimento,
            [DataSanzioneApp] = @DataSanzioneApp,
            [DataFatturaRiparazione] = @DataFatturaRiparazione,
            [DataRichiestaFranchigia] = @DataRichiestaFranchigia,
            [DataIncassoRimborso] = @DataIncassoRimborso
        WHERE [IdMezzoSinistro] = @IdMezzoSinistro;
        SELECT @IdMezzoSinistro AS id;
    END
END
