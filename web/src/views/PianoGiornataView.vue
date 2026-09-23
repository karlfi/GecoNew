<script setup>
// Piano della giornata: la lavagna di assegnazione dei giri ai driver per il giorno scelto.
// A sinistra i giri con spedizioni ancora da assegnare (col numero di pezzi), al centro la mappa con
// i punti di consegna e le aree dei giri (chiare = da assegnare, scure = assegnate, col nome del
// driver sopra), a destra i driver con i giri che hanno in carico e i pezzi. Si assegna trascinando
// un giro sul driver, con la freccia accanto al giro (driver selezionato), con Ctrl+clic su un'area
// chiara della mappa (va al driver selezionato) e con Maiusc+trascinamento di un rettangolo sui
// punti liberi (vanno nel giro del driver piu' vicino). I punti gia' assegnati spariscono dalla mappa.
// Per ogni driver: partenza e ritorno da casa o dalla filiale (tasto destro), "Ottimizza" con HERE
// (percorso unico su tutti i suoi giri, tracciato stradale, km, minuti, arrivi stimati), Excel e stampa.
// Sostituisce le videate legacy "Giri - Assegna a Driver" e "Giri - Ottimizza percorso".
import { ref, computed, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { useNavStore } from '../stores/nav'
import { scaricaDaApi } from '../lib/esporta'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import 'leaflet.markercluster/dist/MarkerCluster.css'
import 'leaflet.markercluster/dist/MarkerCluster.Default.css'
import 'leaflet.markercluster'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import DatePicker from 'primevue/datepicker'
import Dialog from 'primevue/dialog'
import Tag from 'primevue/tag'
import Message from 'primevue/message'
import ContextMenu from 'primevue/contextmenu'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

const toast = useToast()
const nav = useNavStore()
const errore = ref('')
const avviso = (severity, summary, detail, life = 4000) => toast.add({ severity, summary, detail, life })
const messaggio = e => e?.response?.data?.errore ?? e?.message ?? 'Errore'
const dataOra = v => v ? new Date(v).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' }) : ''
const ora = v => v ? new Date(v).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' }) : ''
const km = m => m == null ? '' : `${(m / 1000).toFixed(1)} km`
const minuti = s => s == null ? '' : s >= 3600 ? `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min` : `${Math.round(s / 60)} min`
const cognome = n => (n || '').split(' ')[0]
const GRIGIO = '#8d8d8d'

// --- dati ---
const filiale = ref('')
const filialeCoord = ref(null)
const data = ref(new Date())
const giri = ref([])
const driver = ref([])
const spedizioni = ref([])
const shapes = ref([])
const senzaGiro = ref({ n: 0, geo: 0 })
const caricamento = ref(false)
const lavoro = ref(false)
const dataIso = computed(() => {
  const d = data.value instanceof Date ? data.value : new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
})
const giroPer = computed(() => new Map(giri.value.map(g => [g.idGiro, g])))
const giriDaAssegnare = computed(() => giri.value.filter(g => g.nSped > 0 && !g.idDriver))
const giriDelDriver = id => giri.value.filter(g => g.idDriver === id)
const filtroDriver = ref('')
const driverScelto = ref(null)        // idUtente selezionato a destra
const giroScelto = ref(null)
const driverOrdinati = computed(() => {
  const q = filtroDriver.value.trim().toLowerCase()
  return driver.value
    .map(d => {
      const gg = giriDelDriver(d.idUtente)
      return { ...d, giri: gg, nSped: gg.reduce((s, g) => s + g.nSped, 0), nGeo: gg.reduce((s, g) => s + g.nGeo, 0), nSequenza: gg.reduce((s, g) => s + g.nSequenza, 0) }
    })
    .filter(d => !q || d.nome.toLowerCase().includes(q))
    .sort((a, b) => (b.nSped - a.nSped) || a.nome.localeCompare(b.nome))
})
const driverSceltoDati = computed(() => driverOrdinati.value.find(d => d.idUtente === driverScelto.value) ?? null)
const puntiLiberi = computed(() => spedizioni.value.filter(s => s.lat != null && !(s.idGiro && giroPer.value.get(s.idGiro)?.idDriver)))
const riepilogo = computed(() => {
  const r = { giri: 0, daAssegnare: giriDaAssegnare.value.length, sped: 0, assegnate: 0, driverConCarico: 0, fatti: 0, inCorso: 0 }
  for (const g of giri.value) { if (!g.nSped) continue; r.giri++; r.sped += g.nSped; if (g.idDriver) r.assegnate += g.nSped }
  for (const d of driverOrdinati.value) {
    if (d.nSped) r.driverConCarico++
    if (d.stato === 'FATTA') r.fatti++
    if (d.stato === 'RICHIESTA' || d.stato === 'IN_CORSO') r.inCorso++
  }
  return r
})
let timer = null

async function carica(silenzioso = false) {
  if (!silenzioso) caricamento.value = true
  try {
    const [{ data: d }, { data: s }] = await Promise.all([api.get('/piano', { params: { data: dataIso.value } }), api.get('/sped-giri', { params: { data: dataIso.value } })])
    filiale.value = d.filiale ?? ''
    if (d.lat) filialeCoord.value = { lat: d.lat, lng: d.lng }
    giri.value = d.giri; driver.value = d.driver; senzaGiro.value = d.senzaGiro
    spedizioni.value = s.spedizioni
    if (!shapes.value.length) shapes.value = (await api.get('/giri/shapes')).data
    await nextTick()
    disegnaTutto(!silenzioso)
    clearTimeout(timer)
    const inCorso = driver.value.some(x => x.stato === 'RICHIESTA' || x.stato === 'IN_CORSO')
    if (inCorso) timer = setTimeout(() => carica(true), 4000)
    else if (attesa.value) {
      attesa.value = false
      const d0 = driver.value.find(x => x.idUtente === percorso.value?.piano?.idDriver)
      if (d0?.idPianoDriver) await apriPercorso(d0)
    }
    if (inCorso) attesa.value = true
  } catch (e) { avviso('error', 'Piano', messaggio(e)) } finally { caricamento.value = false }
}
const attesa = ref(false)
onMounted(async () => { preparaMappa(); await carica() })
onBeforeUnmount(() => { clearTimeout(timer); if (map) { map.remove(); map = null } if (mapStampa) { mapStampa.remove(); mapStampa = null } })

// --- mappa ---
let map = null, resizeObs = null, areeLayer, etichetteLayer, puntiCluster, percorsoLayer, rettLayer
const poligoni = new Map()            // idGiro -> [L.polygon]
const mapEl = ref(null)
function preparaMappa() {
  map = L.map(mapEl.value, { center: [43.84, 11.11], zoom: 11, boxZoom: false })
  const osm = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map)
  const satellite = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', { maxZoom: 19, attribution: 'Tiles © Esri' })
  L.control.layers({ Mappa: osm, Satellite: satellite }, null, { position: 'topright' }).addTo(map)
  areeLayer = L.layerGroup().addTo(map)
  etichetteLayer = L.layerGroup().addTo(map)
  puntiCluster = L.markerClusterGroup({ chunkedLoading: true, maxClusterRadius: 30, disableClusteringAtZoom: 13 }).addTo(map)
  percorsoLayer = L.featureGroup().addTo(map)
  rettLayer = L.layerGroup().addTo(map)
  // Maiusc + trascinamento = rettangolo di selezione dei punti liberi per il driver scelto
  const el = mapEl.value
  el.addEventListener('mousedown', ev => {
    if (!ev.shiftKey || ev.button !== 0) return
    if (!driverScelto.value) { avviso('warn', 'Rettangolo', 'Seleziona prima un driver a destra'); return }
    rettInizio = map.mouseEventToLatLng(ev); map.dragging.disable(); ev.preventDefault()
  }, true)
  el.addEventListener('mousemove', ev => {
    if (!rettInizio) return
    rettLayer.clearLayers()
    L.rectangle(L.latLngBounds(rettInizio, map.mouseEventToLatLng(ev)), { color: '#1565c0', weight: 1, dashArray: '4,4', fillOpacity: 0.1 }).addTo(rettLayer)
  })
  el.addEventListener('mouseup', ev => { if (rettInizio) fineRettangolo(map.mouseEventToLatLng(ev)) })
  el.addEventListener('mouseleave', () => { if (rettInizio) { rettInizio = null; rettLayer.clearLayers(); map.dragging.enable() } })
  resizeObs = new ResizeObserver(() => map && map.invalidateSize())
  resizeObs.observe(mapEl.value)
  setTimeout(() => map && map.invalidateSize(), 200)
}
let rettInizio = null
async function fineRettangolo(fine) {
  const b = L.latLngBounds(rettInizio, fine)
  rettInizio = null; rettLayer.clearLayers(); map.dragging.enable()
  const dentro = puntiLiberi.value.filter(s => b.contains([s.lat, s.lng]))
  if (!dentro.length) { avviso('info', 'Rettangolo', 'Nessun punto libero nel rettangolo', 2500); return }
  await assegnaPunti(dentro)
}
function wktToRings(wkt) {
  if (!wkt) return []
  const rings = []
  const re = /\(([^()]+)\)/g
  let m
  while ((m = re.exec(wkt))) {
    const pts = m[1].split(',').map(s => { const [lng, lat] = s.trim().split(/\s+/).map(Number); return [lat, lng] })
      .filter(p => Number.isFinite(p[0]) && Number.isFinite(p[1]))
    if (pts.length >= 3) rings.push(pts)
  }
  return rings
}
function centro(ring) { return [ring.reduce((s, p) => s + p[0], 0) / ring.length, ring.reduce((s, p) => s + p[1], 0) / ring.length] }
function stile(g) {
  const col = g.colore || '#3388ff'
  if (g.idDriver) {
    const sel = driverScelto.value != null && g.idDriver === driverScelto.value
    return { color: sel ? '#1565c0' : col, weight: sel ? 4 : 2, fillColor: col, fillOpacity: sel ? 0.5 : 0.35, dashArray: null }
  }
  const sel = giroScelto.value === g.idGiro
  return { color: col, weight: sel ? 3 : 1, fillColor: col, fillOpacity: g.nSped ? (sel ? 0.25 : 0.12) : 0.03, dashArray: g.nSped ? null : '3,4' }
}
function disegnaTutto(inquadra) {
  areeLayer.clearLayers(); etichetteLayer.clearLayers(); poligoni.clear()
  for (const s of shapes.value) {
    const g = giroPer.value.get(s.idGiro)
    if (!g) continue
    const rings = wktToRings(s.wkt)
    const lista = []
    for (const ring of rings) {
      const poly = L.polygon(ring, stile(g)).bindTooltip(() => `${g.giro} · ${g.nSped} pezzi${g.driver ? ' · ' + g.driver : ' · da assegnare'}`)
      poly.on('click', e => clicArea(e, g))
      poly.addTo(areeLayer); lista.push(poly)
    }
    poligoni.set(g.idGiro, lista)
  }
  disegnaEtichette(); disegnaPunti()
  if (inquadra) {
    const b = puntiCluster.getBounds()
    if (b.isValid()) map.fitBounds(b, { padding: [20, 20] })
    else if (filialeCoord.value) map.setView([filialeCoord.value.lat, filialeCoord.value.lng], 11)
  }
}
function disegnaEtichette() {
  etichetteLayer.clearLayers()
  for (const s of shapes.value) {
    const g = giroPer.value.get(s.idGiro)
    if (!g?.idDriver) continue
    const rings = wktToRings(s.wkt)
    if (!rings.length) continue
    const c = centro(rings.reduce((a, b) => a.length >= b.length ? a : b))
    L.marker(c, { icon: L.divIcon({ className: 'etichetta-driver', html: `<span>${cognome(g.driver)}</span>`, iconSize: null }), interactive: false }).addTo(etichetteLayer)
  }
}
function ristila() {
  for (const [id, lista] of poligoni) { const g = giroPer.value.get(id); if (g) lista.forEach(p => p.setStyle(stile(g))) }
}
function disegnaPunti() {
  puntiCluster.clearLayers()
  const ms = []
  for (const s of puntiLiberi.value) {
    const col = s.idGiro ? ((s.colore && `${s.colore}`.trim()) || '#e53935') : GRIGIO
    ms.push(L.marker([s.lat, s.lng], { icon: L.divIcon({ className: 'sped-punto' + (s.idGiro ? '' : ' senza-giro'), html: `<span style="background:${col}"></span>`, iconSize: [12, 12], iconAnchor: [6, 6] }) })
      .bindTooltip(`<b>${s.barcode ?? ''}</b> ${s.destinatario ?? ''}<br>${s.indirizzo ?? ''} ${s.cap ?? ''} ${s.localita ?? ''}<br>${s.giro ? 'Giro ' + s.giro : '<i>senza giro</i>'}`))
  }
  puntiCluster.addLayers(ms)
}
function clicArea(e, g) {
  if (e.originalEvent.ctrlKey || e.originalEvent.metaKey) {
    L.DomEvent.stopPropagation(e)
    if (!driverScelto.value) { avviso('warn', 'Assegnazione', 'Seleziona prima un driver a destra, poi Ctrl+clic sull\'area'); return }
    if (g.idDriver === driverScelto.value) return
    if (g.idDriver) { chiedi('Cambia driver', `Il giro ${g.giro} e' di ${g.driver}: lo passo a ${driverSceltoDati.value?.nome}?`, () => assegnaGiro(g, driverScelto.value)); return }
    assegnaGiro(g, driverScelto.value)
    return
  }
  giroScelto.value = giroScelto.value === g.idGiro ? null : g.idGiro
  ristila()
}
function inquadraGiro(g) {
  giroScelto.value = g.idGiro; ristila()
  const lista = poligoni.get(g.idGiro)
  if (lista?.length) map.fitBounds(L.featureGroup(lista).getBounds(), { padding: [20, 20] })
}
function scegliDriver(d) {
  driverScelto.value = driverScelto.value === d.idUtente ? null : d.idUtente
  ristila()
  if (driverScelto.value) {
    const lista = giriDelDriver(driverScelto.value).flatMap(g => poligoni.get(g.idGiro) ?? [])
    if (lista.length) map.fitBounds(L.featureGroup(lista).getBounds(), { padding: [30, 30] })
  }
}

