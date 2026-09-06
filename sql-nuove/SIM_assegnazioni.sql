-- SIM: a chi e' assegnata. Una SIM sta su un palmare (tabella PALMARI), oppure
-- e' di una persona, oppure di "altro" (modem, sede: testo libero), oppure
-- genericamente di una filiale, oppure e' libera. Il tipo e' derivato nella
-- vista; i cambi di assegnazione finiscono in SIM_VARIAZIONI come le variazioni
-- di piano, con Campo/Prima/Dopo. Idempotente.
USE DeliveryDB;
GO
IF COL_LENGTH('dbo.SIM_VARIAZIONI', 'Campo') IS NULL
    ALTER TABLE dbo.SIM_VARIAZIONI ADD Campo VARCHAR(30) NULL, Prima NVARCHAR(200) NULL, Dopo NVARCHAR(200) NULL;
GO

CREATE OR ALTER VIEW dbo.V_Sim AS
SELECT s.IdSim, s.Numero, s.ICCID, s.Operatore, s.Prodotto, s.Stato, s.DataAttivazione, s.DataCessazione,
       s.PianoTariffario, s.IdFiliale, f.FILIALE AS Filiale, s.IdUtente, u.Nome AS Dipendente, u.Matricola,
       s.AssegnataA, s.Palmare, s.SerialePalmare, s.Note, s.DataCreazione, s.DataModifica, s.UtenteModifica,
       r.DataRilevazione AS UltimaRilevazione, r.CreditoResiduo, r.GbSoglia, r.GbConsumati, r.GbResidui, r.PercResidua, r.PeriodoSoglia,
       (SELECT COUNT(*) FROM dbo.SIM_VARIAZIONI v WHERE v.IdSim = s.IdSim) AS NumVariazioni,
       pm.IdPalmare, pm.Seriale AS PalmareSeriale, pm.NomeDevice AS PalmareNome, pm.Tag AS PalmareTag, pm.UltimoDriver AS PalmareDriver, pm.Filiale AS PalmareFiliale,
       CASE WHEN pm.IdPalmare IS NOT NULL THEN 'Palmare'
            WHEN s.IdUtente IS NOT NULL THEN 'Persona'
            WHEN s.AssegnataA IS NOT NULL THEN 'Altro'
            WHEN s.IdFiliale IS NOT NULL THEN 'Filiale'
            ELSE 'Libera' END AS TipoAssegnazione,
       CASE WHEN pm.IdPalmare IS NOT NULL THEN pm.NomeDevice + ISNULL(' (' + ISNULL(pm.Filiale, pm.Tag) + ')', '')
            WHEN s.IdUtente IS NOT NULL THEN u.Nome
            WHEN s.AssegnataA IS NOT NULL THEN s.AssegnataA
            WHEN s.IdFiliale IS NOT NULL THEN f.FILIALE
            ELSE NULL END AS Assegnazione
FROM dbo.SIM s
LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = s.IdFiliale
LEFT JOIN dbo.UTENTI u ON u.IdUtente = s.IdUtente
OUTER APPLY (SELECT TOP 1 * FROM dbo.SIM_RILEVAZIONI x WHERE x.IdSim = s.IdSim ORDER BY x.DataRilevazione DESC) r
OUTER APPLY (SELECT TOP 1 p.IdPalmare, p.Seriale, p.NomeDevice, p.Tag, pf.FILIALE AS Filiale, ut.Nome AS UltimoDriver
             FROM dbo.PALMARI p
             LEFT JOIN dbo.FILIALI pf ON pf.IDFILIALE = p.IdFiliale
             OUTER APPLY (SELECT TOP 1 a.idUtente FROM dbo.UTENTI_ATTIVITA a WHERE p.AndroidId IS NOT NULL AND a.Palmare = p.AndroidId ORDER BY a.data DESC) ua
             LEFT JOIN dbo.UTENTI ut ON ut.IdUtente = ua.idUtente
             WHERE p.IdSim = s.IdSim ORDER BY p.DataModifica DESC) pm;
GO

