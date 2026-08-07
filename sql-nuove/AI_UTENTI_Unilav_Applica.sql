-- =============================================================
-- AI_UTENTI_Unilav_Applica: aggiorna la scheda UTENTI con i dati letti da una
-- Comunicazione Obbligatoria UNILAV (pagina "Carica UNILAV"), qualunque sia il
-- modello: Inizio rapporto, Proroga, Trasformazione, Cessazione.
-- Aggiornamento SELETTIVO: i parametri NULL lasciano il campo com'e' (a
-- differenza di AI_UTENTI_Save che sovrascrive tutto), cosi' la conferma a
-- video applica solo i campi spuntati.
--
-- I flag @Azzera* servono ai casi in cui il valore nuovo e' "nessuna data":
-- una trasformazione a tempo indeterminato toglie la scadenza del contratto,
-- e ISNULL(NULL, campo) da solo non potrebbe mai svuotarlo.
--
-- Restituisce il numero di righe aggiornate.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_Unilav_Applica
    @IdUtente int,
    @Nome varchar(50) = NULL,
    @DataNascita date = NULL,
    @DataInizio smalldatetime = NULL,
    @IndirizzoRes varchar(250) = NULL,
    @CapRes varchar(50) = NULL,
    @ComuneRes varchar(250) = NULL,
    @ProvRes varchar(50) = NULL,
    @Livello varchar(50) = NULL,
    @Mansione varchar(50) = NULL,
    @Cittadinanza varchar(100) = NULL,
    @LuogoNascita varchar(100) = NULL,
    @TitoloStudio varchar(100) = NULL,
    @TipoContratto varchar(100) = NULL,
    @DataFineContratto date = NULL,
    @DataFine smalldatetime = NULL,
    @OreSettimanali decimal(4,1) = NULL,
    @Partime float = NULL,
    @IdFiliale int = NULL,
    @CCNL varchar(100) = NULL,
    @SoggiornoTipo varchar(100) = NULL,
    @SoggiornoNumero varchar(100) = NULL,
    @SoggiornoMotivo varchar(100) = NULL,
    @SoggiornoScadenza date = NULL,
    @SoggiornoQuestura varchar(100) = NULL,
    @UnilavCodice varchar(100) = NULL,
    @UnilavData datetime = NULL,
    @AzzeraDataFine bit = 0,
    @AzzeraDataFineContratto bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- la filiale deve esistere: un id sbagliato lascerebbe l'utente orfano
    IF @IdFiliale IS NOT NULL AND NOT EXISTS (SELECT 1 FROM FILIALI WHERE IDFILIALE = @IdFiliale)
    BEGIN
        RAISERROR('Filiale %d inesistente', 16, 1, @IdFiliale);
        RETURN;
    END

    UPDATE UTENTI SET
        Nome              = ISNULL(@Nome, Nome),
        DataNascita       = ISNULL(@DataNascita, DataNascita),
        DataInizio        = ISNULL(@DataInizio, DataInizio),
        IndirizzoRes      = ISNULL(@IndirizzoRes, IndirizzoRes),
        CapRes            = ISNULL(@CapRes, CapRes),
        ComuneRes         = ISNULL(@ComuneRes, ComuneRes),
        ProvRes           = ISNULL(@ProvRes, ProvRes),
        Livello           = ISNULL(@Livello, Livello),
        Mansione          = ISNULL(@Mansione, Mansione),
        Cittadinanza      = ISNULL(@Cittadinanza, Cittadinanza),
        LuogoNascita      = ISNULL(@LuogoNascita, LuogoNascita),
        TitoloStudio      = ISNULL(@TitoloStudio, TitoloStudio),
        TipoContratto     = ISNULL(@TipoContratto, TipoContratto),
        DataFineContratto = CASE WHEN @AzzeraDataFineContratto = 1 THEN NULL
                                ELSE ISNULL(@DataFineContratto, DataFineContratto) END,
        DataFine          = CASE WHEN @AzzeraDataFine = 1 THEN NULL
                                ELSE ISNULL(@DataFine, DataFine) END,
        OreSettimanali    = ISNULL(@OreSettimanali, OreSettimanali),
        Partime           = ISNULL(@Partime, Partime),
        IdFiliale         = ISNULL(@IdFiliale, IdFiliale),
        CCNL              = ISNULL(@CCNL, CCNL),
        SoggiornoTipo     = ISNULL(@SoggiornoTipo, SoggiornoTipo),
        SoggiornoNumero   = ISNULL(@SoggiornoNumero, SoggiornoNumero),
        SoggiornoMotivo   = ISNULL(@SoggiornoMotivo, SoggiornoMotivo),
        SoggiornoScadenza = ISNULL(@SoggiornoScadenza, SoggiornoScadenza),
        SoggiornoQuestura = ISNULL(@SoggiornoQuestura, SoggiornoQuestura),
        UnilavCodice      = ISNULL(@UnilavCodice, UnilavCodice),
        UnilavData        = ISNULL(@UnilavData, UnilavData)
    WHERE IdUtente = @IdUtente;
    SELECT @@ROWCOUNT AS righe;
END
GO
GRANT EXECUTE ON dbo.AI_UTENTI_Unilav_Applica TO claude;
GO
