-- =============================================================
-- SP della pagina "Azioni (OLD)" (AzioniView) — prefisso AI_Azioni_.
-- Tre stored, una per riquadro della videata:
--   AI_Azioni_SaveAzione          upsert su SPED_AZIONI (+ aggancio al processo in insert)
--   AI_Azioni_SaveWorkflow        upsert su SPED_WORKFLOW
--   AI_Azioni_SaveProcessoAzione  upsert su PROCESSI_AZIONI
--
-- Convenzione flag legacy (InDe): -1 = vero, 0/NULL = falso.
-- NB: Chiedi_Scatola e ControlloData NON sono flag (valori 2,3,4 e -9..1).
-- =============================================================

-- Upsert azione: @IdAzione NULL = insert (e se @IdProcesso e' valorizzato la
-- collega subito al processo in PROCESSI_AZIONI); altrimenti update.
-- Restituisce IdAzione.
CREATE OR ALTER PROCEDURE dbo.AI_Azioni_SaveAzione
    @IdAzione           int          = NULL,
    @Azione             varchar(50),
    @Stato_Inizio       varchar(50)  = NULL,
    @Stato_Fine         varchar(50)  = NULL,
    @IdProcessi         varchar(50)  = NULL,
    @TipoDistinta       varchar(50)  = NULL,
    @WebReport          varchar(50)  = NULL,
    @CodFamigliaAzione  varchar(5)   = NULL,
    @Ordine             int          = NULL,
    @Chiedi_Operatore   int          = NULL,
    @Chiedi_Citta       int          = NULL,
    @Chiedi_Filiale     int          = NULL,
    @Chiedi_Distinta    int          = NULL,
    @Chiedi_FilialeDest int          = NULL,
    @Chiedi_FilialeGiac int          = NULL,
    @Chiedi_Resi        int          = NULL,
    @Chiedi_Terzi       int          = NULL,
    @Chiedi_Scatola     int          = NULL,
    @Attivo             int          = NULL,
    @EsitoFinale        int          = NULL,
    @AggiornaSpedizione int          = NULL,
    @Forzabile          int          = NULL,
    @PortaSuPalmare     int          = NULL,
    @ForzaFiliale       int          = NULL,
    @IdProdottoGenerato int          = NULL,
    @MantieniDataPrec   int          = NULL,
    @Descrizione        varchar(1000) = NULL,
    @MaxAtti            int          = NULL,
    @ControlloData      int          = NULL,
    @Param1_Tipo        varchar(50)  = NULL,
    @Param1_Desc        varchar(50)  = NULL,
    @Chiedi_Cartolina   int          = NULL,
    @AttiChiusi         int          = NULL,
    @IdProcesso         int          = NULL   -- solo in insert: processo a cui collegare l'azione
AS
BEGIN
    SET NOCOUNT ON;

    IF LTRIM(RTRIM(ISNULL(@Azione, ''))) = ''
    BEGIN
        RAISERROR('Il nome dell''azione e'' obbligatorio', 16, 1);
        RETURN;
    END

    IF @IdAzione IS NULL
    BEGIN
        INSERT INTO [SPED_AZIONI] (
            [Azione], [Stato_Inizio], [Stato_Fine], [IdProcessi], [TipoDistinta], [WebReport],
            [CodFamigliaAzione], [Ordine],
            [Chiedi_Operatore], [Chiedi_Citta], [Chiedi_Filiale], [Chiedi_Distinta],
            [Chiedi_FilialeDest], [Chiedi_FilialeGiac], [Chiedi_Resi], [Chiedi_Terzi], [Chiedi_Scatola],
            [Attivo], [EsitoFinale], [AggiornaSpedizione], [Forzabile], [PortaSuPalmare],
            [ForzaFiliale], [IdProdottoGenerato], [MantieniDataPrec], [Descrizione],
            [MaxAtti], [ControlloData], [Param1_Tipo], [Param1_Desc], [Chiedi_Cartolina], [AttiChiusi])
        VALUES (
            @Azione, @Stato_Inizio, @Stato_Fine, @IdProcessi, @TipoDistinta, @WebReport,
            @CodFamigliaAzione, @Ordine,
            @Chiedi_Operatore, @Chiedi_Citta, @Chiedi_Filiale, @Chiedi_Distinta,
            @Chiedi_FilialeDest, @Chiedi_FilialeGiac, @Chiedi_Resi, @Chiedi_Terzi, @Chiedi_Scatola,
            @Attivo, @EsitoFinale, @AggiornaSpedizione, @Forzabile, @PortaSuPalmare,
            @ForzaFiliale, @IdProdottoGenerato, @MantieniDataPrec, @Descrizione,
            @MaxAtti, @ControlloData, @Param1_Tipo, @Param1_Desc, @Chiedi_Cartolina, @AttiChiusi);

        SET @IdAzione = SCOPE_IDENTITY();

        -- nuova azione: la collego subito al processo da cui e' stata creata
        IF @IdProcesso IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM [PROCESSI_AZIONI] WHERE [IdProcesso] = @IdProcesso AND [IdAzione] = @IdAzione)
            INSERT INTO [PROCESSI_AZIONI] ([IdProcesso], [IdAzione]) VALUES (@IdProcesso, @IdAzione);
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

        IF @@ROWCOUNT = 0
        BEGIN
            RAISERROR('Azione %d inesistente', 16, 1, @IdAzione);
            RETURN;
        END
    END

    SELECT @IdAzione AS IdAzione;
