import { parseParametriMenu } from '../lib/parametri'

// Mappa: Videata legacy -> pagina di configurazione generica (fallback quando Link è vuoto).
export const CONFIG_TABELLE = {
  Coperture: { key: 'coperture', titolo: 'Coperture' },
  Prodotti: { key: 'prodotti', titolo: 'Prodotti' },
  Listini: { key: 'listini', titolo: 'Listini' },
  Processi: { key: 'processi', titolo: 'Processi' },
  Gruppi: { key: 'gruppi', titolo: 'Gruppi' },
  Aziende: { key: 'aziende', titolo: 'Aziende' },
  Filiali: { key: 'filiali', titolo: 'Filiali' },
  Clienti: { key: 'clienti', titolo: 'Clienti' },
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
