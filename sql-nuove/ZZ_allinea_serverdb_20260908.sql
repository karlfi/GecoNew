-- Allineamento di DeliveryDB su serverdb agli script di sql-nuove dal 3 settembre 2026
-- (generato l'8 settembre 2026 dal fork Ge.C.O. New: la verifica ZZ_verifica_oggetti.sql
-- trovava 61 oggetti mancanti). Sono gli script originali, uno dopo l'altro, nell'ordine
-- delle dipendenze (SIM prima di PALMARI, V_Sim dopo PALMARI, WF in sequenza).
-- Eseguire con un login amministratore su DeliveryDB; gli script sono idempotenti
-- (CREATE OR ALTER, IF NOT EXISTS) e si possono rilanciare. I GRANT sono per l'utente
-- "claude" dove esiste; l'account con cui entra l'applicazione deve avere EXECUTE sulle
-- stored (o essere dbo). Le voci di menu vanno sotto gli ID 1229 (Test - Sviluppo) e
-- 1163 (Gestione Mezzi); gli alias PALMARI_TAG_FILIALE usano le filiali 36 e 1268.
USE DeliveryDB;
GO

-- ============================================================
-- >>> AI_UTENTI_Stato_Save.sql
-- ============================================================
-- =============================================================
-- AI_UTENTI_Stato_Save - cambia lo stato di archiviazione del dipendente
-- dalla griglia "Elenco Dipendenti".
--
-- I valori ammessi sono solo i quattro usati in azienda; qualsiasi altra cosa
-- viene rifiutata qui, cosi' la colonna non si sporca anche se la chiamata
-- arrivasse da fuori la pagina. Lo stato vuoto e' ammesso: e' la condizione
-- della maggior parte delle schede (non ancora classificate).
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_Stato_Save
    @IdUtente int,
    @Stato varchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @Stato = NULLIF(LTRIM(RTRIM(ISNULL(@Stato, ''))), '');

    IF @Stato IS NOT NULL AND @Stato NOT IN ('SI', 'da archiviare', 'da togliere', 'CESSATO')
    BEGIN
        RAISERROR('Stato "%s" non ammesso: usare SI, da archiviare, da togliere o CESSATO', 16, 1, @Stato);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.UTENTI WHERE IdUtente = @IdUtente)
    BEGIN
        RAISERROR('Utente %d inesistente', 16, 1, @IdUtente);
        RETURN;
    END

    UPDATE dbo.UTENTI SET Stato = @Stato WHERE IdUtente = @IdUtente;

    SELECT @IdUtente AS IdUtente, @Stato AS Stato;
END
GO
-- il grant serve solo dove esiste l'utente "claude" (vecchio server): su BLUE
-- l'applicazione entra con twebaccount, che e' dbo e non ne ha bisogno
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.AI_UTENTI_Stato_Save TO claude');
GO
GO

-- ============================================================
-- >>> AI_UTENTI_Del.sql
-- ============================================================
-- =============================================================
-- AI_UTENTI_Del — cancella una scheda utente, ma solo se non ha lasciato
-- traccia da nessuna parte.
--
-- Serve per le schede nate per sbaglio (una doppia, una prova) e cancellarle
-- e' l'unico modo di farle sparire dagli elenchi. E' irreversibile, quindi si
-- rifiuta se qualsiasi tabella del database fa riferimento a quell'IdUtente
-- (giornate di presenza, mezzi, gruppi, profili...) o se l'utente e' mai
-- entrato nell'applicazione. LOG_CALL non conta: e' solo il registro delle
-- pagine aperte.
--
-- Con @Conferma = 0 (default) non cancella: dice solo se si potrebbe e, se no,
-- dove sta la traccia che lo impedisce.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_Del
    @IdUtente int,
    @Conferma bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.UTENTI WHERE IdUtente = @IdUtente)
    BEGIN
        RAISERROR('Utente %d inesistente', 16, 1, @IdUtente);
        RETURN;
    END

    -- tutte le colonne del database che si chiamano IdUtente, tranne quelle
    -- della scheda stessa e del registro delle pagine
    DECLARE @tracce TABLE (Tabella sysname, Righe int);
    DECLARE @t sysname, @c sysname, @sql nvarchar(max), @n int;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT c.TABLE_NAME, c.COLUMN_NAME
        FROM INFORMATION_SCHEMA.COLUMNS c
        JOIN INFORMATION_SCHEMA.TABLES t ON t.TABLE_NAME = c.TABLE_NAME AND t.TABLE_TYPE = 'BASE TABLE'
        WHERE c.COLUMN_NAME = 'IdUtente' AND c.TABLE_NAME NOT IN ('UTENTI', 'LOG_CALL');
    OPEN cur;
    FETCH NEXT FROM cur INTO @t, @c;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'SELECT @n = COUNT(*) FROM ' + QUOTENAME(@t) + N' WHERE ' + QUOTENAME(@c) + N' = @id';
        EXEC sp_executesql @sql, N'@id int, @n int OUTPUT', @id = @IdUtente, @n = @n OUTPUT;
        IF @n > 0 INSERT INTO @tracce VALUES (@t, @n);
        FETCH NEXT FROM cur INTO @t, @c;
    END
    CLOSE cur; DEALLOCATE cur;

    IF EXISTS (SELECT 1 FROM dbo.UTENTI WHERE IdUtente = @IdUtente AND DataUltimoAccesso IS NOT NULL)
        INSERT INTO @tracce VALUES ('UTENTI.DataUltimoAccesso (e'' entrato nell''applicazione)', 1);

    IF EXISTS (SELECT 1 FROM @tracce)
    BEGIN
        SELECT 0 AS Cancellabile, Tabella, Righe FROM @tracce;
        RETURN;
    END

    IF @Conferma = 1
        DELETE FROM dbo.UTENTI WHERE IdUtente = @IdUtente;

    SELECT 1 AS Cancellabile, CASE WHEN @Conferma = 1 THEN 'cancellata' ELSE 'si puo'' cancellare' END AS Tabella, 0 AS Righe;
END
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.AI_UTENTI_Del TO claude');
GO
GO

-- ============================================================
-- >>> AI_UTENTI_ATTIVITA_PulisciVuote.sql
-- ============================================================
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
GO

-- ============================================================
-- >>> AI_MEZZI_AssegnaDriver.sql
-- ============================================================
-- =============================================================
-- AI_MEZZI_AssegnaDriver — sposta un mezzo da un driver a un altro.
--
-- Serve quando lo stesso dipendente ha due schede (un rapporto chiuso e uno
-- nuovo) e il mezzo e' rimasto agganciato a quella sbagliata: il palmare e le
-- giornate di presenza guardano MEZZI.IdUtente, quindi il mezzo deve stare
-- sulla scheda attiva. Con @IdUtente NULL il mezzo resta senza driver.
-- Restituisce com'era e com'e', cosi' chi lo lancia vede cosa ha spostato.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_MEZZI_AssegnaDriver
    @IdMezzo  int,
    @IdUtente int = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.MEZZI WHERE IdMezzo = @IdMezzo)
    BEGIN
        RAISERROR('Mezzo %d inesistente', 16, 1, @IdMezzo);
        RETURN;
    END
    IF @IdUtente IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.UTENTI WHERE IdUtente = @IdUtente)
    BEGIN
        RAISERROR('Utente %d inesistente', 16, 1, @IdUtente);
        RETURN;
    END

    DECLARE @Prima int;
    SELECT @Prima = IdUtente FROM dbo.MEZZI WHERE IdMezzo = @IdMezzo;

    UPDATE dbo.MEZZI SET IdUtente = @IdUtente WHERE IdMezzo = @IdMezzo;

    SELECT m.IdMezzo, m.Targa, @Prima AS DriverPrima, m.IdUtente AS DriverDopo, u.Nome AS NomeDopo
    FROM dbo.MEZZI m LEFT JOIN dbo.UTENTI u ON u.IdUtente = m.IdUtente
    WHERE m.IdMezzo = @IdMezzo;
END
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.AI_MEZZI_AssegnaDriver TO claude');
GO
GO

-- ============================================================
-- >>> AI_MENU_Link_ElencoDipendenti.sql
-- ============================================================
-- =============================================================
-- "Elenco Dipendenti" apre la pagina nuova solo su speedyweb.
--
-- La voce di menu resta Videata = RisultatoInterrogazioni, che e' quello che
-- legge tweb: continua a vedere la griglia di sempre. La webapp nuova invece
-- guarda prima il campo Link, che tweb ignora, e da li' apre la pagina
-- ElencoDipendenti (stessa query, ma con la colonna Stato modificabile).
--
-- Parametri resta invariato: IdQuery e sWhere li legge la pagina nuova come
-- faceva quella generica.
--
-- Idempotente. Per tornare indietro basta rimettere Link = '/interrogazioni'.
-- =============================================================
UPDATE MENU_ELEMENTI
SET Link = '/elenco-dipendenti'
WHERE IdMenuElemento = 1461                       -- Gestione Dipendenti > Elenco Dipendenti
  AND Videata = 'RisultatoInterrogazioni';

-- Le quattro voci "Dipendenti in scadenza a N mesi" girano sulla stessa query
-- 1093, cambia solo il where sulla DataFine che arriva da Parametri: stessa
-- pagina, stessa colonna Stato modificabile.
UPDATE MENU_ELEMENTI
SET Link = '/elenco-dipendenti'
WHERE IdMenuElemento IN (1612, 1613, 1614, 1615)   -- Dipendenti in scadenza a 1/2/3 mesi e oltre
  AND Videata = 'RisultatoInterrogazioni';

SELECT IdMenuElemento, Text, Videata, Link
FROM MENU_ELEMENTI
WHERE IdMenuElemento IN (1461, 1612, 1613, 1614, 1615)
ORDER BY IdMenuElemento;
GO

-- ============================================================
-- >>> FATT_Tipo_Fatturazione.sql
-- ============================================================
-- =============================================================
-- Fatturazione a consuntivo per tipo di vendita (ANCI, ALIA/FFM, ...): erano
-- step dello schedulatore (ANCI\ e SQL\DELIVERY-06_*.sql), tutti uguali a
-- parte il codice del tipo di vendita e i report da produrre.
--
-- FATT_TIPO_Genera e FATT_TIPO_Previsione sono le stored vere, parametriche;
-- FATT_ANCI_* e FATT_ALIA_* sono involucri con i valori del loro tipo, per chi
-- le lancia a mano. Report Excel e mail li fa l'API (Fatturazione.cs): un
-- xlsx da SQL non si scrive e Database Mail non e' configurato.
--
-- La data fattura e' il primo del mese corrente e la fattura copre tutto
-- quello che sta prima (a consuntivo).
-- =============================================================

-- -------------------------------------------------------------
-- FATT_TIPO_Genera: chi e' da fatturare, FATT_Genera per ognuno (se @Genera),
-- e le fatture della data pronte per report e mail. Due elenchi.
-- @CodFamiglia: se indicato, per l'elenco fatture vale solo chi ha una
-- condizione aperta di quella famiglia (cosi' faceva lo step ALIA, con la 'N').
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.FATT_TIPO_Genera
    @CodTipoVendita varchar(20),
    @CodFamiglia    varchar(1) = NULL,
    @DataFattura    date = NULL,   -- NULL = primo del mese corrente
    @IdCliente      int  = NULL,   -- NULL = tutti
    @Genera         bit  = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @DataFattura IS NULL
        SET @DataFattura = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1);

    -- 1) chi e' da fatturare: condizioni attive del tipo, nessuna fattura per la data
    DECLARE @daFare TABLE (IdCliente int PRIMARY KEY);
    INSERT INTO @daFare
    SELECT DISTINCT c.IdCliente
    FROM dbo.CLIENTI c
    WHERE (@IdCliente IS NULL OR c.IdCliente = @IdCliente)
      AND EXISTS (SELECT 1 FROM dbo.CLIENTI_CONDIZIONI cc
                  WHERE cc.IdCliente = c.IdCliente AND cc.CodTipoVendita = @CodTipoVendita
                    AND cc.DataInizioFatturazione < GETDATE()
                    AND ISNULL(cc.DataFineFatturazione, '30000101') > GETDATE())
      AND NOT EXISTS (SELECT 1 FROM dbo.FATT_EMISSIONE fa
                      WHERE fa.IdCliente = c.IdCliente AND fa.DataFattura = @DataFattura);

    SELECT c.IdCliente, c.RagioneSociale, c.EmailPrefattura
    FROM @daFare d JOIN dbo.CLIENTI c ON c.IdCliente = d.IdCliente
    ORDER BY c.RagioneSociale;

    -- 2) una fattura per ognuno (FATT_Genera fa i conti e, se non c'e' nulla, non lascia niente)
    IF @Genera = 1
    BEGIN
        DECLARE @id int;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT IdCliente FROM @daFare;
        OPEN cur; FETCH NEXT FROM cur INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            INSERT INTO dbo.LOG_Exec (chiamata, parametri)
            VALUES ('FATT_TIPO_Genera ' + @CodTipoVendita, 'FATT_Genera @IdCliente=' + CONVERT(varchar(10), @id)
                    + ', @DataFattura=' + CONVERT(varchar(8), @DataFattura, 112));
            EXEC dbo.FATT_Genera @IdCliente = @id, @DataFattura = @DataFattura;
            FETCH NEXT FROM cur INTO @id;
        END
        CLOSE cur; DEALLOCATE cur;
    END

    -- 3) le fatture di questa data, pronte per report e mail
    SELECT c.IdCliente, c.RagioneSociale, @DataFattura AS DataFattura,
           fa.IdFattura, fa.Numero, fa.Pezzi, CONVERT(decimal(10,2), fa.Importo) AS Importo,
           c.EmailPrefattura,
           'FAT_' + CONVERT(varchar(10), c.IdCliente) + '_' + CONVERT(varchar(8), @DataFattura, 112)
               + '_' + fa.Numero AS PrefixFile,
           -- il cliente 5314 (Nexive) ha il dettaglio nel suo tracciato e niente CDC
           CASE WHEN c.IdCliente = 5314 THEN 3 ELSE 0 END AS TipoReport,
           CASE WHEN c.IdCliente = 5314 THEN 0 ELSE 1 END AS ReportCDC,
           CASE WHEN d.IdCliente IS NULL THEN 0 ELSE 1 END AS GenerataOra
    FROM dbo.FATT_EMISSIONE fa
    JOIN dbo.CLIENTI c ON c.IdCliente = fa.IdCliente
    LEFT JOIN @daFare d ON d.IdCliente = c.IdCliente
    WHERE fa.DataFattura = @DataFattura
      AND (@IdCliente IS NULL OR c.IdCliente = @IdCliente)
      AND EXISTS (SELECT 1 FROM dbo.CLIENTI_CONDIZIONI cc
                  WHERE cc.IdCliente = c.IdCliente AND cc.CodTipoVendita = @CodTipoVendita
                    AND (@CodFamiglia IS NULL
                         OR (cc.CodFamiglia = @CodFamiglia AND cc.DataFineFatturazione IS NULL)))
    ORDER BY c.RagioneSociale;
END
GO

-- -------------------------------------------------------------
-- FATT_TIPO_Previsione: quanto verrebbe fatturato, senza fatturare. Esegue la
-- vera FATT_Genera dentro un savepoint e la annulla: pezzi, importo e voci
-- sono esattamente quelli che uscirebbero. Un ROLLBACK secco non va bene:
-- annulla anche la transazione di chi chiama, e con lei le tabelle temporanee.
-- Restano solo gli IdFattura interni consumati, che non sono il numero di
-- fattura (quello lo calcola FATT_Genera dal massimo e non si sposta).
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.FATT_TIPO_Previsione
    @CodTipoVendita varchar(20),
    @DataFattura    date = NULL,
    @IdCliente      int  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @DataFattura IS NULL
        SET @DataFattura = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1);

    DECLARE @daFare TABLE (IdCliente int PRIMARY KEY);
    INSERT INTO @daFare
    SELECT DISTINCT c.IdCliente
    FROM dbo.CLIENTI c
    WHERE (@IdCliente IS NULL OR c.IdCliente = @IdCliente)
      AND EXISTS (SELECT 1 FROM dbo.CLIENTI_CONDIZIONI cc
                  WHERE cc.IdCliente = c.IdCliente AND cc.CodTipoVendita = @CodTipoVendita
                    AND cc.DataInizioFatturazione < GETDATE()
                    AND ISNULL(cc.DataFineFatturazione, '30000101') > GETDATE())
      AND NOT EXISTS (SELECT 1 FROM dbo.FATT_EMISSIONE fa
                      WHERE fa.IdCliente = c.IdCliente AND fa.DataFattura = @DataFattura);

    CREATE TABLE #fatt (IdFattura int, Numero varchar(50), Pezzi int, Importo float, DataFattura date);
    CREATE TABLE #vociTmp (CIG varchar(50), Descrizione varchar(255), NumPezzi int, PrezzoUnitario float, Totale float);
    DECLARE @stime TABLE (IdCliente int, Pezzi int, Importo decimal(10,2), Errore varchar(400));
    DECLARE @voci  TABLE (IdCliente int, CIG varchar(50), Descrizione varchar(255), NumPezzi int,
                          PrezzoUnitario decimal(10,2), Totale decimal(10,2));

    DECLARE @id int, @idf int;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT IdCliente FROM @daFare;
    OPEN cur; FETCH NEXT FROM cur INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            BEGIN TRAN;
            SAVE TRAN prova;
            DELETE #fatt; DELETE #vociTmp;
            INSERT INTO #fatt EXEC dbo.FATT_Genera @IdCliente = @id, @DataFattura = @DataFattura;
            SELECT TOP 1 @idf = IdFattura FROM #fatt;
            IF @idf IS NOT NULL
            BEGIN
                INSERT INTO #vociTmp EXEC dbo.FATT_Report @IdFattura = @idf, @Tipo = 1;
                INSERT INTO @voci SELECT @id, CIG, Descrizione, NumPezzi, PrezzoUnitario, Totale FROM #vociTmp;
            END
            INSERT INTO @stime
            SELECT @id, ISNULL(MAX(Pezzi), 0), ISNULL(MAX(Importo), 0), NULL FROM #fatt;
            ROLLBACK TRAN prova;    -- la fattura di prova sparisce
            COMMIT TRAN;
        END TRY
        BEGIN CATCH
            INSERT INTO @stime VALUES (@id, 0, 0, ERROR_MESSAGE());
            IF XACT_STATE() = -1 ROLLBACK TRAN;
            ELSE IF @@TRANCOUNT > 0 BEGIN ROLLBACK TRAN prova; COMMIT TRAN; END
        END CATCH
        SET @idf = NULL;
        FETCH NEXT FROM cur INTO @id;
    END
    CLOSE cur; DEALLOCATE cur;

    SELECT c.IdCliente, c.RagioneSociale, c.EmailPrefattura, s.Pezzi, s.Importo, s.Errore
    FROM @stime s JOIN dbo.CLIENTI c ON c.IdCliente = s.IdCliente
    ORDER BY c.RagioneSociale;

    SELECT IdCliente, CIG, Descrizione, NumPezzi, PrezzoUnitario, Totale
    FROM @voci ORDER BY IdCliente, Descrizione;
