-- Upsert generato dallo schema di [CLIENTI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_CLIENTI_Save
    @IdCliente int = NULL,
    @IdAzienda int = NULL,
    @RagioneSociale varchar(250) = NULL,
    @CIG varchar(50) = NULL,
    @Descrizione varchar(500) = NULL,
    @PartitaIva varchar(50) = NULL,
    @CodSDI varchar(50) = NULL,
    @PEC varchar(50) = NULL,
    @Indirizzo varchar(250) = NULL,
    @CAP varchar(5) = NULL,
    @Comune varchar(250) = NULL,
    @Prov varchar(2) = NULL,
    @Nazione varchar(5) = NULL,
    @Telefono varchar(50) = NULL,
    @Email varchar(50) = NULL,
    @DataFine date = NULL,
    @CodiceCliente varchar(50) = NULL,
    @Gestionale varchar(50) = NULL,
    @InvioEmailEventi int = NULL,
    @EmailPrefattura varchar(2000) = NULL,
    @Demo int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdCliente IS NULL OR @IdCliente = 0
    BEGIN
        INSERT INTO [CLIENTI] ([IdAzienda], [RagioneSociale], [CIG], [Descrizione], [PartitaIva], [CodSDI], [PEC], [Indirizzo], [CAP], [Comune], [Prov], [Nazione], [Telefono], [Email], [DataFine], [CodiceCliente], [Gestionale], [InvioEmailEventi], [EmailPrefattura], [Demo])
        VALUES (@IdAzienda, @RagioneSociale, @CIG, @Descrizione, @PartitaIva, @CodSDI, @PEC, @Indirizzo, @CAP, @Comune, @Prov, @Nazione, @Telefono, @Email, @DataFine, @CodiceCliente, @Gestionale, @InvioEmailEventi, @EmailPrefattura, @Demo);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [CLIENTI] SET
            [IdAzienda] = @IdAzienda,
            [RagioneSociale] = @RagioneSociale,
            [CIG] = @CIG,
            [Descrizione] = @Descrizione,
            [PartitaIva] = @PartitaIva,
            [CodSDI] = @CodSDI,
            [PEC] = @PEC,
            [Indirizzo] = @Indirizzo,
            [CAP] = @CAP,
            [Comune] = @Comune,
            [Prov] = @Prov,
            [Nazione] = @Nazione,
            [Telefono] = @Telefono,
            [Email] = @Email,
            [DataFine] = @DataFine,
            [CodiceCliente] = @CodiceCliente,
            [Gestionale] = @Gestionale,
            [InvioEmailEventi] = @InvioEmailEventi,
            [EmailPrefattura] = @EmailPrefattura,
            [Demo] = @Demo
        WHERE [IdCliente] = @IdCliente;
        SELECT @IdCliente AS id;
    END
END
