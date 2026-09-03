-- =============================================================
-- FATT_ANCI_Genera — la fatturazione ANCI, che prima era uno step dello
-- schedulatore (ANCI\DELIVERY-06_1_ElencoClienti + 06_11_GeneraFattura +
-- 06_2_ElencoFattura). Fattura a consuntivo: la data fattura e' il primo del
-- mese corrente e la fattura copre tutto quello che sta prima.
--
-- Fa due cose e restituisce due elenchi:
--   1) i clienti ANCI con condizioni attive e ancora senza fattura per quella
--      data: per ognuno, se @Genera = 1, chiama FATT_Genera (che fa i conti e,
--      se non c'e' nulla da fatturare, non lascia niente);
--   2) le fatture ANCI di quella data, con quello che serve all'applicazione
--      per i report e la mail di prefattura (era 06_2_ElencoFattura): il
--      prefisso dei file, i destinatari, i tipi di report per cliente.
-- Report e mail non stanno qui: un xlsx non si scrive da SQL e Database Mail
-- non e' configurato. Li fa l'API, che chiama questa stored.
--
-- @Genera = 0 non tocca nulla: serve alla pagina per mostrare lo stato.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.FATT_ANCI_Genera
    @DataFattura date = NULL,   -- NULL = primo del mese corrente
    @IdCliente   int  = NULL,   -- NULL = tutti i clienti ANCI
    @Genera      bit  = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @DataFattura IS NULL
        SET @DataFattura = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1);

    -- 1) chi e' da fatturare
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

    SELECT c.IdCliente, c.RagioneSociale, c.EmailPrefattura
    FROM @daFare d JOIN dbo.CLIENTI c ON c.IdCliente = d.IdCliente
    ORDER BY c.RagioneSociale;

    -- 2) una fattura per ognuno
    IF @Genera = 1
    BEGIN
        DECLARE @id int;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT IdCliente FROM @daFare;
        OPEN cur; FETCH NEXT FROM cur INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            INSERT INTO dbo.LOG_Exec (chiamata, parametri)
            VALUES ('FATT_ANCI_Genera', 'FATT_Genera @IdCliente=' + CONVERT(varchar(10), @id)
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
           1 AS TipoRiepilogo,
           CASE WHEN c.IdCliente = 5314 THEN 0 ELSE 1 END AS ReportCDC,
           CASE WHEN d.IdCliente IS NULL THEN 0 ELSE 1 END AS GenerataOra
    FROM dbo.FATT_EMISSIONE fa
    JOIN dbo.CLIENTI c ON c.IdCliente = fa.IdCliente
    LEFT JOIN @daFare d ON d.IdCliente = c.IdCliente
    WHERE fa.DataFattura = @DataFattura
      AND (@IdCliente IS NULL OR c.IdCliente = @IdCliente)
      AND EXISTS (SELECT 1 FROM dbo.CLIENTI_CONDIZIONI cc
                  WHERE cc.IdCliente = c.IdCliente AND cc.CodTipoVendita = 'ANCI')
    ORDER BY c.RagioneSociale;
END
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

-- la cartella dove finiscono i file: era Y:\DELIVERY\Fatturazione dello
-- schedulatore. Sul server l'app puo' scrivere solo nella temp (come il proxy
-- dei report), e %TEMP% lo espande l'API; i file si rifanno dalla pagina.
IF NOT EXISTS (SELECT 1 FROM dbo.PARAMETRI WHERE Nome = 'PercorsoFatturazione')
    INSERT INTO dbo.PARAMETRI (Nome, Valore) VALUES ('PercorsoFatturazione', '%TEMP%\speedyweb-fatturazione\');
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    EXEC('GRANT EXECUTE ON dbo.FATT_ANCI_Genera TO claude; GRANT EXECUTE ON dbo.AI_LOG_Exec_Add TO claude');
GO