CREATE OR ALTER PROCEDURE dbo.AI_SIM_Save
    @IdSim           INT           = NULL OUTPUT,
    @Numero          VARCHAR(20),
    @ICCID           VARCHAR(32)   = NULL,
    @Operatore       VARCHAR(30)   = NULL,
    @Prodotto        VARCHAR(50)   = NULL,
    @Stato           VARCHAR(20)   = NULL,
    @DataAttivazione DATE          = NULL,
    @DataCessazione  DATE          = NULL,
    @PianoTariffario VARCHAR(100)  = NULL,
    @IdFiliale       INT           = NULL,
    @IdUtente        INT           = NULL,
    @AssegnataA      NVARCHAR(100) = NULL,
    @Palmare         NVARCHAR(50)  = NULL,
    @SerialePalmare  NVARCHAR(50)  = NULL,
    @Note            NVARCHAR(500) = NULL,
    @Utente          NVARCHAR(50)  = NULL,
    @NotaVariazione  NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Numero = LTRIM(RTRIM(ISNULL(@Numero, '')));
    IF @Numero = '' BEGIN RAISERROR('AI_SIM_Save: il numero e'' obbligatorio.', 16, 1); RETURN; END
    SET @Stato = ISNULL(NULLIF(LTRIM(RTRIM(@Stato)), ''), 'Attiva');
    SET @Operatore = ISNULL(NULLIF(LTRIM(RTRIM(@Operatore)), ''), 'WINDTRE');
    SET @ICCID = NULLIF(LTRIM(RTRIM(@ICCID)), '');
    SET @PianoTariffario = NULLIF(LTRIM(RTRIM(@PianoTariffario)), '');
    SET @AssegnataA = NULLIF(LTRIM(RTRIM(@AssegnataA)), '');
    SET @Palmare = NULLIF(LTRIM(RTRIM(@Palmare)), '');
    SET @SerialePalmare = NULLIF(LTRIM(RTRIM(@SerialePalmare)), '');
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), '');
    DECLARE @Oggi DATE = CAST(GETDATE() AS DATE);

    IF @IdSim IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.SIM WHERE Numero = @Numero)
        BEGIN RAISERROR('AI_SIM_Save: il numero %s esiste gia''.', 16, 1, @Numero); RETURN; END
        INSERT INTO dbo.SIM (Numero, ICCID, Operatore, Prodotto, Stato, DataAttivazione, DataCessazione, PianoTariffario,
                             IdFiliale, IdUtente, AssegnataA, Palmare, SerialePalmare, Note, DataModifica, UtenteModifica)
        VALUES (@Numero, @ICCID, @Operatore, @Prodotto, @Stato, @DataAttivazione, @DataCessazione, @PianoTariffario,
                @IdFiliale, @IdUtente, @AssegnataA, @Palmare, @SerialePalmare, @Note, GETDATE(), @Utente);
        SET @IdSim = SCOPE_IDENTITY();
        INSERT INTO dbo.SIM_VARIAZIONI (IdSim, Data, PianoTariffario, Stato, Origine, Note, Utente)
        VALUES (@IdSim, ISNULL(@DataAttivazione, @Oggi), @PianoTariffario, @Stato, 'INIZIALE', @NotaVariazione, @Utente);
        RETURN;
    END

    DECLARE @p TABLE (PianoTariffario VARCHAR(100), Stato VARCHAR(20), IdUtente INT, IdFiliale INT, AssegnataA NVARCHAR(100));
    INSERT INTO @p SELECT PianoTariffario, Stato, IdUtente, IdFiliale, AssegnataA FROM dbo.SIM WHERE IdSim = @IdSim;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR('AI_SIM_Save: SIM %d inesistente.', 16, 1, @IdSim); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.SIM WHERE Numero = @Numero AND IdSim <> @IdSim)
    BEGIN RAISERROR('AI_SIM_Save: il numero %s appartiene a un''altra SIM.', 16, 1, @Numero); RETURN; END

    UPDATE dbo.SIM
       SET Numero = @Numero, ICCID = @ICCID, Operatore = @Operatore, Prodotto = @Prodotto, Stato = @Stato,
           DataAttivazione = @DataAttivazione, DataCessazione = @DataCessazione, PianoTariffario = @PianoTariffario,
           IdFiliale = @IdFiliale, IdUtente = @IdUtente, AssegnataA = @AssegnataA, Palmare = @Palmare,
           SerialePalmare = @SerialePalmare, Note = @Note, DataModifica = GETDATE(), UtenteModifica = @Utente
     WHERE IdSim = @IdSim;

    -- piano o stato cambiati: la variazione "di profilo", come da import
    INSERT INTO dbo.SIM_VARIAZIONI (IdSim, Data, PianoTariffario, Stato, PianoPrecedente, StatoPrecedente, Origine, Note, Utente)
    SELECT @IdSim, @Oggi, @PianoTariffario, @Stato, p.PianoTariffario, p.Stato, 'MANUALE', @NotaVariazione, @Utente
    FROM @p p WHERE ISNULL(p.PianoTariffario, '') <> ISNULL(@PianoTariffario, '') OR ISNULL(p.Stato, '') <> ISNULL(@Stato, '');

    -- assegnazione cambiata: persona, filiale, testo (coi nomi, non gli id)
    INSERT INTO dbo.SIM_VARIAZIONI (IdSim, Data, Campo, Prima, Dopo, Origine, Note, Utente)
    SELECT @IdSim, @Oggi, x.Campo, x.Prima, x.Dopo, 'MANUALE', @NotaVariazione, @Utente
    FROM @p p CROSS APPLY (VALUES
        ('Persona', (SELECT Nome FROM dbo.UTENTI WHERE IdUtente = p.IdUtente), (SELECT Nome FROM dbo.UTENTI WHERE IdUtente = @IdUtente)),
        ('Filiale', (SELECT FILIALE FROM dbo.FILIALI WHERE IDFILIALE = p.IdFiliale), (SELECT FILIALE FROM dbo.FILIALI WHERE IDFILIALE = @IdFiliale)),
        ('Assegnata a', p.AssegnataA, @AssegnataA)) x (Campo, Prima, Dopo)
    WHERE ISNULL(x.Prima, '') <> ISNULL(x.Dopo, '')
      AND NOT (x.Campo = 'Persona' AND ISNULL(p.IdUtente, -1) = ISNULL(@IdUtente, -1))
      AND NOT (x.Campo = 'Filiale' AND ISNULL(p.IdFiliale, -1) = ISNULL(@IdFiliale, -1));
END
GO