END
GO

-- Upsert transizione di workflow: @IdWorkflow NULL = insert. Restituisce IdWorkflow.
-- Gli stati devono esistere in SPED_STATI (la videata li sceglie da tendina).
CREATE OR ALTER PROCEDURE dbo.AI_Azioni_SaveWorkflow
    @IdWorkflow   int         = NULL,
    @IdAzione     int,
    @Stato_Inizio varchar(50) = NULL,
    @Stato_Fine   varchar(50) = NULL,
    @GiorniSLA    int         = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM [SPED_AZIONI] WHERE [IdAzione] = @IdAzione)
    BEGIN
        RAISERROR('Azione %d inesistente', 16, 1, @IdAzione);
        RETURN;
    END
    IF @Stato_Inizio IS NOT NULL AND NOT EXISTS (SELECT 1 FROM [SPED_STATI] WHERE [STATO] = @Stato_Inizio)
    BEGIN
        RAISERROR('Stato di inizio ''%s'' inesistente in SPED_STATI', 16, 1, @Stato_Inizio);
        RETURN;
    END
    IF @Stato_Fine IS NOT NULL AND NOT EXISTS (SELECT 1 FROM [SPED_STATI] WHERE [STATO] = @Stato_Fine)
    BEGIN
        RAISERROR('Stato di fine ''%s'' inesistente in SPED_STATI', 16, 1, @Stato_Fine);
        RETURN;
    END

    IF @IdWorkflow IS NULL
    BEGIN
        INSERT INTO [SPED_WORKFLOW] ([IdAzione], [Stato_Inizio], [Stato_Fine], [GiorniSLA])
        VALUES (@IdAzione, @Stato_Inizio, @Stato_Fine, @GiorniSLA);
        SET @IdWorkflow = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE [SPED_WORKFLOW] SET
            [IdAzione] = @IdAzione,
            [Stato_Inizio] = @Stato_Inizio,
            [Stato_Fine] = @Stato_Fine,
            [GiorniSLA] = @GiorniSLA
        WHERE [IdWorkflow] = @IdWorkflow;

        IF @@ROWCOUNT = 0
        BEGIN
            RAISERROR('Transizione %d inesistente', 16, 1, @IdWorkflow);
            RETURN;
        END
    END

    SELECT @IdWorkflow AS IdWorkflow;
END
GO

-- Upsert collegamento processo-azione: @IdProcessoAzione NULL = insert.
-- Restituisce IdProcessoAzione. @tipoEventoCodice si sceglie da PALM_TIPOEVENTO.
CREATE OR ALTER PROCEDURE dbo.AI_Azioni_SaveProcessoAzione
    @IdProcessoAzione int         = NULL,
    @IdProcesso       int,
    @IdAzione         int,
    @tipoEventoCodice varchar(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM [PROCESSI] WHERE [IdProcesso] = @IdProcesso)
    BEGIN
        RAISERROR('Processo %d inesistente', 16, 1, @IdProcesso);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM [SPED_AZIONI] WHERE [IdAzione] = @IdAzione)
    BEGIN
        RAISERROR('Azione %d inesistente', 16, 1, @IdAzione);
        RETURN;
    END
    -- niente doppioni processo+azione (su un'altra riga rispetto a quella in modifica)
    IF EXISTS (SELECT 1 FROM [PROCESSI_AZIONI]
               WHERE [IdProcesso] = @IdProcesso AND [IdAzione] = @IdAzione
                 AND [IdProcessoAzione] <> ISNULL(@IdProcessoAzione, -1))
    BEGIN
        RAISERROR('Il processo e'' gia'' collegato a questa azione', 16, 1);
        RETURN;
    END

    IF @IdProcessoAzione IS NULL
    BEGIN
        INSERT INTO [PROCESSI_AZIONI] ([IdProcesso], [IdAzione], [tipoEventoCodice])
        VALUES (@IdProcesso, @IdAzione, @tipoEventoCodice);
        SET @IdProcessoAzione = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE [PROCESSI_AZIONI] SET
            [IdProcesso] = @IdProcesso,
            [IdAzione] = @IdAzione,
            [tipoEventoCodice] = @tipoEventoCodice
        WHERE [IdProcessoAzione] = @IdProcessoAzione;

        IF @@ROWCOUNT = 0
        BEGIN
            RAISERROR('Collegamento %d inesistente', 16, 1, @IdProcessoAzione);
            RETURN;
        END
    END

    SELECT @IdProcessoAzione AS IdProcessoAzione;
END
GO

GRANT EXECUTE ON dbo.AI_Azioni_SaveAzione TO claude;
GRANT EXECUTE ON dbo.AI_Azioni_SaveWorkflow TO claude;
GRANT EXECUTE ON dbo.AI_Azioni_SaveProcessoAzione TO claude;
GO
