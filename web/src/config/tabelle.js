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
  Fornitori: { key: 'fornitori', titolo: 'Fornitori' },
  Lista: { key: 'lista', titolo: 'Lista valori' },
  Mittenti: { key: 'mittenti', titolo: 'Mittenti' },
  Stati: { key: 'stati', titolo: 'Stati' }
}

const TITOLI = {
  coperture: 'Coperture', prodotti: 'Prodotti', listini: 'Listini', processi: 'Processi',
  gruppi: 'Gruppi', aziende: 'Aziende', filiali: 'Filiali',
  clienti: 'Clienti', tracciati: 'File tracciato', fornitori: 'Fornitori',
  lista: 'Lista valori', mittenti: 'Mittenti', stati: 'Stati'
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

// videata legacy del tracking spedizioni (voci "Ricerca/Tracking Barcode")
export function isVideataTracking(videata) {
  return videata === 'Ricerca Barcode'
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
// le varianti Mittenti passano IdCliente nei parametri)
export function isVideataAccettazioneBanco(videata) {
  return ['AccettazioneDaBanco', 'AccettazioneDaBancoFamiglia',
    'AccettazioneDaBancoMittenti', 'Accettazione Da Banco Mittenti'].includes(videata)
}

// videata legacy "Videocodifica" (correzione dei lotti da file)
export function isVideataVideoCodifica(videata) {
  return videata === 'Videocodifica'
}

// videate legacy "Checkin" (accettazione dei lotti in filiale)
export function isVideataCheckin(videata) {
  return ['Checkin', 'Checkin Famiglia'].includes(videata)
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
  if (isVideataUtenti(v)) return { tipo: 'utenti' }
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
  if (isVideataVideoCodifica(v)) return { tipo: 'videocodifica', parametri: parametri ?? '' }
  if (isVideataCheckin(v)) return { tipo: 'checkin' }
  if (isVideataClienti(v)) return { tipo: 'clienti' }
  if (isVideataGruppi(v)) return { tipo: 'gruppi' }
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
  if (link === '/unilav') return { tipo: 'unilav' }
  if (link === '/storici') return { tipo: 'storici' }
  if (link === '/sped-nuova') return { tipo: 'sped-nuova' }
  if (link === '/accettazione-file') return { tipo: 'accettazione-file', parametri: voce.Parametri ?? '' }
  if (link === '/accettazione-banco') return { tipo: 'accettazione-banco', parametri: voce.Parametri ?? '' }
  if (link === '/videocodifica') return { tipo: 'videocodifica', parametri: voce.Parametri ?? '' }
  if (link === '/checkin') return { tipo: 'checkin' }
  if (link === '/clienti') return { tipo: 'clienti' }
  if (link === '/gruppi') return { tipo: 'gruppi' }
  if (link === '/interrogazioni') {
    const { idQuery, sWhere } = parseParametriMenu(voce.Parametri)
    return { tipo: 'interrogazioni', idQuery, sWhere }
  }
  if (link.startsWith('/config/')) {
    const key = link.slice('/config/'.length)
    return { tipo: 'config', key, titolo: TITOLI[key] ?? key }
  }
  return null
}
