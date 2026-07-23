-- =============================================================
-- AI_UTENTI_Unilav_Applica: aggiorna la scheda UTENTI con i dati letti da una
-- Comunicazione Obbligatoria UNILAV (pagina "Carica UNILAV"). Aggiornamento
-- SELETTIVO: i parametri NULL lasciano il campo com'e' (a differenza di
-- AI_UTENTI_Save che sovrascrive tutto), cosi' la conferma a video applica
-- solo i campi spuntati. Restituisce il numero di righe aggiornate.
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
    @OreSettimanali decimal(4,1) = NULL,
    @CCNL varchar(100) = NULL,
    @SoggiornoTipo varchar(100) = NULL,
    @SoggiornoNumero varchar(100) = NULL,
    @SoggiornoMotivo varchar(100) = NULL,
    @SoggiornoScadenza date = NULL,
    @SoggiornoQuestura varchar(100) = NULL,
    @UnilavCodice varchar(100) = NULL,
    @UnilavData datetime = NULL
AS
BEGIN
    SET NOCOUNT ON;
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
        DataFineContratto = ISNULL(@DataFineContratto, DataFineContratto),
        OreSettimanali    = ISNULL(@OreSettimanali, OreSettimanali),
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
