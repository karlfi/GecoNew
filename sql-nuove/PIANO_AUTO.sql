-- Pianificazione automatica (richiesta di Carlo, 25/09/2026): tutte le spedizioni geolocalizzate di una filiale in un
-- giorno divise fra i driver scelti con HERE Tour Planning v3, ottimizzando e bilanciando il carico.
-- Zone "ibride": il giro di ogni consegna e' il suo territorio, ogni driver ha come territori preferiti (non esclusivi)
-- i giri che fa di solito, quindi resta nella sua zona ma prende anche consegne fuori se serve a bilanciare.
-- Ogni calcolo e' una versione (PIANO_AUTO); la conferma scrive la sequenza sulle spedizioni. I giri non si toccano.
--   PIANO_AUTO         una riga per calcolo: filiale, giorno, stato, parametri, totali, costo HERE (transazioni)
--   PIANO_AUTO_DRIVER  i driver del calcolo con i loro vincoli (turno, partenza/ritorno, max pezzi, zone) e i risultati
--   PIANO_AUTO_SPED    per spedizione: driver, fermata, sequenza, arrivo stimato; senza driver = non assegnata (Motivo)
-- Stati: RICHIESTA (in coda) -> IN_CORSO (HERE calcola) -> CALCOLATO | ERRORE; poi CONFERMATO | SCARTATO;
-- un piano confermato diventa SUPERATO quando se ne conferma un altro per la stessa filiale e lo stesso giorno.
-- Il calcolo lo fa lo script scheduler-script/here/here_tour.py (workflow GEO-02_HERE_TOUR, creato qui sotto),
-- messo in coda dalla pagina con WF_PARAMETRI {"IdPianoAuto": n}.

IF OBJECT_ID('dbo.PIANO_AUTO') IS NULL
BEGIN
    CREATE TABLE dbo.PIANO_AUTO (
        IdPianoAuto    int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PIANO_AUTO PRIMARY KEY,
        IdFiliale      int NOT NULL,
        Data           date NOT NULL,
        Stato          varchar(20) NOT NULL,
        Parametri      nvarchar(max) NULL,
        NSpedizioni    int NULL,
        NFermate       int NULL,
        NAssegnate     int NULL,
        NNonAssegnate  int NULL,
        DistanzaM      int NULL,
        TempoS         int NULL,
        Transazioni    int NULL,
        IdEsecuzione   int NULL,
        IdHere         varchar(100) NULL,
        Errore         nvarchar(1000) NULL,
        DataRichiesta  datetime NOT NULL CONSTRAINT DF_PIANO_AUTO_DataRichiesta DEFAULT GETDATE(),
        DataRisposta   datetime NULL,
        DataConferma   datetime NULL,
        Utente         varchar(100) NULL,
        UtenteConferma varchar(100) NULL
    );
    CREATE INDEX IX_PIANO_AUTO_FilialeData ON dbo.PIANO_AUTO (IdFiliale, Data);
END
GO

IF OBJECT_ID('dbo.PIANO_AUTO_DRIVER') IS NULL
BEGIN
    CREATE TABLE dbo.PIANO_AUTO_DRIVER (
        IdPianoAutoDriver int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PIANO_AUTO_DRIVER PRIMARY KEY,
        IdPianoAuto   int NOT NULL CONSTRAINT FK_PIANO_AUTO_DRIVER_PIANO REFERENCES dbo.PIANO_AUTO (IdPianoAuto),
        IdDriver      int NOT NULL,
        Inizio        time(0) NOT NULL,
        Fine          time(0) NOT NULL,
        PartenzaCasa  bit NOT NULL CONSTRAINT DF_PIANO_AUTO_DRIVER_PC DEFAULT 0,
        RitornoCasa   bit NOT NULL CONSTRAINT DF_PIANO_AUTO_DRIVER_RC DEFAULT 0,
        MaxPezzi      int NULL,
        Giri          nvarchar(max) NULL,      -- JSON [IdGiro, ...]: zone preferite
        Colore        varchar(10) NULL,
        NPezzi        int NULL,
        NFermate      int NULL,
        DistanzaM     int NULL,
        TempoS        int NULL,
        OraInizio     datetime NULL,
        OraFine       datetime NULL,
        CONSTRAINT UQ_PIANO_AUTO_DRIVER UNIQUE (IdPianoAuto, IdDriver)
    );
END
GO

