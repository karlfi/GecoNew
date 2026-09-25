// Guida "Gestione dei giri" per gli operatori di filiale (Speedy Web), in Word, con gli screenshot di img/.
const fs = require('fs')
const path = require('path')
const {
  Document, Packer, Paragraph, TextRun, ImageRun, HeadingLevel, AlignmentType, LevelFormat, TableOfContents,
  Header, Footer, PageNumber, Table, TableRow, TableCell, WidthType, BorderStyle, ShadingType, PageBreak,
} = require('docx')

const BLU = '00628F'
const IMG = path.join(__dirname, 'img')
const LARGHEZZA = 650                 // px: larghezza utile della pagina (A4, margini 1,8 cm)
let nFigura = 0
let nElenco = 0

// testo con grassetti: 'normale **grassetto** normale'
function runs(testo, extra = {}) {
  return testo.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map(t =>
    t.startsWith('**') ? new TextRun({ text: t.slice(2, -2), bold: true, ...extra }) : new TextRun({ text: t, ...extra }))
}
const P = (testo, opz = {}) => new Paragraph({ children: runs(testo), spacing: { after: 120 }, ...opz })
const H1 = t => new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun(t)], pageBreakBefore: true })
const H2 = t => new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun(t)] })
const punto = t => new Paragraph({ numbering: { reference: 'punti', level: 0 }, children: runs(t), spacing: { after: 60 } })
function passi(elenco) {
  const n = ++nElenco
  return elenco.map(t => new Paragraph({ numbering: { reference: 'passi', level: 0, instance: n }, children: runs(t), spacing: { after: 60 } }))
}
function nota(testo, titolo = 'Nota') {
  return new Paragraph({
    children: [new TextRun({ text: titolo + ': ', bold: true, color: BLU }), ...runs(testo)],
    shading: { type: ShadingType.CLEAR, fill: 'EAF4F8', color: 'auto' },
    border: { left: { style: BorderStyle.SINGLE, size: 18, color: BLU, space: 6 } },
    spacing: { before: 120, after: 160 }, indent: { left: 120, right: 120 },
  })
}
const DIM = JSON.parse(fs.readFileSync(path.join(__dirname, 'img_doc', 'dimensioni.json'), 'utf8'))
function dimensioni(nome) {
  const [w, h] = DIM[nome]
  return { w, h, data: fs.readFileSync(path.join(__dirname, 'img_doc', nome + '.jpg')) }
}
function figura(nome, didascalia, larghezza = LARGHEZZA) {
  const { w, h, data } = dimensioni(nome)
  const lw = Math.min(larghezza, LARGHEZZA)
  nFigura++
  return [
    new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 120, after: 60 }, keepNext: true,
      children: [new ImageRun({ type: 'jpg', data, transformation: { width: lw, height: Math.round(lw * h / w) },
        altText: { title: didascalia, description: didascalia, name: nome } })] }),
    new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 200 },
      children: [new TextRun({ text: `Figura ${nFigura} – ${didascalia}`, italics: true, size: 18, color: '555555' })] }),
  ]
}
function tabella(intestazione, righe, colonne) {
  const tot = colonne.reduce((a, b) => a + b, 0)
  const bordo = { style: BorderStyle.SINGLE, size: 4, color: 'BFD3DD' }
  const cella = (t, testata) => new TableCell({
    width: { size: colonne[0], type: WidthType.DXA },
    borders: { top: bordo, bottom: bordo, left: bordo, right: bordo },
    shading: testata ? { type: ShadingType.CLEAR, fill: BLU, color: 'auto' } : undefined,
    margins: { top: 60, bottom: 60, left: 100, right: 100 },
    children: [new Paragraph({ children: runs(t, testata ? { bold: true, color: 'FFFFFF' } : {}) })],
  })
  const riga = (celle, testata) => new TableRow({ tableHeader: testata, children: celle.map((t, i) => {
    const c = cella(t, testata); c.options = c.options; return new TableCell({ ...c.options, width: { size: colonne[i], type: WidthType.DXA },
      borders: { top: bordo, bottom: bordo, left: bordo, right: bordo },
      shading: testata ? { type: ShadingType.CLEAR, fill: BLU, color: 'auto' } : undefined,
      margins: { top: 60, bottom: 60, left: 100, right: 100 },
      children: [new Paragraph({ children: runs(t, testata ? { bold: true, color: 'FFFFFF' } : {}) })] }) }) })
  return new Table({ width: { size: tot, type: WidthType.DXA }, columnWidths: colonne,
    rows: [riga(intestazione, true), ...righe.map(r => riga(r, false))] })
}
const vuoto = () => new Paragraph({ children: [] })

