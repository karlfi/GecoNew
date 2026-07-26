# Zone storiche di consegna per filiale

Pipeline in 4 passi per ricavare le zone driver dalle serie storiche della vista
`NEXIVE_consegne` (DeliveryDB → Speedy.dbo.NEXIVE_Consegne). Prima filiale fatta:
**GROSSETO_2** (nov 2019 – mar 2020), output in `grosseto/`.

## I 4 passi

1. **`passo1_zone.py`** — griglia ~450 m sui punti geolocalizzati; k-means pesato
   sul carico con tetto di capacità, contiguità obbligatoria e verificata (ogni
   zona = un blocco unico), rifinitura dei confini con la co-assegnazione
   driver-giorno; k scelto scandendo 10–20 con parsimonia. Presentare la mappa
   (`genera_mappa_html.py` → `web/public/zone-<filiale>.html`) e far approvare.
2. **`passo2_3_aree_shape.py` (passo 2)** — le celle a bassa densità e i buchi
   interni vengono attribuiti alla zona più vicina.
3. **`passo2_3_aree_shape.py` (passo 3)** — contorni rettilinei dell'unione
   celle per zona → WKT MULTIPOLYGON → script SQL con SP
   `AI_GEO_ZonaStorica_Save` per memorizzarli in GEO_GIRI (SHAPE è `geometry`,
   SRID 4326). **Eseguire solo su conferma**: i giri sono visibili alle pagine
   operative della filiale.
4. **`passo4a_frames.py` + `passo4b_deck.js`** — slide PowerPoint con la
   progressione animata (1 giorno → 2 giorni → 1 settimana → 1 mese → periodo
   intero → zone del passo 1 → aree finali), frame su tile OSM, transizioni a
   dissolvenza con avanzamento automatico.

## Per una nuova filiale

1. Adattare `estrai.ps1` (nome filiale in `NEXIVE_Consegne.Filiale` e periodo) e
   lanciarlo → CSV dei punti. Occhio: dal 2020 l'export NEXIVE non ha più
   l'orario di consegna, ma le coordinate sì.
2. Nei .py sistemare `BASE` (cartella di lavoro), il bounding box della
   provincia e i nomi dei file; poi lanciare i passi in ordine, con
   l'approvazione della mappa tra il passo 1 e i successivi.
3. `node passo4b_deck.js` richiede `npm install pptxgenjs` nella cartella di
   lavoro; il render di verifica si fa con PowerPoint via COM (vedi cronologia).