IF OBJECT_ID('dbo.PIANO_AUTO_SPED') IS NULL
BEGIN
    CREATE TABLE dbo.PIANO_AUTO_SPED (
        IdPianoAuto   int NOT NULL CONSTRAINT FK_PIANO_AUTO_SPED_PIANO REFERENCES dbo.PIANO_AUTO (IdPianoAuto),
        IdSpedizione  int NOT NULL,
        IdDriver      int NULL,
        Fermata       int NULL,        -- numero della fermata nel giro del driver (piu' pezzi = stessa fermata)
        Sequenza      int NULL,        -- ordine di consegna del pezzo nel giro del driver (1..n)
        Arrivo        datetime NULL,
        Motivo        nvarchar(300) NULL,
        CONSTRAINT PK_PIANO_AUTO_SPED PRIMARY KEY (IdPianoAuto, IdSpedizione)
    );
    CREATE INDEX IX_PIANO_AUTO_SPED_Sped ON dbo.PIANO_AUTO_SPED (IdSpedizione);
END
GO

-- Nuova richiesta di calcolo.
-- @Parametri: JSON della pagina (sosta, tolleranza, zone, ...), passato tale e quale allo script.
-- @Driver: JSON [{"idDriver":1,"inizio":"08:30","fine":"15:30","partenzaCasa":false,"ritornoCasa":false,
--                 "maxPezzi":null,"giri":[12,13],"colore":"#e6194b"}, ...]
CREATE OR ALTER PROCEDURE dbo.AI_PIANO_AUTO_Richiesta
    @IdFiliale int,
    @Data      date,
    @Parametri nvarchar(max) = NULL,
    @Driver    nvarchar(max),
    @Utente    varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- un calcolo rimasto appeso oltre 40 minuti non blocca il successivo
    UPDATE dbo.PIANO_AUTO SET Stato = 'ERRORE', Errore = 'Nessuna risposta dallo schedulatore entro 40 minuti', DataRisposta = GETDATE()
     WHERE IdFiliale = @IdFiliale AND Data = @Data AND Stato IN ('RICHIESTA', 'IN_CORSO') AND DataRichiesta < DATEADD(minute, -40, GETDATE());
    IF EXISTS (SELECT 1 FROM dbo.PIANO_AUTO WHERE IdFiliale = @IdFiliale AND Data = @Data AND Stato IN ('RICHIESTA', 'IN_CORSO'))
    BEGIN
        RAISERROR('C''e'' gia'' un calcolo in corso per questa filiale e questo giorno', 16, 1);
        RETURN;
    END

    DECLARE @d TABLE (IdDriver int PRIMARY KEY, Inizio time(0), Fine time(0), PartenzaCasa bit, RitornoCasa bit,
                      MaxPezzi int NULL, Giri nvarchar(max) NULL, Colore varchar(10) NULL);
    INSERT INTO @d
    SELECT CAST(JSON_VALUE(value, '$.idDriver') AS int),
           TRY_CAST(JSON_VALUE(value, '$.inizio') AS time(0)), TRY_CAST(JSON_VALUE(value, '$.fine') AS time(0)),
           CASE WHEN JSON_VALUE(value, '$.partenzaCasa') = 'true' THEN 1 ELSE 0 END,
           CASE WHEN JSON_VALUE(value, '$.ritornoCasa') = 'true' THEN 1 ELSE 0 END,
           TRY_CAST(JSON_VALUE(value, '$.maxPezzi') AS int), JSON_QUERY(value, '$.giri'), LEFT(JSON_VALUE(value, '$.colore'), 10)
    FROM OPENJSON(@Driver);
    IF NOT EXISTS (SELECT 1 FROM @d)
    BEGIN
        RAISERROR('Scegli almeno un driver', 16, 1);
        RETURN;
    END
    IF EXISTS (SELECT 1 FROM @d WHERE Inizio IS NULL OR Fine IS NULL OR Fine <= Inizio)
    BEGIN
        RAISERROR('Ogni driver deve avere inizio e fine turno, con la fine dopo l''inizio', 16, 1);
        RETURN;
    END
    IF EXISTS (SELECT 1 FROM @d d LEFT JOIN dbo.UTENTI_GEO g ON g.IdUtente = d.IdDriver
               WHERE (d.PartenzaCasa = 1 OR d.RitornoCasa = 1) AND (g.Lat IS NULL OR g.Lng IS NULL))
    BEGIN
        RAISERROR('Un driver parte o torna da casa ma la sua casa non e'' geolocalizzata: impostala o scegli la filiale', 16, 1);
        RETURN;
    END

    DECLARE @dal datetime = @Data, @al datetime = DATEADD(day, 1, @Data);
    DECLARE @n int, @senza int;
    SELECT @n = COUNT(*), @senza = SUM(CASE WHEN DestinazioneLatitude IS NULL OR DestinazioneLongitude IS NULL THEN 1 ELSE 0 END)
    FROM dbo.SPED_ATTIVITA WHERE IdFiliale = @IdFiliale AND DataCarico >= @dal AND DataCarico < @al;
    IF ISNULL(@n, 0) - ISNULL(@senza, 0) <= 0
    BEGIN
        RAISERROR('Nessuna spedizione geolocalizzata per questa filiale in questo giorno', 16, 1);
        RETURN;
    END

    BEGIN TRAN;
        INSERT INTO dbo.PIANO_AUTO (IdFiliale, Data, Stato, Parametri, NSpedizioni, Utente)
        VALUES (@IdFiliale, @Data, 'RICHIESTA', @Parametri, @n - @senza, @Utente);
        DECLARE @id int = SCOPE_IDENTITY();
        INSERT INTO dbo.PIANO_AUTO_DRIVER (IdPianoAuto, IdDriver, Inizio, Fine, PartenzaCasa, RitornoCasa, MaxPezzi, Giri, Colore)
        SELECT @id, IdDriver, Inizio, Fine, PartenzaCasa, RitornoCasa, NULLIF(MaxPezzi, 0), Giri, Colore FROM @d;
    COMMIT;
    SELECT @id AS IdPianoAuto, @n - @senza AS NSpedizioni, ISNULL(@senza, 0) AS NSenzaCoordinate;
END
GO

CREATE OR ALTER PROCEDURE dbo.AI_PIANO_AUTO_InCorso
    @IdPianoAuto int,
    @IdHere      varchar(100) = NULL,
    @IdEsecuzione int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PIANO_AUTO SET Stato = 'IN_CORSO', IdHere = ISNULL(@IdHere, IdHere), IdEsecuzione = ISNULL(@IdEsecuzione, IdEsecuzione)
     WHERE IdPianoAuto = @IdPianoAuto AND Stato IN ('RICHIESTA', 'IN_CORSO');
END
GO

-- l'esecuzione dello schedulatore che fa il calcolo (per l'avanzamento nella pagina)
CREATE OR ALTER PROCEDURE dbo.AI_PIANO_AUTO_Esecuzione
    @IdPianoAuto  int,
    @IdEsecuzione int
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PIANO_AUTO SET IdEsecuzione = @IdEsecuzione WHERE IdPianoAuto = @IdPianoAuto;
END
GO

