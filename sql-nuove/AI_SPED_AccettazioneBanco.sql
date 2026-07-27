-- Accettazione da banco (pagina /accettazione-banco). Replica il flusso della
-- videata legacy AccettazioneDaBanco[Famiglia]:
--   1. un LOTTO per accettazione: 'LOT-aammgg-N', oppure 'UFFICIO_aammgg-N' se
--      e' scelto un ufficio mittente (come AccettazioneDaBancoMittenti);
--   2. una spedizione per atto tramite la stored legacy SPED_INSERIMENTO (che
--      calcola le coperture e crea PALM_ATTIVITA); il barcode arriva scansionato
--      dalle etichette prestampate, l'eventuale barcode dell'AR va in
--      RiferimentoEsterno1; il mittente e' l'ufficio scelto o l'anagrafica cliente;
--   3. una DISTINTA di accettazione (IdAzione=1, barcode '5001'+IdDistinta a 8
--      cifre) su cui si stampa la ricevuta DELIVERY_Accettazione.fr3.
-- Ogni riga produce un esito ('OK' / motivo di scarto); i barcode gia' presenti
-- non vengono reinseriti. Se nessuna riga passa, il lotto vuoto viene rimosso.
CREATE OR ALTER PROCEDURE dbo.AI_SPED_AccettazioneBanco
    @IdCliente int,
    @CodFamiglia varchar(2),
    @IdProdotto int,
    @IdUtente int = NULL,
    @IdFiliale int = NULL,
    @IdMittente int = NULL,
    @Righe nvarchar(max)   -- JSON: [{barcode, barcodeAr, destinatario, indirizzo, civico, localita, cap, prov, nota}]
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@IdCliente, 0) = 0 OR ISNULL(@IdProdotto, 0) = 0
    BEGIN SELECT 'Cliente e prodotto sono obbligatori' AS Errore; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.PRODOTTI WHERE IdProdotto = @IdProdotto AND CodFamiglia = @CodFamiglia)
    BEGIN SELECT 'Il prodotto non appartiene alla famiglia indicata' AS Errore; RETURN; END

    -- mittente delle spedizioni: l'ufficio MITTENTI scelto, altrimenti l'anagrafica del cliente
    DECLARE @IdAzienda int, @NomeLotto varchar(50) = NULL,
            @MitRagSoc varchar(50), @MitInd varchar(50), @MitLoc varchar(50),
            @MitCap varchar(5), @MitProv varchar(2);
    SELECT @IdAzienda = ISNULL(IdAzienda, 2), @MitRagSoc = LEFT(RagioneSociale, 50),
           @MitInd = LEFT(Indirizzo, 50), @MitLoc = LEFT(Comune, 50),
           @MitCap = LEFT(CAP, 5), @MitProv = LEFT(Prov, 2)
    FROM dbo.CLIENTI WHERE IdCliente = @IdCliente;
    IF @@ROWCOUNT = 0 BEGIN SELECT 'Cliente inesistente' AS Errore; RETURN; END

    IF @IdMittente IS NOT NULL
    BEGIN
        SELECT @MitRagSoc = LEFT(UFFICIOSPEDITORE, 50), @MitInd = LEFT(INDIRIZZO, 50),
               @MitLoc = LEFT(COMUNE, 50), @MitCap = LEFT(CAP, 5), @MitProv = LEFT(PROV, 2),
               @NomeLotto = LEFT(UFFICIOSPEDITORE, 30)
        FROM dbo.MITTENTI WHERE IdMittente = @IdMittente AND idCliente = @IdCliente;
        IF @@ROWCOUNT = 0 BEGIN SELECT 'Mittente non del cliente indicato' AS Errore; RETURN; END
    END

    -- il servizio palmare del prodotto (es. 3 = raccomandata AR) prevale su quello
    -- di famiglia che SPED_INSERIMENTO mette su PALM_ATTIVITA, come nella videata legacy
    DECLARE @PalmProdotto int = (SELECT IdPalmServizio FROM dbo.PRODOTTI WHERE IdProdotto = @IdProdotto);

    DECLARE @r TABLE (Riga int, Barcode varchar(50), BarcodeAr varchar(50),
                      Destinatario varchar(200), Indirizzo varchar(200), Civico varchar(200),
                      Localita varchar(200), Cap varchar(5), Prov varchar(2), Nota varchar(200));
    INSERT INTO @r
    SELECT CAST([key] AS int),
           NULLIF(LTRIM(RTRIM(JSON_VALUE(value, '$.barcode'))), ''),
           NULLIF(LTRIM(RTRIM(JSON_VALUE(value, '$.barcodeAr'))), ''),
           NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(value, '$.destinatario'), 200))), ''),
           NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(value, '$.indirizzo'), 200))), ''),
           NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(value, '$.civico'), 200))), ''),
           NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(value, '$.localita'), 200))), ''),
           NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(value, '$.cap'), 5))), ''),
           NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(value, '$.prov'), 2))), ''),
           NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(value, '$.nota'), 200))), '')
    FROM OPENJSON(@Righe);
    DELETE FROM @r WHERE Barcode IS NULL AND Destinatario IS NULL;   -- righe rimaste vuote a video

    DECLARE @n int = (SELECT COUNT(*) FROM @r);
    IF @n = 0 BEGIN SELECT 'Nessun atto da inserire' AS Errore; RETURN; END

    -- nome lotto come il legacy: LOT-260701-7 / PROCURA DELLA REPUBBLICA DI TE_260724-2
    DECLARE @oggi date = CONVERT(date, GETDATE());
    DECLARE @adesso datetime = GETDATE();
    DECLARE @suffisso varchar(20) = CONVERT(varchar(6), GETDATE(), 12) + '-' + CONVERT(varchar(9), @n);
    DECLARE @Lotto varchar(50) =
        CASE WHEN @NomeLotto IS NULL THEN 'LOT-' + @suffisso
             ELSE LEFT(@NomeLotto, 50 - LEN(@suffisso) - 1) + '_' + @suffisso END;

    INSERT INTO dbo.SPED_LOTTI (Lotto, IdCliente, DataCarico, DataAccettazione,
                                IdFilialeAccettazione, NumeroAtti, CodFamiglia, IdProdotto,
                                IdUtente, DataInserimento)
    VALUES (@Lotto, @IdCliente, @oggi, @oggi, @IdFiliale, 0, @CodFamiglia, @IdProdotto,
            @IdUtente, @adesso);
    DECLARE @IdLotto int = SCOPE_IDENTITY();

    DECLARE @esiti TABLE (Riga int, Barcode varchar(50), IdSpedizione int, EsitoRiga varchar(100));
    DECLARE @riga int, @bc varchar(50), @bcAr varchar(50), @dest varchar(200), @ind varchar(200),
            @civ varchar(200), @loc varchar(200), @cap varchar(5), @prov varchar(2),
            @nota varchar(200), @id int, @esistente int;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT Riga, Barcode, BarcodeAr, Destinatario, Indirizzo, Civico, Localita, Cap, Prov, Nota
        FROM @r ORDER BY Riga;
    OPEN cur;
    FETCH NEXT FROM cur INTO @riga, @bc, @bcAr, @dest, @ind, @civ, @loc, @cap, @prov, @nota;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @id = NULL;
        IF @bc IS NULL
            INSERT INTO @esiti VALUES (@riga, NULL, NULL, 'Barcode mancante');
        ELSE IF @dest IS NULL OR @ind IS NULL OR @loc IS NULL OR @cap IS NULL OR @prov IS NULL
            INSERT INTO @esiti VALUES (@riga, @bc, NULL, 'Dati del destinatario incompleti');
        ELSE
        BEGIN
            SELECT @esistente = IdSpedizione FROM dbo.SPED_ATTIVITA
            WHERE Barcode = @bc AND DataFine IS NULL;
            IF @esistente IS NOT NULL
                INSERT INTO @esiti VALUES (@riga, @bc, @esistente, 'Barcode gia'' presente');
            ELSE
            BEGIN
                EXEC dbo.SPED_INSERIMENTO
                    @Barcode = @bc,
                    @IdCliente = @IdCliente,
                    @IdAzienda = @IdAzienda,
                    @IdProdotto = @IdProdotto,
                    @IdUtente = @IdUtente,
                    @IdFiliale = @IdFiliale,
                    @DataCarico = @oggi,        -- il legacy accetta con la sola data
                    @DestinazioneRagioneSociale = @dest,
                    @DestinazioneIndirizzo = @ind,
                    @DestinazioneNumeroCivico = @civ,
                    @DestinazioneLocalita = @loc,
                    @DestinazioneCap = @cap,
                    @DestinazioneProvinciaCodice = @prov,
                    @DestinazioneNazioneCodice = 'IT',
                    @RiferimentoEsterno1 = @bcAr,
                    @NOTA1 = @nota,
                    @MittenteRagioneSociale = @MitRagSoc,
                    @MittenteIndirizzo = @MitInd,
                    @MittenteLocalita = @MitLoc,
                    @MittenteCap = @MitCap,
                    @MittenteProvinciaCodice = @MitProv,
                    @DataInserimento = @adesso,
                    @IdSpedizione = @id OUTPUT;
                IF @id IS NULL
                    INSERT INTO @esiti VALUES (@riga, @bc, NULL, 'Inserimento non riuscito');
                ELSE
                BEGIN
                    -- come il legacy: l'atto accettato parte in stato '0' (Accettata)
                    UPDATE dbo.SPED_ATTIVITA
                    SET IdLotto = @IdLotto, IdMittente = ISNULL(@IdMittente, IdMittente),
                        Stato = '0', DataStato = @adesso
                    WHERE IdSpedizione = @id;
                    IF @PalmProdotto IS NOT NULL
                    BEGIN
                        DECLARE @IdAtt int = (SELECT MAX(IdAttivita) FROM dbo.PALM_ATTIVITA WHERE Barcode = @bc);
                        UPDATE dbo.PALM_ATTIVITA SET IdPalmServizio = @PalmProdotto
                        WHERE IdAttivita = @IdAtt AND IdPalmServizio <> @PalmProdotto;
                        -- le stampe palmare (CPCL) dipendono dal servizio: vanno rigenerate
                        IF @@ROWCOUNT > 0 EXEC dbo.PALM_AggiornaReport @IdAttivita = @IdAtt;
                    END
                    INSERT INTO @esiti VALUES (@riga, @bc, @id, 'OK');
                END
            END
            SET @esistente = NULL;
        END
        FETCH NEXT FROM cur INTO @riga, @bc, @bcAr, @dest, @ind, @civ, @loc, @cap, @prov, @nota;
    END
    CLOSE cur; DEALLOCATE cur;

    DECLARE @inseriti int = (SELECT COUNT(*) FROM @esiti WHERE EsitoRiga = 'OK');
    DECLARE @IdDistinta int = NULL, @BarcodeDistinta varchar(50) = NULL;

    IF @inseriti = 0
        DELETE FROM dbo.SPED_LOTTI WHERE IdLotto = @IdLotto;   -- niente lotto vuoto
    ELSE
    BEGIN
        -- il suffisso del nome lotto conta gli atti effettivi (come il legacy)
        IF @inseriti <> @n
        BEGIN
            SET @suffisso = CONVERT(varchar(6), GETDATE(), 12) + '-' + CONVERT(varchar(9), @inseriti);
            SET @Lotto = CASE WHEN @NomeLotto IS NULL THEN 'LOT-' + @suffisso
                              ELSE LEFT(@NomeLotto, 50 - LEN(@suffisso) - 1) + '_' + @suffisso END;
        END
        UPDATE dbo.SPED_LOTTI SET NumeroAtti = @inseriti, Lotto = @Lotto WHERE IdLotto = @IdLotto;

        -- distinta di accettazione: barcode '500' + IdAzione(1) + id a 8 cifre;
        -- WebReport = template della ricevuta, come fa il legacy
        INSERT INTO dbo.SPED_DISTINTE (Data, IdAzione, NumeroAtti, IdFiliale, IdUtente, DataInserimento, WebReport)
        VALUES (@oggi, 1, @inseriti, @IdFiliale, @IdUtente, @adesso, 'DELIVERY_Accettazione.fr3');
        SET @IdDistinta = SCOPE_IDENTITY();
        SET @BarcodeDistinta = '5001' + RIGHT('00000000' + CONVERT(varchar(8), @IdDistinta), 8);
        UPDATE dbo.SPED_DISTINTE SET Barcode = @BarcodeDistinta WHERE IdDistinta = @IdDistinta;

        UPDATE dbo.SPED_ATTIVITA
        SET IdDistintaAcc = @IdDistinta, IdDistintaLast = @IdDistinta
        WHERE IdSpedizione IN (SELECT IdSpedizione FROM @esiti WHERE EsitoRiga = 'OK');

        -- tabella ponte spedizioni<->distinta: e' quella letta dalla ricevuta
        -- DELIVERY_Accettazione.fr3 (senza queste righe il report esce vuoto)
        INSERT INTO dbo.SPED_SPED2DISTINTE (IdSpedizione, IdDistinta, Progressivo, Stato_Fine, Data)
        SELECT IdSpedizione, @IdDistinta, ROW_NUMBER() OVER (ORDER BY Riga), '0', @oggi
        FROM @esiti WHERE EsitoRiga = 'OK';
    END

    -- esiti per riga + riepilogo (il chiamante li riconosce da EsitoRiga / IdLotto)
    SELECT Riga, Barcode, IdSpedizione, EsitoRiga FROM @esiti ORDER BY Riga;
    SELECT CASE WHEN @inseriti = 0 THEN NULL ELSE @IdLotto END AS IdLotto,
           CASE WHEN @inseriti = 0 THEN NULL ELSE @Lotto END AS Lotto,
           @IdDistinta AS IdDistinta, @BarcodeDistinta AS BarcodeDistinta,
           @inseriti AS Inseriti, @n - @inseriti AS Scartati;
END
GO
GRANT EXECUTE ON dbo.AI_SPED_AccettazioneBanco TO claude;
