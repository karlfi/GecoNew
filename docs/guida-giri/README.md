# Guida "Gestione dei giri" per gli operatori di filiale

Il PDF pubblicato e' `web/public/doc/Gestione_giri_guida_operatori.pdf`, aperto dalla voce di menu
**Documentazione** in fondo a Gestione Giri Filiale (`sql-nuove/MENU_documentazione_giri.sql`, pagina `DocumentoView`).
Qui gli script per rifarla quando le pagine cambiano:

1. `cdp.mjs` pilota Edge senza finestra (DevTools Protocol, Node 24, nessun pacchetto) sul portale locale:
   `npm run dev` + API locale con l'accesso di sviluppo (`DevLogin` in `api/appsettings.Development.json`).
   I clic sono clic veri del mouse (i menu PrimeVue non rispondono a `element.click()`).
2. `foto_cap1_2.mjs [cap1|cap2]` e `foto_cap3.mjs [prima|dopo]` salvano gli screenshot in `img/`: solo letture e
   prove locali, nessun salvataggio. Il "dopo" del capitolo 3 vuole un calcolo della pianificazione gia' fatto
   (scrive sul DB di produzione: da concordare).
3. Le immagini vanno convertite in JPEG da 1600 px in `img_doc/` con `dimensioni.json` (larghezza, altezza).
4. `genera_doc.js` (npm `docx`) scrive il .docx; poi si apre con Word (COM da PowerShell) per compilare l'indice,
   salvarlo ed esportare il PDF in `web/public/doc/`.

Da una cartella di lavoro fuori dal repository (le immagini e il profilo di Edge non vanno in git):
`npm install docx`, poi gli script nell'ordine.
