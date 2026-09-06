import { parseParametriMenu } from '../lib/parametri'

// Mappa: Videata legacy -> pagina di configurazione generica (fallback quando Link è vuoto).
export const CONFIG_TABELLE = {
  Coperture: { key: 'coperture', titolo: 'Coperture' },
  Prodotti: { key: 'prodotti', titolo: 'Prodotti' },
  Listini: { key: 'listini', titolo: 'Listini' },
  Processi: { key: 'processi', titolo: 'Processi' },
  // 'Gruppi' non e' piu' qui: ha la pagina dedicata (vedi isVideataGruppi)
  Aziende: { key: 'aziende', titolo: 'Aziende' },
  Filiali: { key: 'filiali', titolo: 'Filiali' },
  // 'Clienti' non e' piu' qui: ha la pagina dedicata (vedi isVideataClienti)
  'FILE TRACCIATO': { key: 'tracciati', titolo: 'File tracciato' },
  // videata gemella usata nei menu di test: stesso editor dei tracciati
  Tracciatofile: { key: 'tracciati', titolo: 'File tracciato' },
  Fornitori: { key: 'fornitori', titolo: 'Fornitori' },
  Lista: { key: 'lista', titolo: 'Lista valori' },
  Mittenti: { key: 'mittenti', titolo: 'Mittenti' },
  Stati: { key: 'stati', titolo: 'Stati' },
  // gestione mezzi: manutenzioni (MEZZI_NOTE) e sinistri (MEZZI_SINISTRI)
  Manutenzioni: { key: 'manutenzioni', titolo: 'Manutenzioni mezzi' },
  Sinistri: { key: 'sinistri', titolo: 'Sinistri mezzi' }
}

const TITOLI = {
  coperture: 'Coperture', prodotti: 'Prodotti', listini: 'Listini', processi: 'Processi',
  gruppi: 'Gruppi', aziende: 'Aziende', filiali: 'Filiali',
  clienti: 'Clienti', tracciati: 'File tracciato', fornitori: 'Fornitori',
  lista: 'Lista valori', mittenti: 'Mittenti', stati: 'Stati',
  manutenzioni: 'Manutenzioni mezzi', sinistri: 'Sinistri mezzi'
}

export function configDaVideata(videata) {
  return CONFIG_TABELLE[videata] ?? null
}

const VIDEATE_WORKFLOW = ['Azionenuova', 'Processi Azioni']
export function isVideataWorkflow(videata) {
  return VIDEATE_WORKFLOW.includes(videata)
}

export function isVideataUtenti(videata) {
  return videata === 'Listautenti'
}

// videata legacy "Azioni (OLD)" di Configurazione Generale
export function isVideataAzioniOld(videata) {
  return videata === 'Azioni'
}

// videata legacy del tracking spedizioni (voci "Ricerca/Tracking Barcode");
// la variante "Clienti Lite" e' lo stesso tracking: il filtro sul cliente
// arriva dal claim idCliente dell'utente collegato
export function isVideataTracking(videata) {
  return ['Ricerca Barcode', 'Ricerca Barcode Clienti Lite'].includes(videata)
}

// videata legacy dei contatori giornalieri di filiale ("Attivita Filiali")
export function isVideataAttivitaFiliali(videata) {
  return videata === 'Attivitafiliale'
}

// videata legacy della griglia giornaliera driver ("Attivita Dipendenti")
export function isVideataAttivitaDipendenti(videata) {
  return videata === 'Inserimento Attivita'
}

// videata legacy della creazione bolle di trasferimento ("DDT - creazione")
export function isVideataDdt(videata) {
  return videata === 'Bollainterna'
}

// videata legacy "Esegui Comando" (azioni pagina# come Annulla bolla, svincolo, reso)
export function isVideataEseguiComando(videata) {
  return videata === 'Eseguicomando'
}

// videata legacy "Esiti": pagina operativa cardine (esecuzione azioni su barcode)
export function isVideataEsiti(videata) {
  return videata === 'Esiti'
}

// videata legacy "Creazione giri su Mappa"
export function isVideataGiriMappa(videata) {
  return videata === 'Sped2mappe'
}

// videata legacy "Nuova Spedizione Parcel Speedy"
export function isVideataSpedNuova(videata) {
  return videata === 'Nuovaspedizione'
}

// videate legacy "Accettazione da File" (senza e con parametro CodFamiglia)
export function isVideataAccettazioneFile(videata) {
  return ['AccettazioneDaFile', 'AccettazioneDaFileFamiglia', 'Accettazione Da File Famiglia'].includes(videata)
}