// --- assegnazioni ---
const conferma = ref(null)
function chiedi(titolo, testo, azione) { conferma.value = { titolo, testo, azione } }
async function confermato() { const c = conferma.value; conferma.value = null; if (c) await c.azione() }
async function assegnaGiro(g, idDriver) {
  if (!g) return
  lavoro.value = true
  try {
    const { data: r } = await api.post('/piano/driver', { data: dataIso.value, idGiro: g.idGiro, idDriver: idDriver ?? null })
    g.idPiano = r.IdPiano; g.idDriver = r.IdDriver; g.driver = r.Driver
    avviso('success', g.giro, r.Driver ? `Assegnato a ${r.Driver} (${g.nSped} pezzi)` : 'Tolto dal driver: torna fra quelli da assegnare', 2500)
    ristila(); disegnaEtichette(); disegnaPunti()
    await carica(true)
  } catch (e) { avviso('error', 'Assegnazione', messaggio(e), 5000); await carica(true) } finally { lavoro.value = false }
}
async function assegnaPunti(dentro) {
  lavoro.value = true
  try {
    const { data: r } = await api.post('/piano/punti', { data: dataIso.value, idDriver: driverScelto.value, idSpedizioni: dentro.map(s => s.idSpedizione) })
    avviso('success', driverSceltoDati.value?.nome ?? 'Driver', `${r.cambiate} punti messi nel giro ${r.giro}`, 3500)
    await carica(true)
  } catch (e) { avviso('error', 'Punti', messaggio(e), 6000) } finally { lavoro.value = false }
}
async function driverPredefiniti() {
  lavoro.value = true
  try {
    const { data: r } = await api.post('/piano/driver-predefiniti', { data: dataIso.value })
    avviso('success', 'Driver predefiniti', `${r.assegnati} giri hanno preso il driver predefinito`)
    await carica(true)
  } catch (e) { avviso('error', 'Driver predefiniti', messaggio(e)) } finally { lavoro.value = false }
}
function trascina(e, g) { e.dataTransfer.setData('text/plain', String(g.idGiro)); e.dataTransfer.effectAllowed = 'move' }
function rilascia(e, d) {
  const id = Number(e.dataTransfer.getData('text/plain'))
  const g = giroPer.value.get(id)
  if (g && g.idDriver !== d.idUtente) assegnaGiro(g, d.idUtente)
}