END
GO

-- -------------------------------------------------------------
-- gli involucri per tipo: stessi nomi dei vecchi step, valori gia' messi
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.FATT_ANCI_Genera
    @DataFattura date = NULL, @IdCliente int = NULL, @Genera bit = 1
AS
    EXEC dbo.FATT_TIPO_Genera @CodTipoVendita = 'ANCI', @CodFamiglia = NULL,
         @DataFattura = @DataFattura, @IdCliente = @IdCliente, @Genera = @Genera;
GO
CREATE OR ALTER PROCEDURE dbo.FATT_ANCI_Previsione
    @DataFattura date = NULL, @IdCliente int = NULL
AS
    EXEC dbo.FATT_TIPO_Previsione @CodTipoVendita = 'ANCI', @DataFattura = @DataFattura, @IdCliente = @IdCliente;
GO
-- ALIA: nelle condizioni il tipo di vendita e' FFM, e l'elenco fatture vale
-- per chi ha una condizione aperta di famiglia N (cosi' faceva lo step)
CREATE OR ALTER PROCEDURE dbo.FATT_ALIA_Genera
    @DataFattura date = NULL, @IdCliente int = NULL, @Genera bit = 1
AS
    EXEC dbo.FATT_TIPO_Genera @CodTipoVendita = 'FFM', @CodFamiglia = 'N',
         @DataFattura = @DataFattura, @IdCliente = @IdCliente, @Genera = @Genera;
GO
CREATE OR ALTER PROCEDURE dbo.FATT_ALIA_Previsione
    @DataFattura date = NULL, @IdCliente int = NULL
AS
    EXEC dbo.FATT_TIPO_Previsione @CodTipoVendita = 'FFM', @DataFattura = @DataFattura, @IdCliente = @IdCliente;
GO

-- il registro delle esecuzioni, per la parte che fa l'API (report e mail)
CREATE OR ALTER PROCEDURE dbo.AI_LOG_Exec_Add
    @Chiamata  varchar(100),
    @Parametri varchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.LOG_Exec (chiamata, parametri) VALUES (@Chiamata, LEFT(@Parametri, 4000));
END
GO

-- la cartella dei file: sul server l'app puo' scrivere solo nella temp (come
-- il proxy dei report); %TEMP% lo espande l'API, i file si rifanno dalla pagina
IF NOT EXISTS (SELECT 1 FROM dbo.PARAMETRI WHERE Nome = 'PercorsoFatturazione')
    INSERT INTO dbo.PARAMETRI (Nome, Valore) VALUES ('PercorsoFatturazione', '%TEMP%\speedyweb-fatturazione\');
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.FATT_TIPO_Genera TO claude; GRANT EXECUTE ON dbo.FATT_TIPO_Previsione TO claude;
          GRANT EXECUTE ON dbo.FATT_ANCI_Genera TO claude; GRANT EXECUTE ON dbo.FATT_ANCI_Previsione TO claude;
          GRANT EXECUTE ON dbo.FATT_ALIA_Genera TO claude; GRANT EXECUTE ON dbo.FATT_ALIA_Previsione TO claude;
          GRANT EXECUTE ON dbo.AI_LOG_Exec_Add TO claude');
GO
GO

-- ============================================================
-- >>> FATT_menu.sql
-- ============================================================
-- Voci di menu delle fatturazioni sotto Test - Sviluppo (1229): tweb non le
-- vede (nessuna Videata), la webapp le apre dal campo Link. Idempotente.
IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/fatturazione-anci')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1229, @Text = 'Fatturazione ANCI',
        @Descrizione = 'Fatture ANCI del mese, report Excel e mail di prefattura',
        @Link = '/fatturazione-anci', @Sorting = 11;
IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/fatturazione-alia')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1229, @Text = 'Fatturazione ALIA',
        @Descrizione = 'Fatture ALIA (FFM) del mese, report Excel e mail di prefattura',
        @Link = '/fatturazione-alia', @Sorting = 12;
GO

-- ============================================================
-- >>> WF_database.sql
-- ============================================================
/* ============================================================================
   Workflow Orchestrator - Database completo (modulo WF_) - MSSQL 2016+/2019
   ----------------------------------------------------------------------------
   FILE UNICO E RIESEGUIBILE: lancialo per intero per installare/aggiornare.
   Convenzione: tutti gli oggetti hanno prefisso WF_ (tabelle, vista, tipo TVP,
   vincoli, indici, stored procedure WF_usp_*).

   COMPATIBILITÀ: scritto per girare anche a database COMPATIBILITY_LEVEL 100
   (SQL 2008). NON usa OPENJSON (richiede 130) né TRY_CONVERT (richiede 110).
   Gli step vengono passati alla SP via Table-Valued Parameter (WF_udt_StepList).
   ISJSON nelle CHECK e i JSON salvati come testo funzionano a qualsiasi compat.

   Cosa fa una riesecuzione ("aggiorno tutto"):
     - Tabelle / Tipo TVP: creati solo se assenti. I dati NON vengono toccati.
       Modifiche STRUTTURALI richiedono migrazione manuale (ALTER).
     - Lookup tipi (WF_TipoStep): MERGE con UPDATE -> descrizioni sempre allineate.
     - Indici: creati solo se assenti.
     - Vista e Stored Procedure: CREATE OR ALTER -> sempre riallineate.

   Sottopassi (NSottopassi) = adjacency list su WF_WorkflowStep.IdStepPadre.
   ========================================================================== */
USE DeliveryDB;    -- <<< stesso DB di Speedy Web (TWEB). Unica riga da cambiare per un altro DB.
                   --     (fino al 2026-09 il modulo viveva su NotificheDB: vedi migra_da_NotificheDB.sql)
GO


/* ##########################################################################
   1) TABELLE
   ######################################################################## */

/* ---------- Lookup dei tipi di mattoncino (estendibile senza ALTER) -------- */
IF OBJECT_ID('dbo.WF_TipoStep') IS NULL
CREATE TABLE dbo.WF_TipoStep (
    Codice       NVARCHAR(50)  NOT NULL CONSTRAINT PK_WF_TipoStep PRIMARY KEY,
    Descrizione  NVARCHAR(255) NULL,
    SupportaSottopassi BIT NOT NULL CONSTRAINT DF_WF_TipoStep_Sub DEFAULT 0,
    Attivo       BIT NOT NULL CONSTRAINT DF_WF_TipoStep_Attivo DEFAULT 1
);
GO

/* ---------- Workflow = sezione [ComandoBase] del file step ----------------- */
IF OBJECT_ID('dbo.WF_Workflow') IS NULL
CREATE TABLE dbo.WF_Workflow (
    IdWorkflow            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_Workflow PRIMARY KEY,
    Nome                  NVARCHAR(255)  NOT NULL,   -- nome logico / nome del file step
    Descrizione           NVARCHAR(1000) NULL,

    /* parametri globali [ComandoBase] mappati esplicitamente */
    NStepDichiarati       INT            NULL,        -- NStep nel file (ridondante, per fedeltà)
    DirectoryOutput       NVARCHAR(500)  NULL,
    NomeFileLog           NVARCHAR(500)  NULL,
    NomeFileLogResult     NVARCHAR(500)  NULL,
    PausaTraStepMS        INT            NOT NULL CONSTRAINT DF_WF_Workflow_Pausa DEFAULT 0,
    ApriDirectoryFinale   BIT            NOT NULL CONSTRAINT DF_WF_Workflow_ApriDir DEFAULT 0,
    LoggaInizioOperazione BIT            NOT NULL CONSTRAINT DF_WF_Workflow_LogInizio DEFAULT 1,
    VariabiliGlobali      NVARCHAR(MAX)  NULL,        -- JSON array di nomi: ["IdAgenzia","Ambito"]

    /* catch-all: qualunque chiave di [ComandoBase] non modellata sopra */
    ParametriExtra        NVARCHAR(MAX)  NULL,        -- JSON oggetto

    /* tracciabilità migrazione dal legacy */
    FileOrigine           NVARCHAR(500)  NULL,
    HashOrigine           VARBINARY(32)  NULL,        -- SHA-256 del file, anti-doppione in import
    Attivo                BIT            NOT NULL CONSTRAINT DF_WF_Workflow_Attivo DEFAULT 1,
    DataCreazione         DATETIME2(0)   NOT NULL CONSTRAINT DF_WF_Workflow_DtCre DEFAULT SYSUTCDATETIME(),
    DataModifica          DATETIME2(0)   NOT NULL CONSTRAINT DF_WF_Workflow_DtMod DEFAULT SYSUTCDATETIME(),

    CONSTRAINT UQ_WF_Workflow_Nome UNIQUE (Nome),
    CONSTRAINT CK_WF_Workflow_VarGlob CHECK (VariabiliGlobali IS NULL OR ISJSON(VariabiliGlobali) = 1),
    CONSTRAINT CK_WF_Workflow_Extra   CHECK (ParametriExtra   IS NULL OR ISJSON(ParametriExtra)   = 1)
);
GO

/* ---------- Step = sezioni [StepN] e [StepN_SottopassoM] ------------------- */
IF OBJECT_ID('dbo.WF_WorkflowStep') IS NULL
CREATE TABLE dbo.WF_WorkflowStep (
    IdStep        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_WorkflowStep PRIMARY KEY,
    IdWorkflow    INT           NOT NULL,
    IdStepPadre   INT           NULL,            -- NULL = step radice; valorizzato = sottopasso
    Ordine        INT           NOT NULL,        -- numero step (radice) o numero sottopasso
    NomeSezione   NVARCHAR(120) NOT NULL,        -- es. "Step1", "Step1_Sottopasso2" (fedeltà/debug)
    Tipo          NVARCHAR(50)  NOT NULL,
    EsciSuErrore  BIT           NOT NULL CONSTRAINT DF_WF_Step_EsciErr DEFAULT 0,
    EseguiPasso   BIT           NOT NULL CONSTRAINT DF_WF_Step_Esegui  DEFAULT 1,
    -- 0 = step disabilitato nel legacy via [StepNO<n>] (config conservata, non eseguita)
    Attivo        BIT           NOT NULL CONSTRAINT DF_WF_Step_Attivo  DEFAULT 1,

    /* parametri dinamici specifici del tipo (il "JSONB" richiesto).
       Contiene anche le sotto-strutture NON eseguibili: campiFissi[],
       campiLookup[], campiCombo[], primaRiga[] ecc. */
    Parametri     NVARCHAR(MAX) NOT NULL CONSTRAINT DF_WF_Step_Param DEFAULT N'{}',

    DataCreazione DATETIME2(0)  NOT NULL CONSTRAINT DF_WF_Step_DtCre DEFAULT SYSUTCDATETIME(),

    CONSTRAINT FK_WF_Step_Workflow FOREIGN KEY (IdWorkflow)
        REFERENCES dbo.WF_Workflow(IdWorkflow) ON DELETE CASCADE,
    CONSTRAINT FK_WF_Step_Padre FOREIGN KEY (IdStepPadre)
        REFERENCES dbo.WF_WorkflowStep(IdStep),  -- self-FK NO ACTION (no cascade => niente cicli DDL)
    CONSTRAINT FK_WF_Step_Tipo  FOREIGN KEY (Tipo)
        REFERENCES dbo.WF_TipoStep(Codice),
    CONSTRAINT CK_WF_Step_Param  CHECK (ISJSON(Parametri) = 1)
);
GO


/* ##########################################################################
   2) TIPO TVP per il passaggio degli step alla SP di import
      (Per modificarne le colonne: droppare prima le SP che lo usano,
       poi il tipo, poi rieseguire.)
   ######################################################################## */
IF TYPE_ID('dbo.WF_udt_StepList') IS NULL
CREATE TYPE dbo.WF_udt_StepList AS TABLE (
    TempId       INT           NOT NULL PRIMARY KEY,
    ParentTempId INT           NULL,
    Ordine       INT           NOT NULL,
    NomeSezione  NVARCHAR(120) NOT NULL,
    Tipo         NVARCHAR(50)  NOT NULL,
    EsciSuErrore BIT           NOT NULL,
    EseguiPasso  BIT           NOT NULL,
    Attivo       BIT           NOT NULL,
    Parametri    NVARCHAR(MAX) NOT NULL
);
GO


/* ##########################################################################
   3) SEED DEI TIPI (MERGE: inserisce i nuovi, aggiorna le descrizioni)
   ######################################################################## */
MERGE dbo.WF_TipoStep AS t
USING (VALUES
    ('EXPORTTXT',            'Esporta query su file di testo (campi fissi/delimitato)', 0),
    ('EXPORTXLS',            'Esporta query su file Excel',                              0),
    ('EXPORTXLSFROMTEMPLATE','Esporta query su Excel a partire da un template',          0),
    ('GENERAREPORT',         'Genera report FastReport (PDF)',                           0),
    ('COMPRIMIFILE',         'Comprime/decomprime file (zip)',                           0),
    ('APRIMAIL',             'Compila/invia e-mail',                                     0),
    ('COPYFILE',             'Copia/sposta file',                                        0),
    ('ESEGUIQUERY',          'Esegue query SQL, con eventuali sottopassi per record',    1),
    ('ESEGUISHELL',          'Esegue un programma esterno',                              0),
    ('IMPORTTXT',            'Importa file di testo su tabella',                         0),
    ('IMPORTXLS',            'Importa file Excel su tabella',                            0),
    ('STAMPADOCUMENTO',      'Stampa/apre un documento',                                 0),
    ('SPLITPDF',             'Divide PDF in più file',                                   0),
    ('SFOGLIADIR',           'Sfoglia directory, con eventuali sottopassi per file',     1),
    ('TRASFERISCIFTP',       'Download/Upload/Rename via FTP',                           0),
    ('EXPORTPDF',            'Estrae/spezza PDF per record',                             0),
    ('SFOGLIAMAIL',          'Sfoglia casella POP, con eventuali sottopassi per mail',   1)
) AS s(Codice, Descrizione, SupportaSottopassi)
ON t.Codice = s.Codice
WHEN MATCHED THEN
    UPDATE SET Descrizione = s.Descrizione, SupportaSottopassi = s.SupportaSottopassi
WHEN NOT MATCHED THEN
    INSERT (Codice, Descrizione, SupportaSottopassi)
    VALUES (s.Codice, s.Descrizione, s.SupportaSottopassi);
GO


/* ##########################################################################
   4) INDICI (creati solo se assenti)
   ######################################################################## */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UX_WF_Step_Ordine' AND object_id = OBJECT_ID('dbo.WF_WorkflowStep'))
    CREATE UNIQUE INDEX UX_WF_Step_Ordine
        ON dbo.WF_WorkflowStep (IdWorkflow, IdStepPadre, Ordine);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_WF_Step_Padre' AND object_id = OBJECT_ID('dbo.WF_WorkflowStep'))
    CREATE INDEX IX_WF_Step_Padre
        ON dbo.WF_WorkflowStep (IdStepPadre) WHERE IdStepPadre IS NOT NULL;
GO


/* ##########################################################################
   5) VISTA: albero (step + sottopassi) in ordine di esecuzione
   ######################################################################## */
CREATE OR ALTER VIEW dbo.WF_vw_WorkflowStepAlbero AS
WITH Albero AS (
    SELECT s.IdStep, s.IdWorkflow, s.IdStepPadre, s.Ordine, s.NomeSezione,
           s.Tipo, s.EsciSuErrore, s.EseguiPasso, s.Attivo, s.Parametri,
           0 AS Livello,
           CAST(RIGHT('0000' + CAST(s.Ordine AS VARCHAR(4)), 4) AS VARCHAR(900)) AS Percorso
    FROM dbo.WF_WorkflowStep s
    WHERE s.IdStepPadre IS NULL
    UNION ALL
    SELECT s.IdStep, s.IdWorkflow, s.IdStepPadre, s.Ordine, s.NomeSezione,
           s.Tipo, s.EsciSuErrore, s.EseguiPasso, s.Attivo, s.Parametri,
           a.Livello + 1,
           -- CAST esplicito: anchor e ramo ricorsivo devono avere lo STESSO tipo/lunghezza
           CAST(a.Percorso + '.' + RIGHT('0000' + CAST(s.Ordine AS VARCHAR(4)), 4) AS VARCHAR(900))
    FROM dbo.WF_WorkflowStep s
    JOIN Albero a ON s.IdStepPadre = a.IdStep
)
SELECT * FROM Albero;
GO
-- Esempio: SELECT * FROM dbo.WF_vw_WorkflowStepAlbero WHERE IdWorkflow = 1 ORDER BY Percorso;


/* ##########################################################################
   6) STORED PROCEDURE (scritture SOLO da qui)
   ######################################################################## */

/* ----------------------------------------------------------------------------
   WF_usp_Workflow_Import
   Importa un intero file step (header [ComandoBase] + albero degli step) in
   transazione. Gli step arrivano come Table-Valued Parameter (lista piatta con
   TempId/ParentTempId): l'inserimento procede per livelli e mappa TempId
   applicativo -> IdStep reale via MERGE/OUTPUT, gestendo profondità arbitraria.
   @SovrascriviSeEsiste = 1 -> rimpiazza un Workflow con lo stesso Nome (re-import).
   VariabiliGlobali/ParametriExtra arrivano già serializzati come JSON (testo).
   Vedi src/parser/persist.ts.
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Workflow_Import
    @Nome                  NVARCHAR(255),
    @NStepDichiarati       INT           = NULL,
    @DirectoryOutput       NVARCHAR(500) = NULL,
    @NomeFileLog           NVARCHAR(500) = NULL,
    @NomeFileLogResult     NVARCHAR(500) = NULL,
    @PausaTraStepMS        INT           = 0,
    @ApriDirectoryFinale   BIT           = 0,
    @LoggaInizioOperazione BIT           = 1,
    @VariabiliGlobali      NVARCHAR(MAX) = NULL,   -- JSON array (testo)
    @ParametriExtra        NVARCHAR(MAX) = NULL,   -- JSON object (testo)
    @FileOrigine           NVARCHAR(500) = NULL,
    @HashOrigine           VARBINARY(32) = NULL,
    @SovrascriviSeEsiste   BIT           = 0,
    @Steps                 dbo.WF_udt_StepList READONLY,
    @IdWorkflow            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRAN;

        IF @SovrascriviSeEsiste = 1
        BEGIN
            DECLARE @IdEsistente INT =
                (SELECT IdWorkflow FROM dbo.WF_Workflow WHERE Nome = @Nome);
            IF @IdEsistente IS NOT NULL
            BEGIN
                DELETE FROM dbo.WF_WorkflowStep WHERE IdWorkflow = @IdEsistente;
                DELETE FROM dbo.WF_Workflow     WHERE IdWorkflow = @IdEsistente;
            END
        END

        /* ---- header [ComandoBase] ---- */
        INSERT INTO dbo.WF_Workflow
            (Nome, NStepDichiarati, DirectoryOutput, NomeFileLog, NomeFileLogResult,
             PausaTraStepMS, ApriDirectoryFinale, LoggaInizioOperazione,
             VariabiliGlobali, ParametriExtra, FileOrigine, HashOrigine)
        VALUES
            (@Nome, @NStepDichiarati, @DirectoryOutput, @NomeFileLog, @NomeFileLogResult,
             ISNULL(@PausaTraStepMS, 0), ISNULL(@ApriDirectoryFinale, 0),
             ISNULL(@LoggaInizioOperazione, 1),
             @VariabiliGlobali, @ParametriExtra, @FileOrigine, @HashOrigine);

        SET @IdWorkflow = SCOPE_IDENTITY();

        /* ---- copia locale del TVP (per il loop) ---- */
        DECLARE @StepsLocal TABLE (
            TempId       INT PRIMARY KEY,
            ParentTempId INT NULL,
            Ordine       INT,
            NomeSezione  NVARCHAR(120),
            Tipo         NVARCHAR(50),
            EsciSuErrore BIT,
            EseguiPasso  BIT,
            Attivo       BIT,
            Parametri    NVARCHAR(MAX)
        );
        INSERT INTO @StepsLocal
            (TempId, ParentTempId, Ordine, NomeSezione, Tipo,
             EsciSuErrore, EseguiPasso, Attivo, Parametri)
        SELECT TempId, ParentTempId, Ordine, NomeSezione, Tipo,
               EsciSuErrore, EseguiPasso, Attivo, ISNULL(Parametri, N'{}')
        FROM @Steps;

        /* mappa TempId(applicativo) -> IdStep(reale) */
        DECLARE @Map TABLE (TempId INT PRIMARY KEY, IdStep INT);
        DECLARE @Inseriti INT = 1;

        /* inserimento per livelli: ogni giro inserisce gli step il cui padre
           è già mappato (o radice). Si ferma quando tutti sono inseriti. */
        WHILE EXISTS (SELECT 1 FROM @StepsLocal s
                      WHERE NOT EXISTS (SELECT 1 FROM @Map m WHERE m.TempId = s.TempId))
        BEGIN
            MERGE dbo.WF_WorkflowStep AS tgt
            USING (
                SELECT s.TempId, s.Ordine, s.NomeSezione, s.Tipo,
                       s.EsciSuErrore, s.EseguiPasso, s.Attivo, s.Parametri,
                       pm.IdStep AS IdStepPadre
                FROM @StepsLocal s
                LEFT JOIN @Map pm ON pm.TempId = s.ParentTempId
                WHERE NOT EXISTS (SELECT 1 FROM @Map m WHERE m.TempId = s.TempId)
                  AND (s.ParentTempId IS NULL OR pm.IdStep IS NOT NULL)
            ) AS src
            ON 1 = 0   -- forza sempre l'INSERT (pattern MERGE per usare OUTPUT su colonne sorgente)
            WHEN NOT MATCHED THEN
                INSERT (IdWorkflow, IdStepPadre, Ordine, NomeSezione, Tipo,
                        EsciSuErrore, EseguiPasso, Attivo, Parametri)
                VALUES (@IdWorkflow, src.IdStepPadre, src.Ordine, src.NomeSezione, src.Tipo,
                        src.EsciSuErrore, src.EseguiPasso, src.Attivo, src.Parametri)
            OUTPUT src.TempId, inserted.IdStep INTO @Map (TempId, IdStep);

            SET @Inseriti = @@ROWCOUNT;
            IF @Inseriti = 0   -- restano step ma nessuno inseribile => orfano o ciclo
                RAISERROR('WF_usp_Workflow_Import: sottopassi orfani o ciclo nei parentTempId.', 16, 1);
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE(),
                @sev INT = ERROR_SEVERITY(),
                @sta INT = ERROR_STATE();
        RAISERROR(@msg, @sev, @sta);
    END CATCH
END
GO

/* ----------------------------------------------------------------------------
   WF_usp_Step_UpdateParametri
   Aggiorna i parametri (JSON) e i flag di un singolo step. Usata dall'editor.
   I parametri NULL non vengono modificati (COALESCE sul valore corrente).
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Step_UpdateParametri
    @IdStep       INT,
    @Parametri    NVARCHAR(MAX),
    @EsciSuErrore BIT           = NULL,
    @EseguiPasso  BIT           = NULL,
    @Attivo       BIT           = NULL,
    @Tipo         NVARCHAR(50)  = NULL,
    @NomeSezione  NVARCHAR(120) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@Parametri) <> 1
        RAISERROR('WF_usp_Step_UpdateParametri: @Parametri non è JSON valido.', 16, 1);
    IF @Tipo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.WF_TipoStep WHERE Codice = @Tipo)
        RAISERROR('WF_usp_Step_UpdateParametri: Tipo "%s" inesistente.', 16, 1, @Tipo);

    UPDATE dbo.WF_WorkflowStep
       SET Parametri    = @Parametri,
           EsciSuErrore = ISNULL(@EsciSuErrore, EsciSuErrore),
           EseguiPasso  = ISNULL(@EseguiPasso,  EseguiPasso),
           Attivo       = ISNULL(@Attivo,       Attivo),
           Tipo         = ISNULL(@Tipo,         Tipo),
           NomeSezione  = ISNULL(@NomeSezione,  NomeSezione)
     WHERE IdStep = @IdStep;

    IF @@ROWCOUNT = 0
        RAISERROR('WF_usp_Step_UpdateParametri: IdStep %d inesistente.', 16, 1, @IdStep);
END
GO

/* ----------------------------------------------------------------------------
   WF_usp_Step_Insert
   Aggiunge uno step (radice se @IdStepPadre NULL, altrimenti sottopasso) in
   coda ai fratelli (Ordine = max+1). Restituisce il nuovo IdStep.
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Step_Insert
    @IdWorkflow  INT,
    @IdStepPadre INT           = NULL,
    @Tipo        NVARCHAR(50),
    @NomeSezione NVARCHAR(120) = NULL,
    @IdStep      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.WF_TipoStep WHERE Codice = @Tipo)
        RAISERROR('WF_usp_Step_Insert: Tipo "%s" inesistente.', 16, 1, @Tipo);
    IF @IdStepPadre IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.WF_WorkflowStep
        WHERE IdStep = @IdStepPadre AND IdWorkflow = @IdWorkflow)
        RAISERROR('WF_usp_Step_Insert: IdStepPadre non valido per il workflow.', 16, 1);

    DECLARE @Ordine INT = (
        SELECT ISNULL(MAX(Ordine), 0) + 1 FROM dbo.WF_WorkflowStep
        WHERE IdWorkflow = @IdWorkflow
          AND ((@IdStepPadre IS NULL AND IdStepPadre IS NULL) OR IdStepPadre = @IdStepPadre));

    DECLARE @Sez NVARCHAR(120) = ISNULL(@NomeSezione,
        CASE WHEN @IdStepPadre IS NULL THEN CONCAT('Step', @Ordine)
             ELSE CONCAT('Sottopasso', @Ordine) END);

    INSERT INTO dbo.WF_WorkflowStep
        (IdWorkflow, IdStepPadre, Ordine, NomeSezione, Tipo, Parametri)
    VALUES (@IdWorkflow, @IdStepPadre, @Ordine, @Sez, @Tipo, N'{}');

    SET @IdStep = SCOPE_IDENTITY();
END
GO

/* ----------------------------------------------------------------------------
   WF_usp_Step_Delete
   Elimina uno step e tutti i suoi discendenti (sottopassi a qualsiasi livello).
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Step_Delete
    @IdStep INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @ToDel TABLE (IdStep INT PRIMARY KEY);
        ;WITH D AS (
            SELECT IdStep FROM dbo.WF_WorkflowStep WHERE IdStep = @IdStep
            UNION ALL
            SELECT s.IdStep FROM dbo.WF_WorkflowStep s JOIN D ON s.IdStepPadre = D.IdStep
        )
        INSERT INTO @ToDel SELECT IdStep FROM D;

        -- DELETE massiva set-based: l'intero sottoalbero esce insieme => self-FK ok
        DELETE FROM dbo.WF_WorkflowStep WHERE IdStep IN (SELECT IdStep FROM @ToDel);
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @m NVARCHAR(2048) = ERROR_MESSAGE(), @s INT = ERROR_SEVERITY(), @t INT = ERROR_STATE();
        RAISERROR(@m, @s, @t);
    END CATCH
END
GO

/* ----------------------------------------------------------------------------
   WF_usp_Step_Sposta
   Sposta uno step su/giù scambiando l'Ordine con il fratello adiacente.
   @Direzione: 'su' | 'giu'. No-op se è già all'estremo.
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Step_Sposta
    @IdStep    INT,
    @Direzione NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Direzione NOT IN ('su', 'giu')
        RAISERROR('WF_usp_Step_Sposta: @Direzione deve essere "su" o "giu".', 16, 1);

    DECLARE @IdWorkflow INT, @IdPadre INT, @Ordine INT;
    SELECT @IdWorkflow = IdWorkflow, @IdPadre = IdStepPadre, @Ordine = Ordine
    FROM dbo.WF_WorkflowStep WHERE IdStep = @IdStep;
    IF @IdWorkflow IS NULL
        RAISERROR('WF_usp_Step_Sposta: IdStep %d inesistente.', 16, 1, @IdStep);

    DECLARE @IdAltro INT, @OrdAltro INT;
    IF @Direzione = 'su'
        SELECT TOP 1 @IdAltro = IdStep, @OrdAltro = Ordine FROM dbo.WF_WorkflowStep
         WHERE IdWorkflow = @IdWorkflow
           AND ((@IdPadre IS NULL AND IdStepPadre IS NULL) OR IdStepPadre = @IdPadre)
           AND Ordine < @Ordine ORDER BY Ordine DESC;
    ELSE
        SELECT TOP 1 @IdAltro = IdStep, @OrdAltro = Ordine FROM dbo.WF_WorkflowStep
         WHERE IdWorkflow = @IdWorkflow
           AND ((@IdPadre IS NULL AND IdStepPadre IS NULL) OR IdStepPadre = @IdPadre)
           AND Ordine > @Ordine ORDER BY Ordine ASC;

    IF @IdAltro IS NULL RETURN;  -- già all'estremo

    -- swap atomico in una sola UPDATE: nessuna collisione sull'indice unico
    UPDATE dbo.WF_WorkflowStep
       SET Ordine = CASE IdStep WHEN @IdStep THEN @OrdAltro WHEN @IdAltro THEN @Ordine END
     WHERE IdStep IN (@IdStep, @IdAltro);
END
GO


/* ##########################################################################
   7) SCHEDULAZIONE & ESECUZIONE (rispecchia PLAN_Master/Detail/StepSchedulati)
   ######################################################################## */

/* ---------- Lookup stati esecuzione (codici allineati al legacy) ----------- */
IF OBJECT_ID('dbo.WF_StatoEsecuzione') IS NULL
CREATE TABLE dbo.WF_StatoEsecuzione (
    Codice      INT          NOT NULL CONSTRAINT PK_WF_StatoEsecuzione PRIMARY KEY,
    Nome        NVARCHAR(30) NOT NULL,
    Descrizione NVARCHAR(100) NULL
);
GO
MERGE dbo.WF_StatoEsecuzione AS t
USING (VALUES
    (0, 'PIANIFICATA',   'Occorrenza prevista, non ancora eseguita'),
    (1, 'IN_ESECUZIONE', 'In corso'),
    (2, 'ESEGUITA',      'Completata con successo'),
    (3, 'ERRORE',        'Terminata con errore'),
    (4, 'ANNULLATA',     'Annullata manualmente'),
    (5, 'SALTATA',       'Saltata (festivo / pianificazione sospesa)')
) AS s(Codice, Nome, Descrizione)
ON t.Codice = s.Codice
WHEN MATCHED THEN UPDATE SET Nome = s.Nome, Descrizione = s.Descrizione
WHEN NOT MATCHED THEN INSERT (Codice, Nome, Descrizione) VALUES (s.Codice, s.Nome, s.Descrizione);
GO

/* ---------- Master della pianificazione (la regola, per workflow) ---------- */
IF OBJECT_ID('dbo.WF_PianificazioneMaster') IS NULL
CREATE TABLE dbo.WF_PianificazioneMaster (
    IdPianificazione  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_PianMaster PRIMARY KEY,
    IdWorkflow        INT           NOT NULL,
    Descrizione       NVARCHAR(100) NULL,
    Parametri         NVARCHAR(MAX) NULL,           -- JSON, override sul workflow
    GruppoConcorrenza NVARCHAR(50)  NULL,           -- mutua esclusione (un run alla volta nel gruppo)
    Note              NVARCHAR(MAX) NULL,
    OrizzonteGiorni   INT           NOT NULL CONSTRAINT DF_WF_PianMaster_Oriz DEFAULT 30,
    DataOraFinale     DATETIME2(0)  NULL,           -- fine validità della regola
    Sospesa           BIT           NOT NULL CONSTRAINT DF_WF_PianMaster_Sosp DEFAULT 0,
    Attiva            BIT           NOT NULL CONSTRAINT DF_WF_PianMaster_Att DEFAULT 1,
    DataCreazione     DATETIME2(0)  NOT NULL CONSTRAINT DF_WF_PianMaster_DtCre DEFAULT SYSUTCDATETIME(),
    DataModifica      DATETIME2(0)  NOT NULL CONSTRAINT DF_WF_PianMaster_DtMod DEFAULT SYSUTCDATETIME(),
    DataCancellazione DATETIME2(0)  NULL,           -- soft-delete
    CONSTRAINT FK_WF_PianMaster_Workflow FOREIGN KEY (IdWorkflow)
        REFERENCES dbo.WF_Workflow(IdWorkflow),
    CONSTRAINT CK_WF_PianMaster_Param CHECK (Parametri IS NULL OR ISJSON(Parametri) = 1)
);
GO

/* ---------- Dettaglio: righe di ricorrenza (cron / one-shot) --------------- */
IF OBJECT_ID('dbo.WF_PianificazioneDettaglio') IS NULL
CREATE TABLE dbo.WF_PianificazioneDettaglio (
    IdDettaglio      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_PianDettaglio PRIMARY KEY,
    IdPianificazione INT           NOT NULL,
    TipoRicorrenza   NVARCHAR(10)  NOT NULL,        -- 'CRON' | 'ONESHOT'
    CronExpr         NVARCHAR(120) NULL,            -- se CRON
    DataOraSingola   DATETIME2(0)  NULL,            -- se ONESHOT
    DataOraIniziale  DATETIME2(0)  NULL,            -- inizio validità di questa riga
    Priorita         INT           NOT NULL CONSTRAINT DF_WF_PianDet_Prio DEFAULT 0,
    Parametri        NVARCHAR(MAX) NULL,
    Attiva           BIT           NOT NULL CONSTRAINT DF_WF_PianDet_Att DEFAULT 1,
    CONSTRAINT FK_WF_PianDet_Master FOREIGN KEY (IdPianificazione)
        REFERENCES dbo.WF_PianificazioneMaster(IdPianificazione) ON DELETE CASCADE,
    CONSTRAINT CK_WF_PianDet_Tipo CHECK (TipoRicorrenza IN ('CRON', 'ONESHOT')),
    CONSTRAINT CK_WF_PianDet_Param CHECK (Parametri IS NULL OR ISJSON(Parametri) = 1)
);
GO

/* ---------- Esecuzioni: occorrenze previste + storico (≈ StepSchedulati) --- */
IF OBJECT_ID('dbo.WF_Esecuzione') IS NULL
CREATE TABLE dbo.WF_Esecuzione (
    IdEsecuzione      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_Esecuzione PRIMARY KEY,
    IdPianificazione  INT           NULL,           -- NULL se lancio ad-hoc (API/MANUALE)
    IdDettaglio       INT           NULL,
    IdWorkflow        INT           NOT NULL,
    Parametri         NVARCHAR(MAX) NULL,
    DataOraPrevista   DATETIME2(0)  NOT NULL,        -- spostabile = "muovi l'occorrenza"
    Stato             INT           NOT NULL CONSTRAINT DF_WF_Esec_Stato DEFAULT 0,
    Origine           NVARCHAR(15)  NOT NULL CONSTRAINT DF_WF_Esec_Orig DEFAULT 'SCHEDULER',
    GruppoConcorrenza NVARCHAR(50)  NULL,
    Festivo           BIT           NOT NULL CONSTRAINT DF_WF_Esec_Fest DEFAULT 0,
    InizioUtc         DATETIME2(0)  NULL,
    FineUtc           DATETIME2(0)  NULL,
    MachineName       NVARCHAR(64)  NULL,            -- quale istanza engine l'ha eseguita
    NomeUtente        NVARCHAR(128) NULL,
    Avanzamento       INT           NOT NULL CONSTRAINT DF_WF_Esec_Avz DEFAULT 0,
    Esito             NVARCHAR(MAX) NULL,
    DataCreazione     DATETIME2(0)  NOT NULL CONSTRAINT DF_WF_Esec_DtCre DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_WF_Esec_Workflow FOREIGN KEY (IdWorkflow)
        REFERENCES dbo.WF_Workflow(IdWorkflow),
    CONSTRAINT FK_WF_Esec_Pian FOREIGN KEY (IdPianificazione)
        REFERENCES dbo.WF_PianificazioneMaster(IdPianificazione),
    CONSTRAINT FK_WF_Esec_Det FOREIGN KEY (IdDettaglio)
        REFERENCES dbo.WF_PianificazioneDettaglio(IdDettaglio),
    CONSTRAINT FK_WF_Esec_Stato FOREIGN KEY (Stato)
        REFERENCES dbo.WF_StatoEsecuzione(Codice),
    CONSTRAINT CK_WF_Esec_Param CHECK (Parametri IS NULL OR ISJSON(Parametri) = 1),
    CONSTRAINT CK_WF_Esec_Orig CHECK (Origine IN ('SCHEDULER', 'API', 'MANUALE'))
);
GO
-- anti-doppione sulle occorrenze materializzate da una stessa riga di ricorrenza
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_WF_Esec_Occorrenza'
               AND object_id = OBJECT_ID('dbo.WF_Esecuzione'))
    CREATE UNIQUE INDEX UX_WF_Esec_Occorrenza
        ON dbo.WF_Esecuzione (IdDettaglio, DataOraPrevista) WHERE IdDettaglio IS NOT NULL;
GO
-- poll dello scheduler: stato + quando
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WF_Esec_StatoData'
               AND object_id = OBJECT_ID('dbo.WF_Esecuzione'))
    CREATE INDEX IX_WF_Esec_StatoData ON dbo.WF_Esecuzione (Stato, DataOraPrevista);
