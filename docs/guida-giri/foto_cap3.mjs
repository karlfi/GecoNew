// Screenshot del capitolo 3 (Pianificazione Automatica). Fase "prima": nessun Calcola, nessuna conferma.
// Fase "dopo" (argomento "dopo"): la pagina con il piano gia' calcolato del giorno (il calcolo lo si lancia a parte).
import { avvia, attesa } from './cdp.mjs'
const fase = process.argv[2] || 'prima'
const b = await avvia({ larghezza: 1680, altezza: 960 })
const pad = (r, m = 6) => ({ x: Math.max(0, r.x - m), y: Math.max(0, r.y - m), w: r.w + 2 * m, h: r.h + 2 * m })
const menuAperto = () => b.js(`const i = document.querySelector('input[placeholder="Cerca nel menu..."]'); if (!i) return false; const r = i.getBoundingClientRect(); return r.width > 0 && r.x >= 0 && r.x < 200`)
async function apri(voce, ricerca, titolo) {
  for (let t = 0; t < 3; t++) {
    if (!await menuAperto()) { await b.clicSel('button[aria-label="Menu"]'); await attesa(1200) }
    await b.voceMenu(voce, ricerca)
    if (await b.finche(`document.querySelector('h2')?.innerText.includes(${JSON.stringify(titolo)})`, 8000)) break
  }
  if (await menuAperto()) { await b.clicSel('button[aria-label="Menu"]'); await attesa(1500) }
  await b.js(`document.querySelectorAll('.versione').forEach(e => e.style.visibility = 'hidden')`)
}
try {
  await b.vai('http://localhost:5173/login')
  await apri('Pianificazione Automatica', 'Pianificazione', 'Pianificazione automatica')
  await attesa(4000)
  if (fase === 'prima') {
    await b.foto('a01_pianificazione')
    await b.foto('a02_comandi', pad(await b.rett('.comandi')))
    // i vincoli di un driver: si apre la sua scheda (si guarda, non si calcola)
    await b.clicSel('.driver button[title="Turno, partenza, massimo pezzi, zone"]'); await attesa(1000)
    await b.foto('a03_driver', pad(await b.rett('.sinistra')))
  } else {
    await b.foto('a04_risultato')
    await b.foto('a05_esito', pad(await b.rett('.comandi')))
    await b.foto('a06_driver_risultati', pad(await b.rett('.sinistra')))
    // un driver evidenziato: solo il suo giro con le tappe numerate
    await b.clicSel('.driver .nome'); await attesa(1500)
    await b.foto('a07_driver_scelto')
    const na = await b.rett('.non-assegnate')
    if (na) await b.foto('a08_non_assegnate', pad(na))
  }
} catch (e) {
  console.log('ERRORE', e.message); await b.foto('errore')
} finally { await b.chiudi() }
