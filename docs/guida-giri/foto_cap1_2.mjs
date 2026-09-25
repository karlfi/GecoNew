// Screenshot dei capitoli 1 (Giri) e 2 (Spedizioni del giorno, Piano della giornata). Solo letture e prove locali:
// nessun clic su Salva, Crea, Assegna, Ottimizza, interruttori Attivo, Aggiorna giri di sped.
import { avvia, attesa } from './cdp.mjs'
const solo = process.argv[2]           // es. "cap1" o "cap2" per rifare solo un capitolo
const b = await avvia({ larghezza: 1680, altezza: 960 })
const pad = (r, m = 6) => ({ x: Math.max(0, r.x - m), y: Math.max(0, r.y - m), w: r.w + 2 * m, h: r.h + 2 * m })
async function pulisci() {
  await b.js(`document.querySelectorAll('.versione').forEach(e => e.style.visibility = 'hidden')`)
}
const menuAperto = () => b.js(`const i = document.querySelector('input[placeholder="Cerca nel menu..."]'); if (!i) return false; const r = i.getBoundingClientRect(); return r.width > 0 && r.x >= 0 && r.x < 200`)
async function apri(voce, ricerca, titolo) {
  for (let t = 0; t < 3; t++) {
    if (!await menuAperto()) { await b.clicSel('button[aria-label="Menu"]'); await attesa(1200) }
    await b.voceMenu(voce, ricerca)
    if (await b.finche(`document.querySelector('h2')?.innerText.includes(${JSON.stringify(titolo)})`, 8000)) break
    console.log('riprovo', voce)
  }
  if (await menuAperto()) { await b.clicSel('button[aria-label="Menu"]'); await attesa(1500) }
  await pulisci()
}
async function cercaGiro(testo) {
  await b.clicSel('.tab-giri .cerca'); await b.js(`document.querySelector('.tab-giri .cerca').select()`)
  await b.scrivi(testo); await attesa(600)
}
async function spuntaGiro(nome) {
  const r = await b.js(`const tr = [...document.querySelectorAll('.tab-giri tbody tr')].find(t => t.querySelector('.giro-riga1 b')?.innerText.trim() === ${JSON.stringify(nome)});
    if (!tr) return null; tr.scrollIntoView({ block: 'center' }); await new Promise(r => setTimeout(r, 300)); const c = tr.querySelector('td'); const r = c.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }`)
  if (!r) throw new Error('giro non trovato ' + nome)
  await b.clicXY(r.x, r.y); await attesa(1500)
}
async function modificaGiro(nome) {
  const r = await b.js(`const tr = [...document.querySelectorAll('.tab-giri tbody tr')].find(t => t.querySelector('.giro-riga1 b')?.innerText.trim() === ${JSON.stringify(nome)});
    tr.scrollIntoView({ block: 'center' }); await new Promise(r => setTimeout(r, 300)); const e = tr.querySelector('button[title="Modifica"]'); const r = e.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }`)
  await b.clicXY(r.x, r.y); await attesa(2500)
}

