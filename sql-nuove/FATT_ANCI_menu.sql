-- Voce di menu "Fatturazione ANCI" sotto Test - Sviluppo (1229): tweb non la
-- vede (nessuna Videata), la webapp la apre dal campo Link. Idempotente.
IF NOT EXISTS (SELECT 1 FROM dbo.MENU_ELEMENTI WHERE Link = '/fatturazione-anci')
    EXEC dbo.AI_MENU_ELEMENTI_Save @ParentID = 1229, @Text = 'Fatturazione ANCI',
        @Descrizione = 'Fatture ANCI del mese, report Excel e mail di prefattura',
        @Link = '/fatturazione-anci', @Sorting = 11;
SELECT IdMenuElemento, ParentID, Text, Link, Sorting FROM dbo.MENU_ELEMENTI WHERE Link = '/fatturazione-anci';
