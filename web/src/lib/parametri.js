// Parser dei due formati di parametri usati dal legacy.

// Parametri delle voci di MENU: 'IdQuery=1014|sWhere=" and ..."'
// Le due parti possono comparire in qualsiasi ordine, sWhere puo' mancare o essere vuoto.
export function parseParametriMenu(p) {
  const testo = p ?? ''
  const mId = testo.match(/IdQuery=(\d+)/i)
  let sWhere = ''
  const i = testo.toLowerCase().indexOf('swhere=')
  if (i >= 0) {
    sWhere = testo.slice(i + 7)
    const fine = sWhere.search(/\|IdQuery=/i)
    if (fine >= 0) sWhere = sWhere.slice(0, fine)
    sWhere = togliVirgolette(sWhere)
  }
  return { idQuery: mId ? Number(mId[1]) : null, sWhere }
}

// Valore di una cella queryN#: "1020| and x.IdUtente=123"
// La prima parte (prima del |) e' SOLO il numero, senza l'etichetta IdQuery=.
export function parseAzioneQuery(v) {
  const testo = String(v ?? '')
  const sep = testo.indexOf('|')
  const primo = (sep >= 0 ? testo.slice(0, sep) : testo).trim().replace(/^IdQuery=/i, '')
  const idQuery = Number(primo)
  let sWhere = sep >= 0 ? testo.slice(sep + 1) : ''
  sWhere = sWhere.replace(/^\s*sWhere=/i, '')
  return {
    idQuery: Number.isFinite(idQuery) && idQuery > 0 ? idQuery : null,
    sWhere: togliVirgolette(sWhere)
  }
}

// Parametri della videata "Eseguicomando" (tasto destro/menu). Formato a coppie
// chiave=valore separate da '|', es.:
//   "IdAzione=0|Modale=1|EseguiSubito=1|Nome=Annulla bolla|Parametri=exec [SP] @id= 17"
// La chiave "Parametri" e' l'ultima e puo' contenere '=' nel valore: la si prende
// fino a fine stringa. Restituisce un oggetto con le chiavi trovate.
export function parseParametriComando(p) {
  const testo = p ?? ''
  const out = {}
  const rx = /(\w+)=/g
  let m, prec = null, precInizio = 0
  while ((m = rx.exec(testo))) {
    if (prec) out[prec] = testo.slice(precInizio, m.index).replace(/\|$/, '')
    prec = m[1]
    precInizio = rx.lastIndex
  }
  if (prec) out[prec] = testo.slice(precInizio)
  return out
}

function togliVirgolette(s) {
  let t = (s ?? '').trim()
  if (t.startsWith('"')) t = t.slice(1)
  if (t.endsWith('"')) t = t.slice(0, -1)
  return t
}