GO

/* ---------- Log riga-per-riga di un'esecuzione ----------------------------- */
IF OBJECT_ID('dbo.WF_EsecuzioneLog') IS NULL
CREATE TABLE dbo.WF_EsecuzioneLog (
    IdLog        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_WF_EsecLog PRIMARY KEY,
    IdEsecuzione INT           NOT NULL,
    IdStep       INT           NULL,
    Sequenza     INT           NOT NULL,
    Livello      NVARCHAR(10)  NOT NULL CONSTRAINT DF_WF_EsecLog_Liv DEFAULT 'INFO',
    Messaggio    NVARCHAR(MAX) NULL,
    NumRecord    INT           NULL,
    TimestampUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_WF_EsecLog_Ts DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_WF_EsecLog_Esec FOREIGN KEY (IdEsecuzione)
        REFERENCES dbo.WF_Esecuzione(IdEsecuzione) ON DELETE CASCADE,
    CONSTRAINT FK_WF_EsecLog_Step FOREIGN KEY (IdStep)
        REFERENCES dbo.WF_WorkflowStep(IdStep),
    CONSTRAINT CK_WF_EsecLog_Liv CHECK (Livello IN ('INFO', 'WARN', 'ERRORE'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WF_EsecLog_Esec'
               AND object_id = OBJECT_ID('dbo.WF_EsecuzioneLog'))
    CREATE INDEX IX_WF_EsecLog_Esec ON dbo.WF_EsecuzioneLog (IdEsecuzione, Sequenza);
GO

/* ---------- Vista storico esecuzioni (per la UI) -------------------------- */
CREATE OR ALTER VIEW dbo.WF_vw_Esecuzione AS
SELECT e.IdEsecuzione, e.IdWorkflow, w.Nome AS NomeWorkflow,
       e.IdPianificazione, e.IdDettaglio, e.DataOraPrevista,
       e.Stato, st.Nome AS StatoNome, e.Origine, e.GruppoConcorrenza,
       e.InizioUtc, e.FineUtc, e.MachineName, e.NomeUtente, e.Avanzamento,
       e.Esito, e.Parametri, e.DataCreazione
FROM dbo.WF_Esecuzione e
JOIN dbo.WF_Workflow w        ON w.IdWorkflow = e.IdWorkflow
JOIN dbo.WF_StatoEsecuzione st ON st.Codice = e.Stato;
GO


/* ##########################################################################
   8) SP DI ESECUZIONE (lifecycle del run; usate da engine e API)
   ######################################################################## */

/* Crea un'esecuzione (ad-hoc da API/MANUALE, o materializzata). Stato iniziale 0. */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Crea
    @IdWorkflow        INT,
    @Origine           NVARCHAR(15)  = 'MANUALE',
    @Parametri         NVARCHAR(MAX) = NULL,
    @DataOraPrevista   DATETIME2(0)  = NULL,
    @GruppoConcorrenza NVARCHAR(50)  = NULL,
    @NomeUtente        NVARCHAR(128) = NULL,
    @IdPianificazione  INT           = NULL,
    @IdDettaglio       INT           = NULL,
    @IdEsecuzione      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Parametri IS NOT NULL AND ISJSON(@Parametri) <> 1
        RAISERROR('WF_usp_Esecuzione_Crea: @Parametri non è JSON valido.', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM dbo.WF_Workflow WHERE IdWorkflow = @IdWorkflow)
        RAISERROR('WF_usp_Esecuzione_Crea: Workflow %d inesistente.', 16, 1, @IdWorkflow);

    INSERT INTO dbo.WF_Esecuzione
        (IdPianificazione, IdDettaglio, IdWorkflow, Parametri, DataOraPrevista,
         Stato, Origine, GruppoConcorrenza, NomeUtente)
    VALUES
        (@IdPianificazione, @IdDettaglio, @IdWorkflow, @Parametri,
         ISNULL(@DataOraPrevista, SYSUTCDATETIME()), 0, @Origine, @GruppoConcorrenza, @NomeUtente);

    SET @IdEsecuzione = SCOPE_IDENTITY();
END
GO

/* Segna l'inizio del run (Stato -> IN_ESECUZIONE). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Inizia
    @IdEsecuzione INT,
    @MachineName  NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.WF_Esecuzione
       SET Stato = 1, InizioUtc = SYSUTCDATETIME(),
           MachineName = ISNULL(@MachineName, MachineName), Avanzamento = 0
     WHERE IdEsecuzione = @IdEsecuzione;
    IF @@ROWCOUNT = 0
        RAISERROR('WF_usp_Esecuzione_Inizia: IdEsecuzione %d inesistente.', 16, 1, @IdEsecuzione);
END
GO

/* Chiude il run con esito (2=ESEGUITA, 3=ERRORE, ...). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Termina
    @IdEsecuzione INT,
    @Stato        INT,
    @Esito        NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.WF_StatoEsecuzione WHERE Codice = @Stato)
        RAISERROR('WF_usp_Esecuzione_Termina: Stato %d inesistente.', 16, 1, @Stato);
    UPDATE dbo.WF_Esecuzione
       SET Stato = @Stato, FineUtc = SYSUTCDATETIME(), Esito = @Esito,
           Avanzamento = CASE WHEN @Stato = 2 THEN 100 ELSE Avanzamento END
     WHERE IdEsecuzione = @IdEsecuzione;
    IF @@ROWCOUNT = 0
        RAISERROR('WF_usp_Esecuzione_Termina: IdEsecuzione %d inesistente.', 16, 1, @IdEsecuzione);
END
GO

/* Aggiorna l'avanzamento (%). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Avanzamento
    @IdEsecuzione INT,
    @Avanzamento  INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.WF_Esecuzione SET Avanzamento = @Avanzamento WHERE IdEsecuzione = @IdEsecuzione;
END
GO

/* Annulla manualmente un'esecuzione pianificata o in corso. */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Annulla
    @IdEsecuzione INT,
    @NomeUtente   NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.WF_Esecuzione
       SET Stato = 4, FineUtc = SYSUTCDATETIME(),
           Esito = CONCAT('Annullata da ', ISNULL(@NomeUtente, '?'))
     WHERE IdEsecuzione = @IdEsecuzione AND Stato IN (0, 1);
    IF @@ROWCOUNT = 0
        RAISERROR('WF_usp_Esecuzione_Annulla: esecuzione inesistente o non annullabile.', 16, 1);
END
GO

/* Aggiunge una riga di log all'esecuzione (numerazione Sequenza automatica). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_EsecuzioneLog_Add
    @IdEsecuzione INT,
    @IdStep       INT           = NULL,
    @Livello      NVARCHAR(10)  = 'INFO',
    @Messaggio    NVARCHAR(MAX) = NULL,
    @NumRecord    INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @seq INT = (SELECT ISNULL(MAX(Sequenza), 0) + 1
                        FROM dbo.WF_EsecuzioneLog WHERE IdEsecuzione = @IdEsecuzione);
    INSERT INTO dbo.WF_EsecuzioneLog (IdEsecuzione, IdStep, Sequenza, Livello, Messaggio, NumRecord)
    VALUES (@IdEsecuzione, @IdStep, @seq, @Livello, @Messaggio, @NumRecord);
END
GO


/* ##########################################################################
   9) SP DELLO SCHEDULER (materializzazione occorrenze + claim)
   ######################################################################## */

/* Inserisce una occorrenza PIANIFICATA se non esiste gia (idempotente sulla
   coppia IdDettaglio + DataOraPrevista). Chiamata dallo scheduler (Node calcola
   le date dal cron). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Pianifica
    @IdPianificazione  INT,
    @IdDettaglio       INT,
    @IdWorkflow        INT,
    @DataOraPrevista   DATETIME2(0),
    @GruppoConcorrenza NVARCHAR(50)  = NULL,
    @Parametri         NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.WF_Esecuzione
                   WHERE IdDettaglio = @IdDettaglio AND DataOraPrevista = @DataOraPrevista)
        INSERT INTO dbo.WF_Esecuzione
            (IdPianificazione, IdDettaglio, IdWorkflow, Parametri, DataOraPrevista,
             Stato, Origine, GruppoConcorrenza)
        VALUES
            (@IdPianificazione, @IdDettaglio, @IdWorkflow, @Parametri, @DataOraPrevista,
             0, 'SCHEDULER', @GruppoConcorrenza);
END
GO

/* Prende atomicamente la prossima occorrenza scaduta eseguibile e la porta
   IN_ESECUZIONE. Rispetta i gruppi di concorrenza (un run alla volta per gruppo)
   e salta le pianificazioni sospese. Serializzata via sp_getapplock per essere
   sicura anche con piu istanze scheduler. Restituisce la riga presa (o vuoto). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Claim
    @MachineName NVARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @IdEsecuzione INT = NULL;
    BEGIN TRY
        BEGIN TRAN;
        EXEC sp_getapplock @Resource = 'WF_Esecuzione_Claim',
                           @LockMode = 'Exclusive', @LockOwner = 'Transaction';

        ;WITH cte AS (
            SELECT TOP 1 e.IdEsecuzione
            FROM dbo.WF_Esecuzione e
            WHERE e.Stato = 0
              AND e.DataOraPrevista <= SYSUTCDATETIME()
              AND (e.GruppoConcorrenza IS NULL OR NOT EXISTS (
                    SELECT 1 FROM dbo.WF_Esecuzione g
                    WHERE g.Stato = 1 AND g.GruppoConcorrenza = e.GruppoConcorrenza))
              AND NOT EXISTS (
                    SELECT 1 FROM dbo.WF_PianificazioneMaster m
                    WHERE m.IdPianificazione = e.IdPianificazione AND m.Sospesa = 1)
            ORDER BY e.DataOraPrevista, e.IdEsecuzione
        )
        UPDATE e
           SET e.Stato = 1, e.InizioUtc = SYSUTCDATETIME(), e.MachineName = @MachineName,
               @IdEsecuzione = e.IdEsecuzione
        FROM dbo.WF_Esecuzione e
        JOIN cte ON cte.IdEsecuzione = e.IdEsecuzione;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @m NVARCHAR(2048) = ERROR_MESSAGE(), @s INT = ERROR_SEVERITY(), @t INT = ERROR_STATE();
        RAISERROR(@m, @s, @t);
    END CATCH

    SELECT IdEsecuzione, IdWorkflow, Parametri, GruppoConcorrenza
    FROM dbo.WF_Esecuzione WHERE IdEsecuzione = @IdEsecuzione;
END
GO


/* ##########################################################################
   10) SP DI GESTIONE PIANIFICAZIONI (per la UI)
   ######################################################################## */

/* Upsert del master: se @IdPianificazione è NULL inserisce, altrimenti aggiorna. */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Pianificazione_Salva
    @IdPianificazione  INT           = NULL OUTPUT,
    @IdWorkflow        INT,
    @Descrizione       NVARCHAR(100) = NULL,
    @Parametri         NVARCHAR(MAX) = NULL,
    @GruppoConcorrenza NVARCHAR(50)  = NULL,
    @Note              NVARCHAR(MAX) = NULL,
    @OrizzonteGiorni   INT           = 30,
    @DataOraFinale     DATETIME2(0)  = NULL,
    @Sospesa           BIT           = 0,
    @Attiva            BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @Parametri IS NOT NULL AND ISJSON(@Parametri) <> 1
        RAISERROR('WF_usp_Pianificazione_Salva: @Parametri non è JSON valido.', 16, 1);

    IF @IdPianificazione IS NULL
    BEGIN
        INSERT INTO dbo.WF_PianificazioneMaster
            (IdWorkflow, Descrizione, Parametri, GruppoConcorrenza, Note,
             OrizzonteGiorni, DataOraFinale, Sospesa, Attiva)
        VALUES
            (@IdWorkflow, @Descrizione, @Parametri, @GruppoConcorrenza, @Note,
             ISNULL(@OrizzonteGiorni, 30), @DataOraFinale, ISNULL(@Sospesa, 0), ISNULL(@Attiva, 1));
        SET @IdPianificazione = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE dbo.WF_PianificazioneMaster
           SET Descrizione = @Descrizione, Parametri = @Parametri,
               GruppoConcorrenza = @GruppoConcorrenza, Note = @Note,
               OrizzonteGiorni = ISNULL(@OrizzonteGiorni, OrizzonteGiorni),
               DataOraFinale = @DataOraFinale,
               Sospesa = ISNULL(@Sospesa, Sospesa), Attiva = ISNULL(@Attiva, Attiva),
               DataModifica = SYSUTCDATETIME()
         WHERE IdPianificazione = @IdPianificazione;
END
GO

/* Soft-delete del master + rimozione delle occorrenze future ancora pianificate. */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Pianificazione_Elimina
    @IdPianificazione INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE FROM dbo.WF_Esecuzione
         WHERE IdPianificazione = @IdPianificazione AND Stato = 0;  -- solo le future
        UPDATE dbo.WF_PianificazioneMaster
           SET Attiva = 0, DataCancellazione = SYSUTCDATETIME()
         WHERE IdPianificazione = @IdPianificazione;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @m NVARCHAR(2048) = ERROR_MESSAGE(), @s INT = ERROR_SEVERITY(), @t INT = ERROR_STATE();
        RAISERROR(@m, @s, @t);
    END CATCH
END
GO

/* Upsert di una riga di ricorrenza (cron / one-shot). */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Dettaglio_Salva
    @IdDettaglio      INT           = NULL OUTPUT,
    @IdPianificazione INT,
    @TipoRicorrenza   NVARCHAR(10),
    @CronExpr         NVARCHAR(120) = NULL,
    @DataOraSingola   DATETIME2(0)  = NULL,
    @Priorita         INT           = 0,
    @Attiva           BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @TipoRicorrenza NOT IN ('CRON', 'ONESHOT')
        RAISERROR('WF_usp_Dettaglio_Salva: TipoRicorrenza deve essere CRON o ONESHOT.', 16, 1);

    IF @IdDettaglio IS NULL
    BEGIN
        INSERT INTO dbo.WF_PianificazioneDettaglio
            (IdPianificazione, TipoRicorrenza, CronExpr, DataOraSingola, Priorita, Attiva)
        VALUES
            (@IdPianificazione, @TipoRicorrenza, @CronExpr, @DataOraSingola, ISNULL(@Priorita, 0), ISNULL(@Attiva, 1));
        SET @IdDettaglio = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE dbo.WF_PianificazioneDettaglio
           SET TipoRicorrenza = @TipoRicorrenza, CronExpr = @CronExpr,
               DataOraSingola = @DataOraSingola, Priorita = ISNULL(@Priorita, Priorita),
               Attiva = ISNULL(@Attiva, Attiva)
         WHERE IdDettaglio = @IdDettaglio;
END
GO

/* Elimina una riga di ricorrenza + le sue occorrenze future ancora pianificate. */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Dettaglio_Elimina
    @IdDettaglio INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE FROM dbo.WF_Esecuzione WHERE IdDettaglio = @IdDettaglio AND Stato = 0;
        DELETE FROM dbo.WF_PianificazioneDettaglio WHERE IdDettaglio = @IdDettaglio;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @m NVARCHAR(2048) = ERROR_MESSAGE(), @s INT = ERROR_SEVERITY(), @t INT = ERROR_STATE();
        RAISERROR(@m, @s, @t);
    END CATCH
END
GO

/* ----------------------------------------------------------------------------
   WF_usp_Workflow_Delete
   Elimina un workflow e tutti i suoi step/sottopassi. La DELETE massiva sugli
   step è set-based e soddisfa la self-FK; poi elimina l'header.
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.WF_usp_Workflow_Delete
    @IdWorkflow INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE FROM dbo.WF_WorkflowStep WHERE IdWorkflow = @IdWorkflow;
        DELETE FROM dbo.WF_Workflow     WHERE IdWorkflow = @IdWorkflow;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE(),
                @sev INT = ERROR_SEVERITY(),
                @sta INT = ERROR_STATE();
        RAISERROR(@msg, @sev, @sta);
    END CATCH
END
GO
GO

-- ============================================================
-- >>> WF_stored_cascata.sql
-- ============================================================
-- Schedulatore: le stored che cancellano o rimpiazzano, riviste per convivere
-- con pianificazioni e storico (le FK di WF_PianificazioneMaster, WF_Esecuzione
-- e WF_EsecuzioneLog verso workflow e step non sono a cascata).
--   * Workflow_Import con @SovrascriviSeEsiste: riscrive SUL POSTO (stesso
--     IdWorkflow): testata aggiornata, step rifatti; pianificazioni e storico restano.
--   * Workflow_Delete: cascata esplicita (esecuzioni col log, pianificazioni con
--     le ricorrenze, step, workflow). La pagina lo dice prima di confermare.
--   * Step_Delete / Import: il log delle vecchie esecuzioni resta ma perde il
--     riferimento allo step (IdStep = NULL), il testo del messaggio basta.
--   * Dettaglio_Elimina: le esecuzioni gia' fatte di quella ricorrenza restano
--     nello storico agganciate alla pianificazione, non piu' alla ricorrenza.
USE DeliveryDB;
GO

CREATE OR ALTER PROCEDURE dbo.WF_usp_Workflow_Import
    @Nome                  NVARCHAR(255),
    @NStepDichiarati       INT           = NULL,
    @DirectoryOutput       NVARCHAR(500) = NULL,
    @NomeFileLog           NVARCHAR(500) = NULL,
    @NomeFileLogResult     NVARCHAR(500) = NULL,
    @PausaTraStepMS        INT           = 0,
    @ApriDirectoryFinale   BIT           = 0,
    @LoggaInizioOperazione BIT           = 1,
    @VariabiliGlobali      NVARCHAR(MAX) = NULL,   -- JSON array (testo)
    @ParametriExtra        NVARCHAR(MAX) = NULL,   -- JSON object (testo)
    @FileOrigine           NVARCHAR(500) = NULL,
    @HashOrigine           VARBINARY(32) = NULL,
    @SovrascriviSeEsiste   BIT           = 0,
    @Steps                 dbo.WF_udt_StepList READONLY,
    @IdWorkflow            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;

        DECLARE @IdEsistente INT = (SELECT IdWorkflow FROM dbo.WF_Workflow WHERE Nome = @Nome);
        IF @IdEsistente IS NOT NULL AND @SovrascriviSeEsiste = 1
        BEGIN
            /* stesso workflow, contenuto nuovo: testata aggiornata, step rifatti */
            UPDATE dbo.WF_Workflow
               SET NStepDichiarati = @NStepDichiarati, DirectoryOutput = @DirectoryOutput,
                   NomeFileLog = @NomeFileLog, NomeFileLogResult = @NomeFileLogResult,
                   PausaTraStepMS = ISNULL(@PausaTraStepMS, 0),
                   ApriDirectoryFinale = ISNULL(@ApriDirectoryFinale, 0),
                   LoggaInizioOperazione = ISNULL(@LoggaInizioOperazione, 1),
                   VariabiliGlobali = @VariabiliGlobali, ParametriExtra = @ParametriExtra,
                   FileOrigine = @FileOrigine, HashOrigine = @HashOrigine,
                   DataModifica = SYSUTCDATETIME()
             WHERE IdWorkflow = @IdEsistente;
            UPDATE l SET l.IdStep = NULL
              FROM dbo.WF_EsecuzioneLog l JOIN dbo.WF_WorkflowStep s ON s.IdStep = l.IdStep
             WHERE s.IdWorkflow = @IdEsistente;
            DELETE FROM dbo.WF_WorkflowStep WHERE IdWorkflow = @IdEsistente;
            SET @IdWorkflow = @IdEsistente;
        END
        ELSE
        BEGIN
            /* nuovo (se il nome esiste gia' salta la UNIQUE: e' l'errore giusto) */
            INSERT INTO dbo.WF_Workflow
                (Nome, NStepDichiarati, DirectoryOutput, NomeFileLog, NomeFileLogResult,
                 PausaTraStepMS, ApriDirectoryFinale, LoggaInizioOperazione,
                 VariabiliGlobali, ParametriExtra, FileOrigine, HashOrigine)
            VALUES
                (@Nome, @NStepDichiarati, @DirectoryOutput, @NomeFileLog, @NomeFileLogResult,
                 ISNULL(@PausaTraStepMS, 0), ISNULL(@ApriDirectoryFinale, 0),
                 ISNULL(@LoggaInizioOperazione, 1),
                 @VariabiliGlobali, @ParametriExtra, @FileOrigine, @HashOrigine);
            SET @IdWorkflow = SCOPE_IDENTITY();
        END

        /* ---- step: dal TVP (id provvisori) alle righe vere, per livelli ---- */
        DECLARE @StepsLocal TABLE (
            TempId INT PRIMARY KEY, ParentTempId INT NULL, Ordine INT, NomeSezione NVARCHAR(120),
            Tipo NVARCHAR(50), EsciSuErrore BIT, EseguiPasso BIT, Attivo BIT, Parametri NVARCHAR(MAX));
        INSERT INTO @StepsLocal
            (TempId, ParentTempId, Ordine, NomeSezione, Tipo, EsciSuErrore, EseguiPasso, Attivo, Parametri)
        SELECT TempId, ParentTempId, Ordine, NomeSezione, Tipo, EsciSuErrore, EseguiPasso, Attivo, ISNULL(Parametri, N'{}')
        FROM @Steps;
        DECLARE @Map TABLE (TempId INT PRIMARY KEY, IdStep INT);
        DECLARE @Inseriti INT = 1;
        WHILE EXISTS (SELECT 1 FROM @StepsLocal s WHERE NOT EXISTS (SELECT 1 FROM @Map m WHERE m.TempId = s.TempId))
        BEGIN
            MERGE dbo.WF_WorkflowStep AS tgt
            USING (
                SELECT s.TempId, s.Ordine, s.NomeSezione, s.Tipo, s.EsciSuErrore, s.EseguiPasso, s.Attivo, s.Parametri,
                       pm.IdStep AS IdStepPadre
                FROM @StepsLocal s
                LEFT JOIN @Map pm ON pm.TempId = s.ParentTempId
                WHERE NOT EXISTS (SELECT 1 FROM @Map m WHERE m.TempId = s.TempId)
                  AND (s.ParentTempId IS NULL OR pm.IdStep IS NOT NULL)
            ) AS src
            ON 1 = 0   -- sempre INSERT: il MERGE serve per l'OUTPUT delle colonne sorgente
            WHEN NOT MATCHED THEN
                INSERT (IdWorkflow, IdStepPadre, Ordine, NomeSezione, Tipo, EsciSuErrore, EseguiPasso, Attivo, Parametri)
                VALUES (@IdWorkflow, src.IdStepPadre, src.Ordine, src.NomeSezione, src.Tipo,
                        src.EsciSuErrore, src.EseguiPasso, src.Attivo, src.Parametri)
            OUTPUT src.TempId, inserted.IdStep INTO @Map (TempId, IdStep);
            SET @Inseriti = @@ROWCOUNT;
            IF @Inseriti = 0
                RAISERROR('WF_usp_Workflow_Import: sottopassi orfani o ciclo nei parentTempId.', 16, 1);
        END
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE(), @sev INT = ERROR_SEVERITY(), @sta INT = ERROR_STATE();
        RAISERROR(@msg, @sev, @sta);
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.WF_usp_Workflow_Delete
    @IdWorkflow INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE FROM dbo.WF_Esecuzione           WHERE IdWorkflow = @IdWorkflow;   -- il log va via a cascata
        DELETE FROM dbo.WF_PianificazioneMaster WHERE IdWorkflow = @IdWorkflow;   -- le ricorrenze a cascata
        DELETE FROM dbo.WF_WorkflowStep         WHERE IdWorkflow = @IdWorkflow;
        DELETE FROM dbo.WF_Workflow             WHERE IdWorkflow = @IdWorkflow;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE(), @sev INT = ERROR_SEVERITY(), @sta INT = ERROR_STATE();
        RAISERROR(@msg, @sev, @sta);
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.WF_usp_Step_Delete
    @IdStep INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @ToDel TABLE (IdStep INT PRIMARY KEY);
        ;WITH D AS (
            SELECT IdStep FROM dbo.WF_WorkflowStep WHERE IdStep = @IdStep
            UNION ALL
            SELECT s.IdStep FROM dbo.WF_WorkflowStep s JOIN D ON s.IdStepPadre = D.IdStep
        )
        INSERT INTO @ToDel SELECT IdStep FROM D;
        UPDATE dbo.WF_EsecuzioneLog SET IdStep = NULL WHERE IdStep IN (SELECT IdStep FROM @ToDel);
        -- tutto il sottoalbero in una DELETE sola: la self-FK e' verificata a fine istruzione
        DELETE FROM dbo.WF_WorkflowStep WHERE IdStep IN (SELECT IdStep FROM @ToDel);
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @m NVARCHAR(2048) = ERROR_MESSAGE(), @s INT = ERROR_SEVERITY(), @t INT = ERROR_STATE();
        RAISERROR(@m, @s, @t);
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.WF_usp_Dettaglio_Elimina
    @IdDettaglio INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE FROM dbo.WF_Esecuzione WHERE IdDettaglio = @IdDettaglio AND Stato = 0;   -- le future
        UPDATE dbo.WF_Esecuzione SET IdDettaglio = NULL WHERE IdDettaglio = @IdDettaglio; -- lo storico resta
        DELETE FROM dbo.WF_PianificazioneDettaglio WHERE IdDettaglio = @IdDettaglio;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @m NVARCHAR(2048) = ERROR_MESSAGE(), @s INT = ERROR_SEVERITY(), @t INT = ERROR_STATE();
        RAISERROR(@m, @s, @t);
    END CATCH
END
GO
GO

-- ============================================================
-- >>> WF_stored_raiserror.sql
-- ============================================================
-- RAISERROR con severita' 16 dentro una stored NON ferma l'esecuzione: le
-- istruzioni dopo vengono eseguite lo stesso (cosi' un nome vuoto veniva
-- rifiutato... e inserito). Qui ogni controllo e' seguito da RETURN.
-- Contiene anche WF_usp_Workflow_Salva (testata scritta dalla pagina: nuovo
-- workflow vuoto o modifica; gli step si aggiungono dopo con WF_usp_Step_Insert).
USE DeliveryDB;
GO
CREATE OR ALTER PROCEDURE dbo.WF_usp_Workflow_Salva
    @IdWorkflow            INT            = NULL OUTPUT,
    @Nome                  NVARCHAR(255),
    @Descrizione           NVARCHAR(1000) = NULL,
    @DirectoryOutput       NVARCHAR(500)  = NULL,
    @NomeFileLog           NVARCHAR(500)  = NULL,
    @NomeFileLogResult     NVARCHAR(500)  = NULL,
    @PausaTraStepMS        INT            = NULL,
    @ApriDirectoryFinale   BIT            = NULL,
    @LoggaInizioOperazione BIT            = NULL,
    @VariabiliGlobali      NVARCHAR(MAX)  = NULL,   -- JSON array (testo)
    @Attivo                BIT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Nome = LTRIM(RTRIM(ISNULL(@Nome, '')));
    IF @Nome = ''
    BEGIN
        RAISERROR('WF_usp_Workflow_Salva: il nome del workflow e'' obbligatorio.', 16, 1);
        RETURN;
    END
    IF @VariabiliGlobali IS NOT NULL AND ISJSON(@VariabiliGlobali) <> 1
    BEGIN
        RAISERROR('WF_usp_Workflow_Salva: @VariabiliGlobali non e'' JSON valido.', 16, 1);
        RETURN;
    END
    IF @IdWorkflow IS NULL
    BEGIN
        INSERT INTO dbo.WF_Workflow
            (Nome, Descrizione, DirectoryOutput, NomeFileLog, NomeFileLogResult, PausaTraStepMS,
             ApriDirectoryFinale, LoggaInizioOperazione, VariabiliGlobali, ParametriExtra, Attivo)
        VALUES
            (@Nome, @Descrizione, @DirectoryOutput, @NomeFileLog, @NomeFileLogResult, ISNULL(@PausaTraStepMS, 0),
             ISNULL(@ApriDirectoryFinale, 0), ISNULL(@LoggaInizioOperazione, 1), ISNULL(@VariabiliGlobali, N'[]'), N'{}', ISNULL(@Attivo, 1));
        SET @IdWorkflow = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.WF_Workflow
           SET Nome = @Nome, Descrizione = @Descrizione, DirectoryOutput = @DirectoryOutput,
               NomeFileLog = @NomeFileLog, NomeFileLogResult = @NomeFileLogResult,
               PausaTraStepMS = ISNULL(@PausaTraStepMS, PausaTraStepMS),
               ApriDirectoryFinale = ISNULL(@ApriDirectoryFinale, ApriDirectoryFinale),
               LoggaInizioOperazione = ISNULL(@LoggaInizioOperazione, LoggaInizioOperazione),
               VariabiliGlobali = ISNULL(@VariabiliGlobali, VariabiliGlobali),
               Attivo = ISNULL(@Attivo, Attivo),
               DataModifica = SYSUTCDATETIME()
         WHERE IdWorkflow = @IdWorkflow;
        IF @@ROWCOUNT = 0 RAISERROR('WF_usp_Workflow_Salva: workflow %d inesistente.', 16, 1, @IdWorkflow);
    END
END
GO

CREATE OR ALTER PROCEDURE dbo.WF_usp_Esecuzione_Crea
    @IdWorkflow        INT,
    @Origine           NVARCHAR(15)  = 'MANUALE',
    @Parametri         NVARCHAR(MAX) = NULL,
    @DataOraPrevista   DATETIME2(0)  = NULL,
    @GruppoConcorrenza NVARCHAR(50)  = NULL,
    @NomeUtente        NVARCHAR(128) = NULL,
    @IdPianificazione  INT           = NULL,
    @IdDettaglio       INT           = NULL,
    @IdEsecuzione      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Parametri IS NOT NULL AND ISJSON(@Parametri) <> 1
    BEGIN
        RAISERROR('WF_usp_Esecuzione_Crea: @Parametri non e'' JSON valido.', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.WF_Workflow WHERE IdWorkflow = @IdWorkflow)
    BEGIN
        RAISERROR('WF_usp_Esecuzione_Crea: Workflow %d inesistente.', 16, 1, @IdWorkflow);
        RETURN;
    END
    INSERT INTO dbo.WF_Esecuzione
        (IdPianificazione, IdDettaglio, IdWorkflow, Parametri, DataOraPrevista,
         Stato, Origine, GruppoConcorrenza, NomeUtente)
    VALUES
        (@IdPianificazione, @IdDettaglio, @IdWorkflow, @Parametri,
         ISNULL(@DataOraPrevista, SYSUTCDATETIME()), 0, @Origine, @GruppoConcorrenza, @NomeUtente);
    SET @IdEsecuzione = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE dbo.WF_usp_Pianificazione_Salva
    @IdPianificazione  INT           = NULL OUTPUT,
    @IdWorkflow        INT,
    @Descrizione       NVARCHAR(100) = NULL,
    @Parametri         NVARCHAR(MAX) = NULL,
    @GruppoConcorrenza NVARCHAR(50)  = NULL,
    @Note              NVARCHAR(MAX) = NULL,
    @OrizzonteGiorni   INT           = 30,
    @DataOraFinale     DATETIME2(0)  = NULL,
    @Sospesa           BIT           = 0,
    @Attiva            BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @Parametri IS NOT NULL AND ISJSON(@Parametri) <> 1
    BEGIN
        RAISERROR('WF_usp_Pianificazione_Salva: @Parametri non e'' JSON valido.', 16, 1);
        RETURN;
    END
    IF @IdPianificazione IS NULL
    BEGIN
        INSERT INTO dbo.WF_PianificazioneMaster
            (IdWorkflow, Descrizione, Parametri, GruppoConcorrenza, Note,
             OrizzonteGiorni, DataOraFinale, Sospesa, Attiva)
        VALUES
            (@IdWorkflow, @Descrizione, @Parametri, @GruppoConcorrenza, @Note,
             ISNULL(@OrizzonteGiorni, 30), @DataOraFinale, ISNULL(@Sospesa, 0), ISNULL(@Attiva, 1));
        SET @IdPianificazione = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE dbo.WF_PianificazioneMaster
           SET Descrizione = @Descrizione, Parametri = @Parametri,
               GruppoConcorrenza = @GruppoConcorrenza, Note = @Note,
               OrizzonteGiorni = ISNULL(@OrizzonteGiorni, OrizzonteGiorni),
               DataOraFinale = @DataOraFinale,
               Sospesa = ISNULL(@Sospesa, Sospesa), Attiva = ISNULL(@Attiva, Attiva),
               DataModifica = SYSUTCDATETIME()
         WHERE IdPianificazione = @IdPianificazione;
END
GO

CREATE OR ALTER PROCEDURE dbo.WF_usp_Dettaglio_Salva
    @IdDettaglio      INT           = NULL OUTPUT,
    @IdPianificazione INT,
    @TipoRicorrenza   NVARCHAR(10),
    @CronExpr         NVARCHAR(120) = NULL,
    @DataOraSingola   DATETIME2(0)  = NULL,
    @Priorita         INT           = 0,
    @Attiva           BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @TipoRicorrenza NOT IN ('CRON', 'ONESHOT')
    BEGIN
        RAISERROR('WF_usp_Dettaglio_Salva: TipoRicorrenza deve essere CRON o ONESHOT.', 16, 1);
        RETURN;
    END
    IF @IdDettaglio IS NULL
    BEGIN
        INSERT INTO dbo.WF_PianificazioneDettaglio
            (IdPianificazione, TipoRicorrenza, CronExpr, DataOraSingola, Priorita, Attiva)
        VALUES
            (@IdPianificazione, @TipoRicorrenza, @CronExpr, @DataOraSingola, ISNULL(@Priorita, 0), ISNULL(@Attiva, 1));
        SET @IdDettaglio = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE dbo.WF_PianificazioneDettaglio
           SET TipoRicorrenza = @TipoRicorrenza, CronExpr = @CronExpr,
               DataOraSingola = @DataOraSingola, Priorita = ISNULL(@Priorita, Priorita),
               Attiva = ISNULL(@Attiva, Attiva)
         WHERE IdDettaglio = @IdDettaglio;
END
GO
GO

-- ============================================================
-- >>> WF_tipo_eseguipython.sql
-- ============================================================
-- Nuovo tipo di step: esecuzione di uno script Python (motore GecoMotore).
-- WF_TipoStep e' una lookup senza stored: si allinea come fa database.sql.
IF NOT EXISTS (SELECT 1 FROM dbo.WF_TipoStep WHERE Codice = 'ESEGUIPYTHON')
    INSERT INTO dbo.WF_TipoStep (Codice, Descrizione, SupportaSottopassi, Attivo)
    VALUES ('ESEGUIPYTHON', 'Esegue uno script Python (Script, Argomenti, directory, TimeoutSecondi)', 0, 1);
GO
GO

-- ============================================================
-- >>> WF_smb_lista_valori.sql
-- ============================================================
-- Credenziali della condivisione di rete usata dai workflow dello schedulatore:
-- il motore (servizio) apre la sessione SMB verso SERVER con USER e PASS.
-- Stessa forma di SMTP_SERVER; USER e PASS si compilano dalla pagina Lista Valori.
-- Altri server: Lista = 'SMB_SERVER_2', 'SMB_SERVER_3' ...
IF NOT EXISTS (SELECT 1 FROM dbo.LISTA_VALORI WHERE Lista = 'SMB_SERVER')
BEGIN
    EXEC dbo.AI_LISTA_VALORI_Save @Lista = 'SMB_SERVER', @Valore = 'SERVER', @Codice = '192.168.0.252', @Ordine = 1;
    EXEC dbo.AI_LISTA_VALORI_Save @Lista = 'SMB_SERVER', @Valore = 'USER',   @Codice = '', @Ordine = 2;
    EXEC dbo.AI_LISTA_VALORI_Save @Lista = 'SMB_SERVER', @Valore = 'PASS',   @Codice = '', @Ordine = 3;
END
GO
GO

-- ============================================================
-- >>> WF_menu.sql
-- ============================================================
-- Voci di menu dello schedulatore sotto Test - Sviluppo (1229): tweb non le
-- vede (nessuna Videata), la webapp le apre dal campo Link. Idempotente.
IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/schedulatore')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1229, @Text = 'Schedulatore',
        @Descrizione = 'Workflow dei file step: step, pianificazioni, esecuzioni',
        @Link = '/schedulatore', @Sorting = 13;
IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/schedulatore-storico')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1229, @Text = 'Schedulatore - agenda e storico',
        @Descrizione = 'Prossime esecuzioni pianificate e storico delle esecuzioni',
        @Link = '/schedulatore-storico', @Sorting = 14;
GO
GO

-- ============================================================
-- >>> SIM_tabelle.sql
-- ============================================================
-- Gestione delle SIM aziendali (WindTre): anagrafica, storico delle variazioni
-- di piano/stato e rilevazioni periodiche (consumi, credito) dal portale Wind.
-- Scritture solo via AI_SIM_*: la pagina salva l'anagrafica intera, l'import
-- dei file dell'operatore tocca solo i campi che arrivano da li'.
-- Idempotente. Il collegamento ai palmari oggi e' un testo (Palmare, SerialePalmare):
-- quando ci sara' la tabella dei palmari diventera' una chiave.
USE DeliveryDB;
GO

IF OBJECT_ID('dbo.SIM', 'U') IS NULL
CREATE TABLE dbo.SIM (
    IdSim            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SIM PRIMARY KEY,
    Numero           VARCHAR(20)   NOT NULL CONSTRAINT UQ_SIM_Numero UNIQUE,
    ICCID            VARCHAR(32)   NULL,
    Operatore        VARCHAR(30)   NOT NULL CONSTRAINT DF_SIM_Operatore DEFAULT ('WINDTRE'),
    Prodotto         VARCHAR(50)   NULL,          -- Mobile / Mobile Ricaricabile
    Stato            VARCHAR(20)   NOT NULL CONSTRAINT DF_SIM_Stato DEFAULT ('Attiva'),   -- Attiva / Sospesa / Cessata
    DataAttivazione  DATE          NULL,
    DataCessazione   DATE          NULL,
    PianoTariffario  VARCHAR(100)  NULL,          -- profilo corrente: l'ultima variazione
    IdFiliale        INT           NULL,          -- filiale che la gestisce
    IdUtente         INT           NULL,          -- dipendente a cui e' assegnata (UTENTI)
    AssegnataA       NVARCHAR(100) NULL,          -- oppure un testo (modem, sede, magazzino...)
    Palmare          NVARCHAR(50)  NULL,
    SerialePalmare   NVARCHAR(50)  NULL,
    Note             NVARCHAR(500) NULL,
    DataCreazione    DATETIME      NOT NULL CONSTRAINT DF_SIM_DataCreazione DEFAULT (GETDATE()),
    DataModifica     DATETIME      NULL,
    UtenteModifica   NVARCHAR(50)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SIM_ICCID')
    CREATE INDEX IX_SIM_ICCID ON dbo.SIM (ICCID);
GO

-- ogni cambio di piano o di stato: chi lo ha portato (import o pagina) e da cosa a cosa
IF OBJECT_ID('dbo.SIM_VARIAZIONI', 'U') IS NULL
CREATE TABLE dbo.SIM_VARIAZIONI (
    IdVariazione      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SIM_VARIAZIONI PRIMARY KEY,
    IdSim             INT           NOT NULL CONSTRAINT FK_SIM_VARIAZIONI_SIM REFERENCES dbo.SIM (IdSim) ON DELETE CASCADE,
    Data              DATE          NOT NULL,     -- data della variazione (rilevazione o inserimento)
    PianoTariffario   VARCHAR(100)  NULL,
    Stato             VARCHAR(20)   NULL,
    PianoPrecedente   VARCHAR(100)  NULL,
    StatoPrecedente   VARCHAR(20)   NULL,
    Origine           VARCHAR(30)   NOT NULL,     -- INIZIALE / IMPORT / MANUALE
    Note              NVARCHAR(500) NULL,
    DataRegistrazione DATETIME      NOT NULL CONSTRAINT DF_SIM_VARIAZIONI_Data DEFAULT (GETDATE()),
    Utente            NVARCHAR(50)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SIM_VARIAZIONI_Sim')
    CREATE INDEX IX_SIM_VARIAZIONI_Sim ON dbo.SIM_VARIAZIONI (IdSim, Data);
GO

-- la fotografia periodica dal portale Wind: consumi e credito a una data
IF OBJECT_ID('dbo.SIM_RILEVAZIONI', 'U') IS NULL
CREATE TABLE dbo.SIM_RILEVAZIONI (
    IdRilevazione    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SIM_RILEVAZIONI PRIMARY KEY,
    IdSim            INT           NOT NULL CONSTRAINT FK_SIM_RILEVAZIONI_SIM REFERENCES dbo.SIM (IdSim) ON DELETE CASCADE,
    DataRilevazione  DATE          NOT NULL,
    PianoTariffario  VARCHAR(100)  NULL,
    Stato            VARCHAR(30)   NULL,
    CreditoResiduo   DECIMAL(10,2) NULL,
    GbSoglia         DECIMAL(10,3) NULL,
    GbConsumati      DECIMAL(10,3) NULL,
    GbResidui        DECIMAL(10,3) NULL,
    PercResidua      DECIMAL(6,2)  NULL,
    PeriodoSoglia    VARCHAR(30)   NULL,
    FileOrigine      NVARCHAR(200) NULL,
    DataImport       DATETIME      NOT NULL CONSTRAINT DF_SIM_RILEVAZIONI_Data DEFAULT (GETDATE()),
    CONSTRAINT UQ_SIM_RILEVAZIONI UNIQUE (IdSim, DataRilevazione)
);
GO

-- l'elenco: anagrafica + nomi + ultima rilevazione
CREATE OR ALTER VIEW dbo.V_Sim AS
SELECT s.IdSim, s.Numero, s.ICCID, s.Operatore, s.Prodotto, s.Stato, s.DataAttivazione, s.DataCessazione,
       s.PianoTariffario, s.IdFiliale, f.FILIALE AS Filiale, s.IdUtente, u.Nome AS Dipendente, u.Matricola,
       s.AssegnataA, s.Palmare, s.SerialePalmare, s.Note, s.DataCreazione, s.DataModifica, s.UtenteModifica,
       r.DataRilevazione AS UltimaRilevazione, r.CreditoResiduo, r.GbSoglia, r.GbConsumati, r.GbResidui, r.PercResidua, r.PeriodoSoglia,
       (SELECT COUNT(*) FROM dbo.SIM_VARIAZIONI v WHERE v.IdSim = s.IdSim) AS NumVariazioni
FROM dbo.SIM s
LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = s.IdFiliale
LEFT JOIN dbo.UTENTI u ON u.IdUtente = s.IdUtente
OUTER APPLY (SELECT TOP 1 * FROM dbo.SIM_RILEVAZIONI x WHERE x.IdSim = s.IdSim ORDER BY x.DataRilevazione DESC) r;
GO

-- Salvataggio dalla pagina: tutti i campi. Se piano o stato cambiano, resta traccia in SIM_VARIAZIONI.
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
        VALUES (@IdSim, ISNULL(@DataAttivazione, CAST(GETDATE() AS DATE)), @PianoTariffario, @Stato, 'INIZIALE', @NotaVariazione, @Utente);
        RETURN;
    END

    DECLARE @PianoPrima VARCHAR(100), @StatoPrima VARCHAR(20);
    SELECT @PianoPrima = PianoTariffario, @StatoPrima = Stato FROM dbo.SIM WHERE IdSim = @IdSim;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR('AI_SIM_Save: SIM %d inesistente.', 16, 1, @IdSim); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.SIM WHERE Numero = @Numero AND IdSim <> @IdSim)
    BEGIN RAISERROR('AI_SIM_Save: il numero %s appartiene a un''altra SIM.', 16, 1, @Numero); RETURN; END

    UPDATE dbo.SIM
       SET Numero = @Numero, ICCID = @ICCID, Operatore = @Operatore, Prodotto = @Prodotto, Stato = @Stato,
           DataAttivazione = @DataAttivazione, DataCessazione = @DataCessazione, PianoTariffario = @PianoTariffario,
           IdFiliale = @IdFiliale, IdUtente = @IdUtente, AssegnataA = @AssegnataA, Palmare = @Palmare,
           SerialePalmare = @SerialePalmare, Note = @Note, DataModifica = GETDATE(), UtenteModifica = @Utente
     WHERE IdSim = @IdSim;

    IF ISNULL(@PianoPrima, '') <> ISNULL(@PianoTariffario, '') OR ISNULL(@StatoPrima, '') <> ISNULL(@Stato, '')
        INSERT INTO dbo.SIM_VARIAZIONI (IdSim, Data, PianoTariffario, Stato, PianoPrecedente, StatoPrecedente, Origine, Note, Utente)
        VALUES (@IdSim, CAST(GETDATE() AS DATE), @PianoTariffario, @Stato, @PianoPrima, @StatoPrima, 'MANUALE', @NotaVariazione, @Utente);
END
GO

-- Import dai file dell'operatore: tocca solo i campi che arrivano da li' (chi la
-- gestisce, a chi e' assegnata, note restano com'erano). Nuova se il numero manca.
-- @Esito: NUOVA / AGGIORNATA / INVARIATA.
CREATE OR ALTER PROCEDURE dbo.AI_SIM_Import
    @Numero          VARCHAR(20),
    @ICCID           VARCHAR(32)   = NULL,
    @Prodotto        VARCHAR(50)   = NULL,
    @Stato           VARCHAR(20)   = NULL,
    @DataAttivazione DATE          = NULL,
    @PianoTariffario VARCHAR(100)  = NULL,
    @DataVariazione  DATE          = NULL,     -- data del file (rilevazione); default oggi
    @FileOrigine     NVARCHAR(200) = NULL,
    @Utente          NVARCHAR(50)  = NULL,
    @IdSim           INT           = NULL OUTPUT,
    @Esito           VARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Numero = LTRIM(RTRIM(ISNULL(@Numero, '')));
    IF @Numero = '' BEGIN RAISERROR('AI_SIM_Import: numero mancante.', 16, 1); RETURN; END
    SET @ICCID = NULLIF(LTRIM(RTRIM(@ICCID)), '');
    SET @Prodotto = NULLIF(LTRIM(RTRIM(@Prodotto)), '');
    SET @Stato = NULLIF(LTRIM(RTRIM(@Stato)), '');
    SET @PianoTariffario = NULLIF(LTRIM(RTRIM(@PianoTariffario)), '');
    SET @DataVariazione = ISNULL(@DataVariazione, CAST(GETDATE() AS DATE));

    SELECT @IdSim = IdSim FROM dbo.SIM WHERE Numero = @Numero;
    IF @IdSim IS NULL
    BEGIN
        INSERT INTO dbo.SIM (Numero, ICCID, Prodotto, Stato, DataAttivazione, PianoTariffario, DataModifica, UtenteModifica)
        VALUES (@Numero, @ICCID, @Prodotto, ISNULL(@Stato, 'Attiva'), @DataAttivazione, @PianoTariffario, GETDATE(), @Utente);
        SET @IdSim = SCOPE_IDENTITY();
        INSERT INTO dbo.SIM_VARIAZIONI (IdSim, Data, PianoTariffario, Stato, Origine, Note, Utente)
        VALUES (@IdSim, ISNULL(@DataAttivazione, @DataVariazione), @PianoTariffario, ISNULL(@Stato, 'Attiva'), 'INIZIALE', @FileOrigine, @Utente);
        SET @Esito = 'NUOVA';
        RETURN;
    END

    DECLARE @PianoPrima VARCHAR(100), @StatoPrima VARCHAR(20), @IccidPrima VARCHAR(32), @ProdPrima VARCHAR(50), @DataPrima DATE;
    SELECT @PianoPrima = PianoTariffario, @StatoPrima = Stato, @IccidPrima = ICCID, @ProdPrima = Prodotto, @DataPrima = DataAttivazione
      FROM dbo.SIM WHERE IdSim = @IdSim;
    DECLARE @CambiaProfilo BIT = CASE WHEN (@PianoTariffario IS NOT NULL AND ISNULL(@PianoPrima, '') <> @PianoTariffario)
                                        OR (@Stato IS NOT NULL AND ISNULL(@StatoPrima, '') <> @Stato) THEN 1 ELSE 0 END;
    DECLARE @CambiaAnag BIT = CASE WHEN (@ICCID IS NOT NULL AND ISNULL(@IccidPrima, '') <> @ICCID)
                                     OR (@Prodotto IS NOT NULL AND ISNULL(@ProdPrima, '') <> @Prodotto)
                                     OR (@DataAttivazione IS NOT NULL AND ISNULL(@DataPrima, '19000101') <> @DataAttivazione) THEN 1 ELSE 0 END;
    IF @CambiaProfilo = 0 AND @CambiaAnag = 0 BEGIN SET @Esito = 'INVARIATA'; RETURN; END

    UPDATE dbo.SIM
       SET ICCID = ISNULL(@ICCID, ICCID), Prodotto = ISNULL(@Prodotto, Prodotto), Stato = ISNULL(@Stato, Stato),
           DataAttivazione = ISNULL(@DataAttivazione, DataAttivazione), PianoTariffario = ISNULL(@PianoTariffario, PianoTariffario),
           DataModifica = GETDATE(), UtenteModifica = @Utente
     WHERE IdSim = @IdSim;
    IF @CambiaProfilo = 1
        INSERT INTO dbo.SIM_VARIAZIONI (IdSim, Data, PianoTariffario, Stato, PianoPrecedente, StatoPrecedente, Origine, Note, Utente)
        VALUES (@IdSim, @DataVariazione, ISNULL(@PianoTariffario, @PianoPrima), ISNULL(@Stato, @StatoPrima), @PianoPrima, @StatoPrima, 'IMPORT', @FileOrigine, @Utente);
    SET @Esito = 'AGGIORNATA';
END
GO

-- Una rilevazione (consumi/credito a una data): se per quella data c'e' gia', si sostituisce.
CREATE OR ALTER PROCEDURE dbo.AI_SIM_RILEVAZIONE_Save
    @IdSim           INT,
    @DataRilevazione DATE,
    @PianoTariffario VARCHAR(100)  = NULL,
    @Stato           VARCHAR(30)   = NULL,
    @CreditoResiduo  DECIMAL(10,2) = NULL,
    @GbSoglia        DECIMAL(10,3) = NULL,
    @GbConsumati     DECIMAL(10,3) = NULL,
    @GbResidui       DECIMAL(10,3) = NULL,
    @PercResidua     DECIMAL(6,2)  = NULL,
    @PeriodoSoglia   VARCHAR(30)   = NULL,
    @FileOrigine     NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.SIM WHERE IdSim = @IdSim) BEGIN RAISERROR('AI_SIM_RILEVAZIONE_Save: SIM %d inesistente.', 16, 1, @IdSim); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.SIM_RILEVAZIONI WHERE IdSim = @IdSim AND DataRilevazione = @DataRilevazione)
        UPDATE dbo.SIM_RILEVAZIONI
           SET PianoTariffario = @PianoTariffario, Stato = @Stato, CreditoResiduo = @CreditoResiduo, GbSoglia = @GbSoglia,
               GbConsumati = @GbConsumati, GbResidui = @GbResidui, PercResidua = @PercResidua, PeriodoSoglia = @PeriodoSoglia,
               FileOrigine = @FileOrigine, DataImport = GETDATE()
         WHERE IdSim = @IdSim AND DataRilevazione = @DataRilevazione;
    ELSE
        INSERT INTO dbo.SIM_RILEVAZIONI (IdSim, DataRilevazione, PianoTariffario, Stato, CreditoResiduo, GbSoglia, GbConsumati, GbResidui, PercResidua, PeriodoSoglia, FileOrigine)
        VALUES (@IdSim, @DataRilevazione, @PianoTariffario, @Stato, @CreditoResiduo, @GbSoglia, @GbConsumati, @GbResidui, @PercResidua, @PeriodoSoglia, @FileOrigine);
END
GO

CREATE OR ALTER PROCEDURE dbo.AI_SIM_Del
    @IdSim INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.SIM WHERE IdSim = @IdSim;   -- variazioni e rilevazioni a cascata
    IF @@ROWCOUNT = 0 RAISERROR('AI_SIM_Del: SIM %d inesistente.', 16, 1, @IdSim);
END
GO

-- voce di menu (webapp, campo Link) sotto Test - Sviluppo
IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/sim')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1229, @Text = 'SIM aziendali',
        @Descrizione = 'Anagrafica delle SIM, piani tariffari, variazioni e rilevazioni Wind',
        @Link = '/sim', @Sorting = 15;
GO
GO

-- ============================================================
-- >>> PALMARI_tabelle.sql
-- ============================================================
-- Palmari aziendali (Samsung XCover gestiti con Knox Manage): anagrafica dal file
-- "Device List" di Knox, collegamento alla SIM (per ICCID o numero), alla filiale
-- (dal tag Knox, quando corrisponde a una filiale sola) e all'uso quotidiano dei
-- driver, che l'app registra in UTENTI_ATTIVITA.Palmare con l'Android ID del
-- dispositivo: quello non sta nel file Knox e si abbina dalla scheda.
-- Scritture solo via AI_PALMARI_*. Idempotente.
USE DeliveryDB;
GO

IF OBJECT_ID('dbo.PALMARI', 'U') IS NULL
CREATE TABLE dbo.PALMARI (
    IdPalmare        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PALMARI PRIMARY KEY,
    Seriale          VARCHAR(30)   NOT NULL CONSTRAINT UQ_PALMARI_Seriale UNIQUE,
    Imei             VARCHAR(20)   NULL,
    Imei2            VARCHAR(20)   NULL,
    Mac              VARCHAR(20)   NULL,
    AndroidId        VARCHAR(32)   NULL,          -- l'identificativo che l'app scrive in UTENTI_ATTIVITA.Palmare
    NomeDevice       NVARCHAR(100) NULL,
    Alias            NVARCHAR(100) NULL,
    Modello          NVARCHAR(60)  NULL,
    Produttore       NVARCHAR(40)  NULL,
    Piattaforma      VARCHAR(20)   NULL,
    VersioneOS       VARCHAR(20)   NULL,
    VersioneAgent    VARCHAR(30)   NULL,
    Firmware         VARCHAR(60)   NULL,
    StatoMdm         VARCHAR(30)   NULL,          -- Enrolled / Unenrolled ... (Knox)
    TipoGestione     VARCHAR(40)   NULL,
    TipoEnrollment   VARCHAR(40)   NULL,
    Organizzazione   NVARCHAR(60)  NULL,
    Profilo          NVARCHAR(120) NULL,
    UtenteMdm        NVARCHAR(50)  NULL,
    Tag              NVARCHAR(50)  NULL,          -- Device Tag di Knox (di solito la filiale)
    NumeroMobile     VARCHAR(20)   NULL,
    ICCID            VARCHAR(32)   NULL,
    EID              VARCHAR(40)   NULL,
    IdSim            INT           NULL CONSTRAINT FK_PALMARI_SIM REFERENCES dbo.SIM (IdSim),
    IdFiliale        INT           NULL,
    Problema         NVARCHAR(100) NULL,
    UltimoComando    NVARCHAR(60)  NULL,
    Roaming          BIT           NULL,
    UltimoContatto   NVARCHAR(20)  NULL,          -- "Last Seen" di Knox, com'e' scritto (21m, 3h, 2d)
    UltimoAggiornamentoMdm DATE    NULL,
    CodiceKiosk      VARCHAR(20)   NULL,
    CodiceUnenroll   VARCHAR(30)   NULL,
    CodiceSblocco    VARCHAR(20)   NULL,
    Stato            VARCHAR(20)   NOT NULL CONSTRAINT DF_PALMARI_Stato DEFAULT ('In uso'),   -- In uso / Scorta / Guasto / Dismesso
    Note             NVARCHAR(500) NULL,
    DataImport       DATETIME      NULL,
    DataCreazione    DATETIME      NOT NULL CONSTRAINT DF_PALMARI_DataCreazione DEFAULT (GETDATE()),
    DataModifica     DATETIME      NULL,
    UtenteModifica   NVARCHAR(50)  NULL
);
GO
IF COL_LENGTH('dbo.PALMARI', 'Email') IS NULL
    ALTER TABLE dbo.PALMARI ADD Email NVARCHAR(100) NULL, Gruppi NVARCHAR(300) NULL, ProfiliAssegnati NVARCHAR(300) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PALMARI_AndroidId') CREATE INDEX IX_PALMARI_AndroidId ON dbo.PALMARI (AndroidId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PALMARI_IdSim') CREATE INDEX IX_PALMARI_IdSim ON dbo.PALMARI (IdSim);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_UTENTI_ATTIVITA_Palmare') CREATE INDEX IX_UTENTI_ATTIVITA_Palmare ON dbo.UTENTI_ATTIVITA (Palmare, data) INCLUDE (idUtente, idFiliale);
