-- Gestione clienti (pagina /clienti): condizioni di vendita del cliente.
-- Upsert + cancellazione fisica (sono righe di configurazione, non hanno storico).
CREATE OR ALTER PROCEDURE dbo.AI_CLIENTI_CONDIZIONI_Save
    @IdClienteCondizione int = NULL,
    @IdCliente int,
    @CodFamiglia varchar(5) = NULL,
    @CodTipoVendita varchar(5) = NULL,
    @DataInizioFatturazione date = NULL,
    @DataFineFatturazione date = NULL,
    @Ambito varchar(50) = NULL,
    @Scansione int = NULL,
    @IdProdotto int = NULL,
    @IdTracciato int = NULL,
    @IdFiliale int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdClienteCondizione IS NULL OR @IdClienteCondizione = 0
    BEGIN
        INSERT INTO [CLIENTI_CONDIZIONI] ([IdCliente], [CodFamiglia], [CodTipoVendita], [DataInizioFatturazione], [DataFineFatturazione], [Ambito], [Scansione], [IdProdotto], [IdTracciato], [IdFiliale])
        VALUES (@IdCliente, @CodFamiglia, @CodTipoVendita, @DataInizioFatturazione, @DataFineFatturazione, @Ambito, @Scansione, @IdProdotto, @IdTracciato, @IdFiliale);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [CLIENTI_CONDIZIONI] SET
            [IdCliente] = @IdCliente,
            [CodFamiglia] = @CodFamiglia,
            [CodTipoVendita] = @CodTipoVendita,
            [DataInizioFatturazione] = @DataInizioFatturazione,
            [DataFineFatturazione] = @DataFineFatturazione,
            [Ambito] = @Ambito,
            [Scansione] = @Scansione,
            [IdProdotto] = @IdProdotto,
            [IdTracciato] = @IdTracciato,
            [IdFiliale] = @IdFiliale
        WHERE [IdClienteCondizione] = @IdClienteCondizione;
        SELECT @IdClienteCondizione AS id;
    END
END
GO
GRANT EXECUTE ON dbo.AI_CLIENTI_CONDIZIONI_Save TO claude;
GO

CREATE OR ALTER PROCEDURE dbo.AI_CLIENTI_CONDIZIONI_Del
    @IdClienteCondizione int
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM [CLIENTI_CONDIZIONI] WHERE [IdClienteCondizione] = @IdClienteCondizione;
    SELECT @@ROWCOUNT AS righe;
END
GO
GRANT EXECUTE ON dbo.AI_CLIENTI_CONDIZIONI_Del TO claude;
GO

CREATE OR ALTER PROCEDURE dbo.AI_FATT_LISTINI_Del
    @IdListino int
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM [FATT_LISTINI] WHERE [IdListino] = @IdListino;
    SELECT @@ROWCOUNT AS righe;
END
GO
GRANT EXECUTE ON dbo.AI_FATT_LISTINI_Del TO claude;