// ================= contenuto =================
const copertina = [
  new Paragraph({ spacing: { before: 2600 }, children: [] }),
  new Paragraph({ alignment: AlignmentType.LEFT, children: [new TextRun({ text: 'Speedy Web', size: 32, color: '6B7785' })] }),
  new Paragraph({ spacing: { before: 200, after: 200 }, children: [new TextRun({ text: 'Gestione dei giri', size: 64, bold: true, color: BLU })] }),
  new Paragraph({ children: [new TextRun({ text: 'Guida per gli operatori di filiale', size: 32 })] }),
  new Paragraph({ spacing: { before: 120 }, border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: BLU, space: 4 } }, children: [] }),
  new Paragraph({ spacing: { before: 300 }, children: runs('Creare e modificare i giri, assegnare le spedizioni ai driver, ottimizzare i percorsi e dividere il lavoro in automatico.', { size: 24 }) }),
  new Paragraph({ spacing: { before: 2400 }, children: [new TextRun({ text: 'Menu «Gestione Giri Filiale»  ·  settembre 2026  ·  portale ver.9', color: '6B7785' })] }),
  new Paragraph({ children: [new TextRun({ text: 'Le immagini sono della filiale TOSC - HUB SPEEDY; nelle altre filiali le pagine sono le stesse.', color: '6B7785', size: 18 })] }),
]

const indice = [
  new Paragraph({ pageBreakBefore: true, children: [new TextRun({ text: 'Indice', bold: true, size: 32, color: BLU })], spacing: { after: 200 } }),
  new TableOfContents('Indice', { hyperlink: true, headingStyleRange: '1-2' }),
]

const introduzione = [
  H1('Introduzione'),
  P('I **giri** sono le aree di consegna della filiale. Ogni giro è un\'area disegnata sulla mappa, con un nome, un colore e, di solito, un **driver predefinito**: il driver che lo fa abitualmente.'),
  P('Ogni giorno le spedizioni caricate in filiale vengono attribuite al giro in cui cade l\'indirizzo di consegna; i giri vengono affidati ai driver e, per ogni driver, il programma calcola con HERE il percorso migliore, con l\'ordine delle consegne e l\'orario stimato di arrivo.'),
  H2('Il lavoro in quattro passi'),
  ...passi([
    '**Preparare i giri**: si fa una volta e poi quando cambiano le zone (pagina Giri, capitolo 1).',
    '**Controllare le spedizioni del giorno**: ogni spedizione deve avere il giro giusto e il punto di consegna sulla mappa (pagina Spedizioni del giorno, capitolo 2).',
    '**Affidare i giri ai driver e ottimizzare i percorsi** (pagina Piano della giornata, capitolo 2).',
    'In alternativa al passo 3, **lasciare che il programma divida tutte le spedizioni fra i driver scelti**, bilanciando il carico (pagina Pianificazione automatica, capitolo 3).',
  ]),
  H2('Dove si trovano le pagine'),
  P('Tutte le pagine sono nel menu **Gestione Giri Filiale** e lavorano sulla filiale scelta in alto a destra. Alcune voci di menu aprono la stessa pagina:'),
  tabella(['Voce di menu', 'Pagina che si apre', 'Capitolo'], [
    ['Giri - Creazione giri su Mappa, Giri - Modifica giri su Mappa', 'Giri', '1'],
    ['Giri - Assegnazione, Giri - Modifica punti', 'Spedizioni del giorno', '2'],
    ['Giri - Assegna a Driver, Giri - Ottimizza percorso', 'Piano della giornata', '2'],
    ['Pianificazione Automatica', 'Pianificazione automatica', '3'],
    ['Giri - Elenco', 'elenco dei giri in tabella', '–'],
  ], [4600, 3300, 1100]),
  vuoto(),
  nota('le pagine con la mappa rendono meglio con il menu laterale chiuso: si apre e si chiude con il tasto ☰ in alto a sinistra.', 'Suggerimento'),
]