// videate legacy "Accettazione da Banco" (senza e con parametro CodFamiglia;
// le varianti Mittenti/Adexuffici passano IdCliente nei parametri)
export function isVideataAccettazioneBanco(videata) {
  return ['AccettazioneDaBanco', 'AccettazioneDaBancoFamiglia',
    'AccettazioneDaBancoMittenti', 'Accettazione Da Banco Mittenti', 'Adexuffici'].includes(videata)
}

// variante MGG (Ministero GG, cliente 5318): stessa pagina banco con
// cliente/famiglia/prodotto PICKUP MG preimpostati (la videata legacy li fissava nel codice)
export const PARAMETRI_BANCO_MGG = 'IdCliente=5318|CodFamiglia="P"|IdProdotto=69'
export function isVideataAccettazioneBancoMgg(videata) {
  return videata === 'Accettazione Da Banco MGG'
}

// videate legacy "Videocodifica" (correzione dei lotti da file); la variante
// famiglia passa i filtri in sWhere, la Adex il cliente 5389, la MGG fissa il 5318
export function isVideataVideoCodifica(videata) {
  return ['Videocodifica', 'Videocodificafamiglia', 'Adexvideocodifica'].includes(videata)
}
export const PARAMETRI_VIDEOCODIFICA_MGG = 'IdCliente=5318'
export function isVideataVideoCodificaMgg(videata) {
  return videata === 'Videocodificamgg'
}

// videate legacy "Checkin" (accettazione dei lotti in filiale); le varianti
// MGG/Checkindb passano idCliente nei parametri
export function isVideataCheckin(videata) {
  return ['Checkin', 'Checkin Famiglia', 'Checkin MGG', 'Checkindb'].includes(videata)
}

// videate legacy di ricerca costruite sulle interrogazioni: "Ricerca Multipla"
// (IN su un elenco di barcode), "Trova Distinte" (form di ricerca sulla 1012),
// "Ricercaparams" (form dai segnaposto &[...] della query)
export function isVideataRicercaMultipla(videata) {
  return ['RicercaMultipla', 'Ricerca Multipla'].includes(videata)
}
export function isVideataTrovaDistinte(videata) {
  return ['TrovaDistinte', 'Trova Distinte'].includes(videata)
}
export function isVideataRicercaParams(videata) {
  return videata === 'Ricercaparams'
}

// videata legacy "Scontrini Fine Gita" (riepilogo gite driver + cedolini)
export function isVideataScontriniGita(videata) {
  return videata === 'Scontrini Fine Gita'
}

// videata legacy "Spedizioneinterna" (trasferimenti di materiale tra filiali)
export function isVideataSpedInterna(videata) {
  return videata === 'Spedizioneinterna'
}

// videate legacy delle pagine residue migrate a pagina dedicata
export function isVideataLavoratoDriver(videata) {
  return videata === 'Lavoratodriver'
}
export function isVideataProfilo(videata) {
  return videata === 'Profilo'
}
export function isVideataScatole(videata) {
  return videata === 'Scatola'
}
export function isVideataCeste(videata) {
  return videata === 'Ceste'
}
export function isVideataDipendentiFiliale(videata) {
  return videata === 'Dipendenti'
}
export function isVideataPunteggi(videata) {
  return videata === 'Punteggi'
}
export function isVideataPickup(videata) {
  return videata === 'Pickup'
}

// videata legacy "Distinta Riepilogativa" (modello ministeriale MGG; la variante
// "Distinta Riepilogativa Notifiche" resta da migrare)
export function isVideataDistintaRiepilogativa(videata) {
  return videata === 'Distinta Riepilogativa'
}

// videata legacy "Clienti": gestione dedicata (anagrafica + condizioni + listini)
export function isVideataClienti(videata) {
  return videata === 'Clienti'
}

// videata legacy "Gruppi": gestione dedicata (radici menu + utenti relazionati)
export function isVideataGruppi(videata) {
  return videata === 'Gruppi'
}

