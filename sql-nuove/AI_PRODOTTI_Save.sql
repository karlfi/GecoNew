-- Upsert generato dallo schema di [PRODOTTI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_PRODOTTI_Save
    @IdProdotto int = NULL,
    @Prodotto varchar(50) = NULL,
    @CodFamiglia varchar(5) = NULL,
    @IdPalmServizio int = NULL,
    @IdProcesso int = NULL,
    @IdGruppoProdotto int = NULL,
    @IdListino int = NULL,
    @Figlio int = NULL,
    @IdProdottoCollegato int = NULL,
    @IdProdottoCollegatoTerzi int = NULL,
    @Sigla varchar(50) = NULL,
    @DataFineValidita smalldatetime = NULL,
    @MultiPeso int = NULL,
    @CodConsip varchar(50) = NULL,
    @CodSpike varchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdProdotto IS NULL OR @IdProdotto = 0
    BEGIN
        INSERT INTO [PRODOTTI] ([Prodotto], [CodFamiglia], [IdPalmServizio], [IdProcesso], [IdGruppoProdotto], [IdListino], [Figlio], [IdProdottoCollegato], [IdProdottoCollegatoTerzi], [Sigla], [DataFineValidita], [MultiPeso], [CodConsip], [CodSpike])
        VALUES (@Prodotto, @CodFamiglia, @IdPalmServizio, @IdProcesso, @IdGruppoProdotto, @IdListino, @Figlio, @IdProdottoCollegato, @IdProdottoCollegatoTerzi, @Sigla, @DataFineValidita, @MultiPeso, @CodConsip, @CodSpike);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [PRODOTTI] SET
            [Prodotto] = @Prodotto,
            [CodFamiglia] = @CodFamiglia,
            [IdPalmServizio] = @IdPalmServizio,
            [IdProcesso] = @IdProcesso,
            [IdGruppoProdotto] = @IdGruppoProdotto,
            [IdListino] = @IdListino,
            [Figlio] = @Figlio,
            [IdProdottoCollegato] = @IdProdottoCollegato,
            [IdProdottoCollegatoTerzi] = @IdProdottoCollegatoTerzi,
            [Sigla] = @Sigla,
            [DataFineValidita] = @DataFineValidita,
            [MultiPeso] = @MultiPeso,
            [CodConsip] = @CodConsip,
            [CodSpike] = @CodSpike
        WHERE [IdProdotto] = @IdProdotto;
        SELECT @IdProdotto AS id;
    END
END

