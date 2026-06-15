-- Upsert generato dallo schema di [AZIENDE]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_AZIENDE_Save
    @IdAzienda int = NULL,
    @Azienda varchar(50) = NULL,
    @PartitaIva varchar(50) = NULL,
    @CodiceSDI varchar(50) = NULL,
    @Email varchar(50) = NULL,
    @Pec varchar(50) = NULL,
    @RappresentanteLegale varchar(50) = NULL,
    @Amm_Contatto varchar(50) = NULL,
    @Amm_Telefono varchar(50) = NULL,
    @Indirizzo varchar(50) = NULL,
    @Cap varchar(5) = NULL,
    @Prov varchar(2) = NULL,
    @IdAziendaMaster int = NULL,
    @NomeLogoPalmare varchar(50) = NULL,
    @EmailAssistenza varchar(500) = NULL,
    @GestionePresenze int = NULL,
    @Web varchar(150) = NULL,
    @IdFilialeDistribuzione int = NULL,
    @Comune varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdAzienda IS NULL OR @IdAzienda = 0
    BEGIN
        INSERT INTO [AZIENDE] ([Azienda], [PartitaIva], [CodiceSDI], [Email], [Pec], [RappresentanteLegale], [Amm_Contatto], [Amm_Telefono], [Indirizzo], [Cap], [Prov], [IdAziendaMaster], [NomeLogoPalmare], [EmailAssistenza], [GestionePresenze], [Web], [IdFilialeDistribuzione], [Comune])
        VALUES (@Azienda, @PartitaIva, @CodiceSDI, @Email, @Pec, @RappresentanteLegale, @Amm_Contatto, @Amm_Telefono, @Indirizzo, @Cap, @Prov, @IdAziendaMaster, @NomeLogoPalmare, @EmailAssistenza, @GestionePresenze, @Web, @IdFilialeDistribuzione, @Comune);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [AZIENDE] SET
            [Azienda] = @Azienda,
            [PartitaIva] = @PartitaIva,
            [CodiceSDI] = @CodiceSDI,
            [Email] = @Email,
            [Pec] = @Pec,
            [RappresentanteLegale] = @RappresentanteLegale,
            [Amm_Contatto] = @Amm_Contatto,
            [Amm_Telefono] = @Amm_Telefono,
            [Indirizzo] = @Indirizzo,
            [Cap] = @Cap,
            [Prov] = @Prov,
            [IdAziendaMaster] = @IdAziendaMaster,
            [NomeLogoPalmare] = @NomeLogoPalmare,
            [EmailAssistenza] = @EmailAssistenza,
            [GestionePresenze] = @GestionePresenze,
            [Web] = @Web,
            [IdFilialeDistribuzione] = @IdFilialeDistribuzione,
            [Comune] = @Comune
        WHERE [IdAzienda] = @IdAzienda;
        SELECT @IdAzienda AS id;
    END
END

