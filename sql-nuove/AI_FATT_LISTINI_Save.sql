-- Upsert generato dallo schema di [FATT_LISTINI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_FATT_LISTINI_Save
    @IdListino int = NULL,
    @CodiceListino varchar(50) = NULL,
    @Descrizione varchar(50) = NULL,
    @IdProdotto int = NULL,
    @IdCliente int = NULL,
    @PrezzoAttivo float = NULL,
    @ScontoAttivo float = NULL,
    @PrezzoPassivo float = NULL,
    @ScontoPassivo float = NULL,
    @AliquotaIVA int = NULL,
    @ValidoDal date = NULL,
    @ValidoAl date = NULL,
    @ProdottoServizio varchar(5) = NULL,
    @TipoArea varchar(10) = NULL,
    @Porto int = NULL,
    @PesoMin int = NULL,
    @PesoMax int = NULL,
    @Tipo varchar(100) = NULL,
    @tariffaOS float = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdListino IS NULL OR @IdListino = 0
    BEGIN
        INSERT INTO [FATT_LISTINI] ([CodiceListino], [Descrizione], [IdProdotto], [IdCliente], [PrezzoAttivo], [ScontoAttivo], [PrezzoPassivo], [ScontoPassivo], [AliquotaIVA], [ValidoDal], [ValidoAl], [ProdottoServizio], [TipoArea], [Porto], [PesoMin], [PesoMax], [Tipo], [tariffaOS])
        VALUES (@CodiceListino, @Descrizione, @IdProdotto, @IdCliente, @PrezzoAttivo, @ScontoAttivo, @PrezzoPassivo, @ScontoPassivo, @AliquotaIVA, @ValidoDal, @ValidoAl, @ProdottoServizio, @TipoArea, @Porto, @PesoMin, @PesoMax, @Tipo, @tariffaOS);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [FATT_LISTINI] SET
            [CodiceListino] = @CodiceListino,
            [Descrizione] = @Descrizione,
            [IdProdotto] = @IdProdotto,
            [IdCliente] = @IdCliente,
            [PrezzoAttivo] = @PrezzoAttivo,
            [ScontoAttivo] = @ScontoAttivo,
            [PrezzoPassivo] = @PrezzoPassivo,
            [ScontoPassivo] = @ScontoPassivo,
            [AliquotaIVA] = @AliquotaIVA,
            [ValidoDal] = @ValidoDal,
            [ValidoAl] = @ValidoAl,
            [ProdottoServizio] = @ProdottoServizio,
            [TipoArea] = @TipoArea,
            [Porto] = @Porto,
            [PesoMin] = @PesoMin,
            [PesoMax] = @PesoMax,
            [Tipo] = @Tipo,
            [tariffaOS] = @tariffaOS
        WHERE [IdListino] = @IdListino;
        SELECT @IdListino AS id;
    END
END

