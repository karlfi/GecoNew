-- Nuova spedizione parcel Speedy (pagina /sped-nuova). Wrapper di dbo.SPED_INSERIMENTO:
-- la stored legacy esige il barcode in ingresso, quindi se manca si inserisce con un
-- barcode temporaneo e lo si finalizza a '91' + IdSpedizione a 10 cifre (stessa
-- convenzione di dbo.InserimentoSpedizione), rigenerando poi le stampe del palmare.
CREATE OR ALTER PROCEDURE dbo.AI_SPED_NuovaParcel
    @IdCliente int,
    @IdProdotto int,
    @IdAzienda int = 2,
    @IdUtente int = NULL,
    @IdFiliale int = NULL,
    @IdMittente int = NULL,
    @TariffarioCodice varchar(100) = NULL,
    @Barcode varchar(50) = NULL,
    @DataRitiro datetime = NULL,          -- valorizzata solo se e' richiesto il ritiro
    @RitiroRagioneSociale varchar(200) = NULL,
    @RitiroIndirizzo varchar(200) = NULL,
    @RitiroNumeroCivico varchar(200) = NULL,
    @RitiroLocalita varchar(200) = NULL,
    @RitiroCap varchar(5) = NULL,
    @RitiroProvinciaCodice varchar(2) = NULL,
    @RitiroLatitude float = NULL,
    @RitiroLongitude float = NULL,
    @MittenteRagioneSociale varchar(50) = NULL,
    @MittenteIndirizzo varchar(50) = NULL,
    @MittenteLocalita varchar(50) = NULL,
    @MittenteCap varchar(5) = NULL,
    @MittenteProvinciaCodice varchar(2) = NULL,
    @MittenteEmail varchar(50) = NULL,
    @DestinazioneRagioneSociale varchar(200),
    @DestinazioneIndirizzo varchar(200),
    @DestinazioneNumeroCivico varchar(200) = NULL,
    @DestinazioneLocalita varchar(200),
    @DestinazioneCap varchar(5),
    @DestinazioneProvinciaCodice varchar(2),
    @DestinazioneLatitude float = NULL,
    @DestinazioneLongitude float = NULL,
    @ContattoDestDescrizione varchar(40) = NULL,
    @ContattoDestTelefono varchar(15) = NULL,
    @ContattoDestEmail varchar(100) = NULL,
    @Importo decimal(15, 5) = NULL,
    @ImportoContrassegno numeric(15, 3) = NULL,
    @PesoDichiaratoKG numeric(12, 3) = NULL,
    @Nota varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @bc varchar(50) = NULLIF(LTRIM(RTRIM(ISNULL(@Barcode, ''))), '');
    DECLARE @generato bit = 0;
    IF @bc IS NULL
    BEGIN
        -- temporaneo unico: sostituito con '91'+Id a inserimento riuscito
        SET @bc = 'WT' + RIGHT(REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), 12);
        SET @generato = 1;
    END

    -- NB: niente INSERT..EXEC: SPED_INSERIMENTO (via GetCoperture) emette piu' result
    -- set di forme diverse; i suoi select passano al chiamante, che legge l'ULTIMO
    -- (quello di questa SP, riconoscibile dalla colonna Barcode).
    DECLARE @id int;
    DECLARE @Adesso datetime = GETDATE();   -- @DataInserimento nella legacy e' senza default

    EXEC dbo.SPED_INSERIMENTO
        @Barcode = @bc,
        @IdCliente = @IdCliente,
        @IdAzienda = @IdAzienda,
        @IdProdotto = @IdProdotto,
        @IdUtente = @IdUtente,
        @IdFiliale = @IdFiliale,
        @DataCarico = @DataRitiro,
        @RitiroRagioneSociale = @RitiroRagioneSociale,
        @RitiroIndirizzo = @RitiroIndirizzo,
        @RitiroNumeroCivico = @RitiroNumeroCivico,
        @RitiroLocalita = @RitiroLocalita,
        @RitiroCap = @RitiroCap,
        @RitiroProvinciaCodice = @RitiroProvinciaCodice,
        @RitiroNazioneCodice = 'IT',
        @RitiroLatitude = @RitiroLatitude,
        @RitiroLongitude = @RitiroLongitude,
        @DestinazioneRagioneSociale = @DestinazioneRagioneSociale,
        @DestinazioneIndirizzo = @DestinazioneIndirizzo,
        @DestinazioneNumeroCivico = @DestinazioneNumeroCivico,
        @DestinazioneLocalita = @DestinazioneLocalita,
        @DestinazioneCap = @DestinazioneCap,
        @DestinazioneProvinciaCodice = @DestinazioneProvinciaCodice,
        @DestinazioneNazioneCodice = 'IT',
        @DestinazioneLatitude = @DestinazioneLatitude,
        @DestinazioneLongitude = @DestinazioneLongitude,
        @ContattoDestDescrizione = @ContattoDestDescrizione,
        @ContattoDestTelefono = @ContattoDestTelefono,
        @ContattoDestEmail = @ContattoDestEmail,
        @Importo = @Importo,
        @ImportoContrassegno = @ImportoContrassegno,
        @PesoDichiaratoKG = @PesoDichiaratoKG,
        @NOTA1 = @Nota,
        @TariffarioCodice = @TariffarioCodice,
        @MittenteRagioneSociale = @MittenteRagioneSociale,
        @MittenteIndirizzo = @MittenteIndirizzo,
        @MittenteLocalita = @MittenteLocalita,
        @MittenteCap = @MittenteCap,
        @MittenteProvinciaCodice = @MittenteProvinciaCodice,
        @MittenteEmail = @MittenteEmail,
        @DataInserimento = @Adesso,
        @IdSpedizione = @id OUTPUT;

    DECLARE @IdAttivita int, @Result varchar(200);
    IF @id IS NULL
    BEGIN
        SELECT CAST(NULL AS int) AS IdSpedizione, CAST(NULL AS int) AS IdAttivita,
               'Inserimento non riuscito' AS Result, @bc AS Barcode;
        RETURN;
    END

    SELECT @IdAttivita = MAX(IdAttivita) FROM dbo.PALM_ATTIVITA
    WHERE TipoRiferimento = 0 AND Riferimento = CONVERT(varchar(50), @id);
    SET @Result = 'OK';

    IF @generato = 1
    BEGIN
        SET @bc = '91' + RIGHT('0000000000' + CONVERT(varchar(10), @id), 10);
        UPDATE dbo.SPED_ATTIVITA SET Barcode = @bc WHERE IdSpedizione = @id;
        UPDATE dbo.PALM_ATTIVITA SET Barcode = @bc WHERE IdAttivita = @IdAttivita;
        -- le stampe palmare (CPCL) incorporano il barcode: vanno rigenerate
        EXEC dbo.PALM_AggiornaReport @IdAttivita = @IdAttivita;
    END
    IF @IdMittente IS NOT NULL
        UPDATE dbo.SPED_ATTIVITA SET IdMittente = @IdMittente WHERE IdSpedizione = @id;

    SELECT @id AS IdSpedizione, @IdAttivita AS IdAttivita, @Result AS Result, @bc AS Barcode;
END
GO
GRANT EXECUTE ON dbo.AI_SPED_NuovaParcel TO claude;
