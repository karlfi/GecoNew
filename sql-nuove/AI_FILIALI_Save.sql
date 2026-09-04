-- =============================================================
-- AI_FILIALI_Save: mancava IdFiliale_HRSpeedy, colonna aggiunta alla tabella
-- dopo che la stored era stata scritta. La pagina di modifica manda tutte le
-- colonne, quindi il salvataggio moriva con "troppi argomenti specificati".
-- =============================================================



-- ----------------------------------------------------------

-- AI_FILIALI_Save.sql

-- ----------------------------------------------------------

-- Upsert generato dallo schema di [FILIALI]. Scritture solo via SP (prefisso AI_).

CREATE OR ALTER PROCEDURE dbo.AI_FILIALI_Save

    @IDFILIALE int = NULL,

    @FILIALE varchar(50) = NULL,

    @IdAzienda int = NULL,

    @Indirizzo varchar(250) = NULL,

    @CAP varchar(5) = NULL,

    @Comune varchar(250) = NULL,

    @Prov varchar(2) = NULL,

    @Orari varchar(250) = NULL,

    @Telefono varchar(50) = NULL,

    @Email varchar(50) = NULL,

    @Latitude float = NULL,

    @Longitude float = NULL,

    @IdReferente int = NULL,

    @Cellulare varchar(50) = NULL,

    @FilialeGiacenza int = NULL,

    @FilialeDistribuzione int = NULL,

    @DataAttivazione date = NULL,

    @DataChiusura date = NULL,

    @IdFilialeSpeedy int = NULL,

    @IncrementoGGiacenza int = NULL,

    @bCode varchar(3) = NULL,

    @CodZUK varchar(50) = NULL,
    @IdFiliale_HRSpeedy int = NULL,

    @IBAN varchar(50) = NULL,

    @DirFTP varchar(50) = NULL,

    @NXV varchar(250) = NULL,

    @DescScontrino varchar(250) = NULL,

    @GeoNormalizza int = NULL,

    @HRParcel varchar(50) = NULL,

    @Inpost varchar(50) = NULL

AS

BEGIN

    SET NOCOUNT ON;

    IF @IDFILIALE IS NULL OR @IDFILIALE = 0

    BEGIN

        INSERT INTO [FILIALI] ([FILIALE], [IdAzienda], [Indirizzo], [CAP], [Comune], [Prov], [Orari], [Telefono], [Email], [Latitude], [Longitude], [IdReferente], [Cellulare], [FilialeGiacenza], [FilialeDistribuzione], [DataAttivazione], [DataChiusura], [IdFilialeSpeedy], [IncrementoGGiacenza], [bCode], [CodZUK], [IdFiliale_HRSpeedy], [IBAN], [DirFTP], [NXV], [DescScontrino], [GeoNormalizza], [HRParcel], [Inpost])

        VALUES (@FILIALE, @IdAzienda, @Indirizzo, @CAP, @Comune, @Prov, @Orari, @Telefono, @Email, @Latitude, @Longitude, @IdReferente, @Cellulare, @FilialeGiacenza, @FilialeDistribuzione, @DataAttivazione, @DataChiusura, @IdFilialeSpeedy, @IncrementoGGiacenza, @bCode, @CodZUK, @IdFiliale_HRSpeedy, @IBAN, @DirFTP, @NXV, @DescScontrino, @GeoNormalizza, @HRParcel, @Inpost);

        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;

    END

    ELSE

    BEGIN

        UPDATE [FILIALI] SET

            [FILIALE] = @FILIALE,

            [IdAzienda] = @IdAzienda,

            [Indirizzo] = @Indirizzo,

            [CAP] = @CAP,

            [Comune] = @Comune,

            [Prov] = @Prov,

            [Orari] = @Orari,

            [Telefono] = @Telefono,

            [Email] = @Email,

            [Latitude] = @Latitude,

            [Longitude] = @Longitude,

            [IdReferente] = @IdReferente,

            [Cellulare] = @Cellulare,

            [FilialeGiacenza] = @FilialeGiacenza,

            [FilialeDistribuzione] = @FilialeDistribuzione,

            [DataAttivazione] = @DataAttivazione,

            [DataChiusura] = @DataChiusura,

            [IdFilialeSpeedy] = @IdFilialeSpeedy,

            [IncrementoGGiacenza] = @IncrementoGGiacenza,

            [bCode] = @bCode,

            [CodZUK] = @CodZUK,
            [IdFiliale_HRSpeedy] = @IdFiliale_HRSpeedy,

            [IBAN] = @IBAN,

            [DirFTP] = @DirFTP,

            [NXV] = @NXV,

            [DescScontrino] = @DescScontrino,

            [GeoNormalizza] = @GeoNormalizza,

            [HRParcel] = @HRParcel,

            [Inpost] = @Inpost

        WHERE [IDFILIALE] = @IDFILIALE;

        SELECT @IDFILIALE AS id;

    END

END


GO
