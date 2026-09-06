-- Scheda mezzo (la "Mezzi24" del legacy): salvataggio della testata e dei dati
-- Info via stored. Le altre linguette (km, foto, costi, sinistri, note) leggono
-- le tabelle esistenti; note e sinistri si scrivono con le AI_MEZZI_*_Save gia' in uso.
-- Idempotente.
USE DeliveryDB;
GO
CREATE OR ALTER PROCEDURE dbo.AI_MEZZI_Save
    @idMezzo               INT           = NULL OUTPUT,
    @targa                 VARCHAR(20),
    @codTipoMezzo          CHAR(3)       = NULL,
    @modello               VARCHAR(100)  = NULL,
    @marca                 VARCHAR(100)  = NULL,
    @telaio                VARCHAR(50)   = NULL,
    @dataImmatricolazione  DATE          = NULL,
    @dataAcquisto          DATE          = NULL,
    @dataDismissione       DATE          = NULL,
    @DataRevisione         DATE          = NULL,
    @idFiliale             INT           = NULL,
    @IdUtente              INT           = NULL,
    @Telepass              VARCHAR(50)   = NULL,
    @TesseraCarb           VARCHAR(100)  = NULL,
    @Proprieta             INT           = NULL,     -- 0 di proprieta', 1 noleggio, 2 leasing, NULL altro
    @ImportoRata           FLOAT         = NULL,
    @Noleggiatore          VARCHAR(100)  = NULL,
    @DataContrattoNoleggio DATE          = NULL,
    @Contratto             VARCHAR(100)  = NULL,
    @DataScadenzaNoleggio  DATE          = NULL,
    @ImportoRiscatto       FLOAT         = NULL,
    @Rottamato             INT           = NULL,
    @Scorta                INT           = NULL,
    @DataBollo             DATE          = NULL,
    @IdAzienda             INT           = NULL,
    @DataScadenzaZTL       DATE          = NULL,
    @ComuneZTL             VARCHAR(100)  = NULL,
    @DataFermo             DATE          = NULL,
    @DKV_idveicolo         VARCHAR(50)   = NULL,
    @DKV_trasponder        VARCHAR(50)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @targa = UPPER(REPLACE(LTRIM(RTRIM(ISNULL(@targa, ''))), ' ', ''));
    IF @targa = '' BEGIN RAISERROR('AI_MEZZI_Save: la targa e'' obbligatoria.', 16, 1); RETURN; END
    IF @codTipoMezzo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.MEZZI_TIPI WHERE codTipoMezzo = @codTipoMezzo)
    BEGIN RAISERROR('AI_MEZZI_Save: tipo mezzo %s inesistente.', 16, 1, @codTipoMezzo); RETURN; END

    IF @idMezzo IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.MEZZI WHERE targa = @targa)
        BEGIN RAISERROR('AI_MEZZI_Save: la targa %s esiste gia''.', 16, 1, @targa); RETURN; END
        INSERT INTO dbo.MEZZI (codTipoMezzo, modello, targa, marca, telaio, dataImmatricolazione, dataAcquisto, dataDismissione, DataRevisione,
                               idFiliale, IdUtente, Telepass, TesseraCarb, [Proprietà], ImportoRata, Noleggiatore, DataContrattoNoleggio, Contratto,
                               DataScadenzaNoleggio, ImportoRiscatto, Rottamato, Scorta, DataBollo, IdAzienda, DataScadenzaZTL, ComuneZTL, DataFermo,
                               DKV_idveicolo, DKV_trasponder)
        VALUES (@codTipoMezzo, @modello, @targa, @marca, @telaio, @dataImmatricolazione, @dataAcquisto, @dataDismissione, @DataRevisione,
                @idFiliale, @IdUtente, @Telepass, @TesseraCarb, @Proprieta, @ImportoRata, @Noleggiatore, @DataContrattoNoleggio, @Contratto,
                @DataScadenzaNoleggio, @ImportoRiscatto, @Rottamato, @Scorta, @DataBollo, @IdAzienda, @DataScadenzaZTL, @ComuneZTL, @DataFermo,
                @DKV_idveicolo, @DKV_trasponder);
        SET @idMezzo = SCOPE_IDENTITY();
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.MEZZI WHERE idMezzo = @idMezzo)
    BEGIN RAISERROR('AI_MEZZI_Save: mezzo %d inesistente.', 16, 1, @idMezzo); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.MEZZI WHERE targa = @targa AND idMezzo <> @idMezzo)
    BEGIN RAISERROR('AI_MEZZI_Save: la targa %s appartiene a un altro mezzo.', 16, 1, @targa); RETURN; END

    UPDATE dbo.MEZZI
       SET codTipoMezzo = @codTipoMezzo, modello = @modello, targa = @targa, marca = @marca, telaio = @telaio,
           dataImmatricolazione = @dataImmatricolazione, dataAcquisto = @dataAcquisto, dataDismissione = @dataDismissione, DataRevisione = @DataRevisione,
           idFiliale = @idFiliale, IdUtente = @IdUtente, Telepass = @Telepass, TesseraCarb = @TesseraCarb, [Proprietà] = @Proprieta,
           ImportoRata = @ImportoRata, Noleggiatore = @Noleggiatore, DataContrattoNoleggio = @DataContrattoNoleggio, Contratto = @Contratto,
           DataScadenzaNoleggio = @DataScadenzaNoleggio, ImportoRiscatto = @ImportoRiscatto, Rottamato = @Rottamato, Scorta = @Scorta,
           DataBollo = @DataBollo, IdAzienda = @IdAzienda, DataScadenzaZTL = @DataScadenzaZTL, ComuneZTL = @ComuneZTL, DataFermo = @DataFermo,
           DKV_idveicolo = @DKV_idveicolo, DKV_trasponder = @DKV_trasponder
     WHERE idMezzo = @idMezzo;
END
GO

-- voce diretta sotto Gestione Mezzi (1163); dalle griglie ci si arriva con le azioni "Dettaglio Mezzo"
IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/mezzi')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1163, @Text = 'Scheda Mezzi',
        @Descrizione = 'Scheda del mezzo: anagrafica, km con foto e posizione, costi, sinistri, manutenzioni',
        @Link = '/mezzi', @Sorting = 1;
GO