// --- opzioni del driver (tasto destro) e casa ---
const menu = ref(null)
const driverMenu = ref(null)
const voci = computed(() => {
  const d = driverMenu.value
  if (!d) return []
  return [
    { label: d.partenzaCasa ? '✓ Parte da casa' : 'Parte da casa', icon: 'pi pi-home', command: () => opzioni(d, !d.partenzaCasa, !!d.ritornoCasa) },
    { label: d.ritornoCasa ? '✓ Torna a casa' : 'Torna a casa', icon: 'pi pi-home', command: () => opzioni(d, !!d.partenzaCasa, !d.ritornoCasa) },
    { label: !d.partenzaCasa && !d.ritornoCasa ? '✓ Parte e torna dalla filiale' : 'Parte e torna dalla filiale', icon: 'pi pi-building', command: () => opzioni(d, false, false) },
    { separator: true },
    { label: d.casaIndirizzo ? `Casa: ${d.casaIndirizzo}` : 'Indirizzo di casa…', icon: 'pi pi-map-marker', command: () => apriCasa(d) },
    { label: 'Storico', icon: 'pi pi-history', command: () => apriStorico(d) },
  ]
})
function apriMenu(ev, d) { driverMenu.value = d; menu.value.show(ev) }
async function opzioni(d, partenzaCasa, ritornoCasa) {
  if ((partenzaCasa || ritornoCasa) && d.casaLat == null) { apriCasa(d, { partenzaCasa, ritornoCasa }); return }
  try {
    await api.post('/piano/driver/opzioni', { data: dataIso.value, idDriver: d.idUtente, partenzaCasa, ritornoCasa })
    avviso('success', d.nome, `Parte ${partenzaCasa ? 'da casa' : 'dalla filiale'}, torna ${ritornoCasa ? 'a casa' : 'in filiale'}`, 3000)
    await carica(true)
  } catch (e) { avviso('error', 'Opzioni', messaggio(e)) }
}
const casa = ref(null)                // { driver, indirizzo, dopo }
function apriCasa(d, dopo = null) { casa.value = { driver: d, indirizzo: d.casaIndirizzo || d.residenza || '', dopo } }
async function salvaCasa() {
  const c = casa.value
  if (!c) return
  lavoro.value = true
  try {
    const { data: r } = await api.post(`/piano/driver/${c.driver.idUtente}/casa`, { indirizzo: c.indirizzo })
    avviso('success', c.driver.nome, `Casa: ${r.trovato}`, 5000)
    casa.value = null
    await carica(true)
    if (c.dopo) await opzioni({ ...c.driver, casaLat: r.lat }, c.dopo.partenzaCasa, c.dopo.ritornoCasa)
  } catch (e) { avviso('error', 'Indirizzo di casa', messaggio(e), 6000) } finally { lavoro.value = false }
}