GO

-- cosa e' cambiato su un palmare (SIM, filiale, tag, stato, Android ID...): da import o dalla pagina
IF OBJECT_ID('dbo.PALMARI_VARIAZIONI', 'U') IS NULL
CREATE TABLE dbo.PALMARI_VARIAZIONI (
    IdVariazione      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PALMARI_VARIAZIONI PRIMARY KEY,
    IdPalmare         INT           NOT NULL CONSTRAINT FK_PALMARI_VARIAZIONI REFERENCES dbo.PALMARI (IdPalmare) ON DELETE CASCADE,
    Data              DATE          NOT NULL,
    Campo             VARCHAR(30)   NOT NULL,
    Prima             NVARCHAR(200) NULL,
    Dopo              NVARCHAR(200) NULL,
    Origine           VARCHAR(30)   NOT NULL,     -- INIZIALE / IMPORT / MANUALE
    Utente            NVARCHAR(50)  NULL,
    DataRegistrazione DATETIME      NOT NULL CONSTRAINT DF_PALMARI_VARIAZIONI_Data DEFAULT (GETDATE())
);
GO

-- dove stava il palmare: la "Last Location" di ogni export Knox (una riga per istante),
-- e in futuro altre fonti (Origine)
IF OBJECT_ID('dbo.PALMARI_POSIZIONI', 'U') IS NULL
CREATE TABLE dbo.PALMARI_POSIZIONI (
    IdPosizione   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PALMARI_POSIZIONI PRIMARY KEY,
    IdPalmare     INT           NOT NULL CONSTRAINT FK_PALMARI_POSIZIONI REFERENCES dbo.PALMARI (IdPalmare) ON DELETE CASCADE,
    DataOra       DATETIME      NOT NULL,          -- ora locale, com'e' nel file
    Latitudine    DECIMAL(9,6)  NOT NULL,
    Longitudine   DECIMAL(9,6)  NOT NULL,
    Origine       VARCHAR(20)   NOT NULL CONSTRAINT DF_PALMARI_POSIZIONI_Origine DEFAULT ('KNOX'),
    FileOrigine   NVARCHAR(200) NULL,
    DataImport    DATETIME      NOT NULL CONSTRAINT DF_PALMARI_POSIZIONI_Data DEFAULT (GETDATE()),
    CONSTRAINT UQ_PALMARI_POSIZIONI UNIQUE (IdPalmare, Origine, DataOra)
);
GO

