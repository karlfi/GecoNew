// Spostamento tra le celle con le frecce, come nel vecchio tweb: si scrive e si
// passa alla cella vicina senza premere Invio (lo spostamento conferma da solo
// quella che si lascia). Il Tab funziona gia' come freccia destra: e' PrimeVue
// che lo gestisce, qui non lo si tocca.
//
// Nell'applicazione ci sono tre situazioni diverse, ognuna con la sua funzione:
//   - griglia modificabile cella per cella   -> frecceCellEdit   (Attivita Dipendenti)
//   - griglia modificabile una riga per volta -> frecceRowEdit   (VideoCodifica)
//   - tabella di campi dentro un form         -> frecceCampi     (Attivita Filiali)

const DIREZIONI = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] }

// PrimeVue 4 marca le celle con attributi data-*, non con le classi
const IN_MODIFICA = 'td[data-p-cell-editing="true"]'
const MODIFICABILE = td => td?.dataset?.pEditableColumn === 'true'

// Nel testo libero le frecce laterali muovono il cursore: si esce solo da inizio
// o fine riga. Nei numeri e nelle tendine, dove il contenuto e' corto o non si
// scrive, ci si sposta subito.
function puoLasciare(campo, passoCol) {
  if (passoCol === 0 || !campo) return true
  if (campo.closest?.('.p-inputnumber') || campo.closest?.('.p-select')) return true
  const pos = campo.selectionStart
  if (pos == null) return true
  if (pos !== campo.selectionEnd) return false
  return passoCol < 0 ? pos === 0 : pos === (campo.value ?? '').length
}

// apre l'editor: la griglia reagisce al click, non basta chiamare .click()
const apriCella = el =>
  el?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }))

// Porta la cella allo scoperto. Le colonne fisse (in Attivita Dipendenti quella
// dei nomi) restano ferme sopra le altre: senza questo, spostandosi a sinistra
// la cella di arrivo finisce nascosta sotto di loro e il riquadro di modifica
// compare in mezzo ai nomi.
function portaInVista(cella) {
  if (!cella) return
  // il browser porta la cella dentro l'area visibile...
  cella.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  const cont = cella.closest('.p-datatable-table-container')
  if (!cont) return
  // ...ma non sa che le colonne fisse le stanno sopra: se resta sotto, si scorre
  // ancora fino a scoprirla del tutto
  const fisse = [...cella.parentElement.children]
    .filter(td => td.dataset.pFrozenColumn === 'true' && td !== cella)
  const coperto = fisse.reduce((somma, td) => somma + td.getBoundingClientRect().width, 0)
  const c = cella.getBoundingClientRect(), k = cont.getBoundingClientRect()
  if (c.left < k.left + coperto + 4) cont.scrollLeft -= (k.left + coperto + 4 - c.left)
}

// --- griglia modificabile cella per cella ---
export function frecceCellEdit(e) {
  const dir = DIREZIONI[e.key]
  if (!dir) return
  const cella = e.target.closest?.(IN_MODIFICA)
  if (!cella) return
  const [passoRiga, passoCol] = dir

  // su e giu' nelle tendine servono a scegliere l'opzione
  if (passoRiga !== 0 && e.target.closest('.p-select')) return
  if (!puoLasciare(e.target, passoCol)) return

  const riga = cella.parentElement
  const corpo = riga.parentElement
  const iCol = [...riga.children].indexOf(cella)
  let arrivo = null

  if (passoRiga !== 0) {
    const iRiga = [...corpo.children].indexOf(riga) + passoRiga
    if (corpo.children[iRiga]) arrivo = { iRiga, iCol }
  } else {
    // di lato si saltano le colonne non modificabili (targa, login, palmare...)
    const iRiga = [...corpo.children].indexOf(riga)
    for (let i = iCol + passoCol; i >= 0 && i < riga.children.length; i += passoCol) {
      if (MODIFICABILE(riga.children[i])) { arrivo = { iRiga, iCol: i }; break }
    }
  }
  if (!arrivo) return

  e.preventDefault()
  // Invio chiude la cella e fa partire il salvataggio, poi si apre quella di arrivo
  e.target.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }))
  setTimeout(() => {
    const dest = corpo.children[arrivo.iRiga]?.children[arrivo.iCol]
    apriCella(dest)
    // dopo: aprendo l'editor il campo prende il fuoco e il browser riporta la
    // cella al minimo visibile, che con le colonne fisse vuol dire lasciarla
    // sotto. La correzione va fatta a editor aperto, altrimenti viene annullata.
    requestAnimationFrame(() => portaInVista(dest))
  }, 0)
}

// --- tabella di campi dentro un form (nessun salvataggio: c'e' il pulsante) ---
export function frecceCampi(e) {
  const dir = DIREZIONI[e.key]
  if (!dir) return
  const cella = e.target.closest?.('td')
  const riga = cella?.parentElement
  const corpo = riga?.parentElement
  if (!cella || !corpo) return
  const [passoRiga, passoCol] = dir
  if (!puoLasciare(e.target, passoCol)) return

  const iCol = [...riga.children].indexOf(cella)
  let campo = null
  if (passoRiga !== 0) {
    const vicina = corpo.children[[...corpo.children].indexOf(riga) + passoRiga]
    campo = vicina?.children[iCol]?.querySelector('input')
  } else {
    for (let i = iCol + passoCol; i >= 0 && i < riga.children.length; i += passoCol) {
      const c = riga.children[i]?.querySelector('input')
      if (c && !c.disabled && !c.readOnly) { campo = c; break }
    }
  }
  if (!campo) return
  e.preventDefault()
  campo.focus()
  campo.select?.()
}

// --- griglia modificabile una riga per volta ---
// Su e giu' salvano la riga aperta e aprono quella vicina sulla stessa colonna;
// di lato ci si muove fra i campi della riga (il Tab fa gia' lo stesso).
export function frecceRowEdit(e) {
  const dir = DIREZIONI[e.key]
  if (!dir) return
  const [passoRiga, passoCol] = dir
  const cella = e.target.closest?.('td')
  const riga = cella?.parentElement
  const corpo = riga?.parentElement
  if (!cella || !corpo || !riga.querySelector('.p-datatable-row-editor-save')) return
  if (!puoLasciare(e.target, passoCol)) return

  if (passoRiga === 0) {
    const campi = [...riga.querySelectorAll('input:not([disabled])')]
    const campo = campi[campi.indexOf(e.target) + passoCol]
    if (!campo) return
    e.preventDefault()
    campo.focus(); campo.select?.()
    return
  }

  const iRiga = [...corpo.children].indexOf(riga) + passoRiga
  const vicina = corpo.children[iRiga]
  if (!vicina) return
  const iCol = [...riga.children].indexOf(cella)
  e.preventDefault()

  // si usano i pulsanti della griglia: cosi' il salvataggio segue la sua strada
  riga.querySelector('.p-datatable-row-editor-save')?.click()
  setTimeout(() => {
    const arrivo = corpo.children[iRiga]
    arrivo?.querySelector('.p-datatable-row-editor-init')?.click()
    setTimeout(() => arrivo?.children[iCol]?.querySelector('input')?.focus(), 60)
  }, 60)
}