const cap1 = [
  H1('1. Creare e modificare i giri'),
  P('Si lavora nella pagina **Giri** (menu Giri - Creazione giri su Mappa o Giri - Modifica giri su Mappa).'),
  H2('1.1 La pagina Giri'),
  ...figura('g01_panoramica', 'La pagina Giri: a sinistra i giri e i comuni, al centro la mappa, a destra il pannello del giro'),
  P('La pagina è divisa in tre colonne:'),
  punto('**a sinistra** l\'elenco dei giri e, sotto, l\'elenco dei comuni della filiale;'),
  punto('**al centro** la mappa: si ingrandisce con la rotella del mouse o con + e −; il pulsante in alto a destra della mappa passa alla vista satellite;'),
  punto('**a destra** il pannello «Nuovo giro» o «Modifica giro», con il confine del giro («Bordi») e lo storico delle modifiche.'),
  P('Sopra la mappa:'),
  punto('**Spedizioni di oggi** mostra sulla mappa le spedizioni geolocalizzate del giorno, colorate con il colore del loro giro (grigie quelle senza giro);'),
  punto('**Punti del giro** mostra solo le spedizioni di un giro, oppure solo quelle senza giro; **CAP** le filtra per CAP;'),
  punto('**Aggiorna giri di sped** riassegna ai giri le spedizioni di oggi (vedi 1.3).'),
  H2('1.2 L\'elenco dei giri'),
  ...figura('g02_griglia', 'L\'elenco dei giri e dei comuni', 360),
  P('Ogni giro occupa due righe: sopra il pallino del colore, il nome e quante spedizioni ha oggi; sotto il driver predefinito (o «nessun driver predefinito»), il CAP fisso e il comune fisso se ci sono. A destra di ogni giro:'),
  punto('la **casella** a sinistra mostra o nasconde il giro sulla mappa; «Tutti» e «Nessuno» li mostrano o nascondono tutti;'),
  punto('l\'**interruttore** dice se il giro è attivo (vedi 1.10);'),
  punto('la **lente** inquadra il giro sulla mappa;'),
  punto('la **matita** apre il giro in modifica nel pannello di destra; la riga del giro in modifica ha il bordo azzurro.'),
  P('La casella di ricerca cerca per nome del giro, CAP, comune o driver; «Tutti / Attivi / Non attivi» filtra l\'elenco.'),
  P('Nell\'elenco **Comuni della filiale** la casella di ogni comune lo mostra sulla mappa: i comuni spuntati servono anche per creare un giro dai comuni (1.5) o per rifarne il confine (1.7).'),
  H2('1.3 Come una spedizione prende il suo giro'),
  P('Il giro di una spedizione si decide così, in quest\'ordine:'),
  ...passi([
    '**CAP fisso**: se un giro ha il CAP fisso, tutte le spedizioni con quel CAP vanno a quel giro, dovunque siano;',
    '**comune fisso**: altrimenti, se un giro ha il comune fisso, vanno a quel giro le spedizioni di quel comune;',
    '**area**: altrimenti vince il giro nella cui area cade il punto di consegna. Se due aree si sovrappongono, vince il giro creato per primo: per questo è importante che i confini dei giri vicini combacino (1.8).',
  ]),
  P('Contano solo i giri **attivi**. L\'assegnazione si fa dalla pagina Spedizioni del giorno (capitolo 2); dopo aver cambiato un confine, **Aggiorna giri di sped** riassegna le spedizioni di oggi: ai soli giri spuntati nell\'elenco, oppure, se non ne è spuntato nessuno, a tutti (il programma chiede conferma).'),
  H2('1.4 Creare un giro disegnandolo'),
  ...figura('g03_nuovo_disegno', 'Un giro nuovo disegnato a mano: i punti numerati si trascinano, il + a metà lato aggiunge un punto'),
  ...passi([
    'Se nel pannello di destra c\'è un giro in modifica, premi **+** in alto nel pannello per passare a «Nuovo giro».',
    'Scrivi il **Nome** (almeno 4 caratteri) e scegli il **Colore**; se serve, imposta **CAP fisso**, **Comune fisso** e **Driver predefinito**.',
    'Spunta **Disegna a mano (clic sulla mappa)** e clicca sulla mappa i vertici del confine, in ordine, girando intorno all\'area: ogni clic aggiunge un punto numerato.',
    'Correggi il disegno: **trascina** un punto per spostarlo; clicca il **+** a metà di un lato per aggiungere un punto lì; **tasto destro** su un punto per toglierlo.',
    'Premi **Crea nuovo giro**.',
  ]),
  ...figura('g03b_pannello_nuovo', 'Il pannello «Nuovo giro» con l\'elenco dei punti del confine', 380),
  P('Nell\'elenco **Bordi** ci sono i punti in ordine, con le frecce per spostarli prima o dopo e la X per toglierli; il cestino li toglie tutti. Se «Spedizioni di oggi» è attivo, sotto il pannello compare quante spedizioni di oggi cadono nell\'area disegnata.'),
  H2('1.5 Creare un giro dai comuni'),
  ...figura('g04_da_comuni', 'Comuni spuntati nell\'elenco in basso: il giro nuovo sarà l\'unione dei loro confini'),
  ...passi([
    'Nel pannello «Nuovo giro» scrivi il nome e scegli il colore.',
    'Spunta i comuni nell\'elenco **Comuni della filiale**: compaiono sulla mappa.',
    'Premi **Crea da comuni selezionati**: l\'area del giro è l\'unione dei confini dei comuni.',
  ]),
  P('Conviene quando il giro coincide con uno o più comuni interi: il confine segue esattamente quello dei comuni.'),
  H2('1.6 Modificare un giro'),
  ...figura('g05_modifica', 'Un giro aperto in modifica (matita nell\'elenco): il giro viene inquadrato sulla mappa'),
  P('Con la **matita** il giro si apre nel pannello «Modifica giro». Si possono cambiare nome, colore, CAP fisso, comune fisso, driver predefinito e stato attivo; poi si preme **Salva**.'),
  ...figura('g05b_pannello_modifica', 'Il pannello «Modifica giro»', 380),
  nota('il **driver predefinito** è il driver che fa abitualmente il giro. Il Piano della giornata lo propone da solo e la Pianificazione automatica usa i giri di un driver come sue «zone abituali». Quando nel Piano della giornata si affida un giro a un driver, quel driver diventa il predefinito del giro.'),
  P('In fondo al pannello, **Ultime modifiche** mostra lo storico: chi ha cambiato cosa e quando.'),
  H2('1.7 Modificare il confine'),
  ...figura('g06_confine', 'Il confine in modifica: ogni punto è un pin numerato'),
  P('Nel pannello premi **Modifica confine**: i punti del confine diventano pin numerati e si modificano come nel disegno (trascinare, + a metà lato, tasto destro per togliere). Poi:'),
  punto('**Salva** salva il nuovo confine;'),
  punto('**Annulla modifica confine** butta via le modifiche;'),
  punto('**Sostituisci con i comuni selezionati** rifà il confine come unione dei comuni spuntati (chiede conferma).'),
  P('Se il confine ha più di 300 punti, per poterlo modificare viene semplificato e il pannello lo segnala. Un giro fatto di più aree separate non si modifica a mano: il confine si rifà dai comuni.'),
  H2('1.8 Far combaciare il confine con un giro vicino'),
  P('Due giri vicini devono combaciare: se c\'è uno spazio fra i due, le spedizioni che cadono lì restano senza giro; se si sovrappongono, le spedizioni della parte comune vanno al giro creato per primo. Invece di spostare i punti uno a uno, si usa **Allinea al giro vicino**:'),
  ...passi([
    'Spunta nell\'elenco il **giro vicino**, così è visibile sulla mappa.',
    'Apri in modifica il tuo giro e premi **Modifica confine**.',
    'Nel riquadro **Allinea al giro vicino** scegli il giro: in cima all\'elenco ci sono quelli con più punti vicini (il numero è fra parentesi).',
    'Regola la **distanza** massima (50 m di solito): i tratti del tuo confine che corrono entro quella distanza dal confine del vicino vengono sostituiti con il suo confine. Sulla mappa sono in **verde** e sotto compare quanti punti cambiano.',
    'Premi **Applica**, controlla sulla mappa e poi **Salva**. Il giro vicino non viene toccato.',
  ]),
  ...figura('g07_allinea', 'Allineamento di PO-03B al vicino PO-04B: il tratto sul viale diventa il confine del vicino'),
  ...figura('g07b_pannello_allinea', 'Il riquadro «Allinea al giro vicino» con l\'anteprima', 380),
  P('Se l\'anteprima non convince, **Annulla** (prima di Applica) o **Annulla modifica confine** riportano tutto com\'era.'),
  H2('1.9 Spostare il confine di due giri insieme'),
  ...figura('g08b_mappa_condiviso', 'I punti in comune con il giro vicino hanno il bordo doppio', 520),
  P('Con **Sposta insieme il confine dei giri vicini** spuntato (lo è sempre, all\'inizio), i punti che il tuo giro ha in comune con un giro visibile sulla mappa hanno il **bordo doppio**. Per quei punti:'),
  punto('**trascinandoli** si sposta anche il confine del giro vicino, che si ridisegna tratteggiato;'),
  punto('il **+** a metà di un lato in comune aggiunge il punto in tutti e due i giri; **togliendolo** sparisce da tutti e due;'),
  punto('**Salva** salva il tuo giro e i giri vicini cambiati, tutti insieme: il pannello avvisa quali vicini verranno salvati.'),
  P('I punti sono «in comune» quando coincidono, per esempio dopo **Allinea al giro vicino**. Funziona con i giri vicini fatti di un\'area sola.'),
  P('**Aggancia ai confini visibili** (anch\'esso spuntato all\'inizio): se rilasci un punto vicino al confine di un giro o di un comune visibile, il punto si attacca a quel confine.'),
  H2('1.10 Attivare e disattivare un giro'),
  ...figura('g09_non_attivi', 'I giri non attivi: filtro «Non attivi»', 380),
  P('Un giro si disattiva con l\'**interruttore** nell\'elenco (il programma chiede conferma) o con «Attivo» nel pannello. Un giro non attivo:'),
  punto('resta nell\'elenco, con la riga rigata, e sulla mappa è tratteggiato;'),
  punto('non riceve spedizioni e non compare nelle pagine di assegnazione;'),
  punto('viene tolto dai piani di oggi e dei giorni successivi.'),
  P('Si riattiva con lo stesso interruttore; il filtro «Non attivi» li mostra tutti.'),
]

