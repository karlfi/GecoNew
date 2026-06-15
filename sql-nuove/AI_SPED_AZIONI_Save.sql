-- Upsert generato dallo schema di [SPED_AZIONI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_SPED_AZIONI_Save
    @IdAzione int = NULL,
    @Azione varchar(50) = NULL,
    @Stato_Inizio varchar(50) = NULL,
    @Stato_Fine varchar(50) = NULL,
    @IdProcessi varchar(50) = NULL,
    @TipoDistinta varchar(50) = NULL,
    @WebReport varchar(50) = NULL,
    @CodFamigliaAzione varchar(5) = NULL,
    @Ordine int = NULL,
    @Chiedi_Operatore int = NULL,
    @Chiedi_Citta int = NULL,
    @Chiedi_Filiale int = NULL,
    @Chiedi_Distinta int = NULL,
    @Chiedi_FilialeDest int = NULL,
    @Chiedi_FilialeGiac int = NULL,
    @Chiedi_Resi int = NULL,
    @Chiedi_Terzi int = NULL,
    @Chiedi_Scatola int = NULL,
    @Attivo int = NULL,
    @EsitoFinale int = NULL,
    @AggiornaSpedizione int = NULL,
    @Forzabile int = NULL,
    @PortaSuPalmare int = NULL,
    @ForzaFiliale int = NULL,
    @IdProdottoGenerato int = NULL,
    @MantieniDataPrec int = NULL,
    @Descrizione varchar(1000) = NULL,
    @MaxAtti int = NULL,
    @ControlloData int = NULL,
    @Param1_Tipo varchar(50) = NULL,
    @Param1_Desc varchar(50) = NULL,
    @Chiedi_Cartolina int = NULL,
    @AttiChiusi int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdAzione IS NULL OR @IdAzione = 0
    BEGIN
        INSERT INTO [SPED_AZIONI] ([Azione], [Stato_Inizio], [Stato_Fine], [IdProcessi], [TipoDistinta], [WebReport], [CodFamigliaAzione], [Ordine], [Chiedi_Operatore], [Chiedi_Citta], [Chiedi_Filiale], [Chiedi_Distinta], [Chiedi_FilialeDest], [Chiedi_FilialeGiac], [Chiedi_Resi], [Chiedi_Terzi], [Chiedi_Scatola], [Attivo], [EsitoFinale], [AggiornaSpedizione], [Forzabile], [PortaSuPalmare], [ForzaFiliale], [IdProdottoGenerato], [MantieniDataPrec], [Descrizione], [MaxAtti], [ControlloData], [Param1_Tipo], [Param1_Desc], [Chiedi_Cartolina], [AttiChiusi])
        VALUES (@Azione, @Stato_Inizio, @Stato_Fine, @IdProcessi, @TipoDistinta, @WebReport, @CodFamigliaAzione, @Ordine, @Chiedi_Operatore, @Chiedi_Citta, @Chiedi_Filiale, @Chiedi_Distinta, @Chiedi_FilialeDest, @Chiedi_FilialeGiac, @Chiedi_Resi, @Chiedi_Terzi, @Chiedi_Scatola, @Attivo, @EsitoFinale, @AggiornaSpedizione, @Forzabile, @PortaSuPalmare, @ForzaFiliale, @IdProdottoGenerato, @MantieniDataPrec, @Descrizione, @MaxAtti, @ControlloData, @Param1_Tipo, @Param1_Desc, @Chiedi_Cartolina, @AttiChiusi);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [SPED_AZIONI] SET
            [Azione] = @Azione,
            [Stato_Inizio] = @Stato_Inizio,
            [Stato_Fine] = @Stato_Fine,
            [IdProcessi] = @IdProcessi,
            [TipoDistinta] = @TipoDistinta,
            [WebReport] = @WebReport,
            [CodFamigliaAzione] = @CodFamigliaAzione,
            [Ordine] = @Ordine,
            [Chiedi_Operatore] = @Chiedi_Operatore,
            [Chiedi_Citta] = @Chiedi_Citta,
            [Chiedi_Filiale] = @Chiedi_Filiale,
            [Chiedi_Distinta] = @Chiedi_Distinta,
            [Chiedi_FilialeDest] = @Chiedi_FilialeDest,
            [Chiedi_FilialeGiac] = @Chiedi_FilialeGiac,
            [Chiedi_Resi] = @Chiedi_Resi,
            [Chiedi_Terzi] = @Chiedi_Terzi,
            [Chiedi_Scatola] = @Chiedi_Scatola,
            [Attivo] = @Attivo,
            [EsitoFinale] = @EsitoFinale,
            [AggiornaSpedizione] = @AggiornaSpedizione,
            [Forzabile] = @Forzabile,
            [PortaSuPalmare] = @PortaSuPalmare,
            [ForzaFiliale] = @ForzaFiliale,
            [IdProdottoGenerato] = @IdProdottoGenerato,
            [MantieniDataPrec] = @MantieniDataPrec,
            [Descrizione] = @Descrizione,
            [MaxAtti] = @MaxAtti,
            [ControlloData] = @ControlloData,
            [Param1_Tipo] = @Param1_Tipo,
            [Param1_Desc] = @Param1_Desc,
            [Chiedi_Cartolina] = @Chiedi_Cartolina,
            [AttiChiusi] = @AttiChiusi
        WHERE [IdAzione] = @IdAzione;
        SELECT @IdAzione AS id;
    END
END