-- una posizione: si aggiunge solo se per quell'istante non c'e' gia'
CREATE OR ALTER PROCEDURE dbo.AI_PALMARI_POSIZIONE_Save
    @IdPalmare   INT,
    @DataOra     DATETIME,
    @Latitudine  DECIMAL(9,6),
    @Longitudine DECIMAL(9,6),
    @Origine     VARCHAR(20)   = 'KNOX',
    @FileOrigine NVARCHAR(200) = NULL,
    @Nuova       BIT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Nuova = 0;
    IF NOT EXISTS (SELECT 1 FROM dbo.PALMARI WHERE IdPalmare = @IdPalmare) BEGIN RAISERROR('AI_PALMARI_POSIZIONE_Save: palmare %d inesistente.', 16, 1, @IdPalmare); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.PALMARI_POSIZIONI WHERE IdPalmare = @IdPalmare AND Origine = @Origine AND DataOra = @DataOra) RETURN;
    INSERT INTO dbo.PALMARI_POSIZIONI (IdPalmare, DataOra, Latitudine, Longitudine, Origine, FileOrigine)
    VALUES (@IdPalmare, @DataOra, @Latitudine, @Longitudine, @Origine, @FileOrigine);
    SET @Nuova = 1;
END
GO

-- l'elenco: palmare + SIM + filiale + ultimo uso registrato dall'app + ultima posizione
CREATE OR ALTER VIEW dbo.V_Palmari AS
SELECT p.*,
       f.FILIALE AS Filiale,
       pos.DataOra AS PosizioneData, pos.Latitudine AS PosizioneLat, pos.Longitudine AS PosizioneLng,
       pr.latitude AS AppLat, pr.longitude AS AppLng,
       s.Numero AS SimNumero, s.PianoTariffario AS SimPiano, s.Stato AS SimStato, s.PercResidua AS SimPercResidua, s.UltimaRilevazione AS SimRilevazione,
       u.data AS UltimoUso, u.idUtente AS UltimoIdUtente, ut.Nome AS UltimoDriver, fu.FILIALE AS UltimaFiliale,
       (SELECT COUNT(DISTINCT a.data) FROM dbo.UTENTI_ATTIVITA a WHERE a.Palmare = p.AndroidId AND a.data >= DATEADD(day, -30, CAST(GETDATE() AS DATE))) AS GiorniUso30,
       pr.datainserimento AS UltimoEventoApp, pr.appVersion AS VersioneApp