const cap2 = [
  H1('2. Assegnare le spedizioni ai driver e ottimizzare il giro'),
  P('Ogni giorno: prima si controlla che le spedizioni abbiano il giro giusto (**Spedizioni del giorno**), poi si affidano i giri ai driver e si calcola il percorso di ciascuno (**Piano della giornata**).'),
  H2('2.1 Controllare le spedizioni del giorno'),
  ...figura('s01_spedizioni_giorno', 'Spedizioni del giorno: riepilogo, mappa con le spedizioni colorate per giro, elenco'),
  P('In alto si sceglie il **giorno** e, se serve, il **cliente**. I contatori dicono quante spedizioni ci sono, quante hanno il giro, quante sono **senza giro** e quante **senza coordinate**; un clic su un contatore filtra l\'elenco.'),
  punto('**Assegna le senza giro**: assegna in automatico le spedizioni ancora senza giro (CAP fisso, comune fisso, area: vedi 1.3).'),
  punto('**Riassegna tutte**: rifà l\'assegnazione di tutte le spedizioni del giorno; le correzioni fatte a mano vanno perse (il programma chiede conferma).'),
  punto('**Aree dei giri** mostra le aree sulla mappa; sotto la mappa c\'è l\'elenco dei giri con il numero di spedizioni: un clic filtra.'),
  P('Nell\'elenco a destra ogni spedizione ha barcode, destinatario, indirizzo, giro e posizione nella sequenza; l\'icona **orologio** apre lo storico della spedizione.'),
  H2('2.2 Correggere a mano'),
  ...figura('s02_selezione', 'Due spedizioni selezionate: si sceglie il giro e si preme «Assegna»'),
  ...passi([
    'Seleziona le spedizioni con la **casella** nell\'elenco, oppure premi **Seleziona con un\'area** e disegna un\'area sulla mappa.',
    'Scegli il giro nella casella **giro** e premi **Assegna**; **Togli giro** le lascia senza giro.',
  ]),
  P('**Spedizioni senza coordinate o con il punto sbagliato**: con l\'icona del **segnaposto** della riga scegli «Metti sulla mappa» (o «Sposta il punto»), clicca o trascina il punto dove va consegnata e premi **Salva posizione**: il giro segue la nuova posizione. Una spedizione senza coordinate non entra nei percorsi ottimizzati.'),
  H2('2.3 Affidare i giri ai driver: il Piano della giornata'),
  ...figura('p01_piano', 'Piano della giornata: giri da assegnare, mappa, driver con i loro giri'),
  P('La pagina ha tre colonne: a sinistra i **giri da assegnare** (con i pezzi), al centro la mappa (aree chiare = giri da assegnare, aree scure = già assegnati, con il cognome del driver), a destra i **driver** con i giri che hanno in carico e il totale dei pezzi. In alto il giorno e i contatori: pezzi nei giri, giri da assegnare, pezzi assegnati, percorsi calcolati.'),
  P('Un giro si affida a un driver in uno di questi modi:'),
  punto('**trascina** il giro dalla colonna di sinistra sul driver;'),
  punto('**seleziona** il driver con un clic e usa la **freccia** accanto al giro;'),
  punto('**Ctrl + clic** su un\'area chiara della mappa: il giro va al driver selezionato;'),
  punto('**Maiusc + trascinamento** di un rettangolo sui punti liberi (spedizioni senza giro o di giri non assegnati): vanno nel giro più vicino del driver selezionato.'),
  P('La **×** accanto a un giro, sotto il driver, glielo toglie. **Driver predefiniti** affida ogni giro ancora libero al suo driver predefinito.'),
  nota('le scelte restano come predefinite: aprendo un giorno senza assegnazioni, la pagina ripropone da sola i driver del giorno prima.'),
  H2('2.4 Partenza e ritorno del driver'),
  ...figura('p03_menu_driver', 'Il menu del driver (tasto destro): partenza e ritorno, indirizzo di casa, storico'),
  P('Con il **tasto destro** su un driver: **Parte da casa**, **Torna a casa** oppure **Parte e torna dalla filiale**. Per partire o tornare da casa serve l\'**Indirizzo di casa…**: il programma lo cerca sulla mappa e lo salva. **Storico** mostra le variazioni del giorno per quel driver.'),
  H2('2.5 Ottimizzare il percorso del driver'),
  ...figura('p02_percorso', 'Il percorso ottimizzato di un driver: tappe numerate sulle strade e tabella con gli orari di arrivo'),
  P('Sotto ogni driver ci sono lo stato del percorso e quattro icone: **Ottimizza con HERE** (rombo), **Vedi il percorso sulla mappa**, **Stampa** ed **Excel**.'),
  ...passi([
    'Premi **Ottimizza con HERE** sul driver, oppure **Ottimizza tutti** in alto per tutti i driver con consegne ancora da ottimizzare.',
    'Dopo qualche secondo lo stato diventa **ottimizzato**, con i km e il tempo totale comprese le soste.',
    'Con **Vedi il percorso** la mappa mostra il tragitto sulle strade con le tappe numerate e, sotto, la tabella con l\'ordine di consegna, l\'indirizzo, il giro, l\'orario stimato di arrivo e i km. **Chiudi percorso** torna alla vista normale.',
  ]),
  P('Se dopo l\'ottimizzazione cambiano i giri del driver, i punti o la partenza, il percorso va **rifatto**: il driver lo segnala e basta ottimizzare di nuovo. L\'ordine calcolato è l\'ordine di consegna delle spedizioni.'),
  H2('2.6 Stampare il percorso'),
  ...figura('p04_stampa', 'La stampa del percorso: mappa e lista delle consegne in ordine'),
  P('L\'icona **Stampa** del driver apre l\'anteprima con la mappa e la lista delle consegne in ordine; **Stampa** la manda alla stampante, **Chiudi** torna al piano. L\'icona **Excel** scarica la stessa lista in un file.'),
]

