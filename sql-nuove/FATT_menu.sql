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
