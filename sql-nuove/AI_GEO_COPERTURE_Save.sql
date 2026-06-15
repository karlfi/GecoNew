-- Upsert generato dallo schema di [GEO_COPERTURE]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_GEO_COPERTURE_Save
    @IdCopertura int = NULL,
    @CAP varchar(5) = NULL,
    @TipoArea varchar(10) = NULL,
    @SIGLAPROV varchar(2) = NULL,
    @BELFIORE varchar(5) = NULL,
    @IdProdotto int = NULL,
    @IdFilialeDistribuzione int = NULL,
    @IdFilialeGiacenza int = NULL,
    @Giorni int = NULL,
    @Isola int = NULL,
    @AreaDisagiata int = NULL,
    @AttivoDal date = NULL,
    @FinoAl date = NULL,
    @Comune varchar(250) = NULL,
    @DataModifica datetime = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdCopertura IS NULL OR @IdCopertura = 0
    BEGIN
        INSERT INTO [GEO_COPERTURE] ([CAP], [TipoArea], [SIGLAPROV], [BELFIORE], [IdProdotto], [IdFilialeDistribuzione], [IdFilialeGiacenza], [Giorni], [Isola], [AreaDisagiata], [AttivoDal], [FinoAl], [Comune], [DataModifica])
        VALUES (@CAP, @TipoArea, @SIGLAPROV, @BELFIORE, @IdProdotto, @IdFilialeDistribuzione, @IdFilialeGiacenza, @Giorni, @Isola, @AreaDisagiata, @AttivoDal, @FinoAl, @Comune, @DataModifica);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [GEO_COPERTURE] SET
            [CAP] = @CAP,
            [TipoArea] = @TipoArea,
            [SIGLAPROV] = @SIGLAPROV,
            [BELFIORE] = @BELFIORE,
            [IdProdotto] = @IdProdotto,
            [IdFilialeDistribuzione] = @IdFilialeDistribuzione,
            [IdFilialeGiacenza] = @IdFilialeGiacenza,
            [Giorni] = @Giorni,
            [Isola] = @Isola,
            [AreaDisagiata] = @AreaDisagiata,
            [AttivoDal] = @AttivoDal,
            [FinoAl] = @FinoAl,
            [Comune] = @Comune,
            [DataModifica] = @DataModifica
        WHERE [IdCopertura] = @IdCopertura;
        SELECT @IdCopertura AS id;
    END
END

