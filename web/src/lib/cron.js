// Espressioni cron (5 campi: min ora giorno mese giorno-settimana) da e verso
// un modello semplice, stile "Utilità di pianificazione" di Windows:
//   giornaliera / settimanale (giorni) / mensile (giorni del mese, mesi) / avanzata
//   ora di inizio, e a scelta "ripeti ogni N minuti|ore dalle … alle …".
// Il motore (Cronos) le interpreta nell'ora locale del server.

export const GIORNI = [
  { valore: 1, nome: 'Lunedì', breve: 'lun' }, { valore: 2, nome: 'Martedì', breve: 'mar' }, { valore: 3, nome: 'Mercoledì', breve: 'mer' },
  { valore: 4, nome: 'Giovedì', breve: 'gio' }, { valore: 5, nome: 'Venerdì', breve: 'ven' }, { valore: 6, nome: 'Sabato', breve: 'sab' }, { valore: 0, nome: 'Domenica', breve: 'dom' }
]
export const MESI = ['gen', 'feb', 'mar', 'apr', 'mag', 'giu', 'lug', 'ago', 'set', 'ott', 'nov', 'dic']
export const GIORNI_MESE = [...Array.from({ length: 31 }, (_, i) => ({ valore: i + 1, nome: String(i + 1) })), { valore: 'L', nome: 'ultimo' }]

export function modelloVuoto() {
  return {
    modo: 'giornaliera',              // giornaliera | settimanale | mensile | avanzata
    ora: '06:00',                     // ora di inizio (o dell'unica esecuzione del giorno)
    giorniSettimana: [1, 2, 3, 4, 5],
    giorniMese: [1],
    mesi: [],                         // vuoto = tutti
    ripeti: { attiva: false, ogni: 30, unita: 'minuti', dalle: '08:00', alle: '18:00' },
    espressione: ''                   // solo in modo avanzata
  }
}

const due = n => String(n).padStart(2, '0')
const oraMin = s => { const m = /^(\d{1,2}):(\d{2})$/.exec((s || '').trim()); return m ? [Math.min(23, +m[1]), Math.min(59, +m[2])] : null }
const listaNumeri = v => [...new Set(v)].sort((a, b) => a - b).join(',')

// dal modello all'espressione; lancia un errore parlante se il modello non sta in piedi
export function componi(m) {
  if (m.modo === 'avanzata') {
    const e = (m.espressione || '').trim()
    if (e.split(/\s+/).length !== 5) throw new Error('Servono 5 campi: minuto ora giorno mese giorno-settimana')
    return e
  }
  const inizio = oraMin(m.ora)
  if (!inizio) throw new Error('Ora di inizio non valida')
  let minuto = String(inizio[1]), ora = String(inizio[0])
  if (m.ripeti?.attiva) {
    const da = oraMin(m.ripeti.dalle), a = oraMin(m.ripeti.alle)
    const ogni = Number(m.ripeti.ogni)
    if (!da || !a) throw new Error('Fascia oraria non valida')
    if (a[0] < da[0]) throw new Error('La fascia oraria deve finire dopo che inizia')
    if (!(ogni >= 1)) throw new Error('"Ogni" deve essere almeno 1')
    const fascia = da[0] === a[0] ? String(da[0]) : `${da[0]}-${a[0]}`
    if (m.ripeti.unita === 'minuti') {
      if (ogni > 59) throw new Error('Per intervalli di un\'ora o più usa le ore')
      minuto = ogni === 1 ? '*' : `*/${ogni}`; ora = fascia
    } else {
      if (ogni > 23) throw new Error('Al massimo ogni 23 ore')
      minuto = String(da[1]); ora = ogni === 1 ? fascia : `${fascia}/${ogni}`
    }
  }
  let giorno = '*', mese = '*', settimana = '*'
  if (m.modo === 'settimanale') {
    if (!m.giorniSettimana?.length) throw new Error('Scegli almeno un giorno della settimana')
    settimana = m.giorniSettimana.length === 7 ? '*' : listaNumeri(m.giorniSettimana)
  } else if (m.modo === 'mensile') {
    if (!m.giorniMese?.length) throw new Error('Scegli almeno un giorno del mese')
    const numeri = m.giorniMese.filter(g => g !== 'L'), ultimo = m.giorniMese.includes('L')
    giorno = [numeri.length ? listaNumeri(numeri) : null, ultimo ? 'L' : null].filter(Boolean).join(',')
    mese = m.mesi?.length && m.mesi.length < 12 ? listaNumeri(m.mesi) : '*'
  }
  return `${minuto} ${ora} ${giorno} ${mese} ${settimana}`
}