-- La risposta di HERE (o l'errore).
-- @Driver: JSON [{"idDriver":1,"pezzi":20,"fermate":17,"distanza":45000,"tempo":16000,"inizio":"...","fine":"..."}]
-- @Spedizioni: JSON [{"id":123,"driver":1,"fermata":3,"seq":4,"arrivo":"2026-09-25T09:12:00"} |
--                   {"id":124,"driver":null,"motivo":"capacita' dei driver esaurita"}]
CREATE OR ALTER PROCEDURE dbo.AI_PIANO_AUTO_Risposta
    @IdPianoAuto int,
    @Driver      nvarchar(max) = NULL,
    @Spedizioni  nvarchar(max) = NULL,
    @NFermate    int = NULL,
    @DistanzaM   int = NULL,
    @TempoS      int = NULL,
    @Transazioni int = NULL,
    @Errore      nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Errore IS NOT NULL
    BEGIN
        UPDATE dbo.PIANO_AUTO SET Stato = 'ERRORE', Errore = @Errore, Transazioni = @Transazioni, DataRisposta = GETDATE()
         WHERE IdPianoAuto = @IdPianoAuto;
        RETURN;
    END
    DECLARE @s TABLE (IdSpedizione int PRIMARY KEY, IdDriver int NULL, Fermata int NULL, Sequenza int NULL, Arrivo datetime NULL, Motivo nvarchar(300) NULL);
    INSERT INTO @s
    SELECT CAST(JSON_VALUE(value, '$.id') AS int), TRY_CAST(JSON_VALUE(value, '$.driver') AS int),
           TRY_CAST(JSON_VALUE(value, '$.fermata') AS int), TRY_CAST(JSON_VALUE(value, '$.seq') AS int),
           TRY_CAST(JSON_VALUE(value, '$.arrivo') AS datetime), LEFT(JSON_VALUE(value, '$.motivo'), 300)
    FROM OPENJSON(@Spedizioni);
    IF NOT EXISTS (SELECT 1 FROM @s)
    BEGIN
        RAISERROR('Risposta senza spedizioni', 16, 1);
        RETURN;
    END
    BEGIN TRAN;
        DELETE FROM dbo.PIANO_AUTO_SPED WHERE IdPianoAuto = @IdPianoAuto;
        INSERT INTO dbo.PIANO_AUTO_SPED (IdPianoAuto, IdSpedizione, IdDriver, Fermata, Sequenza, Arrivo, Motivo)
        SELECT @IdPianoAuto, IdSpedizione, IdDriver, Fermata, Sequenza, Arrivo, Motivo FROM @s;
        UPDATE d SET NPezzi = j.Pezzi, NFermate = j.Fermate, DistanzaM = j.Distanza, TempoS = j.Tempo, OraInizio = j.Inizio, OraFine = j.Fine
        FROM dbo.PIANO_AUTO_DRIVER d
        JOIN (SELECT CAST(JSON_VALUE(value, '$.idDriver') AS int) AS IdDriver, TRY_CAST(JSON_VALUE(value, '$.pezzi') AS int) AS Pezzi,
                     TRY_CAST(JSON_VALUE(value, '$.fermate') AS int) AS Fermate, TRY_CAST(JSON_VALUE(value, '$.distanza') AS int) AS Distanza,
                     TRY_CAST(JSON_VALUE(value, '$.tempo') AS int) AS Tempo, TRY_CAST(JSON_VALUE(value, '$.inizio') AS datetime) AS Inizio,
                     TRY_CAST(JSON_VALUE(value, '$.fine') AS datetime) AS Fine
              FROM OPENJSON(ISNULL(@Driver, '[]'))) j ON j.IdDriver = d.IdDriver
        WHERE d.IdPianoAuto = @IdPianoAuto;
        UPDATE dbo.PIANO_AUTO SET Stato = 'CALCOLATO', Errore = NULL, DataRisposta = GETDATE(), NFermate = @NFermate,
               DistanzaM = @DistanzaM, TempoS = @TempoS, Transazioni = @Transazioni,
               NAssegnate = (SELECT COUNT(*) FROM @s WHERE IdDriver IS NOT NULL),
               NNonAssegnate = (SELECT COUNT(*) FROM @s WHERE IdDriver IS NULL)
         WHERE IdPianoAuto = @IdPianoAuto;
    COMMIT;
END
GO

-- Conferma: il piano diventa quello del giorno (l'eventuale precedente confermato passa a SUPERATO) e la sequenza di
-- consegna va sulle spedizioni (SPED_ATTIVITA.Sequenza e, per quelle sul palmare, PALM_ATTIVITA.Sequenza).
CREATE OR ALTER PROCEDURE dbo.AI_PIANO_AUTO_Conferma
    @IdPianoAuto int,
    @Utente      varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @fil int, @data date, @stato varchar(20);
    SELECT @fil = IdFiliale, @data = Data, @stato = Stato FROM dbo.PIANO_AUTO WHERE IdPianoAuto = @IdPianoAuto;
    IF @stato IS NULL
    BEGIN
        RAISERROR('Piano non trovato', 16, 1);
        RETURN;
    END
    IF @stato <> 'CALCOLATO'
    BEGIN
        RAISERROR('Si conferma solo un piano calcolato (questo e'' %s)', 16, 1, @stato);
        RETURN;
    END
    BEGIN TRAN;
        UPDATE dbo.PIANO_AUTO SET Stato = 'SUPERATO' WHERE IdFiliale = @fil AND Data = @data AND Stato = 'CONFERMATO';
        UPDATE s SET Sequenza = p.Sequenza
        FROM dbo.SPED_ATTIVITA s JOIN dbo.PIANO_AUTO_SPED p ON p.IdSpedizione = s.IdSpedizione
        WHERE p.IdPianoAuto = @IdPianoAuto AND p.IdDriver IS NOT NULL;
        UPDATE pa SET Sequenza = p.Sequenza
        FROM dbo.PALM_ATTIVITA pa JOIN dbo.PIANO_AUTO_SPED p ON pa.TipoRiferimento = 0 AND pa.Riferimento = CONVERT(varchar(50), p.IdSpedizione)
        WHERE p.IdPianoAuto = @IdPianoAuto AND p.IdDriver IS NOT NULL;
        UPDATE dbo.PIANO_AUTO SET Stato = 'CONFERMATO', DataConferma = GETDATE(), UtenteConferma = @Utente WHERE IdPianoAuto = @IdPianoAuto;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.AI_PIANO_AUTO_Scarta
    @IdPianoAuto int,
    @Utente      varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PIANO_AUTO WHERE IdPianoAuto = @IdPianoAuto AND Stato IN ('CALCOLATO', 'ERRORE'))
    BEGIN
        RAISERROR('Si scarta solo un piano calcolato o andato in errore', 16, 1);
        RETURN;
    END
    UPDATE dbo.PIANO_AUTO SET Stato = 'SCARTATO', UtenteConferma = @Utente, DataConferma = GETDATE() WHERE IdPianoAuto = @IdPianoAuto;
END
GO

-- Workflow dello schedulatore che fa il calcolo (una volta sola). Sul server di Ge.C.O. New (10.1.0.8) il Python va
-- indicato nello step (il motore ha Python='python', che li' non e' nel PATH), come per GEO-01_HERE.
IF NOT EXISTS (SELECT 1 FROM dbo.WF_Workflow WHERE Nome = 'GEO-02_HERE_TOUR')
BEGIN
    DECLARE @wf int = NULL, @step int;
    EXEC dbo.WF_usp_Workflow_Salva @IdWorkflow = @wf OUTPUT, @Nome = N'GEO-02_HERE_TOUR',
        @Descrizione = N'Pianificazione automatica: divide le spedizioni geolocalizzate di una filiale fra i driver scelti con HERE Tour Planning v3 (zone preferite = giri abituali, tetto di pezzi per bilanciare). Lo mette in coda la pagina con WF_PARAMETRI {"IdPianoAuto": n}; here_tour.py scrive il risultato con AI_PIANO_AUTO_Risposta. Token in Lista Valori HERE/token.',
        @DirectoryOutput = NULL, @NomeFileLog = NULL, @NomeFileLogResult = NULL, @PausaTraStepMS = 0,
        @ApriDirectoryFinale = 0, @LoggaInizioOperazione = 1, @VariabiliGlobali = N'[]', @Attivo = 1;
    EXEC dbo.WF_usp_Step_Insert @IdWorkflow = @wf, @IdStepPadre = NULL, @Tipo = N'ESEGUIPYTHON', @NomeSezione = N'Step1_Tour', @IdStep = @step OUTPUT;
    EXEC dbo.WF_usp_Step_UpdateParametri @IdStep = @step, @Parametri = N'{"Script": "here/here_tour.py", "TimeoutSecondi": "1800", "Python": "C:/Program Files/Python39/python.exe"}',
        @EsciSuErrore = 1, @EseguiPasso = 1, @Attivo = 1, @Tipo = N'ESEGUIPYTHON', @NomeSezione = N'Step1_Tour';
END
GO

-- Voce di menu in fondo a "Gestione Giri Filiale" (il gruppo si cerca per nome: gli Id del DB di Ge.C.O. New sono diversi)
DECLARE @gruppo int = (SELECT TOP 1 IdMenuElemento FROM dbo.MENU_ELEMENTI WHERE Text = 'Gestione Giri Filiale' AND ISNULL(ParentID, 0) = 0);
IF @gruppo IS NULL
    RAISERROR('Manca il gruppo di menu "Gestione Giri Filiale"', 16, 1);
ELSE IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE ParentID = @gruppo AND Link = '/pianificazione-automatica')
BEGIN
    DECLARE @ordine int = (SELECT ISNULL(MAX(Sorting), 0) + 1 FROM dbo.MENU_ELEMENTI WHERE ParentID = @gruppo);
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = @gruppo, @Text = 'Pianificazione Automatica',
        @Descrizione = 'Divide tutte le spedizioni della filiale fra i driver scelti con HERE, ottimizzando e bilanciando il carico',
        @Link = '/pianificazione-automatica', @Sorting = @ordine;
END
GO
