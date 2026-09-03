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
