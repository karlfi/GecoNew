-- =============================================================
-- AI_UTENTI_ATTIVITA_PulisciVuote — toglie le giornate di presenza che non
-- dovrebbero esserci: per default quelle FUORI dal rapporto di lavoro (prima
-- della data di assunzione, o dopo la data di fine se c'e'), oppure tutte
-- quelle fino a una data che si passa (@FinoAl), per svuotare una scheda doppia
-- prima di metterla da parte.
--
-- Servono quando una scheda nasce con la data di inizio sbagliata, o quando lo
-- stesso dipendente ha due schede: il gestionale genera una riga al giorno per
-- ognuna, e sistemando l'anagrafica le righe di troppo restano li' a sporcare i
-- conteggi (e' successo con le due schede GIORDANO e con CANGIOLU, a SDA
-- Cagliari).
--
-- Cancella solo le righe VUOTE: niente ore, niente km, niente contatori, niente
-- note ne' login del palmare, e presenza non lavorata. Se in una di quelle
-- giornate c'e' del lavoro vero, la riga resta: vuol dire che la data di
-- assunzione o l'attribuzione della giornata vanno guardate a mano.
--
-- Con @Conferma = 0 (default) non cancella niente: dice solo quante righe
-- toglierebbe e quante lascerebbe perche' hanno dentro qualcosa.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_ATTIVITA_PulisciVuote
    @IdUtente int,
    @FinoAl   date = NULL,   -- NULL = fuori dal periodo di lavoro della scheda
    @Conferma bit  = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- il periodo "buono": da DataInizio a DataFine (se c'e'). Con @FinoAl si
    -- ignora la scheda e si considera fuori tutto cio' che precede quella data.
    DECLARE @DataInizio date, @DataFine date;
    IF @FinoAl IS NOT NULL
        SET @DataInizio = @FinoAl;
    ELSE
        SELECT @DataInizio = CONVERT(date, DataInizio), @DataFine = CONVERT(date, DataFine)
        FROM dbo.UTENTI WHERE IdUtente = @IdUtente;

    IF @DataInizio IS NULL
    BEGIN
        RAISERROR('Utente %d inesistente o senza data di assunzione: passare @FinoAl', 16, 1, @IdUtente);
        RETURN;
    END

    -- righe fuori dal periodo, divise fra vuote (si possono togliere) e con
    -- qualcosa dentro (si lasciano)
    SELECT
        @IdUtente AS IdUtente,
        @DataInizio AS DalGiorno, @DataFine AS AlGiorno,
        SUM(CASE WHEN v.Vuota = 1 THEN 1 ELSE 0 END) AS DaTogliere,
        SUM(CASE WHEN v.Vuota = 0 THEN 1 ELSE 0 END) AS ConDatiDaGuardare,
        MIN(a.data) AS Dal,
        MAX(a.data) AS Al
    FROM dbo.UTENTI_ATTIVITA a
    CROSS APPLY (SELECT CASE WHEN
             ISNULL(a.ore, 0) = 0 AND ISNULL(a.KmPercorsi, 0) = 0
         AND ISNULL(a.Note, '') = '' AND ISNULL(a.Palmare, '') = ''
         AND a.Login IS NULL AND a.Logout IS NULL
         AND ISNULL(a.Punteggio, 0) = 0
         AND ISNULL(a.codPresenza, '') IN ('', 'NLV')
         AND ISNULL(a.ParamI01,0) + ISNULL(a.ParamI02,0) + ISNULL(a.ParamI03,0) + ISNULL(a.ParamI04,0)
           + ISNULL(a.ParamI05,0) + ISNULL(a.ParamI06,0) + ISNULL(a.ParamI07,0) + ISNULL(a.ParamI08,0)
           + ISNULL(a.ParamI09,0) + ISNULL(a.ParamI10,0) + ISNULL(a.ParamI11,0) + ISNULL(a.ParamI12,0)
           + ISNULL(a.ParamI13,0) + ISNULL(a.ParamI14,0) + ISNULL(a.ParamI15,0) + ISNULL(a.ParamI16,0)
           + ISNULL(a.ParamI17,0) + ISNULL(a.ParamI18,0) + ISNULL(a.ParamI19,0) + ISNULL(a.ParamI20,0)
           + ISNULL(a.ParamB02,0) + ISNULL(a.ParamB03,0) + ISNULL(a.ParamB04,0)
           + ISNULL(a.ParamB09,0) + ISNULL(a.ParamB10,0) + ISNULL(a.ParamB11,0) = 0
        THEN 1 ELSE 0 END AS Vuota) v
    WHERE a.idUtente = @IdUtente AND (a.data < @DataInizio OR (@DataFine IS NOT NULL AND a.data > @DataFine));

    IF @Conferma = 1
        DELETE a
        FROM dbo.UTENTI_ATTIVITA a
        WHERE a.idUtente = @IdUtente AND (a.data < @DataInizio OR (@DataFine IS NOT NULL AND a.data > @DataFine))
          AND ISNULL(a.ore, 0) = 0 AND ISNULL(a.KmPercorsi, 0) = 0
          AND ISNULL(a.Note, '') = '' AND ISNULL(a.Palmare, '') = ''
          AND a.Login IS NULL AND a.Logout IS NULL
          AND ISNULL(a.Punteggio, 0) = 0
          AND ISNULL(a.codPresenza, '') IN ('', 'NLV')
          AND ISNULL(a.ParamI01,0) + ISNULL(a.ParamI02,0) + ISNULL(a.ParamI03,0) + ISNULL(a.ParamI04,0)
            + ISNULL(a.ParamI05,0) + ISNULL(a.ParamI06,0) + ISNULL(a.ParamI07,0) + ISNULL(a.ParamI08,0)
            + ISNULL(a.ParamI09,0) + ISNULL(a.ParamI10,0) + ISNULL(a.ParamI11,0) + ISNULL(a.ParamI12,0)
            + ISNULL(a.ParamI13,0) + ISNULL(a.ParamI14,0) + ISNULL(a.ParamI15,0) + ISNULL(a.ParamI16,0)
            + ISNULL(a.ParamI17,0) + ISNULL(a.ParamI18,0) + ISNULL(a.ParamI19,0) + ISNULL(a.ParamI20,0)
            + ISNULL(a.ParamB02,0) + ISNULL(a.ParamB03,0) + ISNULL(a.ParamB04,0)
            + ISNULL(a.ParamB09,0) + ISNULL(a.ParamB10,0) + ISNULL(a.ParamB11,0) = 0;

    SELECT @@ROWCOUNT AS Cancellate;
END
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.AI_UTENTI_ATTIVITA_PulisciVuote TO claude');
GO
