-- =============================================================
-- SP della pagina "Attivita Dipendenti" (AttivitaDipendentiView) —
-- AI_AttivitaDipendenti_Save. SOLO UPDATE su UTENTI_ATTIVITA: niente
-- inserimenti di utenti o date (le righe le crea il gestionale/palmare).
--
-- Regole:
--  - non si modificano attivita' piu' vecchie di 15 giorni (esito negativo);
--  - Login/Logout, mezzo (idMezzo/targa), KmPercorsi, Palmare e Partime NON
--    si toccano: arrivano dal palmare/gestionale;
--  - mappa contatori (da V_UtentiAttivita2024):
--      I07 Parcel Poste | I09 Rac140 Cons | I18 Rac140 Avvisati
--      I10-I12 MOD1 Cons/Ass/Sco | I13-I15 MOD2 Cons/Ass/Sco | I16 AG
--      I05 Hermes | I06 InPost | I08 iMile | I17 Folletto | I20 Gofo | I04 Altri
--      I03 Parcel Speedy | I19 SDA Bancario
--      B03 BK M1 Reso | B04 BK M2 Reso | B10 BK Lista 143 | B11 BK Inviato UP
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_AttivitaDipendenti_Save
    @IdAttivita  bigint,
    @IdFiliale   int,               -- filiale del driver in quel giorno
    @CodPresenza char(3)     = NULL,
    @Note        varchar(50) = NULL,
    @ParamI03 smallint = 0, @ParamI04 smallint = 0, @ParamI05 smallint = 0,
    @ParamI06 smallint = 0, @ParamI07 smallint = 0, @ParamI08 smallint = 0,
    @ParamI09 smallint = 0, @ParamI10 smallint = 0, @ParamI11 smallint = 0,
    @ParamI12 smallint = 0, @ParamI13 smallint = 0, @ParamI14 smallint = 0,
    @ParamI15 smallint = 0, @ParamI16 smallint = 0, @ParamI17 smallint = 0,
    @ParamI18 smallint = 0, @ParamI19 smallint = 0, @ParamI20 smallint = 0,
    @ParamB03 smallint = 0, @ParamB04 smallint = 0,
    @ParamB10 smallint = 0, @ParamB11 smallint = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @dataRiga date;
    SELECT @dataRiga = [data] FROM [UTENTI_ATTIVITA] WHERE [idAttivita] = @IdAttivita;

    IF @dataRiga IS NULL
    BEGIN
        RAISERROR('Attivita'' %I64d inesistente', 16, 1, @IdAttivita);
        RETURN;
    END
    -- regola di chiusura: oltre 15 giorni non si modifica piu' nulla
    IF DATEDIFF(DAY, @dataRiga, GETDATE()) > 15
    BEGIN
        RAISERROR('Modifica non consentita: attivita'' piu'' vecchia di 15 giorni', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM [FILIALI] WHERE [IDFILIALE] = @IdFiliale)
    BEGIN
        RAISERROR('Filiale %d inesistente', 16, 1, @IdFiliale);
        RETURN;
    END
    IF @CodPresenza IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM [UTENTI_TIPOPRESENZE] WHERE [codPresenza] = @CodPresenza)
    BEGIN
        RAISERROR('Codice presenza ''%s'' inesistente', 16, 1, @CodPresenza);
        RETURN;
    END

    UPDATE [UTENTI_ATTIVITA] SET
        [idFiliale]    = @IdFiliale,
        [codPresenza]  = @CodPresenza,
        [Note]         = @Note,
        [dataModifica] = GETDATE(),
        [ParamI03] = @ParamI03, [ParamI04] = @ParamI04, [ParamI05] = @ParamI05,
        [ParamI06] = @ParamI06, [ParamI07] = @ParamI07, [ParamI08] = @ParamI08,
        [ParamI09] = @ParamI09, [ParamI10] = @ParamI10, [ParamI11] = @ParamI11,
        [ParamI12] = @ParamI12, [ParamI13] = @ParamI13, [ParamI14] = @ParamI14,
        [ParamI15] = @ParamI15, [ParamI16] = @ParamI16, [ParamI17] = @ParamI17,
        [ParamI18] = @ParamI18, [ParamI19] = @ParamI19, [ParamI20] = @ParamI20,
        [ParamB03] = @ParamB03, [ParamB04] = @ParamB04,
        [ParamB10] = @ParamB10, [ParamB11] = @ParamB11
    WHERE [idAttivita] = @IdAttivita;

    SELECT @IdAttivita AS IdAttivita;
END
GO

-- il grant serve solo dove esiste l'utente "claude" (vecchio server): su BLUE
-- l'applicazione entra con twebaccount, che e' dbo e non ne ha bisogno
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.AI_AttivitaDipendenti_Save TO claude');
GO