// --- ottimizzazione ---
const STATO = { RICHIESTA: { nome: 'in coda', sev: 'info' }, IN_CORSO: { nome: 'in corso', sev: 'info' }, FATTA: { nome: 'ottimizzato', sev: 'success' }, ERRORE: { nome: 'errore', sev: 'danger' } }
async function ottimizza(d) {
  if (d.stato === 'FATTA' && !d.daRifare && d.nSequenza >= d.nGeo) return chiedi('Rifai il percorso', `${d.nome} ha gia' il percorso ottimizzato: lo rifaccio con le consegne di adesso?`, () => ottimizzaDavvero(d))
  await ottimizzaDavvero(d)
}
async function ottimizzaDavvero(d) {
  lavoro.value = true
  try {
    const { data: r } = await api.post('/piano/ottimizza', { data: dataIso.value, idDriver: d.idUtente })
    avviso('info', d.nome, `Richiesta a HERE per ${r.nPunti} consegne${r.nSenzaCoordinate ? ` (${r.nSenzaCoordinate} senza coordinate restano fuori)` : ''}: esecuzione ${r.idEsecuzione}`, 6000)
    await carica(true)
  } catch (e) { avviso('error', 'Ottimizzazione', messaggio(e), 6000) } finally { lavoro.value = false }
}
function chiediOttimizzaTutti() {
  const daFare = driverOrdinati.value.filter(d => d.nGeo > 0 && !['RICHIESTA', 'IN_CORSO'].includes(d.stato ?? '') && (d.stato !== 'FATTA' || d.daRifare || d.nSequenza < d.nGeo)).length
  chiedi('Ottimizza tutti', daFare ? `Chiedo a HERE il percorso dei ${daFare} driver con consegne e senza percorso aggiornato. Procedo?` : 'Tutti i driver con consegne hanno gia\' il percorso: li rifaccio tutti?', () => ottimizzaTutti(!!daFare))
}
async function ottimizzaTutti(soloDaFare) {
  lavoro.value = true
  try {
    const { data: r } = await api.post('/piano/ottimizza-tutti', { data: dataIso.value, soloDaFare })
    avviso('info', 'Ottimizza tutti', `${r.richieste} richieste in coda${r.saltati.length ? `, ${r.saltati.length} saltati: ${r.saltati[0]}` : ''}`, 7000)
    await carica(true)
  } catch (e) { avviso('error', 'Ottimizza tutti', messaggio(e), 6000) } finally { lavoro.value = false }
}

