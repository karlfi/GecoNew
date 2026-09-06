-- Correzione dei km rilevati dall'app (MEZZI_KM.km): quando il driver sbaglia
-- a digitare si corregge il valore dalla scheda del mezzo, e il valore di prima
-- resta scritto in MEZZI_KM_CORREZIONI con chi e quando.
USE DeliveryDB;
GO
IF OBJECT_ID('dbo.MEZZI_KM_CORREZIONI') IS NULL
BEGIN
    CREATE TABLE dbo.MEZZI_KM_CORREZIONI (
        IdCorrezione INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MEZZI_KM_CORREZIONI PRIMARY KEY,
        IdMezziKM    INT           NOT NULL CONSTRAINT FK_MEZZI_KM_CORREZIONI_KM FOREIGN KEY REFERENCES dbo.MEZZI_KM (IdMezziKM),
        KmPrima      FLOAT         NULL,
        KmDopo       FLOAT         NOT NULL,
        Data         DATETIME      NOT NULL CONSTRAINT DF_MEZZI_KM_CORREZIONI_Data DEFAULT (GETDATE()),
        Utente       NVARCHAR(50)  NULL,
        Note         NVARCHAR(500) NULL
    );
    CREATE INDEX IX_MEZZI_KM_CORREZIONI_KM ON dbo.MEZZI_KM_CORREZIONI (IdMezziKM, Data);
END
GO
CREATE OR ALTER PROCEDURE dbo.AI_MEZZI_KM_Correggi
    @IdMezziKM INT,
    @Km        FLOAT,
    @Utente    NVARCHAR(50)  = NULL,
    @Note      NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Km IS NULL OR @Km < 0 BEGIN RAISERROR('AI_MEZZI_KM_Correggi: km non validi.', 16, 1); RETURN; END
    DECLARE @Prima FLOAT, @Targa VARCHAR(20);
    SELECT @Prima = km, @Targa = targa FROM dbo.MEZZI_KM WHERE IdMezziKM = @IdMezziKM;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR('AI_MEZZI_KM_Correggi: rilevazione %d inesistente.', 16, 1, @IdMezziKM); RETURN; END
    IF @Prima = @Km RETURN;
    BEGIN TRAN;
    UPDATE dbo.MEZZI_KM SET km = @Km WHERE IdMezziKM = @IdMezziKM;
    INSERT INTO dbo.MEZZI_KM_CORREZIONI (IdMezziKM, KmPrima, KmDopo, Utente, Note) VALUES (@IdMezziKM, @Prima, @Km, @Utente, NULLIF(LTRIM(RTRIM(@Note)), ''));
    COMMIT;
END
GO
