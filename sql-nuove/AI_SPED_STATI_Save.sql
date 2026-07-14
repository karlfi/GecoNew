-- Upsert generato dallo schema di [SPED_STATI] (pagina "Stati"). Scritture solo via SP (prefisso AI_).
-- Particolarita': la PK e' STATO (varchar, codice digitato dall'utente per i nuovi record),
-- mentre IdStato e' un identity SEPARATO (assegnato dal DB, non si tocca).
-- L'upsert si decide per ESISTENZA di STATO (non sul valore dell'identity).
CREATE OR ALTER PROCEDURE dbo.AI_SPED_STATI_Save
    @STATO varchar(50) = NULL,
    @Descrizione varchar(50) = NULL,
    @CodGruppoStati varchar(5) = NULL,
    @DescrizioneCliente varchar(50) = NULL,
    @VisibileCliente int = NULL,
    @CodEsitoAder varchar(2) = NULL,
    @CodConsip varchar(50) = NULL,
    @ADER4 varchar(50) = NULL,
    @ADER4_Motivo varchar(1) = NULL,
    @Bloccante int = NULL,
    @CodSNEM varchar(50) = NULL,
    @CodADEX varchar(4) = NULL,
    @IdStato int = NULL          -- identity: accettato dal frontend ma mai scritto
AS
BEGIN
    SET NOCOUNT ON;
    IF @STATO IS NULL OR LTRIM(RTRIM(@STATO)) = ''
    BEGIN
        RAISERROR('Il codice STATO e'' obbligatorio.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM [SPED_STATI] WHERE [STATO] = @STATO)
    BEGIN
        INSERT INTO [SPED_STATI] ([STATO], [Descrizione], [CodGruppoStati], [DescrizioneCliente], [VisibileCliente], [CodEsitoAder], [CodConsip], [ADER4], [ADER4_Motivo], [Bloccante], [CodSNEM], [CodADEX])
        VALUES (@STATO, @Descrizione, @CodGruppoStati, @DescrizioneCliente, @VisibileCliente, @CodEsitoAder, @CodConsip, @ADER4, @ADER4_Motivo, @Bloccante, @CodSNEM, @CodADEX);
    END
    ELSE
    BEGIN
        UPDATE [SPED_STATI] SET
            [Descrizione] = @Descrizione,
            [CodGruppoStati] = @CodGruppoStati,
            [DescrizioneCliente] = @DescrizioneCliente,
            [VisibileCliente] = @VisibileCliente,
            [CodEsitoAder] = @CodEsitoAder,
            [CodConsip] = @CodConsip,
            [ADER4] = @ADER4,
            [ADER4_Motivo] = @ADER4_Motivo,
            [Bloccante] = @Bloccante,
            [CodSNEM] = @CodSNEM,
            [CodADEX] = @CodADEX
        WHERE [STATO] = @STATO;
    END

    SELECT (SELECT [IdStato] FROM [SPED_STATI] WHERE [STATO] = @STATO) AS id;
END