const cap3 = [
  H1('3. Pianificazione automatica'),
  P('Invece di affidare i giri uno per uno, la **Pianificazione automatica** divide tutte le spedizioni geolocalizzate del giorno fra i driver scelti, con HERE: i percorsi sono ottimizzati e il carico è bilanciato. Ogni driver lavora di preferenza nelle sue **zone abituali** (i giri di cui è driver predefinito), ma può ricevere consegne fuori zona per bilanciare il lavoro. I giri non cambiano.'),
  H2('3.1 La pagina'),
  ...figura('a01_pianificazione', 'Pianificazione automatica: parametri e Calcola in alto, driver a sinistra, spedizioni del giorno sulla mappa'),
  P('In alto il giorno e il riepilogo: spedizioni, spedizioni geolocalizzate (quelle senza coordinate non entrano nel calcolo e vanno sistemate prima in Spedizioni del giorno), indirizzi, driver scelti e pezzi medi a testa. Prima del calcolo la mappa mostra le spedizioni colorate per giro.'),
  ...figura('a02_comandi', 'Riepilogo e parametri del calcolo'),
  punto('**Sosta**: i secondi di ogni fermata.'),
  punto('**+ per pezzo**: i secondi in più per ogni pezzo oltre il primo allo stesso indirizzo.'),
  punto('**Equilibrio ±**: quanto un driver può scostarsi dalla media dei pezzi e delle fermate (0 = nessun vincolo di equilibrio).'),
  punto('**Zone abituali**: ogni driver lavora di preferenza nelle sue zone.'),
  punto('**Usa tutti i driver**: fa lavorare tutti i driver scelti, invece di usarne il meno possibile.'),
  H2('3.2 Scegliere i driver e i loro vincoli'),
  ...figura('a03_driver', 'L\'elenco dei driver: si spuntano quelli che lavorano e si regolano i vincoli di ciascuno', 380),
  P('Spunta i driver che lavorano nel giorno («tutti» e «nessuno» per spuntarli tutti o nessuno). Con l\'icona delle **impostazioni** accanto al nome si regolano i vincoli del driver:'),
  punto('**Turno**: ora di inizio e di fine;'),
  punto('**Partenza** e **Ritorno**: dalla filiale o da casa (la casa si imposta nel Piano della giornata, 2.4);'),
  punto('**Massimo pezzi**: il tetto di consegne del driver (vuoto = nessun limite oltre l\'equilibrio);'),
  punto('**Zone abituali**: i giri in cui lavora di preferenza.'),
  P('La pagina propone i valori dell\'ultimo calcolo; la prima volta turno 08:30–15:30, partenza e ritorno dalla filiale e, come zone, i giri di cui il driver è predefinito.'),
  H2('3.3 Calcolare'),
  ...passi([
    'Premi **Calcola**.',
    'La barra di avanzamento dice prima «in coda», poi «HERE sta calcolando i giri»: di solito servono **2-3 minuti**. Si può lasciare la pagina e tornare dopo.',
    'Alla fine compare l\'esito: pezzi assegnati e non assegnati, fermate, km e ore di lavoro in tutto.',
  ]),
  H2('3.4 Leggere il risultato'),
  punto('Sulla mappa ogni driver ha un colore, con il suo percorso; nell\'elenco di sinistra, per ogni driver: pezzi, fermate, km, ore, ora di fine e il giro in **Excel**.'),
  punto('Un clic sul **nome** di un driver mostra solo il suo giro, con le tappe numerate; un altro clic torna alla vista di tutti.'),
  punto('Le **non assegnate** sono elencate sotto la mappa con il motivo: per esempio «posizione sospetta» (un punto molto più lontano di tutti gli altri, quasi sempre un indirizzo geolocalizzato male: va corretto in Spedizioni del giorno), turni non sufficienti o driver arrivati al massimo dei pezzi.'),
  punto('Se dopo il calcolo arrivano altre spedizioni, la pagina lo segnala: per includerle si calcola di nuovo.'),
  H2('3.5 Confermare o scartare'),
  punto('**Conferma** rende il piano quello del giorno e scrive sulle spedizioni l\'ordine di consegna; un piano confermato prima per lo stesso giorno viene sostituito.'),
  punto('**Scarta** butta via il calcolo.'),
  P('Ogni calcolo resta salvato: riaprendo la pagina su quel giorno si ritrova il piano confermato o l\'ultimo calcolo.'),
]

