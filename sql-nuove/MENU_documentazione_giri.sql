-- Voce "Documentazione" in fondo a "Gestione Giri Filiale" (richiesta di Carlo, 25/09/2026): apre dentro il portale
-- la guida per gli operatori di filiale "Gestione dei giri" (PDF in web/public/doc, pubblicato con la release).
-- Un Link che finisce in .pdf apre la pagina DocumentoView (tabelle.js, tipo 'documento'). Idempotente.
-- Il gruppo si cerca per nome (Text), cosi' lo script vale anche sul DB di Ge.C.O. New dove gli Id sono diversi.
-- il gruppo e' quello della voce "Giri - Ottimizza percorso" (Videata Ottimizza): in Speedy Web e' "Gestione Giri Filiale",
-- in Ge.C.O. New le voci dei giri sono un blocco dentro "Gestione Filiale"; la voce nuova va in coda al blocco dei giri
DECLARE @gruppo int = (SELECT TOP 1 ParentID FROM dbo.MENU_ELEMENTI WHERE Videata = 'Ottimizza' AND Link = '/piano-giornata');
IF @gruppo IS NULL
    RAISERROR('Manca la voce di menu "Giri - Ottimizza percorso": non so in che gruppo mettere la voce nuova', 16, 1);
ELSE IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE ParentID = @gruppo AND Link = '/doc/Gestione_giri_guida_operatori.pdf')
BEGIN
    DECLARE @ordine int = (SELECT ISNULL(MAX(Sorting), 0) + 1 FROM dbo.MENU_ELEMENTI WHERE ParentID = @gruppo
                           AND (Text LIKE 'Giri - %' OR Link IN ('/pianificazione-automatica', '/doc/Gestione_giri_guida_operatori.pdf')));
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = @gruppo, @Text = 'Documentazione',
        @Descrizione = 'Guida per gli operatori di filiale: creare e modificare i giri, assegnare le spedizioni ai driver, ottimizzare i percorsi, pianificazione automatica',
        @Link = '/doc/Gestione_giri_guida_operatori.pdf', @Sorting = @ordine;
END
GO
