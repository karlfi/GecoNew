-- =============================================================
-- Giri (pagina "Giri" di Speedy Web): modifica di un giro esistente con storico.
-- GEO_GIRI e GEO_GIRIVERTICI restano quelle del legacy (le usano GEO_AssegnaGIRI, Geo_GetVertici
-- e la vecchia videata); lo SHAPE viene ricostruito con GEO_AllineaGiri come nella creazione
-- (AI_GEO_CreaGiro). Ogni campo cambiato lascia una riga in GEO_GIRI_VARIAZIONI, il confine
-- precedente ci resta come WKT: da li' si ricostruisce com'era un giro in una certa data.
-- =============================================================
IF OBJECT_ID('dbo.GEO_GIRI_VARIAZIONI') IS NULL
CREATE TABLE dbo.GEO_GIRI_VARIAZIONI (
    IdVariazione int IDENTITY(1,1) NOT NULL CONSTRAINT PK_GEO_GIRI_VARIAZIONI PRIMARY KEY,
    IdGiro       int NOT NULL,
    DataOra      datetime NOT NULL CONSTRAINT DF_GEO_GIRI_VARIAZIONI_DataOra DEFAULT (GETDATE()),
    Utente       varchar(100) NULL,
    Campo        varchar(50) NOT NULL,     -- Giro, Colore, CAP, Belfiore, IdDriverDefault, Attivo, SHAPE
    Prima        nvarchar(max) NULL,
    Dopo         nvarchar(max) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_GEO_GIRI_VARIAZIONI_Giro')
    CREATE INDEX IX_GEO_GIRI_VARIAZIONI_Giro ON dbo.GEO_GIRI_VARIAZIONI (IdGiro, DataOra);
GO

-- Campi del giro, chiusura/riapertura (DataFine) e, se @Vertici e' valorizzato, il confine nuovo:
-- i vertici vanno in GEO_GIRIVERTICI (ordine = ordine del JSON) e GEO_AllineaGiri rifa' lo SHAPE.
CREATE OR ALTER PROCEDURE dbo.AI_GEO_GIRO_Save
    @IdGiro          int,
    @Giro            varchar(50),
    @Colore          varchar(50) = NULL,
    @CAP             varchar(5) = NULL,
    @Belfiore        varchar(5) = NULL,
    @IdDriverDefault int = NULL,
    @Attivo          bit = 1,
    @Vertici         nvarchar(max) = NULL,   -- JSON [{"lat":43.7,"lng":11.2}, ...]
    @Utente          varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF LEN(LTRIM(RTRIM(ISNULL(@Giro, '')))) <= 3
    BEGIN
        RAISERROR('Nome del giro non impostato o troppo corto', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.GEO_GIRI WHERE IdGiro = @IdGiro)
    BEGIN
        RAISERROR('Giro inesistente', 16, 1);
        RETURN;
    END
    IF @Vertici IS NOT NULL AND (SELECT COUNT(*) FROM OPENJSON(@Vertici)) < 3
    BEGIN
        RAISERROR('Servono almeno 3 punti per definire l''area del giro', 16, 1);
        RETURN;
    END
    SET @Giro = LTRIM(RTRIM(@Giro));
    SET @CAP = NULLIF(LTRIM(RTRIM(@CAP)), '');
    SET @Belfiore = NULLIF(LTRIM(RTRIM(@Belfiore)), '');
    SET @Colore = NULLIF(LTRIM(RTRIM(@Colore)), '');

    DECLARE @g TABLE (Giro varchar(50), Colore varchar(50), CAP varchar(5), Belfiore varchar(5),
                      IdDriverDefault int, DataFine smalldatetime, Wkt nvarchar(max));
    INSERT INTO @g
    SELECT Giro, Colore, CAP, Belfiore, IdDriverDefault, DataFine, SHAPE.STAsText()
    FROM dbo.GEO_GIRI WHERE IdGiro = @IdGiro;

    BEGIN TRAN;

    INSERT INTO dbo.GEO_GIRI_VARIAZIONI (IdGiro, Utente, Campo, Prima, Dopo)
    SELECT @IdGiro, @Utente, x.Campo, x.Prima, x.Dopo
    FROM @g g
    CROSS APPLY (VALUES
        ('Giro',            g.Giro,                                   @Giro),
        ('Colore',          g.Colore,                                 ISNULL(@Colore, g.Colore)),
        ('CAP',             g.CAP,                                    @CAP),
        ('Belfiore',        g.Belfiore,                               @Belfiore),
        ('IdDriverDefault', CAST(g.IdDriverDefault AS varchar(20)),   CAST(@IdDriverDefault AS varchar(20))),
        ('Attivo',          CASE WHEN g.DataFine IS NULL THEN '1' ELSE '0' END, CASE WHEN @Attivo = 1 THEN '1' ELSE '0' END)
    ) x (Campo, Prima, Dopo)
    WHERE ISNULL(x.Prima, '') <> ISNULL(x.Dopo, '');

    UPDATE dbo.GEO_GIRI SET
        Giro = @Giro,
        Colore = ISNULL(@Colore, Colore),
        CAP = @CAP,
        Belfiore = @Belfiore,
        IdDriverDefault = @IdDriverDefault,
        DataFine = CASE WHEN @Attivo = 1 THEN NULL ELSE ISNULL(DataFine, GETDATE()) END,
        DataModifica = GETDATE()
    WHERE IdGiro = @IdGiro;

    IF @Vertici IS NOT NULL
    BEGIN
        DELETE FROM dbo.GEO_GIRIVERTICI WHERE IdGiro = @IdGiro;
        INSERT INTO dbo.GEO_GIRIVERTICI (IdGiro, Latitude, Longitude, Sequenza, DataModifica)
        SELECT @IdGiro,
               CAST(JSON_VALUE(value, '$.lat') AS float),
               CAST(JSON_VALUE(value, '$.lng') AS float),
               CAST([key] AS int),
               GETDATE()
        FROM OPENJSON(@Vertici)
        ORDER BY CAST([key] AS int);
        EXEC dbo.GEO_AllineaGiri @IdGiro;
        INSERT INTO dbo.GEO_GIRI_VARIAZIONI (IdGiro, Utente, Campo, Prima, Dopo)
        SELECT @IdGiro, @Utente, 'SHAPE', g.Wkt, gg.SHAPE.STAsText()
        FROM @g g CROSS JOIN dbo.GEO_GIRI gg
        WHERE gg.IdGiro = @IdGiro;
    END

    COMMIT;
    SELECT IdGiro, Giro, Colore, CAP, Belfiore, IdDriverDefault, DataFine, DataModifica
    FROM dbo.GEO_GIRI WHERE IdGiro = @IdGiro;
END
GO

-- Confine di un giro esistente rifatto come unione dei comuni scelti (GEO_COMUNE.SHAPE), come
-- AI_GEO_CreaGiroDaComuni. I vertici vengono tolti: il confine non viene piu' da loro.
CREATE OR ALTER PROCEDURE dbo.AI_GEO_GIRO_Comuni
    @IdGiro   int,
    @IdComuni nvarchar(max),                 -- JSON [2857, 2838]
    @Utente   varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.GEO_GIRI WHERE IdGiro = @IdGiro)
    BEGIN
        RAISERROR('Giro inesistente', 16, 1);
        RETURN;
    END
    DECLARE @ids TABLE (IdComune int);
    INSERT INTO @ids (IdComune) SELECT CAST(value AS int) FROM OPENJSON(@IdComuni);
    IF NOT EXISTS (SELECT 1 FROM @ids)
    BEGIN
        RAISERROR('Nessun comune selezionato', 16, 1);
        RETURN;
    END
    DECLARE @union geometry = (
        SELECT geometry::UnionAggregate(SHAPE)
        FROM dbo.GEO_COMUNE
        WHERE IdComune IN (SELECT IdComune FROM @ids) AND SHAPE IS NOT NULL
    );
    IF @union IS NULL
    BEGIN
        RAISERROR('I comuni selezionati non hanno geometria', 16, 1);
        RETURN;
    END
    IF @union.STIsValid() = 0 SET @union = @union.MakeValid();

    BEGIN TRAN;
    INSERT INTO dbo.GEO_GIRI_VARIAZIONI (IdGiro, Utente, Campo, Prima, Dopo)
    SELECT @IdGiro, @Utente, 'SHAPE', SHAPE.STAsText(), @union.STAsText()
    FROM dbo.GEO_GIRI WHERE IdGiro = @IdGiro;
    DELETE FROM dbo.GEO_GIRIVERTICI WHERE IdGiro = @IdGiro;
    UPDATE dbo.GEO_GIRI SET SHAPE = @union, DataModifica = GETDATE() WHERE IdGiro = @IdGiro;
    COMMIT;
    SELECT @IdGiro AS IdGiro;
END
GO