const faq = [
  H1('Domande frequenti'),
  H2('Una spedizione è finita nel giro sbagliato'),
  P('Controlla se c\'è un giro con il **CAP fisso** o il **comune fisso** di quella spedizione (vincono sull\'area) e se il punto sulla mappa è giusto (Spedizioni del giorno, 2.2). Correggi a mano, oppure sistema il confine (1.7-1.9) e usa **Aggiorna giri di sped**.'),
  H2('Una spedizione non ha coordinate'),
  P('Mettila sulla mappa da Spedizioni del giorno con «Metti sulla mappa» (2.2): finché non ha il punto non entra nei percorsi.'),
  H2('Due giri si sovrappongono o fra due giri c\'è uno spazio'),
  P('Usa **Allinea al giro vicino** (1.8); poi, per spostare il confine comune, trascina i punti con il bordo doppio (1.9).'),
  H2('Un giro non compare nel Piano della giornata'),
  P('È **non attivo** (1.10) oppure oggi non ha spedizioni.'),
  H2('Il percorso di un driver è da rifare'),
  P('Dopo l\'ottimizzazione sono cambiati i suoi giri, i punti o la partenza: premi di nuovo **Ottimizza con HERE** sul driver (2.5).'),
]

// ================= documento =================
const doc = new Document({
  creator: 'Speedy Web', title: 'Gestione dei giri - Guida per gli operatori di filiale',
  styles: {
    default: { document: { run: { font: 'Calibri', size: 22 } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 36, bold: true, color: BLU }, paragraph: { spacing: { before: 240, after: 200 }, outlineLevel: 0 } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 27, bold: true, color: BLU }, paragraph: { spacing: { before: 300, after: 120 }, outlineLevel: 1, keepNext: true } },
    ],
  },
  numbering: {
    config: [
      { reference: 'punti', levels: [{ level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 540, hanging: 280 } } } }] },
      { reference: 'passi', levels: [{ level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 540, hanging: 340 } } } }] },
    ],
  },
  sections: [{
    properties: { page: { size: { width: 11906, height: 16838 }, margin: { top: 1134, bottom: 1134, left: 1020, right: 1020 } } },
    headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT,
      children: [new TextRun({ text: 'Speedy Web · Gestione dei giri', color: '8A96A3', size: 16 })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
      children: [new TextRun({ children: ['Pagina ', PageNumber.CURRENT, ' di ', PageNumber.TOTAL_PAGES], color: '8A96A3', size: 16 })] })] }) },
    children: [...copertina, ...indice, ...introduzione, ...cap1, ...cap2, ...cap3, ...faq],
  }],
})

const uscita = process.argv[2] || 'Gestione_giri_guida_operatori.docx'
Packer.toBuffer(doc).then(buf => { fs.writeFileSync(uscita, buf); console.log('scritto', uscita, Math.round(buf.length / 1024), 'KB,', nFigura, 'figure') })
