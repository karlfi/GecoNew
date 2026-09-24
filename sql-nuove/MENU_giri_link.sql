-- Link alle voci del menu "Gestione Giri Filiale" che aprivano gia' le pagine nuove passando dalla
-- Videata (navDaVideata) ma, col Link vuoto, restavano grigie e senza pallino nel menu. Con il Link
-- la webapp le apre dal routing primario (navDaLink) e il menu le mostra come migrate.
--   Assegnagiri (Giri - Assegnazione) e Spostageo (Giri - Modifica punti)   -> Spedizioni del giorno
--   Assegnadriver (Giri - Assegna a Driver) e Ottimizza (Ottimizza percorso) -> Piano della giornata
--   Mappagiri (Giri - Modifica giri su Mappa)                               -> Giri (la stessa pagina
--     crea e modifica i giri; prima questa voce apriva la pagina segnaposto)
-- Scritture via AI_MENU_ELEMENTI_Save con tutti i valori attuali della voce. Idempotente: tocca solo
-- le voci con il Link ancora vuoto.
DECLARE @voci TABLE (Videata varchar(50), Link varchar(100));
INSERT @voci VALUES ('Assegnagiri', '/spedizioni-giorno'), ('Spostageo', '/spedizioni-giorno'),
                    ('Assegnadriver', '/piano-giornata'), ('Ottimizza', '/piano-giornata'),
                    ('Mappagiri', '/giri-mappa');

DECLARE @Id int, @ParentID int, @Text varchar(255), @Descrizione varchar(255), @Videata varchar(50),
        @Link varchar(4000), @Parametri varchar(max), @NavigateUrl varchar(255), @Sorting int,
        @ToolTip varchar(250), @Disabled int, @Icon varchar(250), @Popup int, @CodFamiglia varchar(1);
DECLARE voci CURSOR LOCAL FAST_FORWARD FOR
    SELECT m.IdMenuElemento, m.ParentID, m.Text, m.Descrizione, m.Videata, v.Link, m.Parametri, m.NavigateUrl,
           m.Sorting, m.ToolTip, m.Disabled, m.Icon, m.Popup, m.CodFamiglia
    FROM dbo.MENU_ELEMENTI m
    JOIN @voci v ON v.Videata = m.Videata
    WHERE LTRIM(RTRIM(ISNULL(m.Link, ''))) = '';
OPEN voci;
FETCH voci INTO @Id, @ParentID, @Text, @Descrizione, @Videata, @Link, @Parametri, @NavigateUrl, @Sorting, @ToolTip, @Disabled, @Icon, @Popup, @CodFamiglia;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.AI_MENU_ELEMENTI_Save @IdMenuElemento = @Id, @ParentID = @ParentID, @Text = @Text, @Descrizione = @Descrizione,
        @Videata = @Videata, @Link = @Link, @Parametri = @Parametri, @NavigateUrl = @NavigateUrl, @Sorting = @Sorting,
        @ToolTip = @ToolTip, @Disabled = @Disabled, @Icon = @Icon, @Popup = @Popup, @CodFamiglia = @CodFamiglia;
    FETCH voci INTO @Id, @ParentID, @Text, @Descrizione, @Videata, @Link, @Parametri, @NavigateUrl, @Sorting, @ToolTip, @Disabled, @Icon, @Popup, @CodFamiglia;
END
CLOSE voci;
DEALLOCATE voci;
GO