// --- percorso di un driver sulla mappa ---
const percorso = ref(null)
const tappaScelta = ref(null)
async function apriPercorso(d) {
  if (!d.idPianoDriver) { avviso('info', d.nome, 'Nessun percorso ancora: assegna i giri e premi Ottimizza', 3500); return }
  try {
    const { data: r } = await api.get(`/piano/driver/${d.idPianoDriver}/percorso`)
    percorso.value = r
    disegnaPercorso(percorsoLayer, r, map)
  } catch (e) { avviso('error', 'Percorso', messaggio(e)) }
}
function chiudiPercorso() { percorso.value = null; percorsoLayer.clearLayers() }
function disegnaPercorso(layer, r, mappa) {
  layer.clearLayers()
  const col = '#1565c0'
  const tappe = []
  const casaIcona = t => L.divIcon({ className: 'tappa-base', html: `<span>${t === 'casa' ? '⌂' : '▣'}</span>`, iconSize: [26, 26], iconAnchor: [13, 13] })
  if (r.partenza?.lat != null) {
    L.marker([r.partenza.lat, r.partenza.lng], { icon: casaIcona(r.piano.partenzaCasa ? 'casa' : 'filiale') }).bindTooltip(`Partenza: ${r.partenza.indirizzo ?? ''}`).addTo(layer)
    tappe.push([r.partenza.lat, r.partenza.lng])
  }
  for (const p of r.punti) {
    if (p.lat == null) continue
    const m = L.marker([p.lat, p.lng], { icon: L.divIcon({ className: 'tappa', html: `<span style="background:${col}">${p.sequenza ?? '·'}</span>`, iconSize: [22, 22], iconAnchor: [11, 11] }) })
      .bindTooltip(`<b>${p.sequenza ? p.sequenza + '. ' : ''}${p.barcode ?? ''}</b> ${p.destinatario ?? ''}<br>${p.indirizzo ?? ''}<br>${p.cap ?? ''} ${p.localita ?? ''}${p.arrivo ? '<br>arrivo stimato ' + ora(p.arrivo) : ''}`)
    m.on('click', () => { tappaScelta.value = p.idSpedizione })
    m.addTo(layer)
    if (p.sequenza) tappe.push([p.lat, p.lng])
  }
  if (r.ritorno?.lat != null) {
    L.marker([r.ritorno.lat, r.ritorno.lng], { icon: casaIcona(r.piano.ritornoCasa ? 'casa' : 'filiale') }).bindTooltip(`Ritorno: ${r.ritorno.indirizzo ?? ''}`).addTo(layer)
    tappe.push([r.ritorno.lat, r.ritorno.lng])
  }
  if (r.piano.stato === 'FATTA') {
    if (r.polilinea?.length) L.polyline(r.polilinea, { color: col, weight: 4, opacity: 0.85 }).addTo(layer)
    else if (tappe.length > 1) L.polyline(tappe, { color: col, weight: 3, opacity: 0.7, dashArray: '6,6' }).addTo(layer)
  }
  const b = layer.getBounds()
  if (b.isValid()) mappa.fitBounds(b, { padding: [20, 20] })
}
function evidenzia(p) { tappaScelta.value = p.idSpedizione; if (map && p.lat != null) map.panTo([p.lat, p.lng]) }
function esporta(d) {
  scaricaDaApi(api, `/piano/driver/${d.idPianoDriver}/export`, {}, `percorso_${d.nome}_${dataIso.value}.xlsx`).catch(e => avviso('error', 'Excel', messaggio(e)))
}

// --- stampa: percorso e lista delle consegne, a tutta pagina ---
const stampa = ref(null)
const mapStampaEl = ref(null)
let mapStampa = null
async function apriStampa(d) {
  if (!d.idPianoDriver) { avviso('info', d.nome, 'Nessun percorso da stampare', 3000); return }
  try {
    const { data: r } = await api.get(`/piano/driver/${d.idPianoDriver}/percorso`)
    stampa.value = r
    await nextTick()
    if (mapStampa) { mapStampa.remove(); mapStampa = null }
    mapStampa = L.map(mapStampaEl.value, { zoomControl: false, attributionControl: true })
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(mapStampa)
    const layer = L.featureGroup().addTo(mapStampa)
    setTimeout(() => { mapStampa.invalidateSize(); disegnaPercorso(layer, r, mapStampa) }, 250)
  } catch (e) { avviso('error', 'Stampa', messaggio(e)) }
}
function chiudiStampa() { if (mapStampa) { mapStampa.remove(); mapStampa = null } stampa.value = null }

// --- storico ---
const storico = ref(null)
async function apriStorico(d) {
  if (!d.idPianoDriver) { avviso('info', d.nome, 'Nessuna modifica registrata'); return }
  try { storico.value = { driver: d, righe: (await api.get(`/piano/driver/${d.idPianoDriver}/storico`)).data } } catch (e) { avviso('error', 'Storico', messaggio(e)) }
}
function vaiSpedizioni() { nav.drill({ tipo: 'sped-giorno' }) }
</script>

