// Attrezzi comuni alle pagine dello schedulatore: le date arrivano dal server
// in UTC (con la Z) e si mostrano in ora locale; i colori degli stati sono
// quelli di WF_StatoEsecuzione.
export const SEVERITA_STATO = { 0: 'info', 1: 'warn', 2: 'success', 3: 'danger', 4: 'secondary', 5: 'contrast' }
export const severitaStato = s => SEVERITA_STATO[s] ?? 'secondary'
export const STATI = [
  { Codice: 0, Nome: 'PIANIFICATA' }, { Codice: 1, Nome: 'IN_ESECUZIONE' }, { Codice: 2, Nome: 'ESEGUITA' },
  { Codice: 3, Nome: 'ERRORE' }, { Codice: 4, Nome: 'ANNULLATA' }, { Codice: 5, Nome: 'SALTATA' }
]

export const dataOra = v => v ? new Date(v).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' }) : '—'
// finestre di date per gli elenchi di esecuzioni (ora locale, a mezzanotte)
export const inizioGiorno = d => { const x = new Date(d); x.setHours(0, 0, 0, 0); return x }
export const giorniFa = n => { const x = inizioGiorno(new Date()); x.setDate(x.getDate() - n); return x }
// i parametri dal/al per /schedulatore/esecuzioni: "al" e' incluso fino a fine giornata
export function parametriFinestra(dal, al) {
  const p = {}
  if (dal) p.dal = inizioGiorno(dal).toISOString()
  if (al) { const a = inizioGiorno(al); a.setDate(a.getDate() + 1); p.al = a.toISOString() }
  return p
}
export const oraSec = v => v ? new Date(v).toLocaleTimeString('it-IT') : ''

export function durata(inizio, fine) {
  if (!inizio) return '—'
  const ms = (fine ? new Date(fine) : new Date()) - new Date(inizio)
  if (ms < 0) return '—'
  const s = Math.round(ms / 1000)
  return s < 90 ? `${s}s` : s < 5400 ? `${Math.round(s / 60)} min` : `${(s / 3600).toFixed(1)} h`
}

export const messaggioErrore = (e, altrimenti = 'Errore') => e?.response?.data?.errore ?? e?.message ?? altrimenti

// un file scelto nel browser -> base64 (senza il prefisso data:)
export const fileBase64 = f => new Promise((ok, ko) => {
  const r = new FileReader()
  r.onload = () => ok(String(r.result).split(',')[1] ?? '')
  r.onerror = ko
  r.readAsDataURL(f)
})
