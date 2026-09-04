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