FROM dbo.PALMARI p
LEFT JOIN dbo.FILIALI f ON f.IDFILIALE = p.IdFiliale
LEFT JOIN dbo.V_Sim s ON s.IdSim = p.IdSim
OUTER APPLY (SELECT TOP 1 a.data, a.idUtente, a.idFiliale FROM dbo.UTENTI_ATTIVITA a WHERE p.AndroidId IS NOT NULL AND a.Palmare = p.AndroidId ORDER BY a.data DESC, a.idAttivita DESC) u
LEFT JOIN dbo.UTENTI ut ON ut.IdUtente = u.idUtente
LEFT JOIN dbo.FILIALI fu ON fu.IDFILIALE = u.idFiliale
OUTER APPLY (SELECT TOP 1 r.datainserimento, r.appVersion, r.latitude, r.longitude FROM dbo.PALM_RAW r WHERE p.AndroidId IS NOT NULL AND r.imei = p.AndroidId ORDER BY r.id DESC) pr
OUTER APPLY (SELECT TOP 1 x.DataOra, x.Latitudine, x.Longitudine FROM dbo.PALMARI_POSIZIONI x WHERE x.IdPalmare = p.IdPalmare ORDER BY x.DataOra DESC) pos;
GO

-- Salvataggio dalla pagina: tutti i campi. Le variazioni sui campi che contano restano in PALMARI_VARIAZIONI.
CREATE OR ALTER PROCEDURE dbo.AI_PALMARI_Save
    @IdPalmare  INT           = NULL OUTPUT,
    @Seriale    VARCHAR(30),
    @Imei       VARCHAR(20)   = NULL,
    @Imei2      VARCHAR(20)   = NULL,
    @Mac        VARCHAR(20)   = NULL,
    @AndroidId  VARCHAR(32)   = NULL,
    @NomeDevice NVARCHAR(100) = NULL,
    @Alias      NVARCHAR(100) = NULL,
    @Modello    NVARCHAR(60)  = NULL,
    @Produttore NVARCHAR(40)  = NULL,
    @Tag        NVARCHAR(50)  = NULL,
    @NumeroMobile VARCHAR(20) = NULL,
    @ICCID      VARCHAR(32)   = NULL,
    @IdSim      INT           = NULL,
    @IdFiliale  INT           = NULL,
    @Stato      VARCHAR(20)   = NULL,
    @Note       NVARCHAR(500) = NULL,
    @Utente     NVARCHAR(50)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Seriale = LTRIM(RTRIM(ISNULL(@Seriale, '')));
    IF @Seriale = '' BEGIN RAISERROR('AI_PALMARI_Save: il seriale e'' obbligatorio.', 16, 1); RETURN; END
    SET @AndroidId = LOWER(NULLIF(LTRIM(RTRIM(@AndroidId)), ''));
    SET @Stato = ISNULL(NULLIF(LTRIM(RTRIM(@Stato)), ''), 'In uso');
    SET @Tag = NULLIF(LTRIM(RTRIM(@Tag)), ''); SET @Note = NULLIF(LTRIM(RTRIM(@Note)), ''); SET @Alias = NULLIF(LTRIM(RTRIM(@Alias)), '');
    SET @ICCID = NULLIF(LTRIM(RTRIM(@ICCID)), ''); SET @NumeroMobile = NULLIF(LTRIM(RTRIM(@NumeroMobile)), '');
    IF @AndroidId IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.PALMARI WHERE AndroidId = @AndroidId AND IdPalmare <> ISNULL(@IdPalmare, -1))
    BEGIN RAISERROR('AI_PALMARI_Save: l''Android ID %s e'' gia'' abbinato a un altro palmare.', 16, 1, @AndroidId); RETURN; END

    DECLARE @Oggi DATE = CAST(GETDATE() AS DATE);
    IF @IdPalmare IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.PALMARI WHERE Seriale = @Seriale)
        BEGIN RAISERROR('AI_PALMARI_Save: il seriale %s esiste gia''.', 16, 1, @Seriale); RETURN; END
        INSERT INTO dbo.PALMARI (Seriale, Imei, Imei2, Mac, AndroidId, NomeDevice, Alias, Modello, Produttore, Tag, NumeroMobile, ICCID,
                                 IdSim, IdFiliale, Stato, Note, DataModifica, UtenteModifica)
        VALUES (@Seriale, @Imei, @Imei2, @Mac, @AndroidId, @NomeDevice, @Alias, @Modello, @Produttore, @Tag, @NumeroMobile, @ICCID,
                @IdSim, @IdFiliale, @Stato, @Note, GETDATE(), @Utente);
        SET @IdPalmare = SCOPE_IDENTITY();
        INSERT INTO dbo.PALMARI_VARIAZIONI (IdPalmare, Data, Campo, Prima, Dopo, Origine, Utente) VALUES (@IdPalmare, @Oggi, 'Creazione', NULL, @Seriale, 'INIZIALE', @Utente);
        RETURN;
    END

    DECLARE @p TABLE (AndroidId VARCHAR(32), Tag NVARCHAR(50), IdSim INT, IdFiliale INT, Stato VARCHAR(20));
    INSERT INTO @p SELECT AndroidId, Tag, IdSim, IdFiliale, Stato FROM dbo.PALMARI WHERE IdPalmare = @IdPalmare;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR('AI_PALMARI_Save: palmare %d inesistente.', 16, 1, @IdPalmare); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.PALMARI WHERE Seriale = @Seriale AND IdPalmare <> @IdPalmare)
    BEGIN RAISERROR('AI_PALMARI_Save: il seriale %s appartiene a un altro palmare.', 16, 1, @Seriale); RETURN; END

    UPDATE dbo.PALMARI
       SET Seriale = @Seriale, Imei = @Imei, Imei2 = @Imei2, Mac = @Mac, AndroidId = @AndroidId, NomeDevice = @NomeDevice, Alias = @Alias,
           Modello = @Modello, Produttore = @Produttore, Tag = @Tag, NumeroMobile = @NumeroMobile, ICCID = @ICCID, IdSim = @IdSim,
           IdFiliale = @IdFiliale, Stato = @Stato, Note = @Note, DataModifica = GETDATE(), UtenteModifica = @Utente
     WHERE IdPalmare = @IdPalmare;

    INSERT INTO dbo.PALMARI_VARIAZIONI (IdPalmare, Data, Campo, Prima, Dopo, Origine, Utente)
    SELECT @IdPalmare, @Oggi, x.Campo, x.Prima, x.Dopo, 'MANUALE', @Utente
    FROM @p p CROSS APPLY (VALUES
        ('AndroidId', p.AndroidId, @AndroidId),
        ('Tag', p.Tag, @Tag),
        ('IdSim', CAST(p.IdSim AS NVARCHAR(20)), CAST(@IdSim AS NVARCHAR(20))),
        ('IdFiliale', CAST(p.IdFiliale AS NVARCHAR(20)), CAST(@IdFiliale AS NVARCHAR(20))),
        ('Stato', p.Stato, @Stato)) x (Campo, Prima, Dopo)
    WHERE ISNULL(x.Prima, '') <> ISNULL(x.Dopo, '');
