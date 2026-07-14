-- =============================================================
-- Associazioni N:N dell'utente (collezioni figlie della pagina Utenti):
-- Gruppi, Famiglie di prodotti, Processi, Filiali abilitate.
-- Add: inserisce se non già presente. Del: cancella per chiave dell'associazione.
-- =============================================================

-- ---- Gruppi (UTENTI_GRUPPI) ----
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_GRUPPI_Add @IdUtente int, @IdGruppo int
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM UTENTI_GRUPPI WHERE IdUtente = @IdUtente AND IdGruppo = @IdGruppo)
        INSERT INTO UTENTI_GRUPPI (IdUtente, IdGruppo) VALUES (@IdUtente, @IdGruppo);
END
GO
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_GRUPPI_Del @IdUtenteGruppo int
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM UTENTI_GRUPPI WHERE IdUtenteGruppo = @IdUtenteGruppo;
END
GO

-- ---- Famiglie di prodotti (UTENTI_PROFILI) ----
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_PROFILI_Add @IdUtente int, @CodFamiglia varchar(5)
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM UTENTI_PROFILI WHERE IdUtente = @IdUtente AND CodFamiglia = @CodFamiglia)
        INSERT INTO UTENTI_PROFILI (IdUtente, CodFamiglia) VALUES (@IdUtente, @CodFamiglia);
END
GO
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_PROFILI_Del @IdUtentiProfili int
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM UTENTI_PROFILI WHERE IdUtentiProfili = @IdUtentiProfili;
END
GO

-- ---- Processi (UTENTI_PROCESSI), con eventuale comune Belfiore ----
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_PROCESSI_Add @IdUtente int, @IdProcesso int, @Belfiore varchar(5) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM UTENTI_PROCESSI
                   WHERE IdUtente = @IdUtente AND IdProcesso = @IdProcesso
                     AND ISNULL(Belfiore,'') = ISNULL(@Belfiore,''))
        INSERT INTO UTENTI_PROCESSI (IdUtente, IdProcesso, Belfiore)
        VALUES (@IdUtente, @IdProcesso, @Belfiore);
END
GO
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_PROCESSI_Del @IdUtentiProcessi int
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM UTENTI_PROCESSI WHERE IdUtentiProcessi = @IdUtentiProcessi;
END
GO

-- ---- Filiali abilitate (UTENTI_FILIALI) ----
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_FILIALI_Add @IdUtente int, @IdFiliale int
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM UTENTI_FILIALI WHERE IdUtente = @IdUtente AND IdFiliale = @IdFiliale)
        INSERT INTO UTENTI_FILIALI (IdUtente, IdFiliale) VALUES (@IdUtente, @IdFiliale);
END
GO
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_FILIALI_Del @IdUtenteFiliale int
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM UTENTI_FILIALI WHERE IdUtenteFiliale = @IdUtenteFiliale;
END
GO
