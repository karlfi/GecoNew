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
