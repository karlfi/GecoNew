-- =============================================================
-- SP della pagina "Attivita Filiali" (AttivitaFilialiView) — AI_AttivitaFiliali_Save.
-- Upsert su FILIALI_ATTIVITA: una riga per filiale+giorno con i contatori
-- ParamI01..I18 (mappa presa da V_ElencoFilialiAttivita03):
--   Arrivi:        I01 Nexive, I02 Hermes, I03 InPost, I04 iMile, I05 Folletto, I16 Gofo
--   Distribuzione: I06 Nexive, I07 Hermes, I08 InPost, I09 iMile, I10 Folletto, I17 Gofo
--   Inventario:    I11 Nexive, I12 Hermes, I13 InPost, I14 iMile, I15 Folletto, I18 Gofo
-- L'IdFiliale arriva dal token (lato API), mai dal client.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_AttivitaFiliali_Save
    @IdAttivita bigint   = NULL,   -- NULL = nuovo giorno
    @IdFiliale  int,
    @Data       date,
    @ParamI01 smallint = 0, @ParamI02 smallint = 0, @ParamI03 smallint = 0,
    @ParamI04 smallint = 0, @ParamI05 smallint = 0, @ParamI06 smallint = 0,
    @ParamI07 smallint = 0, @ParamI08 smallint = 0, @ParamI09 smallint = 0,
    @ParamI10 smallint = 0, @ParamI11 smallint = 0, @ParamI12 smallint = 0,
    @ParamI13 smallint = 0, @ParamI14 smallint = 0, @ParamI15 smallint = 0,
    @ParamI16 smallint = 0, @ParamI17 smallint = 0, @ParamI18 smallint = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM [FILIALI] WHERE [IDFILIALE] = @IdFiliale)
    BEGIN
        RAISERROR('Filiale %d inesistente', 16, 1, @IdFiliale);
        RETURN;
    END
    IF @Data IS NULL
    BEGIN
        RAISERROR('La data e'' obbligatoria', 16, 1);
        RETURN;
    END
    -- una sola riga per filiale+giorno
    IF EXISTS (SELECT 1 FROM [FILIALI_ATTIVITA]
               WHERE [idFiliale] = @IdFiliale AND [data] = @Data
                 AND [idAttivita] <> ISNULL(@IdAttivita, -1))
    BEGIN
        RAISERROR('Esiste gia'' una riga di attivita'' per questa filiale in questa data', 16, 1);
        RETURN;
    END

    IF @IdAttivita IS NULL
    BEGIN
        INSERT INTO [FILIALI_ATTIVITA] (
            [idFiliale], [data], [dataModifica],
            [ParamI01], [ParamI02], [ParamI03], [ParamI04], [ParamI05],
            [ParamI06], [ParamI07], [ParamI08], [ParamI09], [ParamI10],
            [ParamI11], [ParamI12], [ParamI13], [ParamI14], [ParamI15],
            [ParamI16], [ParamI17], [ParamI18], [ParamI19], [ParamI20])
        VALUES (
            @IdFiliale, @Data, GETDATE(),
            @ParamI01, @ParamI02, @ParamI03, @ParamI04, @ParamI05,
            @ParamI06, @ParamI07, @ParamI08, @ParamI09, @ParamI10,
            @ParamI11, @ParamI12, @ParamI13, @ParamI14, @ParamI15,
            @ParamI16, @ParamI17, @ParamI18, 0, 0);
        SET @IdAttivita = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE [FILIALI_ATTIVITA] SET
            [data] = @Data,
            [dataModifica] = GETDATE(),
            [ParamI01] = @ParamI01, [ParamI02] = @ParamI02, [ParamI03] = @ParamI03,
            [ParamI04] = @ParamI04, [ParamI05] = @ParamI05, [ParamI06] = @ParamI06,
            [ParamI07] = @ParamI07, [ParamI08] = @ParamI08, [ParamI09] = @ParamI09,
            [ParamI10] = @ParamI10, [ParamI11] = @ParamI11, [ParamI12] = @ParamI12,
            [ParamI13] = @ParamI13, [ParamI14] = @ParamI14, [ParamI15] = @ParamI15,
            [ParamI16] = @ParamI16, [ParamI17] = @ParamI17, [ParamI18] = @ParamI18
        WHERE [idAttivita] = @IdAttivita AND [idFiliale] = @IdFiliale;

        IF @@ROWCOUNT = 0
        BEGIN
            RAISERROR('Riga di attivita'' %I64d inesistente per la filiale %d', 16, 1, @IdAttivita, @IdFiliale);
            RETURN;
        END
    END

    SELECT @IdAttivita AS IdAttivita;
END
GO

GRANT EXECUTE ON dbo.AI_AttivitaFiliali_Save TO claude;
GO