// dall'espressione al modello; null se non è una di quelle che la maschera sa fare (resta "avanzata")
export function scomponi(expr) {
  const campi = (expr || '').trim().split(/\s+/)
  if (campi.length !== 5) return null
  const [fMin, fOra, fGiorno, fMese, fSett] = campi
  const m = modelloVuoto()
  // minuto e ora, con o senza ripetizione nella giornata
  let mm, hMin, hMax, passoOre = 1, passoMin = null
  let x
  if ((x = /^(\d{1,2})$/.exec(fMin))) mm = +x[1]
  else if (fMin === '*') passoMin = 1
  else if ((x = /^\*\/(\d{1,2})$/.exec(fMin))) passoMin = +x[1]
  else return null
  if ((x = /^(\d{1,2})$/.exec(fOra))) { hMin = hMax = +x[1] }
  else if ((x = /^(\d{1,2})-(\d{1,2})$/.exec(fOra))) { hMin = +x[1]; hMax = +x[2] }
  else if ((x = /^(\d{1,2})-(\d{1,2})\/(\d{1,2})$/.exec(fOra))) { hMin = +x[1]; hMax = +x[2]; passoOre = +x[3] }
  else return null
  if (passoMin != null) {
    if (passoOre !== 1) return null
    m.ripeti = { attiva: true, ogni: passoMin, unita: 'minuti', dalle: `${due(hMin)}:00`, alle: `${due(hMax)}:00` }
    m.ora = `${due(hMin)}:00`
  } else if (hMin !== hMax || passoOre !== 1) {
    m.ripeti = { attiva: true, ogni: passoOre, unita: 'ore', dalle: `${due(hMin)}:${due(mm)}`, alle: `${due(hMax)}:${due(mm)}` }
    m.ora = `${due(hMin)}:${due(mm)}`
  } else m.ora = `${due(hMin)}:${due(mm)}`
  // giorni
  const lista = (s, max, conL) => {
    if (s === '*') return []
    const out = []
    for (const parte of s.split(',')) {
      if (conL && parte === 'L') { out.push('L'); continue }
      let r
      if ((r = /^(\d{1,2})$/.exec(parte))) out.push(+r[1])
      else if ((r = /^(\d{1,2})-(\d{1,2})$/.exec(parte))) { for (let i = +r[1]; i <= +r[2]; i++) out.push(i) }
      else return null
    }
    return out.some(v => v !== 'L' && (v < 0 || v > max)) ? null : out
  }
  const sett = lista(fSett, 7, false), giorni = lista(fGiorno, 31, true), mesi = lista(fMese, 12, false)
  if (!sett || !giorni || !mesi) return null
  if (sett.length && (giorni.length || mesi.length)) return null
  if (sett.length) { m.modo = 'settimanale'; m.giorniSettimana = [...new Set(sett.map(g => g === 7 ? 0 : g))] }
  else if (giorni.length) { m.modo = 'mensile'; m.giorniMese = giorni; m.mesi = mesi }
  else if (mesi.length) return null
  else m.modo = 'giornaliera'
  return m
}

// l'espressione detta in italiano; se non si sa leggere, torna com'è
export function descrivi(expr) {
  const m = scomponi(expr)
  if (!m) return expr || ''
  let quando
  if (m.modo === 'giornaliera') quando = 'ogni giorno'
  else if (m.modo === 'settimanale') {
    const g = m.giorniSettimana
    const feriali = [1, 2, 3, 4, 5]
    if (g.length === 7) quando = 'ogni giorno'
    else if (g.length === 5 && feriali.every(x => g.includes(x))) quando = 'dal lunedì al venerdì'
    else quando = GIORNI.filter(x => g.includes(x.valore)).map(x => x.breve).join(', ')
  } else {
    const giorni = m.giorniMese.map(g => g === 'L' ? 'l\'ultimo' : 'il ' + g)
    quando = (giorni.length > 1 ? giorni.slice(0, -1).join(', ') + ' e ' + giorni[giorni.length - 1] : giorni[0]) + ' del mese'
    if (m.mesi.length) quando += ' (' + m.mesi.map(x => MESI[x - 1]).join(', ') + ')'
  }
  const r = m.ripeti
  const orario = r.attiva
    ? `ogni ${r.ogni} ${r.unita === 'minuti' ? (r.ogni === 1 ? 'minuto' : 'minuti') : (r.ogni === 1 ? 'ora' : 'ore')} dalle ${r.dalle} alle ${r.alle}`
    : `alle ${m.ora}`
  return `${quando}, ${orario}`
}
