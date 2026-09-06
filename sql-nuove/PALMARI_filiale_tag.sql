-- Palmari: filiale dal tag Knox. Quando il tag non combacia con una filiale sola
-- per nome, decide la lista PALMARI_TAG_FILIALE in LISTA_VALORI (Valore = tag,
-- Codice = IDFILIALE), modificabile dalla pagina Lista Valori. La stored
-- AI_PALMARI_Filiale scrive la filiale e ne tiene traccia nelle variazioni.
USE DeliveryDB;
GO
CREATE OR ALTER PROCEDURE dbo.AI_PALMARI_Filiale
    @IdPalmare INT,
    @IdFiliale INT           = NULL,
    @Utente    NVARCHAR(50)  = NULL,
    @Origine   VARCHAR(30)   = 'MANUALE'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Prima INT;
    SELECT @Prima = IdFiliale FROM dbo.PALMARI WHERE IdPalmare = @IdPalmare;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR('AI_PALMARI_Filiale: palmare %d inesistente.', 16, 1, @IdPalmare); RETURN; END
    IF @IdFiliale IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.FILIALI WHERE IDFILIALE = @IdFiliale)
    BEGIN RAISERROR('AI_PALMARI_Filiale: filiale %d inesistente.', 16, 1, @IdFiliale); RETURN; END
    IF ISNULL(@Prima, -1) = ISNULL(@IdFiliale, -1) RETURN;
    UPDATE dbo.PALMARI SET IdFiliale = @IdFiliale, DataModifica = GETDATE(), UtenteModifica = @Utente WHERE IdPalmare = @IdPalmare;
    INSERT INTO dbo.PALMARI_VARIAZIONI (IdPalmare, Data, Campo, Prima, Dopo, Origine, Utente)
    VALUES (@IdPalmare, CAST(GETDATE() AS DATE), 'IdFiliale', CAST(@Prima AS NVARCHAR(20)), CAST(@IdFiliale AS NVARCHAR(20)), @Origine, @Utente);
END
GO

-- i tag che il nome da solo non scioglie: SDA (senza citta') e' la SDA di Firenze,
-- i due tag HUB vanno sull'hub Speedy (l'altra filiale HUB e' POPUP)
IF NOT EXISTS (SELECT 1 FROM dbo.LISTA_VALORI WHERE Lista = 'PALMARI_TAG_FILIALE')
BEGIN
    EXEC dbo.AI_LISTA_VALORI_Save @Lista = 'PALMARI_TAG_FILIALE', @Valore = 'SDA',                @Codice = '1268', @Ordine = 1;   -- TOSC - SDA Firenze
    EXEC dbo.AI_LISTA_VALORI_Save @Lista = 'PALMARI_TAG_FILIALE', @Valore = 'SDA - Responsabile', @Codice = '1268', @Ordine = 2;   -- TOSC - SDA Firenze
    EXEC dbo.AI_LISTA_VALORI_Save @Lista = 'PALMARI_TAG_FILIALE', @Valore = 'FI HUB',             @Codice = '36',   @Ordine = 3;   -- TOSC - HUB SPEEDY
    EXEC dbo.AI_LISTA_VALORI_Save @Lista = 'PALMARI_TAG_FILIALE', @Valore = 'CALENZANO HUB',      @Codice = '36',   @Ordine = 4;   -- TOSC - HUB SPEEDY
END
GO
