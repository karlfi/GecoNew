-- =============================================================
-- FATT_ANCI_Previsione — quanto verrebbe fatturato, prima di fatturare.
--
-- Non rifa' i conti di FATT_Genera (listini e regole per cliente cambiano):
-- la esegue davvero, dentro una transazione, legge pezzi, importo e voci, e
-- poi annulla tutto. Cosi' la previsione e' esattamente la fattura che si
-- otterrebbe. Restano solo i numeri di identita' consumati da FATT_EMISSIONE
-- (l'IdFattura interno), che non sono il numero di fattura: quello lo calcola
-- FATT_Genera dal massimo esistente e non si sposta.
--
-- Restituisce due elenchi: la stima per cliente, e le voci di ogni stima.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.FATT_ANCI_Previsione
    @DataFattura date = NULL,   -- NULL = primo del mese corrente
    @IdCliente   int  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @DataFattura IS NULL
        SET @DataFattura = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1);

    -- gli stessi clienti che FATT_ANCI_Genera fatturerebbe
    DECLARE @daFare TABLE (IdCliente int PRIMARY KEY);
    INSERT INTO @daFare
    SELECT DISTINCT c.IdCliente
    FROM dbo.CLIENTI c
    WHERE (@IdCliente IS NULL OR c.IdCliente = @IdCliente)
      AND EXISTS (SELECT 1 FROM dbo.CLIENTI_CONDIZIONI cc
                  WHERE cc.IdCliente = c.IdCliente AND cc.CodTipoVendita = 'ANCI'
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
        -- Si annulla con un savepoint, non con ROLLBACK secco: quello annulla
        -- anche l'eventuale transazione di chi chiama (e con lei le tabelle
        -- temporanee create qui sopra). Il COMMIT chiude un livello ormai vuoto.
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
            IF XACT_STATE() = -1 ROLLBACK TRAN;             -- transazione compromessa: via tutto
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
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.FATT_ANCI_Previsione TO claude');
GO
