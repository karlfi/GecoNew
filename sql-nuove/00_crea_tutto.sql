-- ============================================================
-- Ge.C.O. Web - oggetti SQL della nuova webapp (prefisso AI_)
-- Script idempotente: si puo' rieseguire per creare/aggiornare tutto.
-- Genera SP + compila MENU_ELEMENTI.Link + permessi EXECUTE.
-- ============================================================
USE [DeliveryDB];
GO

-- ----------------------------------------------------------
-- AI_AuthLogin.sql
-- ----------------------------------------------------------
-- =============================================================
-- AI_AuthLogin — login per la nuova webapp
-- Verifica la password SERVER-SIDE (equivalente di SimpleCrypter.MD5
-- dell'app InDe: if passDB == MD5(pass)) e non restituisce MAI
-- password o hash al chiamante.
--
-- Esiti (prima colonna del primo result set):
--   0 = OK (seguono profilo utente + result set gruppi)
--   1 = credenziali non valide (utente inesistente, disattivato o pwd errata)
--   2 = utente bloccato per troppi tentativi
--   3 = utente solo-palmare (nessuna password web): accesso web negato
--
-- Convenzione: prefisso AI_ per tutte le SP della nuova webapp.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_AuthLogin
    @Utente    varchar(100),
    @Pwd       varchar(250),
    @MaxErrori int = 10          -- soglia di blocco: allineare a quella dell'app InDe
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IdUtente int, @PassDB varchar(50), @LoginErrors int;

    SELECT @IdUtente    = u.IdUtente,
           @PassDB      = u.Pass,
           @LoginErrors = ISNULL(u.LoginErrors, 0)
    FROM dbo.UTENTI u
    WHERE u.Utente = @Utente
      AND u.DataFine IS NULL;          -- stesso criterio di "utente attivo" di LogInCSO

    -- Utente inesistente o disattivato: esito generico, non riveliamo quale dei due
    IF @IdUtente IS NULL
    BEGIN
        SELECT 1 AS Esito;
        RETURN;
    END

    -- Utente solo-palmare (password vuota): mai ammesso dal web
    IF @PassDB IS NULL OR @PassDB = ''
    BEGIN
        SELECT 3 AS Esito;
        RETURN;
    END

    -- Bloccato per troppi tentativi falliti
    IF @LoginErrors >= @MaxErrori
    BEGIN
        SELECT 2 AS Esito;
        RETURN;
    END

    -- Confronto MD5 server-side. CONVERT(...,2) = hex senza prefisso '0x' (maiuscolo).
    -- NB: HASHBYTES su varchar lavora sulla code page del DB: per password ASCII
    --     (lettere/numeri/simboli comuni) e' identico all'MD5(UTF8) di .NET.
    --     Se esistono password con caratteri accentati, verificare un caso reale.
    IF UPPER(@PassDB) <> CONVERT(char(32), HASHBYTES('MD5', @Pwd), 2)
    BEGIN
        -- Il trigger TR_UP_UTENTI ignora gli update di soli LoginErrors/DataUltimoAccesso:
        -- niente spam in LogTabelle.
        UPDATE dbo.UTENTI
        SET LoginErrors = ISNULL(LoginErrors, 0) + 1
        WHERE IdUtente = @IdUtente;

        SELECT 1 AS Esito;
        RETURN;
    END

    -- Successo: azzero i tentativi e registro l'accesso
    UPDATE dbo.UTENTI
    SET LoginErrors = 0,
        DataUltimoAccesso = GETDATE()
    WHERE IdUtente = @IdUtente;

    -- Result set 1: esito + profilo per costruire il JWT (MAI Pass o hash)
    SELECT 0 AS Esito,
           u.IdUtente, u.Utente, u.Nome, u.Email,
           u.IdRuolo, r.Ruolo,
           u.IdFiliale, u.IdCliente, u.IdUtentePadre
    FROM dbo.UTENTI u
    LEFT JOIN dbo.RUOLI r ON r.IdRuolo = u.IdRuolo
    WHERE u.IdUtente = @IdUtente;

    -- Result set 2: gruppi dell'utente (per i claims di autorizzazione)
    SELECT g.IdGruppo, g.Gruppo
    FROM dbo.UTENTI_GRUPPI ug
    JOIN dbo.GRUPPI g ON g.IdGruppo = ug.IdGruppo
    WHERE ug.IdUtente = @IdUtente;
END
GO

-- ----------------------------------------------------------
-- AI_ElencoMenuGruppi.sql
-- ----------------------------------------------------------
-- =============================================================
-- AI_ElencoMenuGruppi — versione per la nuova webapp di ElencoMenuGruppi.
-- Identica alla SP legacy, ma restituisce in piu' la colonna Link
-- (mappatura menu -> pagina nuova). La SP legacy resta intatta per l'app InDe.
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.AI_ElencoMenuGruppi
    @IdUtente int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idRuolo int = NULL;

    IF @IdUtente IS NOT NULL
        SELECT @IdRuolo = idruolo FROM UTENTI WHERE IdUtente = @IdUtente;
    IF @IdRuolo IS NULL SET @IdRuolo = 99;

    -- tutte le righe di menu con il flag "Attivato" in funzione del RUOLO (escluse disabled)
    SELECT me.idmenuelemento, me.parentid, me.text, me.Videata, me.Parametri,
           me.navigateurl, me.ToolTip, me.Icon, me.Popup,
           MAX(CASE WHEN mr.idruolo IS NULL THEN 0 ELSE 1 END) AS Attivato
    INTO #tmp
    FROM menu_elementi me
    LEFT JOIN menu_elementiruoli lnk ON lnk.idmenuelemento = me.idmenuelemento
    LEFT JOIN ruoli mr ON mr.idruolo = lnk.idruolo AND mr.idruolo = @idruolo
    LEFT JOIN menu_elementi mp ON mp.idmenuelemento = me.parentid
    WHERE ISNULL(me.Disabled, 0) = 0
    GROUP BY me.idmenuelemento, me.parentid, me.text, me.navigateurl,
             me.Videata, me.Parametri, me.ToolTip, me.Icon, me.Popup;

    -- attivo le righe che rientrano nei GRUPPI dell'utente
    UPDATE #tmp SET Attivato = 1
    FROM #tmp me
    INNER JOIN MENU_ELEMENTIGRUPPI meg ON meg.IdMenu = me.IdMenuElemento
    INNER JOIN GRUPPI g ON g.IdGruppo = meg.IdGruppo
    INNER JOIN UTENTI_GRUPPI ug ON ug.IdGruppo = g.IdGruppo
    INNER JOIN UTENTI u ON u.IdUtente = ug.IdUtente AND u.IdUtente = @idutente;

    -- propago padre/figli
    SELECT x.*, ISNULL(xpadre.attivato, 0) AS PadreAttivo,
           ISNULL((SELECT MAX(Attivato) FROM #tmp WHERE ParentID = x.IdMenuElemento), 0) AS FiglioAttivo
    INTO #tmpDef
    FROM #tmp x
    LEFT JOIN #tmp AS xpadre ON xpadre.idmenuelemento = x.parentid;

    SELECT me.IdMenuElemento AS ID, me.ParentID, me.Text, me.Videata, me.Parametri,
           me.NavigateUrl, me.ToolTip, me.Icon, me.Popup,
           me.Link,                                 -- << aggiunta per la nuova app
           CASE WHEN me.parentid = 0
                THEN 100 - COALESCE(me.sorting, me.idmenuelemento)
                ELSE COALESCE(mp.sorting, mp.idmenuelemento) * 10000 + COALESCE(me.sorting, me.idmenuelemento) * 100
           END AS sorting
    FROM #tmpDef xdef
    INNER JOIN menu_elementi me ON me.IdMenuElemento = xdef.IdMenuElemento
    LEFT JOIN menu_elementi mp ON mp.idmenuelemento = me.parentid
    WHERE Attivato + PadreAttivo + FiglioAttivo > 0
    ORDER BY sorting;
END
GO

-- ----------------------------------------------------------
-- AI_GEO_COPERTURE_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [GEO_COPERTURE]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_GEO_COPERTURE_Save
    @IdCopertura int = NULL,
    @CAP varchar(5) = NULL,
    @TipoArea varchar(10) = NULL,
    @SIGLAPROV varchar(2) = NULL,
    @BELFIORE varchar(5) = NULL,
    @IdProdotto int = NULL,
    @IdFilialeDistribuzione int = NULL,
    @IdFilialeGiacenza int = NULL,
    @Giorni int = NULL,
    @Isola int = NULL,
    @AreaDisagiata int = NULL,
    @AttivoDal date = NULL,
    @FinoAl date = NULL,
    @Comune varchar(250) = NULL,
    @DataModifica datetime = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdCopertura IS NULL OR @IdCopertura = 0
    BEGIN
        INSERT INTO [GEO_COPERTURE] ([CAP], [TipoArea], [SIGLAPROV], [BELFIORE], [IdProdotto], [IdFilialeDistribuzione], [IdFilialeGiacenza], [Giorni], [Isola], [AreaDisagiata], [AttivoDal], [FinoAl], [Comune], [DataModifica])
        VALUES (@CAP, @TipoArea, @SIGLAPROV, @BELFIORE, @IdProdotto, @IdFilialeDistribuzione, @IdFilialeGiacenza, @Giorni, @Isola, @AreaDisagiata, @AttivoDal, @FinoAl, @Comune, @DataModifica);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [GEO_COPERTURE] SET
            [CAP] = @CAP,
            [TipoArea] = @TipoArea,
            [SIGLAPROV] = @SIGLAPROV,
            [BELFIORE] = @BELFIORE,
            [IdProdotto] = @IdProdotto,
            [IdFilialeDistribuzione] = @IdFilialeDistribuzione,
            [IdFilialeGiacenza] = @IdFilialeGiacenza,
            [Giorni] = @Giorni,
            [Isola] = @Isola,
            [AreaDisagiata] = @AreaDisagiata,
            [AttivoDal] = @AttivoDal,
            [FinoAl] = @FinoAl,
            [Comune] = @Comune,
            [DataModifica] = @DataModifica
        WHERE [IdCopertura] = @IdCopertura;
        SELECT @IdCopertura AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_PRODOTTI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [PRODOTTI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_PRODOTTI_Save
    @IdProdotto int = NULL,
    @Prodotto varchar(50) = NULL,
    @CodFamiglia varchar(5) = NULL,
    @IdPalmServizio int = NULL,
    @IdProcesso int = NULL,
    @IdGruppoProdotto int = NULL,
    @IdListino int = NULL,
    @Figlio int = NULL,
    @IdProdottoCollegato int = NULL,
    @IdProdottoCollegatoTerzi int = NULL,
    @Sigla varchar(50) = NULL,
    @DataFineValidita smalldatetime = NULL,
    @MultiPeso int = NULL,
    @CodConsip varchar(50) = NULL,
    @CodSpike varchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdProdotto IS NULL OR @IdProdotto = 0
    BEGIN
        INSERT INTO [PRODOTTI] ([Prodotto], [CodFamiglia], [IdPalmServizio], [IdProcesso], [IdGruppoProdotto], [IdListino], [Figlio], [IdProdottoCollegato], [IdProdottoCollegatoTerzi], [Sigla], [DataFineValidita], [MultiPeso], [CodConsip], [CodSpike])
        VALUES (@Prodotto, @CodFamiglia, @IdPalmServizio, @IdProcesso, @IdGruppoProdotto, @IdListino, @Figlio, @IdProdottoCollegato, @IdProdottoCollegatoTerzi, @Sigla, @DataFineValidita, @MultiPeso, @CodConsip, @CodSpike);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [PRODOTTI] SET
            [Prodotto] = @Prodotto,
            [CodFamiglia] = @CodFamiglia,
            [IdPalmServizio] = @IdPalmServizio,
            [IdProcesso] = @IdProcesso,
            [IdGruppoProdotto] = @IdGruppoProdotto,
            [IdListino] = @IdListino,
            [Figlio] = @Figlio,
            [IdProdottoCollegato] = @IdProdottoCollegato,
            [IdProdottoCollegatoTerzi] = @IdProdottoCollegatoTerzi,
            [Sigla] = @Sigla,
            [DataFineValidita] = @DataFineValidita,
            [MultiPeso] = @MultiPeso,
            [CodConsip] = @CodConsip,
            [CodSpike] = @CodSpike
        WHERE [IdProdotto] = @IdProdotto;
        SELECT @IdProdotto AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_FATT_LISTINI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [FATT_LISTINI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_FATT_LISTINI_Save
    @IdListino int = NULL,
    @CodiceListino varchar(50) = NULL,
    @Descrizione varchar(50) = NULL,
    @IdProdotto int = NULL,
    @IdCliente int = NULL,
    @PrezzoAttivo float = NULL,
    @ScontoAttivo float = NULL,
    @PrezzoPassivo float = NULL,
    @ScontoPassivo float = NULL,
    @AliquotaIVA int = NULL,
    @ValidoDal date = NULL,
    @ValidoAl date = NULL,
    @ProdottoServizio varchar(5) = NULL,
    @TipoArea varchar(10) = NULL,
    @Porto int = NULL,
    @PesoMin int = NULL,
    @PesoMax int = NULL,
    @Tipo varchar(100) = NULL,
    @tariffaOS float = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdListino IS NULL OR @IdListino = 0
    BEGIN
        INSERT INTO [FATT_LISTINI] ([CodiceListino], [Descrizione], [IdProdotto], [IdCliente], [PrezzoAttivo], [ScontoAttivo], [PrezzoPassivo], [ScontoPassivo], [AliquotaIVA], [ValidoDal], [ValidoAl], [ProdottoServizio], [TipoArea], [Porto], [PesoMin], [PesoMax], [Tipo], [tariffaOS])
        VALUES (@CodiceListino, @Descrizione, @IdProdotto, @IdCliente, @PrezzoAttivo, @ScontoAttivo, @PrezzoPassivo, @ScontoPassivo, @AliquotaIVA, @ValidoDal, @ValidoAl, @ProdottoServizio, @TipoArea, @Porto, @PesoMin, @PesoMax, @Tipo, @tariffaOS);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [FATT_LISTINI] SET
            [CodiceListino] = @CodiceListino,
            [Descrizione] = @Descrizione,
            [IdProdotto] = @IdProdotto,
            [IdCliente] = @IdCliente,
            [PrezzoAttivo] = @PrezzoAttivo,
            [ScontoAttivo] = @ScontoAttivo,
            [PrezzoPassivo] = @PrezzoPassivo,
            [ScontoPassivo] = @ScontoPassivo,
            [AliquotaIVA] = @AliquotaIVA,
            [ValidoDal] = @ValidoDal,
            [ValidoAl] = @ValidoAl,
            [ProdottoServizio] = @ProdottoServizio,
            [TipoArea] = @TipoArea,
            [Porto] = @Porto,
            [PesoMin] = @PesoMin,
            [PesoMax] = @PesoMax,
            [Tipo] = @Tipo,
            [tariffaOS] = @tariffaOS
        WHERE [IdListino] = @IdListino;
        SELECT @IdListino AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_PROCESSI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [PROCESSI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_PROCESSI_Save
    @IdProcesso int = NULL,
    @Processo varchar(50) = NULL,
    @GiorniSLA int = NULL,
    @CodFamiglia varchar(5) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdProcesso IS NULL OR @IdProcesso = 0
    BEGIN
        INSERT INTO [PROCESSI] ([Processo], [GiorniSLA], [CodFamiglia])
        VALUES (@Processo, @GiorniSLA, @CodFamiglia);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [PROCESSI] SET
            [Processo] = @Processo,
            [GiorniSLA] = @GiorniSLA,
            [CodFamiglia] = @CodFamiglia
        WHERE [IdProcesso] = @IdProcesso;
        SELECT @IdProcesso AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_GRUPPI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [GRUPPI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_GRUPPI_Save
    @IdGruppo int = NULL,
    @Gruppo varchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdGruppo IS NULL OR @IdGruppo = 0
    BEGIN
        INSERT INTO [GRUPPI] ([Gruppo])
        VALUES (@Gruppo);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [GRUPPI] SET
            [Gruppo] = @Gruppo
        WHERE [IdGruppo] = @IdGruppo;
        SELECT @IdGruppo AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_AZIENDE_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [AZIENDE]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_AZIENDE_Save
    @IdAzienda int = NULL,
    @Azienda varchar(50) = NULL,
    @PartitaIva varchar(50) = NULL,
    @CodiceSDI varchar(50) = NULL,
    @Email varchar(50) = NULL,
    @Pec varchar(50) = NULL,
    @RappresentanteLegale varchar(50) = NULL,
    @Amm_Contatto varchar(50) = NULL,
    @Amm_Telefono varchar(50) = NULL,
    @Indirizzo varchar(50) = NULL,
    @Cap varchar(5) = NULL,
    @Prov varchar(2) = NULL,
    @IdAziendaMaster int = NULL,
    @NomeLogoPalmare varchar(50) = NULL,
    @EmailAssistenza varchar(500) = NULL,
    @GestionePresenze int = NULL,
    @Web varchar(150) = NULL,
    @IdFilialeDistribuzione int = NULL,
    @Comune varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdAzienda IS NULL OR @IdAzienda = 0
    BEGIN
        INSERT INTO [AZIENDE] ([Azienda], [PartitaIva], [CodiceSDI], [Email], [Pec], [RappresentanteLegale], [Amm_Contatto], [Amm_Telefono], [Indirizzo], [Cap], [Prov], [IdAziendaMaster], [NomeLogoPalmare], [EmailAssistenza], [GestionePresenze], [Web], [IdFilialeDistribuzione], [Comune])
        VALUES (@Azienda, @PartitaIva, @CodiceSDI, @Email, @Pec, @RappresentanteLegale, @Amm_Contatto, @Amm_Telefono, @Indirizzo, @Cap, @Prov, @IdAziendaMaster, @NomeLogoPalmare, @EmailAssistenza, @GestionePresenze, @Web, @IdFilialeDistribuzione, @Comune);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [AZIENDE] SET
            [Azienda] = @Azienda,
            [PartitaIva] = @PartitaIva,
            [CodiceSDI] = @CodiceSDI,
            [Email] = @Email,
            [Pec] = @Pec,
            [RappresentanteLegale] = @RappresentanteLegale,
            [Amm_Contatto] = @Amm_Contatto,
            [Amm_Telefono] = @Amm_Telefono,
            [Indirizzo] = @Indirizzo,
            [Cap] = @Cap,
            [Prov] = @Prov,
            [IdAziendaMaster] = @IdAziendaMaster,
            [NomeLogoPalmare] = @NomeLogoPalmare,
            [EmailAssistenza] = @EmailAssistenza,
            [GestionePresenze] = @GestionePresenze,
            [Web] = @Web,
            [IdFilialeDistribuzione] = @IdFilialeDistribuzione,
            [Comune] = @Comune
        WHERE [IdAzienda] = @IdAzienda;
        SELECT @IdAzienda AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_FILIALI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [FILIALI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_FILIALI_Save
    @IDFILIALE int = NULL,
    @FILIALE varchar(50) = NULL,
    @IdAzienda int = NULL,
    @Indirizzo varchar(250) = NULL,
    @CAP varchar(5) = NULL,
    @Comune varchar(250) = NULL,
    @Prov varchar(2) = NULL,
    @Orari varchar(250) = NULL,
    @Telefono varchar(50) = NULL,
    @Email varchar(50) = NULL,
    @Latitude float = NULL,
    @Longitude float = NULL,
    @IdReferente int = NULL,
    @Cellulare varchar(50) = NULL,
    @FilialeGiacenza int = NULL,
    @FilialeDistribuzione int = NULL,
    @DataAttivazione date = NULL,
    @DataChiusura date = NULL,
    @IdFilialeSpeedy int = NULL,
    @IncrementoGGiacenza int = NULL,
    @bCode varchar(3) = NULL,
    @CodZUK varchar(50) = NULL,
    @IBAN varchar(50) = NULL,
    @DirFTP varchar(50) = NULL,
    @NXV varchar(250) = NULL,
    @DescScontrino varchar(250) = NULL,
    @GeoNormalizza int = NULL,
    @HRParcel varchar(50) = NULL,
    @Inpost varchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IDFILIALE IS NULL OR @IDFILIALE = 0
    BEGIN
        INSERT INTO [FILIALI] ([FILIALE], [IdAzienda], [Indirizzo], [CAP], [Comune], [Prov], [Orari], [Telefono], [Email], [Latitude], [Longitude], [IdReferente], [Cellulare], [FilialeGiacenza], [FilialeDistribuzione], [DataAttivazione], [DataChiusura], [IdFilialeSpeedy], [IncrementoGGiacenza], [bCode], [CodZUK], [IBAN], [DirFTP], [NXV], [DescScontrino], [GeoNormalizza], [HRParcel], [Inpost])
        VALUES (@FILIALE, @IdAzienda, @Indirizzo, @CAP, @Comune, @Prov, @Orari, @Telefono, @Email, @Latitude, @Longitude, @IdReferente, @Cellulare, @FilialeGiacenza, @FilialeDistribuzione, @DataAttivazione, @DataChiusura, @IdFilialeSpeedy, @IncrementoGGiacenza, @bCode, @CodZUK, @IBAN, @DirFTP, @NXV, @DescScontrino, @GeoNormalizza, @HRParcel, @Inpost);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [FILIALI] SET
            [FILIALE] = @FILIALE,
            [IdAzienda] = @IdAzienda,
            [Indirizzo] = @Indirizzo,
            [CAP] = @CAP,
            [Comune] = @Comune,
            [Prov] = @Prov,
            [Orari] = @Orari,
            [Telefono] = @Telefono,
            [Email] = @Email,
            [Latitude] = @Latitude,
            [Longitude] = @Longitude,
            [IdReferente] = @IdReferente,
            [Cellulare] = @Cellulare,
            [FilialeGiacenza] = @FilialeGiacenza,
            [FilialeDistribuzione] = @FilialeDistribuzione,
            [DataAttivazione] = @DataAttivazione,
            [DataChiusura] = @DataChiusura,
            [IdFilialeSpeedy] = @IdFilialeSpeedy,
            [IncrementoGGiacenza] = @IncrementoGGiacenza,
            [bCode] = @bCode,
            [CodZUK] = @CodZUK,
            [IBAN] = @IBAN,
            [DirFTP] = @DirFTP,
            [NXV] = @NXV,
            [DescScontrino] = @DescScontrino,
            [GeoNormalizza] = @GeoNormalizza,
            [HRParcel] = @HRParcel,
            [Inpost] = @Inpost
        WHERE [IDFILIALE] = @IDFILIALE;
        SELECT @IDFILIALE AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_CLIENTI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [CLIENTI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_CLIENTI_Save
    @IdCliente int = NULL,
    @IdAzienda int = NULL,
    @RagioneSociale varchar(250) = NULL,
    @CIG varchar(50) = NULL,
    @Descrizione varchar(500) = NULL,
    @PartitaIva varchar(50) = NULL,
    @CodSDI varchar(50) = NULL,
    @PEC varchar(50) = NULL,
    @Indirizzo varchar(250) = NULL,
    @CAP varchar(5) = NULL,
    @Comune varchar(250) = NULL,
    @Prov varchar(2) = NULL,
    @Nazione varchar(5) = NULL,
    @Telefono varchar(50) = NULL,
    @Email varchar(50) = NULL,
    @DataFine date = NULL,
    @CodiceCliente varchar(50) = NULL,
    @Gestionale varchar(50) = NULL,
    @InvioEmailEventi int = NULL,
    @EmailPrefattura varchar(2000) = NULL,
    @Demo int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdCliente IS NULL OR @IdCliente = 0
    BEGIN
        INSERT INTO [CLIENTI] ([IdAzienda], [RagioneSociale], [CIG], [Descrizione], [PartitaIva], [CodSDI], [PEC], [Indirizzo], [CAP], [Comune], [Prov], [Nazione], [Telefono], [Email], [DataFine], [CodiceCliente], [Gestionale], [InvioEmailEventi], [EmailPrefattura], [Demo])
        VALUES (@IdAzienda, @RagioneSociale, @CIG, @Descrizione, @PartitaIva, @CodSDI, @PEC, @Indirizzo, @CAP, @Comune, @Prov, @Nazione, @Telefono, @Email, @DataFine, @CodiceCliente, @Gestionale, @InvioEmailEventi, @EmailPrefattura, @Demo);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [CLIENTI] SET
            [IdAzienda] = @IdAzienda,
            [RagioneSociale] = @RagioneSociale,
            [CIG] = @CIG,
            [Descrizione] = @Descrizione,
            [PartitaIva] = @PartitaIva,
            [CodSDI] = @CodSDI,
            [PEC] = @PEC,
            [Indirizzo] = @Indirizzo,
            [CAP] = @CAP,
            [Comune] = @Comune,
            [Prov] = @Prov,
            [Nazione] = @Nazione,
            [Telefono] = @Telefono,
            [Email] = @Email,
            [DataFine] = @DataFine,
            [CodiceCliente] = @CodiceCliente,
            [Gestionale] = @Gestionale,
            [InvioEmailEventi] = @InvioEmailEventi,
            [EmailPrefattura] = @EmailPrefattura,
            [Demo] = @Demo
        WHERE [IdCliente] = @IdCliente;
        SELECT @IdCliente AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_FILE_TRACCIATO_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [FILE_TRACCIATO]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_FILE_TRACCIATO_Save
    @IdTracciato int = NULL,
    @Tracciato varchar(50) = NULL,
    @IdUtente int = NULL,
    @IdCliente int = NULL,
    @Separatore varchar(50) = NULL,
    @ColonneTotali int = NULL,
    @infoTracciato varchar(250) = NULL,
    @RigheIntestazione int = NULL,
    @RigheFooter int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdTracciato IS NULL OR @IdTracciato = 0
    BEGIN
        INSERT INTO [FILE_TRACCIATO] ([Tracciato], [IdUtente], [IdCliente], [Separatore], [ColonneTotali], [infoTracciato], [RigheIntestazione], [RigheFooter])
        VALUES (@Tracciato, @IdUtente, @IdCliente, @Separatore, @ColonneTotali, @infoTracciato, @RigheIntestazione, @RigheFooter);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [FILE_TRACCIATO] SET
            [Tracciato] = @Tracciato,
            [IdUtente] = @IdUtente,
            [IdCliente] = @IdCliente,
            [Separatore] = @Separatore,
            [ColonneTotali] = @ColonneTotali,
            [infoTracciato] = @infoTracciato,
            [RigheIntestazione] = @RigheIntestazione,
            [RigheFooter] = @RigheFooter
        WHERE [IdTracciato] = @IdTracciato;
        SELECT @IdTracciato AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_FORNITORI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [FORNITORI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_FORNITORI_Save
    @ID int = NULL,
    @Fornitore varchar(255) = NULL,
    @Tipo int = NULL,
    @CPCODICE varchar(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @ID IS NULL OR @ID = 0
    BEGIN
        INSERT INTO [FORNITORI] ([Fornitore], [Tipo], [CPCODICE])
        VALUES (@Fornitore, @Tipo, @CPCODICE);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [FORNITORI] SET
            [Fornitore] = @Fornitore,
            [Tipo] = @Tipo,
            [CPCODICE] = @CPCODICE
        WHERE [ID] = @ID;
        SELECT @ID AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_LISTA_VALORI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [LISTA_VALORI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_LISTA_VALORI_Save
    @IdListaValori int = NULL,
    @Lista varchar(50) = NULL,
    @Valore varchar(500) = NULL,
    @Codice varchar(50) = NULL,
    @Ordine int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdListaValori IS NULL OR @IdListaValori = 0
    BEGIN
        INSERT INTO [LISTA_VALORI] ([Lista], [Valore], [Codice], [Ordine])
        VALUES (@Lista, @Valore, @Codice, @Ordine);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [LISTA_VALORI] SET
            [Lista] = @Lista,
            [Valore] = @Valore,
            [Codice] = @Codice,
            [Ordine] = @Ordine
        WHERE [IdListaValori] = @IdListaValori;
        SELECT @IdListaValori AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_MITTENTI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [MITTENTI]. Scritture solo via SP (prefisso AI_).
-- Nota: la tabella non ha PK dichiarata; la chiave logica e' l'identity IdMittente.
-- Nota: la colonna [CODICE_FISCALE ] ha uno SPAZIO finale nel nome (legacy). Il parametro
--       e' @CODICE_FISCALE (senza spazio, il backend fa TrimEnd sui nomi); la colonna
--       viene referenziata con le parentesi quadre comprensive dello spazio.
CREATE OR ALTER PROCEDURE dbo.AI_MITTENTI_Save
    @IdMittente int = NULL,
    @UFFICIOSPEDITORE varchar(250) = NULL,
    @FILIALECOMPETENZA varchar(250) = NULL,
    @COMUNE varchar(250) = NULL,
    @PROV varchar(2) = NULL,
    @INDIRIZZO varchar(250) = NULL,
    @NOTE1 varchar(250) = NULL,
    @CAP varchar(250) = NULL,
    @NOTE2 varchar(250) = NULL,
    @NomeControlloReportistica varchar(250) = NULL,
    @EmailControlloReportistica varchar(250) = NULL,
    @Telefonocontrolloreportistica varchar(250) = NULL,
    @NomeControlloReportistica2 varchar(250) = NULL,
    @EmailControlloReportistica2 varchar(250) = NULL,
    @Telefonocontrolloreportistica2 varchar(250) = NULL,
    @CODICE_FISCALE varchar(250) = NULL,
    @CODICE_UNIVOCO varchar(250) = NULL,
    @idFilialeDistribuzione int = NULL,
    @idCliente int = NULL,
    @LU int = NULL,
    @MA int = NULL,
    @ME int = NULL,
    @GI int = NULL,
    @VE int = NULL,
    @SA int = NULL,
    @idStpRepFunz int = NULL,
    @email_mittente varchar(250) = NULL,
    @Responsabile_operativo varchar(250) = NULL,
    @Email_operativa varchar(250) = NULL,
    @Resp_amministrativo varchar(250) = NULL,
    @Email_amministrativo varchar(250) = NULL,
    @idUfficioMitt int = NULL,
    @DescScontrino varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdMittente IS NULL OR @IdMittente = 0
    BEGIN
        INSERT INTO [MITTENTI] ([UFFICIOSPEDITORE], [FILIALECOMPETENZA], [COMUNE], [PROV], [INDIRIZZO], [NOTE1], [CAP], [NOTE2], [NomeControlloReportistica], [EmailControlloReportistica], [Telefonocontrolloreportistica], [NomeControlloReportistica2], [EmailControlloReportistica2], [Telefonocontrolloreportistica2], [CODICE_FISCALE ], [CODICE_UNIVOCO], [idFilialeDistribuzione], [idCliente], [LU], [MA], [ME], [GI], [VE], [SA], [idStpRepFunz], [email_mittente], [Responsabile_operativo], [Email_operativa], [Resp_amministrativo], [Email_amministrativo], [idUfficioMitt], [DescScontrino])
        VALUES (@UFFICIOSPEDITORE, @FILIALECOMPETENZA, @COMUNE, @PROV, @INDIRIZZO, @NOTE1, @CAP, @NOTE2, @NomeControlloReportistica, @EmailControlloReportistica, @Telefonocontrolloreportistica, @NomeControlloReportistica2, @EmailControlloReportistica2, @Telefonocontrolloreportistica2, @CODICE_FISCALE, @CODICE_UNIVOCO, @idFilialeDistribuzione, @idCliente, @LU, @MA, @ME, @GI, @VE, @SA, @idStpRepFunz, @email_mittente, @Responsabile_operativo, @Email_operativa, @Resp_amministrativo, @Email_amministrativo, @idUfficioMitt, @DescScontrino);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [MITTENTI] SET
            [UFFICIOSPEDITORE] = @UFFICIOSPEDITORE,
            [FILIALECOMPETENZA] = @FILIALECOMPETENZA,
            [COMUNE] = @COMUNE,
            [PROV] = @PROV,
            [INDIRIZZO] = @INDIRIZZO,
            [NOTE1] = @NOTE1,
            [CAP] = @CAP,
            [NOTE2] = @NOTE2,
            [NomeControlloReportistica] = @NomeControlloReportistica,
            [EmailControlloReportistica] = @EmailControlloReportistica,
            [Telefonocontrolloreportistica] = @Telefonocontrolloreportistica,
            [NomeControlloReportistica2] = @NomeControlloReportistica2,
            [EmailControlloReportistica2] = @EmailControlloReportistica2,
            [Telefonocontrolloreportistica2] = @Telefonocontrolloreportistica2,
            [CODICE_FISCALE ] = @CODICE_FISCALE,
            [CODICE_UNIVOCO] = @CODICE_UNIVOCO,
            [idFilialeDistribuzione] = @idFilialeDistribuzione,
            [idCliente] = @idCliente,
            [LU] = @LU,
            [MA] = @MA,
            [ME] = @ME,
            [GI] = @GI,
            [VE] = @VE,
            [SA] = @SA,
            [idStpRepFunz] = @idStpRepFunz,
            [email_mittente] = @email_mittente,
            [Responsabile_operativo] = @Responsabile_operativo,
            [Email_operativa] = @Email_operativa,
            [Resp_amministrativo] = @Resp_amministrativo,
            [Email_amministrativo] = @Email_amministrativo,
            [idUfficioMitt] = @idUfficioMitt,
            [DescScontrino] = @DescScontrino
        WHERE [IdMittente] = @IdMittente;
        SELECT @IdMittente AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_SPED_STATI_Save.sql  (pagina "Stati")
-- ----------------------------------------------------------
-- Upsert di [SPED_STATI]. PK = STATO (varchar, codice digitato per i nuovi record);
-- IdStato e' un identity SEPARATO (non si tocca). L'upsert si decide per ESISTENZA di STATO.
CREATE OR ALTER PROCEDURE dbo.AI_SPED_STATI_Save
    @STATO varchar(50) = NULL,
    @Descrizione varchar(50) = NULL,
    @CodGruppoStati varchar(5) = NULL,
    @DescrizioneCliente varchar(50) = NULL,
    @VisibileCliente int = NULL,
    @CodEsitoAder varchar(2) = NULL,
    @CodConsip varchar(50) = NULL,
    @ADER4 varchar(50) = NULL,
    @ADER4_Motivo varchar(1) = NULL,
    @Bloccante int = NULL,
    @CodSNEM varchar(50) = NULL,
    @CodADEX varchar(4) = NULL,
    @IdStato int = NULL          -- identity: accettato dal frontend ma mai scritto
AS
BEGIN
    SET NOCOUNT ON;
    IF @STATO IS NULL OR LTRIM(RTRIM(@STATO)) = ''
    BEGIN
        RAISERROR('Il codice STATO e'' obbligatorio.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM [SPED_STATI] WHERE [STATO] = @STATO)
    BEGIN
        INSERT INTO [SPED_STATI] ([STATO], [Descrizione], [CodGruppoStati], [DescrizioneCliente], [VisibileCliente], [CodEsitoAder], [CodConsip], [ADER4], [ADER4_Motivo], [Bloccante], [CodSNEM], [CodADEX])
        VALUES (@STATO, @Descrizione, @CodGruppoStati, @DescrizioneCliente, @VisibileCliente, @CodEsitoAder, @CodConsip, @ADER4, @ADER4_Motivo, @Bloccante, @CodSNEM, @CodADEX);
    END
    ELSE
    BEGIN
        UPDATE [SPED_STATI] SET
            [Descrizione] = @Descrizione,
            [CodGruppoStati] = @CodGruppoStati,
            [DescrizioneCliente] = @DescrizioneCliente,
            [VisibileCliente] = @VisibileCliente,
            [CodEsitoAder] = @CodEsitoAder,
            [CodConsip] = @CodConsip,
            [ADER4] = @ADER4,
            [ADER4_Motivo] = @ADER4_Motivo,
            [Bloccante] = @Bloccante,
            [CodSNEM] = @CodSNEM,
            [CodADEX] = @CodADEX
        WHERE [STATO] = @STATO;
    END

    SELECT (SELECT [IdStato] FROM [SPED_STATI] WHERE [STATO] = @STATO) AS id;
END
GO

-- ----------------------------------------------------------
-- AI_INTERROGAZIONI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [INTERROGAZIONI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_INTERROGAZIONI_Save
    @IdQuery int = NULL,
    @Titolo varchar(500) = NULL,
    @Descrizione varchar(5000) = NULL,
    @Query varchar(5000) = NULL,
    @SqlSelect varchar(5000) = NULL,
    @SqlFrom varchar(5000) = NULL,
    @SqlWhere varchar(5000) = NULL,
    @SqlGroup varchar(5000) = NULL,
    @SqlOrder varchar(5000) = NULL,
    @Alias varchar(5000) = NULL,
    @Visibilita int = NULL,
    @Parametri varchar(250) = NULL,
    @CanSee varchar(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdQuery IS NULL OR @IdQuery = 0
    BEGIN
        INSERT INTO [INTERROGAZIONI] ([Titolo], [Descrizione], [Query], [SqlSelect], [SqlFrom], [SqlWhere], [SqlGroup], [SqlOrder], [Alias], [Visibilita], [Parametri], [CanSee])
        VALUES (@Titolo, @Descrizione, @Query, @SqlSelect, @SqlFrom, @SqlWhere, @SqlGroup, @SqlOrder, @Alias, @Visibilita, @Parametri, @CanSee);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [INTERROGAZIONI] SET
            [Titolo] = @Titolo,
            [Descrizione] = @Descrizione,
            [Query] = @Query,
            [SqlSelect] = @SqlSelect,
            [SqlFrom] = @SqlFrom,
            [SqlWhere] = @SqlWhere,
            [SqlGroup] = @SqlGroup,
            [SqlOrder] = @SqlOrder,
            [Alias] = @Alias,
            [Visibilita] = @Visibilita,
            [Parametri] = @Parametri,
            [CanSee] = @CanSee
        WHERE [IdQuery] = @IdQuery;
        SELECT @IdQuery AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_MENU_ELEMENTI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [MENU_ELEMENTI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_MENU_ELEMENTI_Save
    @IdMenuElemento int = NULL,
    @ParentID int = NULL,
    @Text varchar(255) = NULL,
    @Descrizione varchar(255) = NULL,
    @Videata varchar(50) = NULL,
    @Link varchar(4000) = NULL,
    @Parametri varchar(max) = NULL,
    @NavigateUrl varchar(255) = NULL,
    @Sorting int = NULL,
    @ToolTip varchar(250) = NULL,
    @Disabled int = NULL,
    @Icon varchar(250) = NULL,
    @Popup int = NULL,
    @CodFamiglia varchar(1) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdMenuElemento IS NULL OR @IdMenuElemento = 0
    BEGIN
        INSERT INTO [MENU_ELEMENTI] ([ParentID], [Text], [Descrizione], [Videata], [Link], [Parametri], [NavigateUrl], [Sorting], [ToolTip], [Disabled], [Icon], [Popup], [CodFamiglia])
        VALUES (@ParentID, @Text, @Descrizione, @Videata, @Link, @Parametri, @NavigateUrl, @Sorting, @ToolTip, @Disabled, @Icon, @Popup, @CodFamiglia);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [MENU_ELEMENTI] SET
            [ParentID] = @ParentID,
            [Text] = @Text,
            [Descrizione] = @Descrizione,
            [Videata] = @Videata,
            [Link] = @Link,
            [Parametri] = @Parametri,
            [NavigateUrl] = @NavigateUrl,
            [Sorting] = @Sorting,
            [ToolTip] = @ToolTip,
            [Disabled] = @Disabled,
            [Icon] = @Icon,
            [Popup] = @Popup,
            [CodFamiglia] = @CodFamiglia
        WHERE [IdMenuElemento] = @IdMenuElemento;
        SELECT @IdMenuElemento AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_UTENTI_Save.sql
-- ----------------------------------------------------------
-- AI_UTENTI_Save: upsert utente. La password si imposta SOLO passando @NuovaPassword
-- (hash MD5 server-side, come AI_AuthLogin). In update, se @NuovaPassword e' NULL la Pass resta invariata.
CREATE OR ALTER PROCEDURE dbo.AI_UTENTI_Save
    @IdUtente int = NULL,
    @Utente varchar(100) = NULL,
    @Email varchar(50) = NULL,
    @Nome varchar(50) = NULL,
    @CodiceFiscale varchar(16) = NULL,
    @IdRuolo int = NULL,
    @IdUtentePadre int = NULL,
    @LoginErrors int = NULL,
    @DataUltimoAccesso datetime = NULL,
    @IdFiliale int = NULL,
    @DataInizio smalldatetime = NULL,
    @DataFine smalldatetime = NULL,
    @RECHASH varchar(50) = NULL,
    @RECDATA datetime = NULL,
    @IdCliente int = NULL,
    @codAppLogin varchar(50) = NULL,
    @IdMezzo_Default int = NULL,
    @CodPoste varchar(50) = NULL,
    @CodADER4 varchar(8) = NULL,
    @Telefono varchar(50) = NULL,
    @CERT_ProfiloCertificatore smalldatetime = NULL,
    @CERT_CertificatoValido smalldatetime = NULL,
    @CERT_IdUtenteCertificatore int = NULL,
    @CERT_Alias varchar(50) = NULL,
    @CERT_PIN varchar(50) = NULL,
    @CERT_Tentativi int = NULL,
    @CERT_StatoNascita varchar(2) = NULL,
    @CERT_uniqueidentifier varchar(50) = NULL,
    @CERT_DataRevoca smalldatetime = NULL,
    @CERT_DataSospensione smalldatetime = NULL,
    @CERT_SerialNumber varchar(50) = NULL,
    @CERT_DataScadenza smalldatetime = NULL,
    @CERT_TempSospeso smalldatetime = NULL,
    @CodADER varchar(10) = NULL,
    @FotoTessera varchar(2000) = NULL,
    @FirmaEstesa varchar(2000) = NULL,
    @FirmaSigla varchar(2000) = NULL,
    @flagFirma int = NULL,
    @idAziendaFatt int = NULL,
    @Partime float = NULL,
    @IndirizzoRes varchar(250) = NULL,
    @CapRes varchar(50) = NULL,
    @ComuneRes varchar(250) = NULL,
    @ProvRes varchar(50) = NULL,
    @Matricola varchar(50) = NULL,
    @DataNascita date = NULL,
    @GiorniLavorativi varchar(50) = NULL,
    @OrarioLavoro varchar(50) = NULL,
    @Livello varchar(50) = NULL,
    @Mansione varchar(50) = NULL,
    @Iban varchar(50) = NULL,
    @NumeroScarpe varchar(50) = NULL,
    @TagliaAbbigliamento varchar(50) = NULL,
    @Note varchar(50) = NULL,
    @Stato varchar(50) = NULL,
    @Colore varchar(50) = NULL,
    @Cod_iMile varchar(100) = NULL,
    @tokenAutoLogin varchar(50) = NULL,
    @tokenRegistrazione varchar(50) = NULL,
    @NuovaPassword varchar(250) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @hash varchar(32) = CASE WHEN @NuovaPassword IS NULL THEN NULL
        ELSE CONVERT(char(32), HASHBYTES('MD5', @NuovaPassword), 2) END;
    IF @IdUtente IS NULL OR @IdUtente = 0
    BEGIN
        INSERT INTO [UTENTI] ([Utente], [Email], [Nome], [CodiceFiscale], [IdRuolo], [IdUtentePadre], [LoginErrors], [DataUltimoAccesso], [IdFiliale], [DataInizio], [DataFine], [RECHASH], [RECDATA], [IdCliente], [codAppLogin], [IdMezzo_Default], [CodPoste], [CodADER4], [Telefono], [CERT_ProfiloCertificatore], [CERT_CertificatoValido], [CERT_IdUtenteCertificatore], [CERT_Alias], [CERT_PIN], [CERT_Tentativi], [CERT_StatoNascita], [CERT_uniqueidentifier], [CERT_DataRevoca], [CERT_DataSospensione], [CERT_SerialNumber], [CERT_DataScadenza], [CERT_TempSospeso], [CodADER], [FotoTessera], [FirmaEstesa], [FirmaSigla], [flagFirma], [idAziendaFatt], [Partime], [IndirizzoRes], [CapRes], [ComuneRes], [ProvRes], [Matricola], [DataNascita], [GiorniLavorativi], [OrarioLavoro], [Livello], [Mansione], [Iban], [NumeroScarpe], [TagliaAbbigliamento], [Note], [Stato], [Colore], [Cod_iMile], [tokenAutoLogin], [tokenRegistrazione], [Pass])
        VALUES (@Utente, @Email, @Nome, @CodiceFiscale, @IdRuolo, @IdUtentePadre, @LoginErrors, @DataUltimoAccesso, @IdFiliale, @DataInizio, @DataFine, @RECHASH, @RECDATA, @IdCliente, @codAppLogin, @IdMezzo_Default, @CodPoste, @CodADER4, @Telefono, @CERT_ProfiloCertificatore, @CERT_CertificatoValido, @CERT_IdUtenteCertificatore, @CERT_Alias, @CERT_PIN, @CERT_Tentativi, @CERT_StatoNascita, @CERT_uniqueidentifier, @CERT_DataRevoca, @CERT_DataSospensione, @CERT_SerialNumber, @CERT_DataScadenza, @CERT_TempSospeso, @CodADER, @FotoTessera, @FirmaEstesa, @FirmaSigla, @flagFirma, @idAziendaFatt, @Partime, @IndirizzoRes, @CapRes, @ComuneRes, @ProvRes, @Matricola, @DataNascita, @GiorniLavorativi, @OrarioLavoro, @Livello, @Mansione, @Iban, @NumeroScarpe, @TagliaAbbigliamento, @Note, @Stato, @Colore, @Cod_iMile, @tokenAutoLogin, @tokenRegistrazione, @hash);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [UTENTI] SET
            [Utente] = @Utente,
            [Email] = @Email,
            [Nome] = @Nome,
            [CodiceFiscale] = @CodiceFiscale,
            [IdRuolo] = @IdRuolo,
            [IdUtentePadre] = @IdUtentePadre,
            [LoginErrors] = @LoginErrors,
            [DataUltimoAccesso] = @DataUltimoAccesso,
            [IdFiliale] = @IdFiliale,
            [DataInizio] = @DataInizio,
            [DataFine] = @DataFine,
            [RECHASH] = @RECHASH,
            [RECDATA] = @RECDATA,
            [IdCliente] = @IdCliente,
            [codAppLogin] = @codAppLogin,
            [IdMezzo_Default] = @IdMezzo_Default,
            [CodPoste] = @CodPoste,
            [CodADER4] = @CodADER4,
            [Telefono] = @Telefono,
            [CERT_ProfiloCertificatore] = @CERT_ProfiloCertificatore,
            [CERT_CertificatoValido] = @CERT_CertificatoValido,
            [CERT_IdUtenteCertificatore] = @CERT_IdUtenteCertificatore,
            [CERT_Alias] = @CERT_Alias,
            [CERT_PIN] = @CERT_PIN,
            [CERT_Tentativi] = @CERT_Tentativi,
            [CERT_StatoNascita] = @CERT_StatoNascita,
            [CERT_uniqueidentifier] = @CERT_uniqueidentifier,
            [CERT_DataRevoca] = @CERT_DataRevoca,
            [CERT_DataSospensione] = @CERT_DataSospensione,
            [CERT_SerialNumber] = @CERT_SerialNumber,
            [CERT_DataScadenza] = @CERT_DataScadenza,
            [CERT_TempSospeso] = @CERT_TempSospeso,
            [CodADER] = @CodADER,
            [FotoTessera] = @FotoTessera,
            [FirmaEstesa] = @FirmaEstesa,
            [FirmaSigla] = @FirmaSigla,
            [flagFirma] = @flagFirma,
            [idAziendaFatt] = @idAziendaFatt,
            [Partime] = @Partime,
            [IndirizzoRes] = @IndirizzoRes,
            [CapRes] = @CapRes,
            [ComuneRes] = @ComuneRes,
            [ProvRes] = @ProvRes,
            [Matricola] = @Matricola,
            [DataNascita] = @DataNascita,
            [GiorniLavorativi] = @GiorniLavorativi,
            [OrarioLavoro] = @OrarioLavoro,
            [Livello] = @Livello,
            [Mansione] = @Mansione,
            [Iban] = @Iban,
            [NumeroScarpe] = @NumeroScarpe,
            [TagliaAbbigliamento] = @TagliaAbbigliamento,
            [Note] = @Note,
            [Stato] = @Stato,
            [Colore] = @Colore,
            [Cod_iMile] = @Cod_iMile,
            [tokenAutoLogin] = @tokenAutoLogin,
            [tokenRegistrazione] = @tokenRegistrazione,
            [Pass] = CASE WHEN @NuovaPassword IS NULL THEN [Pass] ELSE @hash END
        WHERE [IdUtente] = @IdUtente;
        SELECT @IdUtente AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_UTENTI_Relazioni.sql
-- ----------------------------------------------------------
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
GO

-- ----------------------------------------------------------
-- AI_SPED_WORKFLOW_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [SPED_WORKFLOW]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_SPED_WORKFLOW_Save
    @IdWorkflow int = NULL,
    @IdAzione int = NULL,
    @Stato_Inizio varchar(50) = NULL,
    @Stato_Fine varchar(50) = NULL,
    @GiorniSLA int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdWorkflow IS NULL OR @IdWorkflow = 0
    BEGIN
        INSERT INTO [SPED_WORKFLOW] ([IdAzione], [Stato_Inizio], [Stato_Fine], [GiorniSLA])
        VALUES (@IdAzione, @Stato_Inizio, @Stato_Fine, @GiorniSLA);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [SPED_WORKFLOW] SET
            [IdAzione] = @IdAzione,
            [Stato_Inizio] = @Stato_Inizio,
            [Stato_Fine] = @Stato_Fine,
            [GiorniSLA] = @GiorniSLA
        WHERE [IdWorkflow] = @IdWorkflow;
        SELECT @IdWorkflow AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_SPED_AZIONI_Save.sql
-- ----------------------------------------------------------
-- Upsert generato dallo schema di [SPED_AZIONI]. Scritture solo via SP (prefisso AI_).
CREATE OR ALTER PROCEDURE dbo.AI_SPED_AZIONI_Save
    @IdAzione int = NULL,
    @Azione varchar(50) = NULL,
    @Stato_Inizio varchar(50) = NULL,
    @Stato_Fine varchar(50) = NULL,
    @IdProcessi varchar(50) = NULL,
    @TipoDistinta varchar(50) = NULL,
    @WebReport varchar(50) = NULL,
    @CodFamigliaAzione varchar(5) = NULL,
    @Ordine int = NULL,
    @Chiedi_Operatore int = NULL,
    @Chiedi_Citta int = NULL,
    @Chiedi_Filiale int = NULL,
    @Chiedi_Distinta int = NULL,
    @Chiedi_FilialeDest int = NULL,
    @Chiedi_FilialeGiac int = NULL,
    @Chiedi_Resi int = NULL,
    @Chiedi_Terzi int = NULL,
    @Chiedi_Scatola int = NULL,
    @Attivo int = NULL,
    @EsitoFinale int = NULL,
    @AggiornaSpedizione int = NULL,
    @Forzabile int = NULL,
    @PortaSuPalmare int = NULL,
    @ForzaFiliale int = NULL,
    @IdProdottoGenerato int = NULL,
    @MantieniDataPrec int = NULL,
    @Descrizione varchar(1000) = NULL,
    @MaxAtti int = NULL,
    @ControlloData int = NULL,
    @Param1_Tipo varchar(50) = NULL,
    @Param1_Desc varchar(50) = NULL,
    @Chiedi_Cartolina int = NULL,
    @AttiChiusi int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdAzione IS NULL OR @IdAzione = 0
    BEGIN
        INSERT INTO [SPED_AZIONI] ([Azione], [Stato_Inizio], [Stato_Fine], [IdProcessi], [TipoDistinta], [WebReport], [CodFamigliaAzione], [Ordine], [Chiedi_Operatore], [Chiedi_Citta], [Chiedi_Filiale], [Chiedi_Distinta], [Chiedi_FilialeDest], [Chiedi_FilialeGiac], [Chiedi_Resi], [Chiedi_Terzi], [Chiedi_Scatola], [Attivo], [EsitoFinale], [AggiornaSpedizione], [Forzabile], [PortaSuPalmare], [ForzaFiliale], [IdProdottoGenerato], [MantieniDataPrec], [Descrizione], [MaxAtti], [ControlloData], [Param1_Tipo], [Param1_Desc], [Chiedi_Cartolina], [AttiChiusi])
        VALUES (@Azione, @Stato_Inizio, @Stato_Fine, @IdProcessi, @TipoDistinta, @WebReport, @CodFamigliaAzione, @Ordine, @Chiedi_Operatore, @Chiedi_Citta, @Chiedi_Filiale, @Chiedi_Distinta, @Chiedi_FilialeDest, @Chiedi_FilialeGiac, @Chiedi_Resi, @Chiedi_Terzi, @Chiedi_Scatola, @Attivo, @EsitoFinale, @AggiornaSpedizione, @Forzabile, @PortaSuPalmare, @ForzaFiliale, @IdProdottoGenerato, @MantieniDataPrec, @Descrizione, @MaxAtti, @ControlloData, @Param1_Tipo, @Param1_Desc, @Chiedi_Cartolina, @AttiChiusi);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [SPED_AZIONI] SET
            [Azione] = @Azione,
            [Stato_Inizio] = @Stato_Inizio,
            [Stato_Fine] = @Stato_Fine,
            [IdProcessi] = @IdProcessi,
            [TipoDistinta] = @TipoDistinta,
            [WebReport] = @WebReport,
            [CodFamigliaAzione] = @CodFamigliaAzione,
            [Ordine] = @Ordine,
            [Chiedi_Operatore] = @Chiedi_Operatore,
            [Chiedi_Citta] = @Chiedi_Citta,
            [Chiedi_Filiale] = @Chiedi_Filiale,
            [Chiedi_Distinta] = @Chiedi_Distinta,
            [Chiedi_FilialeDest] = @Chiedi_FilialeDest,
            [Chiedi_FilialeGiac] = @Chiedi_FilialeGiac,
            [Chiedi_Resi] = @Chiedi_Resi,
            [Chiedi_Terzi] = @Chiedi_Terzi,
            [Chiedi_Scatola] = @Chiedi_Scatola,
            [Attivo] = @Attivo,
            [EsitoFinale] = @EsitoFinale,
            [AggiornaSpedizione] = @AggiornaSpedizione,
            [Forzabile] = @Forzabile,
            [PortaSuPalmare] = @PortaSuPalmare,
            [ForzaFiliale] = @ForzaFiliale,
            [IdProdottoGenerato] = @IdProdottoGenerato,
            [MantieniDataPrec] = @MantieniDataPrec,
            [Descrizione] = @Descrizione,
            [MaxAtti] = @MaxAtti,
            [ControlloData] = @ControlloData,
            [Param1_Tipo] = @Param1_Tipo,
            [Param1_Desc] = @Param1_Desc,
            [Chiedi_Cartolina] = @Chiedi_Cartolina,
            [AttiChiusi] = @AttiChiusi
        WHERE [IdAzione] = @IdAzione;
        SELECT @IdAzione AS id;
    END
END
GO

-- ----------------------------------------------------------
-- AI_MENU_Link_migrazione.sql  (compila MENU_ELEMENTI.Link)
-- ----------------------------------------------------------
-- =============================================================
-- Compila MENU_ELEMENTI.Link per le pagine GIA' migrate nella nuova webapp.
-- Le foglie con Link valorizzato = migrate; con Link NULL = ancora da migrare.
-- Idempotente: si puo' rieseguire (riallinea il Link in base alla Videata).
-- Convenzione Link: rotta interna della SPA nuova.
-- =============================================================

-- Motore interrogazioni (la pagina legge IdQuery/sWhere dal campo Parametri)
UPDATE MENU_ELEMENTI SET Link = '/interrogazioni'
WHERE Videata IN ('RisultatoInterrogazioni', 'Risutatointerrogazioni');

-- Pagine di configurazione generiche
UPDATE MENU_ELEMENTI SET Link = '/config/coperture' WHERE Videata = 'Coperture';
UPDATE MENU_ELEMENTI SET Link = '/config/prodotti'  WHERE Videata = 'Prodotti';
UPDATE MENU_ELEMENTI SET Link = '/config/listini'   WHERE Videata = 'Listini';
UPDATE MENU_ELEMENTI SET Link = '/config/processi'  WHERE Videata = 'Processi';
UPDATE MENU_ELEMENTI SET Link = '/config/gruppi'    WHERE Videata = 'Gruppi';
UPDATE MENU_ELEMENTI SET Link = '/config/aziende'   WHERE Videata = 'Aziende';
UPDATE MENU_ELEMENTI SET Link = '/config/filiali'   WHERE Videata = 'Filiali';
UPDATE MENU_ELEMENTI SET Link = '/config/clienti'   WHERE Videata = 'Clienti';
UPDATE MENU_ELEMENTI SET Link = '/config/tracciati' WHERE Videata = 'FILE TRACCIATO';
UPDATE MENU_ELEMENTI SET Link = '/config/fornitori' WHERE Videata = 'Fornitori';
UPDATE MENU_ELEMENTI SET Link = '/config/lista'     WHERE Videata = 'Lista';
UPDATE MENU_ELEMENTI SET Link = '/config/mittenti'  WHERE Videata = 'Mittenti';
UPDATE MENU_ELEMENTI SET Link = '/config/stati'     WHERE Videata = 'Stati';

-- Editor avanzati
UPDATE MENU_ELEMENTI SET Link = '/interrogazioni-editor' WHERE Videata = 'ModificaInterrogazioni';
UPDATE MENU_ELEMENTI SET Link = '/menu'                  WHERE Videata = 'MenuElementi';
UPDATE MENU_ELEMENTI SET Link = '/utenti'                WHERE Videata = 'Listautenti';

-- Editor workflow / azioni (macchina a stati per processo)
UPDATE MENU_ELEMENTI SET Link = '/workflow' WHERE Videata IN ('Azionenuova', 'Processi Azioni');

-- Dashboard
UPDATE MENU_ELEMENTI SET Link = '/dashboard' WHERE Videata = 'Dashboard';
GO

-- ============================================================
-- PERMESSI: EXECUTE all'utente applicativo "claude"
-- ============================================================
GRANT EXECUTE ON dbo.AI_AuthLogin TO claude;
GRANT EXECUTE ON dbo.AI_ElencoMenuGruppi TO claude;
GRANT EXECUTE ON dbo.AI_GEO_COPERTURE_Save TO claude;
GRANT EXECUTE ON dbo.AI_PRODOTTI_Save TO claude;
GRANT EXECUTE ON dbo.AI_FATT_LISTINI_Save TO claude;
GRANT EXECUTE ON dbo.AI_PROCESSI_Save TO claude;
GRANT EXECUTE ON dbo.AI_GRUPPI_Save TO claude;
GRANT EXECUTE ON dbo.AI_AZIENDE_Save TO claude;
GRANT EXECUTE ON dbo.AI_FILIALI_Save TO claude;
GRANT EXECUTE ON dbo.AI_CLIENTI_Save TO claude;
GRANT EXECUTE ON dbo.AI_FILE_TRACCIATO_Save TO claude;
GRANT EXECUTE ON dbo.AI_FORNITORI_Save TO claude;
GRANT EXECUTE ON dbo.AI_LISTA_VALORI_Save TO claude;
GRANT EXECUTE ON dbo.AI_MITTENTI_Save TO claude;
GRANT EXECUTE ON dbo.AI_SPED_STATI_Save TO claude;
GRANT EXECUTE ON dbo.AI_INTERROGAZIONI_Save TO claude;
GRANT EXECUTE ON dbo.AI_MENU_ELEMENTI_Save TO claude;
GRANT EXECUTE ON dbo.AI_UTENTI_Save TO claude;
GRANT EXECUTE ON dbo.AI_UTENTI_GRUPPI_Add TO claude;
GRANT EXECUTE ON dbo.AI_UTENTI_GRUPPI_Del TO claude;
GRANT EXECUTE ON dbo.AI_UTENTI_PROFILI_Add TO claude;
GRANT EXECUTE ON dbo.AI_UTENTI_PROFILI_Del TO claude;
GRANT EXECUTE ON dbo.AI_UTENTI_PROCESSI_Add TO claude;
GRANT EXECUTE ON dbo.AI_UTENTI_PROCESSI_Del TO claude;
GRANT EXECUTE ON dbo.AI_UTENTI_FILIALI_Add TO claude;
GRANT EXECUTE ON dbo.AI_UTENTI_FILIALI_Del TO claude;
GRANT EXECUTE ON dbo.AI_SPED_WORKFLOW_Save TO claude;
GRANT EXECUTE ON dbo.AI_SPED_AZIONI_Save TO claude;
GRANT EXECUTE ON dbo.ElencoFiliali TO claude;
GO