END
GO

-- Import dal file Knox: tocca solo i campi che arrivano da li'. Nuovo se il seriale manca.
-- La SIM si aggancia per ICCID o per numero; la filiale (@IdFiliale) la propone l'API dal tag,
-- e si scrive solo se il palmare non ne ha gia' una. @Esito: NUOVO / AGGIORNATO / INVARIATO.
CREATE OR ALTER PROCEDURE dbo.AI_PALMARI_Import
    @Seriale        VARCHAR(30),
    @Imei           VARCHAR(20)   = NULL,
    @Imei2          VARCHAR(20)   = NULL,
    @Mac            VARCHAR(20)   = NULL,
    @NomeDevice     NVARCHAR(100) = NULL,
    @Alias          NVARCHAR(100) = NULL,
    @Modello        NVARCHAR(60)  = NULL,
    @Produttore     NVARCHAR(40)  = NULL,
    @Piattaforma    VARCHAR(20)   = NULL,
    @VersioneOS     VARCHAR(20)   = NULL,
    @VersioneAgent  VARCHAR(30)   = NULL,
    @Firmware       VARCHAR(60)   = NULL,
    @StatoMdm       VARCHAR(30)   = NULL,
    @TipoGestione   VARCHAR(40)   = NULL,
    @TipoEnrollment VARCHAR(40)   = NULL,
    @Organizzazione NVARCHAR(60)  = NULL,
    @Profilo        NVARCHAR(120) = NULL,
    @UtenteMdm      NVARCHAR(50)  = NULL,
    @Tag            NVARCHAR(50)  = NULL,
    @NumeroMobile   VARCHAR(20)   = NULL,
    @ICCID          VARCHAR(32)   = NULL,
    @EID            VARCHAR(40)   = NULL,
    @Problema       NVARCHAR(100) = NULL,
    @UltimoComando  NVARCHAR(60)  = NULL,
    @Roaming        BIT           = NULL,
    @UltimoContatto NVARCHAR(20)  = NULL,
    @UltimoAggiornamentoMdm DATE  = NULL,
    @CodiceKiosk    VARCHAR(20)   = NULL,
    @CodiceUnenroll VARCHAR(30)   = NULL,
    @CodiceSblocco  VARCHAR(20)   = NULL,
    @Email          NVARCHAR(100) = NULL,
    @Gruppi         NVARCHAR(300) = NULL,
    @ProfiliAssegnati NVARCHAR(300) = NULL,
    @IdFiliale      INT           = NULL,
    @Utente         NVARCHAR(50)  = NULL,
    @IdPalmare      INT           = NULL OUTPUT,
    @Esito          VARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Seriale = LTRIM(RTRIM(ISNULL(@Seriale, '')));
    IF @Seriale = '' BEGIN RAISERROR('AI_PALMARI_Import: seriale mancante.', 16, 1); RETURN; END
    SET @ICCID = NULLIF(LTRIM(RTRIM(@ICCID)), ''); SET @NumeroMobile = NULLIF(LTRIM(RTRIM(@NumeroMobile)), ''); SET @Tag = NULLIF(LTRIM(RTRIM(@Tag)), '');
    DECLARE @Oggi DATE = CAST(GETDATE() AS DATE);
    DECLARE @IdSim INT = (SELECT TOP 1 IdSim FROM dbo.SIM WHERE (@ICCID IS NOT NULL AND ICCID = @ICCID) OR (@NumeroMobile IS NOT NULL AND Numero = @NumeroMobile) ORDER BY CASE WHEN ICCID = @ICCID THEN 0 ELSE 1 END);

    SELECT @IdPalmare = IdPalmare FROM dbo.PALMARI WHERE Seriale = @Seriale;
    IF @IdPalmare IS NULL
    BEGIN
        INSERT INTO dbo.PALMARI (Seriale, Imei, Imei2, Mac, NomeDevice, Alias, Modello, Produttore, Piattaforma, VersioneOS, VersioneAgent, Firmware,
                                 StatoMdm, TipoGestione, TipoEnrollment, Organizzazione, Profilo, UtenteMdm, Tag, NumeroMobile, ICCID, EID, IdSim, IdFiliale,
                                 Problema, UltimoComando, Roaming, UltimoContatto, UltimoAggiornamentoMdm, CodiceKiosk, CodiceUnenroll, CodiceSblocco,
                                 Email, Gruppi, ProfiliAssegnati, DataImport, DataModifica, UtenteModifica)
        VALUES (@Seriale, @Imei, @Imei2, @Mac, @NomeDevice, @Alias, @Modello, @Produttore, @Piattaforma, @VersioneOS, @VersioneAgent, @Firmware,
                @StatoMdm, @TipoGestione, @TipoEnrollment, @Organizzazione, @Profilo, @UtenteMdm, @Tag, @NumeroMobile, @ICCID, @EID, @IdSim, @IdFiliale,
                @Problema, @UltimoComando, @Roaming, @UltimoContatto, @UltimoAggiornamentoMdm, @CodiceKiosk, @CodiceUnenroll, @CodiceSblocco,
                @Email, @Gruppi, @ProfiliAssegnati, GETDATE(), GETDATE(), @Utente);
        SET @IdPalmare = SCOPE_IDENTITY();
        INSERT INTO dbo.PALMARI_VARIAZIONI (IdPalmare, Data, Campo, Prima, Dopo, Origine, Utente) VALUES (@IdPalmare, @Oggi, 'Creazione', NULL, @Seriale, 'INIZIALE', @Utente);
        SET @Esito = 'NUOVO';
        RETURN;
    END

    DECLARE @p TABLE (ICCID VARCHAR(32), IdSim INT, Tag NVARCHAR(50), StatoMdm VARCHAR(30), UtenteMdm NVARCHAR(50), Profilo NVARCHAR(120), NumeroMobile VARCHAR(20), IdFiliale INT);
    INSERT INTO @p SELECT ICCID, IdSim, Tag, StatoMdm, UtenteMdm, Profilo, NumeroMobile, IdFiliale FROM dbo.PALMARI WHERE IdPalmare = @IdPalmare;
    -- filiale: dal tag se il palmare non ne ha una, o se il tag e' cambiato e il nuovo tag ne indica una
    DECLARE @IdFilialeNuova INT = (SELECT CASE WHEN @Tag IS NOT NULL AND ISNULL(Tag, '') <> @Tag AND @IdFiliale IS NOT NULL THEN @IdFiliale ELSE ISNULL(IdFiliale, @IdFiliale) END FROM @p);
    DECLARE @IdSimNuova INT = ISNULL(@IdSim, (SELECT IdSim FROM @p));   -- senza ICCID nel file la SIM resta quella che c'e'
    IF @ICCID IS NOT NULL AND @IdSim IS NULL SET @IdSimNuova = NULL;      -- ICCID nuovo ma sconosciuto: la SIM di prima non e' piu' quella

    UPDATE dbo.PALMARI
       SET Imei = ISNULL(@Imei, Imei), Imei2 = ISNULL(@Imei2, Imei2), Mac = ISNULL(@Mac, Mac), NomeDevice = ISNULL(@NomeDevice, NomeDevice),
           Alias = ISNULL(@Alias, Alias), Modello = ISNULL(@Modello, Modello), Produttore = ISNULL(@Produttore, Produttore),
           Piattaforma = ISNULL(@Piattaforma, Piattaforma), VersioneOS = ISNULL(@VersioneOS, VersioneOS), VersioneAgent = ISNULL(@VersioneAgent, VersioneAgent),
           Firmware = ISNULL(@Firmware, Firmware), StatoMdm = ISNULL(@StatoMdm, StatoMdm), TipoGestione = ISNULL(@TipoGestione, TipoGestione),
           TipoEnrollment = ISNULL(@TipoEnrollment, TipoEnrollment), Organizzazione = ISNULL(@Organizzazione, Organizzazione), Profilo = ISNULL(@Profilo, Profilo),
           UtenteMdm = ISNULL(@UtenteMdm, UtenteMdm), Tag = ISNULL(@Tag, Tag), NumeroMobile = ISNULL(@NumeroMobile, NumeroMobile),
           ICCID = ISNULL(@ICCID, ICCID), EID = ISNULL(@EID, EID), IdSim = @IdSimNuova, IdFiliale = @IdFilialeNuova,
           Problema = @Problema, UltimoComando = ISNULL(@UltimoComando, UltimoComando), Roaming = ISNULL(@Roaming, Roaming),
           UltimoContatto = ISNULL(@UltimoContatto, UltimoContatto), UltimoAggiornamentoMdm = ISNULL(@UltimoAggiornamentoMdm, UltimoAggiornamentoMdm),
           CodiceKiosk = ISNULL(@CodiceKiosk, CodiceKiosk), CodiceUnenroll = ISNULL(@CodiceUnenroll, CodiceUnenroll), CodiceSblocco = ISNULL(@CodiceSblocco, CodiceSblocco),
           Email = ISNULL(@Email, Email), Gruppi = ISNULL(@Gruppi, Gruppi), ProfiliAssegnati = ISNULL(@ProfiliAssegnati, ProfiliAssegnati),
           DataImport = GETDATE()
     WHERE IdPalmare = @IdPalmare;

    INSERT INTO dbo.PALMARI_VARIAZIONI (IdPalmare, Data, Campo, Prima, Dopo, Origine, Utente)
    SELECT @IdPalmare, @Oggi, x.Campo, x.Prima, x.Dopo, 'IMPORT', @Utente
    FROM @p p CROSS APPLY (VALUES
        ('ICCID', p.ICCID, ISNULL(@ICCID, p.ICCID)),
        ('IdSim', CAST(p.IdSim AS NVARCHAR(20)), CAST(@IdSimNuova AS NVARCHAR(20))),
        ('Tag', p.Tag, ISNULL(@Tag, p.Tag)),
        ('StatoMdm', p.StatoMdm, ISNULL(@StatoMdm, p.StatoMdm)),
        ('UtenteMdm', p.UtenteMdm, ISNULL(@UtenteMdm, p.UtenteMdm)),
        ('Profilo', p.Profilo, ISNULL(@Profilo, p.Profilo)),
        ('NumeroMobile', p.NumeroMobile, ISNULL(@NumeroMobile, p.NumeroMobile)),
        ('IdFiliale', CAST(p.IdFiliale AS NVARCHAR(20)), CAST(@IdFilialeNuova AS NVARCHAR(20)))) x (Campo, Prima, Dopo)
    WHERE ISNULL(x.Prima, '') <> ISNULL(x.Dopo, '');
    SET @Esito = CASE WHEN @@ROWCOUNT > 0 THEN 'AGGIORNATO' ELSE 'INVARIATO' END;