// Risolve una Videata legacy (+ parametri) nell'oggetto di navigazione interno.
// E' la stessa logica di fallback del menu: usata da AppShell e dalle azioni
// "paginaN#" delle interrogazioni (valore cella = "Videata#Parametri").
export function navDaVideata(videata, parametri = '') {
  const v = (videata ?? '').trim()
  if (v.toLowerCase() === 'risultatointerrogazioni') {
    const { idQuery, sWhere } = parseParametriMenu(parametri)
    return { tipo: 'interrogazioni', idQuery, sWhere }
  }
  const cfg = configDaVideata(v)
  if (cfg) return { tipo: 'config', key: cfg.key, titolo: cfg.titolo }
  if (isVideataWorkflow(v)) return { tipo: 'workflow' }
  if (isVideataUtenti(v)) {
    // "Listautenti#IdUtente=4137": dalla griglia dipendenti si chiede la scheda
    // di quel dipendente, non l'elenco di tutti
    const m = (parametri ?? '').match(/IdUtente=(\d+)/i)
    return { tipo: 'utenti', idUtente: m ? Number(m[1]) : null }
  }
  if (isVideataAzioniOld(v)) return { tipo: 'azioni' }
  if (isVideataTracking(v)) return { tipo: 'tracking' }
  if (isVideataAttivitaFiliali(v)) return { tipo: 'attivita-filiali' }
  if (isVideataAttivitaDipendenti(v)) return { tipo: 'attivita-dipendenti' }
  if (isVideataDdt(v)) return { tipo: 'ddt' }
  if (isVideataEseguiComando(v)) return { tipo: 'esegui-comando', parametri: parametri ?? '' }
  if (isVideataEsiti(v)) return { tipo: 'esiti', parametri: parametri ?? '' }
  if (isVideataGiriMappa(v)) return { tipo: 'giri-mappa' }
  if (isVideataSpedNuova(v)) return { tipo: 'sped-nuova' }
  if (isVideataAccettazioneFile(v)) return { tipo: 'accettazione-file', parametri: parametri ?? '' }
  if (isVideataAccettazioneBanco(v)) return { tipo: 'accettazione-banco', parametri: parametri ?? '' }
  if (isVideataAccettazioneBancoMgg(v)) return { tipo: 'accettazione-banco', parametri: parametri || PARAMETRI_BANCO_MGG }
  if (isVideataVideoCodifica(v)) return { tipo: 'videocodifica', parametri: parametri ?? '' }
  if (isVideataVideoCodificaMgg(v)) return { tipo: 'videocodifica', parametri: parametri || PARAMETRI_VIDEOCODIFICA_MGG }
  if (isVideataCheckin(v)) return { tipo: 'checkin', parametri: parametri ?? '' }
  if (isVideataRicercaMultipla(v)) {
    const { idQuery, sWhere } = parseParametriMenu(parametri)
    return { tipo: 'ricerca-multipla', idQuery, sWhere }
  }
  if (isVideataTrovaDistinte(v)) {
    const { idQuery, sWhere } = parseParametriMenu(parametri)
    return { tipo: 'trova-distinte', idQuery: idQuery ?? 1012, sWhere }
  }
  if (isVideataRicercaParams(v)) {
    const { idQuery, sWhere } = parseParametriMenu(parametri)
    return { tipo: 'ricerca-params', idQuery, sWhere }
  }
  if (isVideataScontriniGita(v)) return { tipo: 'scontrini-gita' }
  if (isVideataSpedInterna(v)) return { tipo: 'sped-interna' }
  if (isVideataDistintaRiepilogativa(v)) return { tipo: 'distinta-riepilogativa' }
  if (isVideataLavoratoDriver(v)) return { tipo: 'lavorato-driver' }
  if (isVideataProfilo(v)) return { tipo: 'profilo' }
  if (isVideataScatole(v)) return { tipo: 'scatole' }
  if (isVideataCeste(v)) return { tipo: 'ceste' }
  if (isVideataDipendentiFiliale(v)) return { tipo: 'dipendenti-filiale' }
  if (isVideataPunteggi(v)) return { tipo: 'punteggi' }
  if (isVideataPickup(v)) return { tipo: 'pickup' }
  if (isVideataClienti(v)) return { tipo: 'clienti' }
  if (isVideataGruppi(v)) return { tipo: 'gruppi' }
  // scheda mezzo: dalle griglie legacy "MEZZI#targa=XX000XX|Modale=0" e
  // "Mezzi24#targa=..."; "targa=InserimentoMezzo" e' il mezzo nuovo
  if (v.toLowerCase() === 'mezzi' || v.toLowerCase() === 'mezzi24') {
    const m = (parametri ?? '').match(/targa=([^|#&]+)/i)
    const targa = m ? m[1].trim() : ''
    if (!targa || targa.toLowerCase() === 'inserimentomezzo') return { tipo: 'mezzi', nuovo: true }
    return { tipo: 'mezzi', targa }
  }
  // videata non ancora migrata: placeholder
  return { tipo: 'videata', videata: v, parametri: parametri ?? '' }
}

// Routing primario: dal campo Link di MENU_ELEMENTI alla pagina interna.
// Restituisce l'oggetto di navigazione per lo store nav, o null se il Link
// è vuoto/sconosciuto (così si ricade sul vecchio routing per Videata).
export function navDaLink(voce) {
  const link = (voce.Link ?? '').trim()
  if (!link) return null

  if (link === '/dashboard') return { tipo: 'dashboard' }
  if (link === '/utenti') return { tipo: 'utenti' }
  if (link === '/menu') return { tipo: 'menu-editor' }
  if (link === '/interrogazioni-editor') return { tipo: 'interrogazioni-editor' }
  if (link === '/workflow') return { tipo: 'workflow' }
  if (link === '/azioni') return { tipo: 'azioni' }
  if (link === '/tracking') return { tipo: 'tracking' }
  if (link === '/attivita-filiali') return { tipo: 'attivita-filiali' }
  if (link === '/attivita-dipendenti') return { tipo: 'attivita-dipendenti' }
  if (link === '/ddt') return { tipo: 'ddt' }
  if (link === '/esegui-comando') return { tipo: 'esegui-comando', parametri: voce.Parametri ?? '' }
  if (link === '/esiti') return { tipo: 'esiti', parametri: voce.Parametri ?? '' }
  if (link === '/giri-mappa') return { tipo: 'giri-mappa' }
  if (link === '/export-hr') return { tipo: 'export-hr' }
  if (link === '/presenze-ts') return { tipo: 'presenze-ts' }
  if (link === '/unilav') return { tipo: 'unilav' }
  if (link === '/storici') return { tipo: 'storici' }
  if (link === '/sped-nuova') return { tipo: 'sped-nuova' }
  if (link === '/accettazione-file') return { tipo: 'accettazione-file', parametri: voce.Parametri ?? '' }
  if (link === '/accettazione-banco') return { tipo: 'accettazione-banco', parametri: voce.Parametri ?? '' }
  if (link === '/accettazione-banco-mgg') return { tipo: 'accettazione-banco', parametri: voce.Parametri || PARAMETRI_BANCO_MGG }
  if (link === '/videocodifica') return { tipo: 'videocodifica', parametri: voce.Parametri ?? '' }
  if (link === '/videocodifica-mgg') return { tipo: 'videocodifica', parametri: voce.Parametri || PARAMETRI_VIDEOCODIFICA_MGG }
  if (link === '/checkin') return { tipo: 'checkin', parametri: voce.Parametri ?? '' }
  if (link === '/scontrini-gita') return { tipo: 'scontrini-gita' }
  if (link === '/sped-interna') return { tipo: 'sped-interna' }
  if (link === '/distinta-riepilogativa') return { tipo: 'distinta-riepilogativa' }
  if (link === '/lavorato-driver') return { tipo: 'lavorato-driver' }
  if (link === '/profilo') return { tipo: 'profilo' }
  if (link === '/scatole') return { tipo: 'scatole' }
  if (link === '/ceste') return { tipo: 'ceste' }
  if (link === '/dipendenti-filiale') return { tipo: 'dipendenti-filiale' }
  if (link === '/punteggi') return { tipo: 'punteggi' }
  if (link === '/pickup') return { tipo: 'pickup' }
  if (link === '/clienti') return { tipo: 'clienti' }
  if (link === '/gruppi') return { tipo: 'gruppi' }
  // schedulatore (gia' TNOT): workflow, pianificazioni, storico
  if (link === '/schedulatore') return { tipo: 'schedulatore' }
  if (link === '/schedulatore-storico') return { tipo: 'schedulatore-storico' }
  if (link === '/sim') return { tipo: 'sim' }
  if (link === '/palmari') return { tipo: 'palmari' }
  if (link === '/mezzi') return { tipo: 'mezzi' }
  if (link === '/interrogazioni') {
    const { idQuery, sWhere } = parseParametriMenu(voce.Parametri)
    return { tipo: 'interrogazioni', idQuery, sWhere }
  }
  // stessa query dell'interrogazione, ma con la griglia dell'Elenco Dipendenti
  // (colonna Stato modificabile): in tweb la voce resta RisultatoInterrogazioni
  // fatturazioni a consuntivo: stessa pagina, profilo diverso (ANCI, ALIA)
  if (link === '/fatturazione-anci') return { tipo: 'fatturazione', profilo: 'anci' }
  if (link === '/fatturazione-alia') return { tipo: 'fatturazione', profilo: 'alia' }
  if (link === '/elenco-dipendenti') {
    const { idQuery, sWhere } = parseParametriMenu(voce.Parametri)
    return { tipo: 'elenco-dipendenti', idQuery, sWhere }
  }
  if (link === '/ricerca-multipla') {
    const { idQuery, sWhere } = parseParametriMenu(voce.Parametri)
    return { tipo: 'ricerca-multipla', idQuery, sWhere }
  }
  if (link === '/trova-distinte') {
    const { idQuery, sWhere } = parseParametriMenu(voce.Parametri)
    return { tipo: 'trova-distinte', idQuery: idQuery ?? 1012, sWhere }
  }
  if (link === '/ricerca-params') {
    const { idQuery, sWhere } = parseParametriMenu(voce.Parametri)
    return { tipo: 'ricerca-params', idQuery, sWhere }
  }
  if (link.startsWith('/config/')) {
    const key = link.slice('/config/'.length)
    return { tipo: 'config', key, titolo: TITOLI[key] ?? key }
  }
  return null
}