<template>
  <div class="pagina">
    <div class="testata">
      <div>
        <h2>Piano della giornata <span class="filiale">{{ filiale }}</span></h2>
        <p class="sotto">Trascina un giro su un driver, o seleziona il driver e usa la freccia, Ctrl+clic sull'area chiara nella mappa, Maiusc+rettangolo sui punti liberi. Tasto destro sul driver: partenza e ritorno da casa o dalla filiale.</p>
      </div>
      <div class="barra">
        <DatePicker v-model="data" dateFormat="dd/mm/yy" showIcon size="small" class="data" @update:modelValue="chiudiPercorso(); carica()" />
        <Button label="Driver predefiniti" icon="pi pi-users" size="small" outlined :loading="lavoro" title="Mette il driver predefinito del giro dove manca" @click="driverPredefiniti" />
        <Button label="Ottimizza tutti" icon="pi pi-directions" size="small" :loading="lavoro" :disabled="!riepilogo.assegnate" @click="chiediOttimizzaTutti" />
        <Button icon="pi pi-refresh" text :loading="caricamento" title="Ricarica" @click="carica()" />
      </div>
    </div>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="riepilogo">
      <span class="chip">{{ riepilogo.sped }} pezzi in {{ riepilogo.giri }} giri</span>
      <span class="chip" :class="riepilogo.daAssegnare ? 'attenzione' : 'ok'">{{ riepilogo.daAssegnare }} giri da assegnare</span>
      <span class="chip">{{ riepilogo.assegnate }} pezzi assegnati a {{ riepilogo.driverConCarico }} driver</span>
      <span class="chip" :class="{ ok: riepilogo.fatti && riepilogo.fatti === riepilogo.driverConCarico }">{{ riepilogo.fatti }} percorsi<template v-if="riepilogo.inCorso">, {{ riepilogo.inCorso }} in corso</template></span>
      <button v-if="senzaGiro.n" class="chip attenzione" title="Apri Spedizioni del giorno" @click="vaiSpedizioni">{{ senzaGiro.n }} spedizioni senza giro</button>
    </div>

    <div class="lavagna">
      <!-- sinistra: giri da assegnare -->
      <div class="colonna sinistra">
        <div class="titolo-col">Giri da assegnare <span class="conteggio">{{ giriDaAssegnare.length }}</span></div>
        <div class="lista">
          <div v-for="g in giriDaAssegnare" :key="g.idGiro" class="giro" :class="{ scelto: giroScelto === g.idGiro }" draggable="true"
            @dragstart="e => trascina(e, g)" @click="inquadraGiro(g)">
            <span class="pallino" :style="{ background: g.colore || '#ccc' }"></span>
            <span class="nome">{{ g.giro }}</span>
            <b class="pezzi" :title="g.nGeo < g.nSped ? `${g.nSped - g.nGeo} senza coordinate` : ''">{{ g.nSped }}</b>
            <Button icon="pi pi-arrow-right" text rounded size="small" :disabled="!driverScelto || lavoro" :title="driverScelto ? `Assegna a ${driverSceltoDati?.nome}` : 'Seleziona prima un driver'" @click.stop="assegnaGiro(g, driverScelto)" />
          </div>
          <p v-if="!giriDaAssegnare.length" class="nota vuoto">Tutti i giri con spedizioni sono assegnati.</p>
        </div>
      </div>

      <!-- centro: mappa -->
      <div class="colonna centro">
        <div class="strumenti">
          <template v-if="percorso">
            <b>{{ percorso.piano.driver }}</b>
            <span class="nota"> · {{ percorso.punti.length }} consegne<template v-if="percorso.piano.stato === 'FATTA'">, {{ km(percorso.piano.distanzaM) }}, {{ minuti(percorso.piano.tempoS) }} con le soste</template><template v-else>, percorso non ancora ottimizzato</template></span>
            <span class="spazio"></span>
            <Button label="Chiudi percorso" icon="pi pi-times" size="small" text @click="chiudiPercorso" />
          </template>
          <template v-else>
            <span class="nota" v-if="driverSceltoDati">Driver selezionato: <b>{{ driverSceltoDati.nome }}</b> · Ctrl+clic su un'area chiara la assegna, Maiusc+rettangolo assegna i punti liberi</span>
            <span class="nota" v-else>Aree chiare = giri da assegnare, scure = assegnate (col driver). Sulla mappa restano solo i punti non ancora assegnati.</span>
            <span class="spazio"></span>
            <span class="nota">{{ puntiLiberi.length }} punti liberi</span>
          </template>
        </div>
        <div ref="mapEl" class="mappa"></div>
        <div v-if="percorso" class="tappe">
          <table>
            <thead><tr><th>#</th><th>Barcode</th><th>Destinatario</th><th>Indirizzo</th><th>Giro</th><th>Arrivo</th><th>km</th></tr></thead>
            <tbody>
              <tr v-for="p in percorso.punti" :key="p.idSpedizione" :class="{ scelta: tappaScelta === p.idSpedizione }" @click="evidenzia(p)">
                <td class="num">{{ p.sequenza ?? '' }}</td><td class="mono">{{ p.barcode }}</td><td>{{ p.destinatario }}</td>
                <td>{{ p.indirizzo }}<span class="nota"> {{ p.cap }} {{ p.localita }}</span></td><td class="nota">{{ p.giro }}</td>
                <td>{{ ora(p.arrivo) }}</td><td class="num">{{ p.kmProgressivi ?? '' }}</td>
              </tr>
              <tr v-if="percorso.ritorno" class="ritorno"><td></td><td colspan="4">Ritorno: {{ percorso.ritorno.indirizzo }}</td><td>{{ ora(percorso.ritorno.arrivo) }}</td><td class="num">{{ percorso.ritorno.kmProgressivi ?? '' }}</td></tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- destra: driver -->
      <div class="colonna destra">
        <div class="titolo-col">Driver <span class="conteggio">{{ driverOrdinati.length }}</span>
          <InputText v-model="filtroDriver" placeholder="cerca" size="small" class="cerca" /></div>
        <div class="lista">
          <div v-for="d in driverOrdinati" :key="d.idUtente" class="driver" :class="{ scelto: driverScelto === d.idUtente, vuoto: !d.nSped }"
            @click="scegliDriver(d)" @contextmenu.prevent="apriMenu($event, d)" @dragover.prevent @drop.prevent="e => rilascia(e, d)">
            <div class="riga">
              <b class="nome">{{ d.nome }}</b>
              <span v-if="d.partenzaCasa || d.ritornoCasa" class="nota casa" :title="`parte ${d.partenzaCasa ? 'da casa' : 'dalla filiale'}, torna ${d.ritornoCasa ? 'a casa' : 'in filiale'}`">⌂{{ d.partenzaCasa ? '→' : '' }}{{ d.ritornoCasa ? '←' : '' }}</span>
              <span class="spazio"></span>
              <b class="pezzi">{{ d.nSped }}</b>
            </div>
            <div v-if="d.giri.length" class="giri-driver">
              <span v-for="g in d.giri" :key="g.idGiro" class="giro-chip" :title="`${g.giro}: ${g.nSped} pezzi`">
                <span class="pallino" :style="{ background: g.colore || '#ccc' }"></span>{{ g.giro }} <b>{{ g.nSped }}</b>
                <button class="x" title="Togli il giro al driver" @click.stop="assegnaGiro(g, null)">×</button>
              </span>
            </div>
            <div class="riga stato">
              <template v-if="d.stato">
                <Tag :value="STATO[d.stato]?.nome ?? d.stato" :severity="STATO[d.stato]?.sev ?? 'secondary'" />
                <span v-if="d.stato === 'FATTA'" class="nota">{{ km(d.distanzaM) }} · {{ minuti(d.tempoS) }}</span>
                <span v-if="d.stato === 'FATTA' && (d.daRifare || d.nSequenza < d.nGeo)" class="attenzione" title="Giri, punti o opzioni cambiati dopo il percorso">da rifare</span>
                <i v-else-if="d.stato === 'RICHIESTA' || d.stato === 'IN_CORSO'" class="pi pi-spin pi-spinner nota"></i>
                <span v-if="d.stato === 'ERRORE'" class="attenzione piccolo" :title="d.errore">{{ d.errore }}</span>
              </template>
              <span v-else-if="d.nSped" class="nota">percorso da fare</span>
              <span class="spazio"></span>
              <Button icon="pi pi-directions" text rounded size="small" title="Ottimizza con HERE" :disabled="!d.nGeo || d.stato === 'RICHIESTA' || d.stato === 'IN_CORSO' || lavoro" @click.stop="ottimizza(d)" />
              <Button icon="pi pi-map" text rounded size="small" title="Vedi il percorso sulla mappa" :disabled="!d.idPianoDriver" @click.stop="apriPercorso(d)" />
              <Button icon="pi pi-print" text rounded size="small" title="Stampa percorso e lista" :disabled="d.stato !== 'FATTA'" @click.stop="apriStampa(d)" />
              <Button icon="pi pi-file-excel" text rounded size="small" title="Excel" :disabled="d.stato !== 'FATTA'" @click.stop="esporta(d)" />
            </div>
          </div>
        </div>
      </div>
    </div>

    <ContextMenu ref="menu" :model="voci" />

    <Dialog :visible="!!conferma" modal :header="conferma?.titolo" :style="{ width: '34rem' }" @update:visible="conferma = null">
      <p>{{ conferma?.testo }}</p>
      <template #footer>
        <Button label="Annulla" text @click="conferma = null" />
        <Button label="Conferma" @click="confermato" />
      </template>
    </Dialog>

    <Dialog :visible="!!casa" modal :header="casa ? `Casa di ${casa.driver.nome}` : ''" :style="{ width: '34rem' }" @update:visible="casa = null">
      <template v-if="casa">
        <p class="nota">Via, numero, CAP e comune: HERE trova le coordinate, che servono per partire o tornare da casa.</p>
        <InputText v-model="casa.indirizzo" fluid placeholder="es. Via Roma 10, 50018 Scandicci" @keyup.enter="salvaCasa" />
        <p v-if="casa.driver.casaLat" class="nota">Adesso: {{ casa.driver.casaLat.toFixed(5) }}, {{ casa.driver.casaLng.toFixed(5) }}</p>
      </template>
      <template #footer>
        <Button label="Annulla" text @click="casa = null" />
        <Button label="Cerca e salva" icon="pi pi-search" :loading="lavoro" @click="salvaCasa" />
      </template>
    </Dialog>

    <Dialog :visible="!!storico" modal :header="storico ? `Storico ${storico.driver.nome}` : ''" :style="{ width: '40rem' }" @update:visible="storico = null">
      <DataTable v-if="storico" :value="storico.righe" size="small" stripedRows>
        <Column header="Quando" style="width: 9rem"><template #body="{ data: r }">{{ dataOra(r.dataOra) }}</template></Column>
        <Column field="campo" header="Cosa" style="width: 8rem" />
        <Column header="Dettaglio"><template #body="{ data: r }">{{ [r.prima, r.dopo].filter(Boolean).join(' → ') }}</template></Column>
        <Column field="utente" header="Chi" style="width: 8rem" />
        <template #empty><span class="nota">Nessuna modifica registrata.</span></template>
      </DataTable>
    </Dialog>

    <Teleport to="body">
      <div v-if="stampa" class="stampa">
        <div class="stampa-barra no-print">
          <Button label="Stampa" icon="pi pi-print" @click="() => window.print()" />
          <Button label="Chiudi" text @click="chiudiStampa" />
        </div>
        <h2>Percorso di {{ stampa.piano.driver }} · {{ new Date(stampa.piano.data).toLocaleDateString('it-IT') }}</h2>
        <p>{{ stampa.piano.filiale }} · giri: {{ stampa.piano.giri.join(', ') }} · {{ stampa.punti.length }} consegne · {{ km(stampa.piano.distanzaM) }} · {{ minuti(stampa.piano.tempoS) }} con le soste ·
          parte {{ stampa.piano.partenzaCasa ? 'da casa' : 'dalla filiale' }}, torna {{ stampa.piano.ritornoCasa ? 'a casa' : 'in filiale' }}</p>
        <div ref="mapStampaEl" class="mappa-stampa"></div>
        <table class="tab-stampa">
          <thead><tr><th>#</th><th>Barcode</th><th>Destinatario</th><th>Indirizzo</th><th>Giro</th><th>Arrivo</th><th>km</th><th>Firma / note</th></tr></thead>
          <tbody>
            <tr><td></td><td colspan="3">Partenza: {{ stampa.partenza?.indirizzo }}</td><td></td><td>{{ ora(stampa.partenza?.partenza) }}</td><td></td><td></td></tr>
            <tr v-for="p in stampa.punti" :key="p.idSpedizione">
              <td class="num">{{ p.sequenza ?? '' }}</td><td class="mono">{{ p.barcode }}</td><td>{{ p.destinatario }}</td><td>{{ p.indirizzo }}, {{ p.cap }} {{ p.localita }}</td>
              <td>{{ p.giro }}</td><td>{{ ora(p.arrivo) }}</td><td class="num">{{ p.kmProgressivi ?? '' }}</td><td></td>
            </tr>
            <tr v-if="stampa.ritorno"><td></td><td colspan="3">Ritorno: {{ stampa.ritorno.indirizzo }}</td><td></td><td>{{ ora(stampa.ritorno.arrivo) }}</td><td class="num">{{ stampa.ritorno.kmProgressivi ?? '' }}</td><td></td></tr>
          </tbody>
        </table>
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: .5rem; height: calc(100vh - 7rem); min-height: 600px; }
.testata { display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
.testata h2 { margin: 0; }
.filiale { font-weight: 400; color: var(--p-text-muted-color); font-size: 1rem; margin-left: .5rem; }
.sotto { margin: .15rem 0 0; color: var(--p-text-muted-color); font-size: .85rem; max-width: 70rem; }
.barra { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.data { width: 9.5rem; }
.riepilogo { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.chip { border: 1px solid var(--p-surface-300); background: var(--p-surface-0); border-radius: 999px; padding: .2rem .7rem; font-size: .85rem; }
.chip.ok { color: #1a7a1a; border-color: #1a7a1a; }
.chip.attenzione { color: var(--p-orange-600); border-color: var(--p-orange-400); cursor: pointer; }
.nota { color: var(--p-text-muted-color); font-size: .85rem; }
.attenzione { color: var(--p-orange-600); font-size: .85rem; }
.piccolo { font-size: .78rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 12rem; }
.spazio { flex: 1; }
.mono { font-family: monospace; }
.pallino { display: inline-block; width: 11px; height: 11px; border-radius: 50%; border: 1px solid #999; margin-right: .35rem; flex: none; }

.lavagna { display: grid; grid-template-columns: 16rem 1fr 22rem; gap: .75rem; flex: 1; min-height: 0; }
.colonna { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
.sinistra, .destra { border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; }
.titolo-col { background: var(--p-surface-50); padding: .35rem .6rem; font-weight: 600; font-size: .9rem; border-bottom: 1px solid var(--p-surface-200); display: flex; align-items: center; gap: .4rem; }
.conteggio { font-weight: 400; color: var(--p-text-muted-color); }
.cerca { margin-left: auto; width: 8rem; }
.lista { overflow-y: auto; flex: 1; }
.giro { display: flex; align-items: center; gap: .35rem; padding: .3rem .5rem; border-bottom: 1px solid var(--p-surface-100); cursor: grab; font-size: .88rem; }
.giro:hover { background: var(--p-surface-50); }
.giro.scelto { background: #e3f2fd; }
.giro .nome { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.pezzi { min-width: 1.6rem; text-align: right; }
.driver { padding: .35rem .5rem; border-bottom: 1px solid var(--p-surface-100); cursor: pointer; font-size: .88rem; }
.driver:hover { background: var(--p-surface-50); }
.driver.scelto { background: #e3f2fd; outline: 2px solid #1565c0; outline-offset: -2px; }
.driver.vuoto { opacity: .6; }
.driver .riga { display: flex; align-items: center; gap: .4rem; }
.driver .nome { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.driver .casa { font-size: .95rem; }
.driver .stato { margin-top: .15rem; min-height: 1.9rem; }
.giri-driver { display: flex; flex-wrap: wrap; gap: .25rem; margin: .2rem 0; }
.giro-chip { display: inline-flex; align-items: center; gap: .15rem; border: 1px solid var(--p-surface-200); border-radius: 4px; padding: .05rem .35rem; font-size: .78rem; background: var(--p-surface-0); }
.giro-chip .x { border: none; background: none; color: #c62828; cursor: pointer; font-size: .95rem; line-height: 1; padding: 0 .1rem; }
.centro .strumenti { display: flex; align-items: center; gap: .5rem; min-height: 2.2rem; padding: 0 .2rem; flex-wrap: wrap; }
.mappa { flex: 1; min-height: 300px; border: 1px solid var(--p-surface-300); border-radius: 6px; z-index: 0; }
.tappe { max-height: 32%; overflow-y: auto; border: 1px solid var(--p-surface-200); border-radius: 6px; font-size: .82rem; margin-top: .35rem; }
.tappe table { width: 100%; border-collapse: collapse; }
.tappe th { text-align: left; padding: .25rem .4rem; background: var(--p-surface-50); position: sticky; top: 0; }
.tappe td { padding: .2rem .4rem; border-top: 1px solid var(--p-surface-100); cursor: pointer; }
.tappe .num { text-align: right; }
.tappe tr.scelta td { background: #e3f2fd; }
.tappe tr.ritorno td { color: var(--p-text-muted-color); font-style: italic; }
.vuoto { padding: .5rem; }
@media (max-width: 1200px) {
  .pagina { height: auto; }
  .lavagna { grid-template-columns: 1fr; }
  .sinistra, .destra { max-height: 22rem; }
  .mappa { height: 50vh; }
}
</style>

<style>
.sped-punto span { display: block; width: 12px; height: 12px; border-radius: 50%; border: 1px solid rgba(0,0,0,.45); box-sizing: border-box; }
.sped-punto.senza-giro span { border: 2px solid #c62828; }
.etichetta-driver span { display: inline-block; padding: .1rem .4rem; background: rgba(255,255,255,.85); border: 1px solid #555; border-radius: 4px; font-size: 11px; font-weight: 700; white-space: nowrap; transform: translate(-50%, -50%); }
.tappa span { display: flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 50%; color: #fff; font-weight: 700; font-size: 11px; border: 2px solid #fff; box-shadow: 0 1px 3px rgba(0,0,0,.45); }
.tappa-base span { display: flex; align-items: center; justify-content: center; width: 26px; height: 26px; border-radius: 6px; background: #333; color: #fff; font-size: 15px; border: 2px solid #fff; box-shadow: 0 1px 3px rgba(0,0,0,.45); }
.stampa { position: fixed; inset: 0; z-index: 2000; background: #fff; overflow: auto; padding: 1.2rem 1.5rem; font-size: 12px; color: #000; }
.stampa h2 { margin: 0 0 .2rem; font-size: 18px; }
.stampa p { margin: 0 0 .6rem; }
.stampa-barra { display: flex; gap: .5rem; justify-content: flex-end; margin-bottom: .5rem; }
.mappa-stampa { height: 52vh; border: 1px solid #999; margin-bottom: .6rem; }
.tab-stampa { width: 100%; border-collapse: collapse; }
.tab-stampa th, .tab-stampa td { border: 1px solid #bbb; padding: .2rem .35rem; text-align: left; vertical-align: top; }
.tab-stampa .num { text-align: right; }
.tab-stampa td:last-child { min-width: 7rem; }
@media print {
  body > *:not(.stampa) { display: none !important; }
  .stampa { position: static; padding: 0; overflow: visible; }
  .no-print { display: none !important; }
  .mappa-stampa { height: 120mm; }
  .tab-stampa tr { page-break-inside: avoid; }
}
</style>