END
GO

CREATE OR ALTER PROCEDURE dbo.AI_PALMARI_Del
    @IdPalmare INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.PALMARI WHERE IdPalmare = @IdPalmare;
    IF @@ROWCOUNT = 0 RAISERROR('AI_PALMARI_Del: palmare %d inesistente.', 16, 1, @IdPalmare);
END
GO

-- V_Sim (col palmare che monta la SIM e l'assegnazione) sta in SIM_assegnazioni.sql

IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/palmari')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1229, @Text = 'Palmari',
        @Descrizione = 'Palmari aziendali (Knox): dispositivi, SIM, filiale e uso quotidiano dei driver',
        @Link = '/palmari', @Sorting = 16;
GO
GO

-- ============================================================
-- >>> SIM_assegnazioni.sql
-- ============================================================
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
GO

-- ============================================================
-- >>> PALMARI_filiale_tag.sql
-- ============================================================
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
GO

-- ============================================================
-- >>> MEZZI_scheda.sql
-- ============================================================
-- Scheda mezzo (la "Mezzi24" del legacy): salvataggio della testata e dei dati
-- Info via stored. Le altre linguette (km, foto, costi, sinistri, note) leggono
-- le tabelle esistenti; note e sinistri si scrivono con le AI_MEZZI_*_Save gia' in uso.
-- Idempotente.
USE DeliveryDB;
GO
CREATE OR ALTER PROCEDURE dbo.AI_MEZZI_Save
    @idMezzo               INT           = NULL OUTPUT,
    @targa                 VARCHAR(20),
    @codTipoMezzo          CHAR(3)       = NULL,
    @modello               VARCHAR(100)  = NULL,
    @marca                 VARCHAR(100)  = NULL,
    @telaio                VARCHAR(50)   = NULL,
    @dataImmatricolazione  DATE          = NULL,
    @dataAcquisto          DATE          = NULL,
    @dataDismissione       DATE          = NULL,
    @DataRevisione         DATE          = NULL,
    @idFiliale             INT           = NULL,
    @IdUtente              INT           = NULL,
    @Telepass              VARCHAR(50)   = NULL,
    @TesseraCarb           VARCHAR(100)  = NULL,
    @Proprieta             INT           = NULL,     -- 0 di proprieta', 1 noleggio, 2 leasing, NULL altro
    @ImportoRata           FLOAT         = NULL,
    @Noleggiatore          VARCHAR(100)  = NULL,
    @DataContrattoNoleggio DATE          = NULL,
    @Contratto             VARCHAR(100)  = NULL,
    @DataScadenzaNoleggio  DATE          = NULL,
    @ImportoRiscatto       FLOAT         = NULL,
    @Rottamato             INT           = NULL,
    @Scorta                INT           = NULL,
    @DataBollo             DATE          = NULL,
    @IdAzienda             INT           = NULL,
    @DataScadenzaZTL       DATE          = NULL,
    @ComuneZTL             VARCHAR(100)  = NULL,
    @DataFermo             DATE          = NULL,
    @DKV_idveicolo         VARCHAR(50)   = NULL,
    @DKV_trasponder        VARCHAR(50)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @targa = UPPER(REPLACE(LTRIM(RTRIM(ISNULL(@targa, ''))), ' ', ''));
    IF @targa = '' BEGIN RAISERROR('AI_MEZZI_Save: la targa e'' obbligatoria.', 16, 1); RETURN; END
    IF @codTipoMezzo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.MEZZI_TIPI WHERE codTipoMezzo = @codTipoMezzo)
    BEGIN RAISERROR('AI_MEZZI_Save: tipo mezzo %s inesistente.', 16, 1, @codTipoMezzo); RETURN; END

    IF @idMezzo IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.MEZZI WHERE targa = @targa)
        BEGIN RAISERROR('AI_MEZZI_Save: la targa %s esiste gia''.', 16, 1, @targa); RETURN; END
        INSERT INTO dbo.MEZZI (codTipoMezzo, modello, targa, marca, telaio, dataImmatricolazione, dataAcquisto, dataDismissione, DataRevisione,
                               idFiliale, IdUtente, Telepass, TesseraCarb, [Proprietà], ImportoRata, Noleggiatore, DataContrattoNoleggio, Contratto,
                               DataScadenzaNoleggio, ImportoRiscatto, Rottamato, Scorta, DataBollo, IdAzienda, DataScadenzaZTL, ComuneZTL, DataFermo,
                               DKV_idveicolo, DKV_trasponder)
        VALUES (@codTipoMezzo, @modello, @targa, @marca, @telaio, @dataImmatricolazione, @dataAcquisto, @dataDismissione, @DataRevisione,
                @idFiliale, @IdUtente, @Telepass, @TesseraCarb, @Proprieta, @ImportoRata, @Noleggiatore, @DataContrattoNoleggio, @Contratto,
                @DataScadenzaNoleggio, @ImportoRiscatto, @Rottamato, @Scorta, @DataBollo, @IdAzienda, @DataScadenzaZTL, @ComuneZTL, @DataFermo,
                @DKV_idveicolo, @DKV_trasponder);
        SET @idMezzo = SCOPE_IDENTITY();
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.MEZZI WHERE idMezzo = @idMezzo)
    BEGIN RAISERROR('AI_MEZZI_Save: mezzo %d inesistente.', 16, 1, @idMezzo); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.MEZZI WHERE targa = @targa AND idMezzo <> @idMezzo)
    BEGIN RAISERROR('AI_MEZZI_Save: la targa %s appartiene a un altro mezzo.', 16, 1, @targa); RETURN; END

    UPDATE dbo.MEZZI
       SET codTipoMezzo = @codTipoMezzo, modello = @modello, targa = @targa, marca = @marca, telaio = @telaio,
           dataImmatricolazione = @dataImmatricolazione, dataAcquisto = @dataAcquisto, dataDismissione = @dataDismissione, DataRevisione = @DataRevisione,
           idFiliale = @idFiliale, IdUtente = @IdUtente, Telepass = @Telepass, TesseraCarb = @TesseraCarb, [Proprietà] = @Proprieta,
           ImportoRata = @ImportoRata, Noleggiatore = @Noleggiatore, DataContrattoNoleggio = @DataContrattoNoleggio, Contratto = @Contratto,
           DataScadenzaNoleggio = @DataScadenzaNoleggio, ImportoRiscatto = @ImportoRiscatto, Rottamato = @Rottamato, Scorta = @Scorta,
           DataBollo = @DataBollo, IdAzienda = @IdAzienda, DataScadenzaZTL = @DataScadenzaZTL, ComuneZTL = @ComuneZTL, DataFermo = @DataFermo,
           DKV_idveicolo = @DKV_idveicolo, DKV_trasponder = @DKV_trasponder
     WHERE idMezzo = @idMezzo;
END
GO

-- voce diretta sotto Gestione Mezzi (1163); dalle griglie ci si arriva con le azioni "Dettaglio Mezzo"
IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/mezzi')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1163, @Text = 'Scheda Mezzi',
        @Descrizione = 'Scheda del mezzo: anagrafica, km con foto e posizione, costi, sinistri, manutenzioni',
        @Link = '/mezzi', @Sorting = 1;
GO
GO

-- ============================================================
-- >>> MEZZI_km_correzioni.sql
-- ============================================================
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
GO