try {
  await b.vai('http://localhost:5173/login')
  await pulisci()

  if (!solo || solo === 'cap1') {
    // --- capitolo 1: pagina Giri ---
    await apri('Giri - Creazione giri su Mappa', 'Creazione giri', 'Giri')
    await b.clicTesto('Tutti', { selettore: '.tab-giri .tab-titolo button' }); await attesa(7000)
    await b.clicSel('.controlli .p-checkbox'); await attesa(3000)             // spedizioni di oggi
    await b.foto('g01_panoramica')
    await b.foto('g02_griglia', pad(await b.rett('.sinistra')))

    // nuovo giro disegnato a mano (solo bozza, non si crea)
    await b.clicTesto('Nessuno', { selettore: '.tab-giri .tab-titolo button' }); await attesa(1500)
    await b.clicSel('.controlli .p-checkbox'); await attesa(800)              // via le spedizioni
    await b.clicSel('.form input'); await b.scrivi('Esempio nuovo giro')
    await b.clicTesto('Disegna a mano (clic sulla mappa)', { selettore: '.form label' })
    const m = await b.rett('.mappa')
    const cx = m.x + m.w * 0.5, cy = m.y + m.h * 0.5
    for (const [dx, dy] of [[-120, -110], [60, -140], [170, -30], [140, 110], [-20, 150], [-150, 60]]) await b.clicXY(cx + dx, cy + dy)
    await attesa(800)
    await b.foto('g03_nuovo_disegno')
    await b.foto('g03b_pannello_nuovo', pad(await b.rett('.pannello')))
    await b.clicSel('.pannello-titolo button[title="Svuota"]'); await attesa(500)
    await b.clicTesto('Disegna a mano (clic sulla mappa)', { selettore: '.form label' })

    // nuovo giro dai comuni (si selezionano, non si crea)
    for (const c of ['Calenzano', 'Campi Bisenzio']) {
      const r = await b.js(`const tr = [...document.querySelectorAll('.tab-comuni tbody tr')].find(t => t.innerText.includes(${JSON.stringify(c)}));
        if (!tr) return null; tr.scrollIntoView({ block: 'nearest' }); const r = tr.querySelector('td').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }`)
      if (r) { await b.clicXY(r.x, r.y); await attesa(1500) }
    }
    await attesa(1500)
    await b.foto('g04_da_comuni')
    for (const c of ['Calenzano', 'Campi Bisenzio']) {
      const r = await b.js(`const tr = [...document.querySelectorAll('.tab-comuni tbody tr')].find(t => t.innerText.includes(${JSON.stringify(c)}));
        if (!tr) return null; tr.scrollIntoView({ block: 'nearest' }); const r = tr.querySelector('td').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }`)
      if (r) { await b.clicXY(r.x, r.y); await attesa(800) }
    }

    // modifica di un giro esistente: PO-03B col vicino PO-04B
    await cercaGiro('PO-0')
    await spuntaGiro('PO-04B')
    console.log('PO-04B spuntato:', await b.js(`return [...document.querySelectorAll('.tab-giri tbody tr')].some(t => t.innerText.includes('PO-04B') && t.querySelector('input[type=checkbox]')?.checked)`))
    await modificaGiro('PO-03B')
    await b.foto('g05_modifica')
    await b.foto('g05b_pannello_modifica', pad(await b.rett('.pannello')))
    await b.clicTesto('Modifica confine', { selettore: '.pannello button' }); await attesa(1500)
    await b.foto('g06_confine')
    // allinea al giro vicino (anteprima, poi applica: resta in bozza, non si salva)
    await b.clicSel('.allinea .vicino'); await attesa(700)
    await b.clicTesto('PO-04B', { contiene: true, selettore: '.p-select-option' }); await attesa(1500)
    await b.foto('g07_allinea')
    await b.foto('g07b_pannello_allinea', pad(await b.rett('.pannello')))
    await b.clicTesto('Applica', { selettore: '.allinea button' }); await attesa(1500)
    await b.foto('g08_condiviso')
    await b.foto('g08b_mappa_condiviso', await b.rett('.mappa'))
    await b.clicTesto('Annulla modifica confine', { selettore: '.pannello button' }); await attesa(1500)
    // giri non attivi
    await cercaGiro('')
    await b.clicTesto('Non attivi', { selettore: '.tab-filtri *' }); await attesa(1200)
    await b.foto('g09_non_attivi', pad(await b.rett('.tab-giri')))
    await b.clicTesto('Tutti', { selettore: '.tab-filtri *' }); await attesa(800)
  }

  if (!solo || solo === 'cap2') {
    // --- capitolo 2: Spedizioni del giorno ---
    await apri('Giri - Assegnazione', 'Assegnazione', 'Spedizioni del giorno')
    await attesa(3000)
    await b.foto('s01_spedizioni_giorno')
    // selezione di due righe: compare la barra di assegnazione (non si assegna)
    const righe = await b.js(`return [...document.querySelectorAll('tbody tr')].slice(0, 2).map(t => { const r = t.querySelector('td').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 } })`)
    for (const r of righe) { await b.clicXY(r.x, r.y); await attesa(500) }
    await attesa(800)
    await b.foto('s02_selezione')

    // --- capitolo 2: Piano della giornata ---
    await apri('Giri - Assegna a Driver', 'Assegna a Driver', 'Piano della giornata')
    await attesa(4000)
    await b.foto('p01_piano')
    // il percorso ottimizzato di un driver
    await b.clicSel('[title="Vedi il percorso sulla mappa"]'); await attesa(3000)
    await b.foto('p02_percorso')
    // menu del driver (tasto destro): partenza e ritorno, casa, storico
    const d = await b.js(`const e = document.querySelector('[title="Vedi il percorso sulla mappa"]').closest('.driver'); const r = e.getBoundingClientRect(); return { x: r.x + 40, y: r.y + 12 }`)
    await b.clicXY(d.x, d.y, 'right'); await attesa(800)
    await b.foto('p03_menu_driver')
    await b.cmd('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 })
    await b.cmd('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 })
    await attesa(500)
    // anteprima di stampa del percorso
    await b.clicSel('[title="Stampa percorso e lista"]'); await attesa(3500)
    await b.foto('p04_stampa')
  }
} catch (e) {
  console.log('ERRORE', e.message)
  await b.foto('errore')
} finally { await b.chiudi() }
