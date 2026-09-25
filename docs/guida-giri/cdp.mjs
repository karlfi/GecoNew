// Pilota Edge senza finestra (DevTools Protocol) per gli screenshot della documentazione: apre il portale locale
// (npm run dev + API locale con l'accesso di sviluppo), naviga, clicca, salva PNG. Solo letture: niente salvataggi.
import { spawn } from 'child_process'
import fs from 'fs'
import path from 'path'

const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
const PORTA = 9333
export const DIR = path.resolve('img')
fs.mkdirSync(DIR, { recursive: true })

export async function avvia({ larghezza = 1600, altezza = 950, scala = 1.25 } = {}) {
  const profilo = path.resolve('profilo-edge')
  const edge = spawn(EDGE, ['--headless=new', `--remote-debugging-port=${PORTA}`, `--user-data-dir=${profilo}`, '--no-first-run',
    '--disable-extensions', `--window-size=${larghezza},${altezza}`, 'about:blank'], { stdio: 'ignore' })
  let pagine = null
  for (let i = 0; i < 40 && !pagine; i++) {
    await attesa(250)
    try { pagine = await (await fetch(`http://127.0.0.1:${PORTA}/json/list`)).json() } catch { /* non ancora */ }
  }
  const pagina = pagine.find(p => p.type === 'page')
  const ws = new WebSocket(pagina.webSocketDebuggerUrl)
  await new Promise(r => ws.addEventListener('open', r, { once: true }))
  let id = 0
  const inAttesa = new Map()
  ws.addEventListener('message', ev => {
    const m = JSON.parse(ev.data)
    if (m.id && inAttesa.has(m.id)) { const { ok, ko } = inAttesa.get(m.id); inAttesa.delete(m.id); m.error ? ko(new Error(JSON.stringify(m.error))) : ok(m.result) }
  })
  const cmd = (method, params = {}) => new Promise((ok, ko) => { const i = ++id; inAttesa.set(i, { ok, ko }); ws.send(JSON.stringify({ id: i, method, params })) })
  await cmd('Page.enable'); await cmd('Runtime.enable')
  await cmd('Emulation.setDeviceMetricsOverride', { width: larghezza, height: altezza, deviceScaleFactor: scala, mobile: false })
  const b = {
    cmd,
    async js(codice) {
      const r = await cmd('Runtime.evaluate', { expression: `(async () => { ${codice} })()`, awaitPromise: true, returnByValue: true })
      if (r.exceptionDetails) throw new Error('JS: ' + (r.exceptionDetails.exception?.description ?? r.exceptionDetails.text))
      return r.result.value
    },
    async vai(url) {
      await cmd('Page.navigate', { url })
      for (let i = 0; i < 60; i++) {
        await attesa(300)
        if (await b.js('return !!document.querySelector(".p-panelmenu") && document.querySelectorAll(".p-panelmenu *").length > 50')) break
      }
      await attesa(800)
    },
    // aspetta che una condizione JS diventi vera (max ms)
    async finche(condizione, ms = 15000) {
      for (let t = 0; t < ms; t += 300) { if (await b.js('return !!(' + condizione + ')')) return true; await attesa(300) }
      return false
    },
    async clicXY(x, y, tasto = 'left') {
      for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased'])
        await cmd('Input.dispatchMouseEvent', { type, x, y, button: tasto, clickCount: 1 })
      await attesa(250)
    },
    async trascina(x1, y1, x2, y2, passi = 12) {
      await cmd('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x1, y: y1 })
      await cmd('Input.dispatchMouseEvent', { type: 'mousePressed', x: x1, y: y1, button: 'left', clickCount: 1 })
      for (let i = 1; i <= passi; i++) await cmd('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x1 + (x2 - x1) * i / passi, y: y1 + (y2 - y1) * i / passi, button: 'left', buttons: 1 })
      await cmd('Input.dispatchMouseEvent', { type: 'mouseReleased', x: x2, y: y2, button: 'left', clickCount: 1 })
      await attesa(400)
    },
    async scrivi(testo) { await cmd('Input.insertText', { text: testo }); await attesa(300) },
    // clic (col mouse, al centro) sul primo elemento visibile col testo esatto (o che lo contiene)
    async clicTesto(testo, { contiene = false, selettore = '*', tasto = 'left' } = {}) {
      const r = await b.js(`
        const vis = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 };
        const t = ${JSON.stringify(testo)};
        const el = [...document.querySelectorAll(${JSON.stringify(selettore)})].filter(vis)
          .filter(e => { const x = (e.innerText || e.value || '').trim(); return ${contiene ? 'x.includes(t)' : 'x === t'} })
          .sort((a, b) => (a.innerText || '').length - (b.innerText || '').length)[0];
        if (!el) return null; el.scrollIntoView({ block: 'nearest' }); const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }`)
      if (!r) throw new Error('non trovo: ' + testo)
      await b.clicXY(r.x, r.y, tasto)
      await attesa(500)
    },
    async clicSel(selettore, tasto = 'left') {
      const r = await b.js(`const e = document.querySelector(${JSON.stringify(selettore)}); if (!e) return null; e.scrollIntoView({ block: 'nearest' }); const r = e.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }`)
      if (!r) throw new Error('non trovo: ' + selettore)
      await b.clicXY(r.x, r.y, tasto)
      await attesa(500)
    },
    async voceMenu(voce, ricerca = voce) {
      await b.js(`
        const i = document.querySelector('input[placeholder="Cerca nel menu..."]');
        const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        set.call(i, ${JSON.stringify(ricerca)}); i.dispatchEvent(new Event('input', { bubbles: true }));`)
      await attesa(900)
      await b.clicTesto(voce, { selettore: '.p-panelmenu-item-label' })
      await attesa(4000)
    },
    rett: sel => b.js(`const e = document.querySelector(${JSON.stringify(sel)}); if (!e) return null; const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }`),
    // screenshot della pagina intera o di un riquadro {x, y, w, h} (in px CSS)
    async foto(nome, riquadro = null) {
      const p = { format: 'png', captureBeyondViewport: false }
      if (riquadro) p.clip = { x: riquadro.x, y: riquadro.y, width: riquadro.w, height: riquadro.h, scale: 1 }
      const r = await cmd('Page.captureScreenshot', p)
      fs.writeFileSync(path.join(DIR, nome + '.png'), Buffer.from(r.data, 'base64'))
      console.log('foto', nome)
    },
    async chiudi() { try { ws.close() } catch { } edge.kill() },
  }
  return b
}
export const attesa = ms => new Promise(r => setTimeout(r, ms))
