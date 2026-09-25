<script setup>
// Giri della filiale (ex videata legacy "Creazione giri su Mappa"): le aree di consegna dei driver.
// Sulla mappa (Leaflet, OSM o satellite) si vedono i giri esistenti, i confini dei comuni, le
// spedizioni geolocalizzate del giorno colorate per giro; un giro nuovo si disegna a mano (pin
// numerati, trascinabili, con i punti intermedi cliccabili) o si crea come unione di comuni; un giro
// esistente si modifica da qui (nome, colore, CAP e comune fissi, driver predefinito, attivo) e il
// suo confine si ritocca trascinando i vertici o si rifa' dai comuni. Ogni modifica resta nello storico.
// Confini che combaciano: "Allinea al giro vicino" sostituisce i tratti del confine in modifica che corrono entro N
// metri da quello di un giro visibile con il pezzo corrispondente del suo confine (vertici compresi, con anteprima);
// e un vertice rilasciato a pochi pixel dal confine di un giro o comune visibile ci si aggancia.
// Confine condiviso: i vertici del confine in modifica che coincidono (entro mezzo metro) con quelli di un giro visibile
// si spostano insieme nei due giri (anche aggiungendo o togliendo punti sul tratto comune); Salva salva il giro e i
// vicini cambiati in una transazione sola.
// Flag "Attivo" (interruttore nell'elenco e nell'editor, DataFine vuota in GEO_GIRI): qui si vedono
// tutti i giri, con il filtro; le pagine di assegnazione (Spedizioni del giorno, Piano della giornata)
// e le stored vedono solo quelli attivi. Disattivare toglie il giro dai piani di oggi e dei giorni dopo.
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import 'leaflet.markercluster/dist/MarkerCluster.css'
import 'leaflet.markercluster/dist/MarkerCluster.Default.css'
import 'leaflet.markercluster'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Checkbox from 'primevue/checkbox'
import ColorPicker from 'primevue/colorpicker'
import Select from 'primevue/select'
import Dialog from 'primevue/dialog'
import Tag from 'primevue/tag'
import ToggleSwitch from 'primevue/toggleswitch'
import SelectButton from 'primevue/selectbutton'
import Message from 'primevue/message'
import InputNumber from 'primevue/inputnumber'

const toast = useToast()
const errore = ref('')
const avviso = (severity, summary, detail, life = 4000) => toast.add({ severity, summary, detail, life })
const messaggio = e => e?.response?.data?.errore ?? e?.message ?? 'Errore'
const dataOra = v => v ? new Date(v).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' }) : ''
const MAX_VERTICI = 300      // oltre, il confine viene semplificato prima di poterlo trascinare

// --- mappa e livelli ---
let map = null, resizeObs = null
let comuniLayer, giriLayer, spedizioniCluster, anteprimaLayer, disegnoLayer, intermediLayer
const comuniDisegnati = new Map()   // idComune -> L.featureGroup
const giriDisegnati = new Map()     // idGiro   -> L.featureGroup
const anelliGiri = new Map()        // idGiro   -> [{ pts: [[lat,lng],...], bounds }]: per allineare e agganciare
const anelliComuni = new Map()      // idComune -> idem (solo aggancio)
let allineaLayer = null
const mapEl = ref(null)
const filiale = ref('')

// --- dati ---
const comuni = ref([])
const giri = ref([])
const driver = ref([])
const contatori = ref({ totale: 0, senzaGiro: 0 })
const comuniSel = ref([])
const giriSel = ref([])
const filtroComuni = ref('')
const filtroGiri = ref('')
const filtroStato = ref('tutti')      // tutti | attivi | nonattivi
const OPZIONI_STATO = [{ label: 'Tutti', value: 'tutti' }, { label: 'Attivi', value: 'attivi' }, { label: 'Non attivi', value: 'nonattivi' }]
const caricamento = ref(false)

const comuniFiltrati = computed(() => {
  const q = filtroComuni.value.trim().toLowerCase()
  return q ? comuni.value.filter(c => `${c.denominazione} ${c.cap} ${c.belfiore}`.toLowerCase().includes(q)) : comuni.value
})
const giriFiltrati = computed(() => {
  const q = filtroGiri.value.trim().toLowerCase()
  return giri.value
    .filter(g => filtroStato.value === 'tutti' || (filtroStato.value === 'attivi') === !!g.attivo)
    .filter(g => !q || `${g.giro} ${g.cap ?? ''} ${g.comune ?? ''} ${g.driverDefault ?? ''}`.toLowerCase().includes(q))
    // in ordine di nome, attivi e non attivi insieme: un giro spento resta dov'era (prima finiva in fondo
    // e sembrava sparito)
    .sort((a, b) => (a.giro ?? '').localeCompare(b.giro ?? '', 'it', { numeric: true, sensitivity: 'base' }))
})
const nAttivi = computed(() => giri.value.filter(g => g.attivo).length)

// --- spedizioni del giorno ---
const visualizza = ref(false)
const filtroGiro = ref(null)
const filtroCap = ref('')
let spedData = []   // [{lat,lng,...}] per l'anteprima punto-nel-poligono

// --- editor (nuovo giro o modifica di un giro esistente) ---
const modo = ref('nuovo')            // 'nuovo' | 'modifica'
const vuoto = () => ({ idGiro: null, giro: '', colore: 'F44F22', cap: '', belfiore: null, idDriverDefault: null, attivo: true })
const form = ref(vuoto())
const dettaglio = ref(null)          // scheda del giro in modifica (/giri/{id})
const attivoDisegno = ref(false)     // il clic sulla mappa aggiunge un vertice
const confineInModifica = ref(false) // i vertici del giro esistente sono sulla mappa, trascinabili
const semplificato = ref(null)       // { da, a } quando il confine e' stato ridotto per la modifica
const bordi = ref([])                // [{lat, lng, marker}]
const salvataggio = ref(false)
const nDentro = ref(0)
const coloreHex = computed(() => '#' + `${form.value.colore || 'F44F22'}`.replace('#', ''))
const nomeValido = computed(() => form.value.giro.trim().length > 3)
const puoCreare = computed(() => nomeValido.value && bordi.value.length >= 3)
const puoCreareDaComuni = computed(() => nomeValido.value && comuniSel.value.length > 0)
const puoSalvare = computed(() => nomeValido.value && (!confineInModifica.value || bordi.value.length >= 3))
const poligonoSemplice = computed(() => dettaglio.value?.tipoShape === 'Polygon' && Array.isArray(dettaglio.value?.anello))
const descrizioneArea = computed(() => {
  const d = dettaglio.value
  if (!d) return ''
  if (!d.tipoShape) return 'Giro senza area: disegna il confine o scegli i comuni'
  if (d.tipoShape === 'Polygon') return `Poligono di ${d.anello?.length ?? d.nPunti} punti`
  return `Area in ${d.nParti} parti (${d.nPunti} punti): il confine si rifa' dai comuni`
})

// --- conferme (niente ConfirmationService nell'app: un Dialog basta) ---
const conferma = ref(null)           // { titolo, testo, azione }
function chiedi(titolo, testo, azione) { conferma.value = { titolo, testo, azione } }
async function confermato() { const c = conferma.value; conferma.value = null; if (c) await c.azione() }

// --- WKT (POLYGON / MULTIPOLYGON / GEOMETRYCOLLECTION) -> anelli [[lat,lng],...] ---
function wktToRings(wkt) {
  if (!wkt) return []
  const rings = []
  const re = /\(([^()]+)\)/g
  let m
  while ((m = re.exec(wkt))) {
    const pts = m[1].split(',').map(s => {
      const [lng, lat] = s.trim().split(/\s+/).map(Number)
      return [lat, lng]
    }).filter(p => Number.isFinite(p[0]) && Number.isFinite(p[1]))
    if (pts.length >= 3) rings.push(pts)
  }
  return rings
}

onMounted(async () => {
  try {
    const { data: init } = await api.get('/giri/init')
    filiale.value = init.filiale ?? ''
    map = L.map(mapEl.value, { center: [init.lat, init.lng], zoom: 11 })
    const osm = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map)
    const satellite = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', { maxZoom: 19, attribution: 'Tiles © Esri' })
    L.control.layers({ Mappa: osm, Satellite: satellite }, null, { position: 'topright' }).addTo(map)
    comuniLayer = L.layerGroup().addTo(map)
    giriLayer = L.layerGroup().addTo(map)
    spedizioniCluster = L.markerClusterGroup({ chunkedLoading: true, maxClusterRadius: 40, disableClusteringAtZoom: 15 }).addTo(map)
    anteprimaLayer = L.layerGroup().addTo(map)
    disegnoLayer = L.layerGroup().addTo(map)
    intermediLayer = L.layerGroup().addTo(map)
    allineaLayer = L.layerGroup().addTo(map)
    map.on('click', onMapClick)
    resizeObs = new ResizeObserver(() => map && map.invalidateSize())
    resizeObs.observe(mapEl.value)
    setTimeout(() => map && map.invalidateSize(), 200)
    await carica()
  } catch (e) {
    errore.value = messaggio(e) || 'Errore nel caricamento della mappa'
  }
})
onBeforeUnmount(() => {
  if (resizeObs) { resizeObs.disconnect(); resizeObs = null }
  if (map) { map.remove(); map = null }
})

async function carica() {
  caricamento.value = true
  try {
    const [{ data: lk }, { data: g }] = await Promise.all([api.get('/giri/lookup'), api.get('/giri/elenco', { params: { tutti: true } })])
    comuni.value = lk.comuni; driver.value = lk.driver; contatori.value = lk.spedizioni
    giri.value = g
    if (visualizza.value) await aggiornaSpedizioni()
  } catch (e) { avviso('error', 'Giri', messaggio(e)) } finally { caricamento.value = false }
}
async function ricaricaGiri() {
  const { data } = await api.get('/giri/elenco', { params: { tutti: true } })
  giri.value = data
  // le righe selezionate (mostrate sulla mappa) seguono i dati nuovi
  const ids = new Set(giriSel.value.map(g => g.idGiro))
  giriSel.value = giri.value.filter(g => ids.has(g.idGiro))
}

// --- comuni: confini dallo SHAPE ---
async function toggleComuni() {
  const selIds = new Set(comuniSel.value.map(c => c.idComune))
  for (const [id, grp] of comuniDisegnati) {
    if (!selIds.has(id)) { comuniLayer.removeLayer(grp); comuniDisegnati.delete(id); anelliComuni.delete(id) }
  }
  for (const com of comuniSel.value) {
    if (comuniDisegnati.has(com.idComune)) continue
    try {
      const { data } = await api.get('/giri/shape', { params: { idComune: com.idComune } })
      const grp = disegnaShape(data.wkt, '#223344', 0.12, com.denominazione)
      if (grp) { comuniLayer.addLayer(grp); comuniDisegnati.set(com.idComune, grp); anelliComuni.set(com.idComune, anelli(data.wkt)) }
    } catch { /* comune senza geometria */ }
  }
}

// --- giri: area e perimetro dallo SHAPE ---
async function toggleGiri() {
  const selIds = new Set(giriSel.value.map(g => g.idGiro))
  for (const [id, grp] of giriDisegnati) {
    if (!selIds.has(id)) { giriLayer.removeLayer(grp); giriDisegnati.delete(id); anelliGiri.delete(id) }
  }
  for (const g of giriSel.value) {
    if (giriDisegnati.has(g.idGiro)) continue
    await disegnaGiro(g)
    const vic = viciniInModifica.get(g.idGiro)
    if (vic?.modificato) ridisegnaVicino(vic)
  }
  if (confineInModifica.value) collegaCondivisi()
}
async function disegnaGiro(g) {
  try {
    const { data } = await api.get('/giri/shape', { params: { idGiro: g.idGiro } })
    const grp = disegnaShape(data.wkt, g.colore || '#3388ff', g.attivo ? 0.25 : 0.12,
      `${g.giro}${g.attivo ? '' : ' · non attivo'}${g.nSped ? ' · ' + g.nSped + ' sped.' : ''}`, !g.attivo)
    if (grp) { giriLayer.addLayer(grp); giriDisegnati.set(g.idGiro, grp); anelliGiri.set(g.idGiro, anelli(data.wkt)) }
    return grp
  } catch { return null }
}
async function ridisegnaGiro(idGiro) {
  const grp = giriDisegnati.get(idGiro)
  if (grp) { giriLayer.removeLayer(grp); giriDisegnati.delete(idGiro); anelliGiri.delete(idGiro) }
  const g = giri.value.find(x => x.idGiro === idGiro)
  if (g && giriSel.value.some(x => x.idGiro === idGiro)) await disegnaGiro(g)
}
function disegnaShape(wkt, col, opacity, tooltip, tratteggio = false) {
  const rings = wktToRings(wkt)
  if (!rings.length) return null
  const grp = L.featureGroup()
  for (const ring of rings) {
    L.polygon(ring, { color: col, weight: 2, fillColor: col, fillOpacity: opacity, dashArray: tratteggio ? '6,6' : null })
      .bindTooltip(tooltip).on('click', onRefClick).addTo(grp)
  }
  return grp
}
function mostraTutti() { giriSel.value = [...giri.value]; toggleGiri() }
function nascondiTutti() { giriSel.value = []; toggleGiri() }
async function inquadra(g) {
  if (!giriSel.value.some(x => x.idGiro === g.idGiro)) { giriSel.value = [...giriSel.value, g]; await toggleGiri() }
  const grp = giriDisegnati.get(g.idGiro)
  if (grp && grp.getBounds().isValid()) map.fitBounds(grp.getBounds(), { padding: [20, 20] })
  else avviso('info', g.giro, 'Il giro non ha un\'area disegnata')
}

// --- spedizioni del giorno (cluster, colore del giro; grigie quelle senza giro) ---
async function aggiornaSpedizioni() {
  spedizioniCluster.clearLayers()
  spedData = []
  if (!visualizza.value) { anteprimaLayer.clearLayers(); nDentro.value = 0; return }
  try {
    const { data: sped } = await api.get('/giri/spedizioni', {
      params: { idGiro: filtroGiro.value ?? undefined, cap: filtroCap.value?.length === 5 ? filtroCap.value : undefined }
    })
    const markers = []
    for (const s of sped) {
      if (s.lat == null || s.lng == null) continue
      spedData.push(s)
      const col = s.idGiro ? ((s.colore && `${s.colore}`.trim()) || '#e53935') : '#8d8d8d'
      markers.push(L.marker([s.lat, s.lng], { icon: dotIcon(col, !s.idGiro) })
        .bindTooltip(`<b>${s.barcode ?? ''}</b><br>${s.indirizzo ?? ''}<br>${s.cap ?? ''} ${s.localita ?? ''}<br>${s.giro ? 'Giro: ' + s.giro : '<i>senza giro</i>'}`))
    }
    spedizioniCluster.addLayers(markers)
    if (!sped.length) avviso('info', 'Spedizioni', 'Nessuna spedizione geolocalizzata da mostrare', 2500)
    aggiornaAnteprima()
  } catch (e) { avviso('error', 'Spedizioni', messaggio(e)) }
}
function dotIcon(col, senzaGiro) {
  return L.divIcon({ className: 'sped-dot' + (senzaGiro ? ' senza-giro' : ''), html: `<span style="background:${col}"></span>`, iconSize: [12, 12], iconAnchor: [6, 6] })
}

// --- anteprima: le spedizioni che cadono nel confine in disegno/modifica ---
function puntoInPoligono(lat, lng, ring) {
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const yi = ring[i][0], xi = ring[i][1], yj = ring[j][0], xj = ring[j][1]
    if (((yi > lat) !== (yj > lat)) && (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)) inside = !inside
  }
  return inside
}
function aggiornaAnteprima() {
  anteprimaLayer.clearLayers()
  nDentro.value = 0
  if (bordi.value.length < 3 || !spedData.length) return
  const ring = bordi.value.map(v => [v.lat, v.lng])
  let n = 0
  for (const s of spedData) {
    if (puntoInPoligono(s.lat, s.lng, ring)) {
      n++
      L.circleMarker([s.lat, s.lng], { radius: 7, color: '#1a7a1a', weight: 2, fill: false }).addTo(anteprimaLayer)
    }
  }
  nDentro.value = n
}

// --- vertici sulla mappa: pin numerati trascinabili, punti intermedi per aggiungerne, tasto destro per togliere ---
function iconaNum(n, condiviso = false) {
  return L.divIcon({ className: 'vertice-num' + (condiviso ? ' condiviso' : ''), html: `<span style="background:${coloreHex.value}">${n}</span>`, iconSize: [24, 24], iconAnchor: [12, 12] })
}
function onMapClick(e) { if (attivoDisegno.value) aggiungiVertice(e.latlng.lat, e.latlng.lng) }
function onRefClick(e) {
  if (!attivoDisegno.value) return
  aggiungiVertice(e.latlng.lat, e.latlng.lng)
  L.DomEvent.stopPropagation(e)
}
function creaMarker(v, n) {
  const marker = L.marker([v.lat, v.lng], { draggable: true, icon: iconaNum(n) })
  marker.on('drag', ev => { const ll = ev.target.getLatLng(); v.lat = ll.lat; v.lng = ll.lng; seguiVicini(v); ridisegnaBozza(false) })
  marker.on('dragend', () => {
    agganciaVertice(v); seguiVicini(v); collegaCondivisi()
    ridisegnaBozza(true); aggiornaAnteprima(); if (vicino.value) calcolaAllineamento()
  })
  marker.on('contextmenu', ev => { L.DomEvent.stopPropagation(ev); rimuoviVertice(v) })
  marker.bindTooltip('trascina per spostare, tasto destro per togliere', { direction: 'top', offset: [0, -10] })
  v.marker = marker
  disegnoLayer.addLayer(marker)
  return marker
}
function aggiungiVertice(lat, lng, posizione = null) {
  const v = { lat, lng, marker: null }
  if (posizione === null || posizione >= bordi.value.length) bordi.value.push(v)
  else bordi.value.splice(posizione, 0, v)
  creaMarker(v, bordi.value.indexOf(v) + 1)
  refreshNumeri(); ridisegnaBozza(true); aggiornaAnteprima()
}
let bozzaPoly = null
function ridisegnaBozza(conIntermedi) {
  if (bozzaPoly) { disegnoLayer.removeLayer(bozzaPoly); bozzaPoly = null }
  if (bordi.value.length >= 2) {
    bozzaPoly = L.polygon(bordi.value.map(v => [v.lat, v.lng]), {
      color: coloreHex.value, weight: 2, fillColor: coloreHex.value, fillOpacity: 0.2, dashArray: '5,5'
    })
    disegnoLayer.addLayer(bozzaPoly)
  }
  if (conIntermedi) ridisegnaIntermedi()
}
// i punti a meta' di ogni lato: un clic li trasforma in un vertice vero
function ridisegnaIntermedi() {
  intermediLayer.clearLayers()
  const n = bordi.value.length
  if (n < 2) return
  for (let i = 0; i < n; i++) {
    if (n === 2 && i === 1) break
    const a = bordi.value[i], b = bordi.value[(i + 1) % n]
    const m = L.marker([(a.lat + b.lat) / 2, (a.lng + b.lng) / 2], {
      icon: L.divIcon({ className: 'vertice-mezzo', html: '<span>+</span>', iconSize: [16, 16], iconAnchor: [8, 8] }),
      keyboard: false, zIndexOffset: -100
    }).bindTooltip('clic per aggiungere un punto qui', { direction: 'top', offset: [0, -8] })
    m.on('click', ev => {
      L.DomEvent.stopPropagation(ev)
      inserisciNeiVicini(a, b, ev.latlng.lat, ev.latlng.lng)
      aggiungiVertice(ev.latlng.lat, ev.latlng.lng, i + 1)
      collegaCondivisi()
    })
    intermediLayer.addLayer(m)
  }
}
function refreshNumeri() { bordi.value.forEach((v, i) => v.marker && v.marker.setIcon(iconaNum(i + 1, !!v.condivisi?.length))) }
function sposta(i, dir) {
  const j = i + dir
  if (j < 0 || j >= bordi.value.length) return
  const arr = [...bordi.value]
  ;[arr[i], arr[j]] = [arr[j], arr[i]]
  bordi.value = arr
  refreshNumeri(); ridisegnaBozza(true); aggiornaAnteprima()
}
function rimuoviVertice(v) {
  for (const { vic, p } of v.condivisi ?? []) {
    if (vic.pts.length > 3) { vic.pts = vic.pts.filter(x => x !== p); vic.modificato = true; ridisegnaVicino(vic) }
  }
  if (v.marker) disegnoLayer.removeLayer(v.marker)
  bordi.value = bordi.value.filter(x => x !== v)
  refreshNumeri(); ridisegnaBozza(true); aggiornaAnteprima()
}
function svuotaDisegno() {
  bordi.value.forEach(v => v.marker && disegnoLayer.removeLayer(v.marker))
  bordi.value = []
  intermediLayer.clearLayers()
  ridisegnaBozza(false); aggiornaAnteprima()
}
function centraSuVertice(v) { map.panTo([v.lat, v.lng]) }

// --- confini che combaciano: aggancio dei vertici e allineamento al giro vicino ---
// anelli di una geometria WKT senza il punto di chiusura ripetuto, con il loro riquadro
function anelli(wkt) {
  return wktToRings(wkt).map(r => {
    const pts = r.length > 1 && r[0][0] === r[r.length - 1][0] && r[0][1] === r[r.length - 1][1] ? r.slice(0, -1) : r
    return { pts, bounds: L.latLngBounds(pts) }
  })
}
const aggancio = ref(true)            // un vertice rilasciato vicino al confine di un giro/comune visibile ci si attacca
const SOGLIA_AGGANCIO = 14            // pixel
function agganciaVertice(v) {
  if (!aggancio.value || !map) return
  const pv = map.latLngToLayerPoint([v.lat, v.lng])
  const intorno = L.latLngBounds(map.layerPointToLatLng(pv.subtract([SOGLIA_AGGANCIO, SOGLIA_AGGANCIO])),
    map.layerPointToLatLng(pv.add([SOGLIA_AGGANCIO, SOGLIA_AGGANCIO])))
  let vertice = null, lato = null
  const legati = new Set((v.condivisi ?? []).map(c => c.vic.idGiro))
  const candidati = [...[...anelliGiri.keys()].filter(id => id !== form.value.idGiro && !legati.has(id)).map(anelliDi), ...anelliComuni.values()].flat()
  for (const { pts, bounds } of candidati) {
    if (!bounds.intersects(intorno)) continue
    const px = pts.map(p => map.latLngToLayerPoint(p))
    for (let i = 0; i < px.length; i++) {
      const d = pv.distanceTo(px[i])
      if (d <= SOGLIA_AGGANCIO && (!vertice || d < vertice.d)) vertice = { d, ll: pts[i] }
      const a = px[i], b = px[(i + 1) % px.length]
      const dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
      const t = l2 ? Math.max(0, Math.min(1, ((pv.x - a.x) * dx + (pv.y - a.y) * dy) / l2)) : 0
      const q = L.point(a.x + t * dx, a.y + t * dy)
      const dq = pv.distanceTo(q)
      if (dq <= SOGLIA_AGGANCIO && (!lato || dq < lato.d)) lato = { d: dq, q }
    }
  }
  // un vertice del confine vicino vince sul punto a meta' lato: cosi' i due confini hanno gli stessi punti
  const ll = vertice ? L.latLng(vertice.ll[0], vertice.ll[1]) : lato ? map.layerPointToLatLng(lato.q) : null
  if (!ll) return
  v.lat = ll.lat; v.lng = ll.lng
  v.marker && v.marker.setLatLng(ll)
}

// allineamento: i tratti del confine in modifica entro "tolleranza" metri dal confine del giro vicino diventano il
// pezzo corrispondente di quel confine (i suoi vertici fra le proiezioni del primo e dell'ultimo punto del tratto)
const vicino = ref(null)
const tolleranzaAllinea = ref(50)
const allineamento = ref(null)        // { anello, tratti, sostituiti, aggiunti } oppure { messaggio }
const viciniPossibili = computed(() => {
  void bordi.value.length
  return giriSel.value.filter(g => g.idGiro !== form.value.idGiro && anelliGiri.has(g.idGiro))
    .map(g => ({ idGiro: g.idGiro, etichetta: `${g.giro}${puntiVicini(g.idGiro) ? ` (${puntiVicini(g.idGiro)} punti vicini)` : ''}`, n: puntiVicini(g.idGiro) }))
    .sort((a, b) => b.n - a.n || a.etichetta.localeCompare(b.etichetta, 'it', { numeric: true }))
})
function metrico(lat0) {
  const kx = 111320 * Math.cos(lat0 * Math.PI / 180), ky = 110540
  return { xy: p => [p[1] * kx, p[0] * ky], ll: q => [q[1] / ky, q[0] / kx] }
}
function proiezioni(PX, RX) {
  // per ogni punto: il punto piu' vicino dell'anello RX (chiuso), con la sua ascissa lungo l'anello
  const cum = [0]
  for (let i = 0; i < RX.length; i++) { const a = RX[i], b = RX[(i + 1) % RX.length]; cum.push(cum[i] + Math.hypot(b[0] - a[0], b[1] - a[1])) }
  const proj = PX.map(p => {
    let best = null
    for (let i = 0; i < RX.length; i++) {
      const a = RX[i], b = RX[(i + 1) % RX.length]
      const dx = b[0] - a[0], dy = b[1] - a[1], l2 = dx * dx + dy * dy
      const t = l2 ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2)) : 0
      const x = a[0] + t * dx, y = a[1] + t * dy
      const d = Math.hypot(p[0] - x, p[1] - y)
      if (!best || d < best.d) best = { d, xy: [x, y], s: cum[i] + t * Math.sqrt(l2) }
    }
    return best
  })
  return { proj, cum, L: cum[RX.length] }
}
function puntiVicini(idGiro) {
  const rings = anelliDi(idGiro)
  if (!rings || bordi.value.length < 3) return 0
  const m = metrico(bordi.value[0].lat)
  const PX = bordi.value.map(v => m.xy([v.lat, v.lng]))
  let n = 0
  for (const r of rings) {
    const RX = r.pts.map(m.xy)
    n = Math.max(n, proiezioni(PX, RX).proj.filter(p => p.d <= tolleranzaAllinea.value).length)
  }
  return n
}
function calcolaAllineamento() {
  allineaLayer && allineaLayer.clearLayers()
  allineamento.value = null
  const rings = anelliDi(vicino.value)
  if (!rings || bordi.value.length < 3) return
  const tol = tolleranzaAllinea.value || 50
  const P = bordi.value.map(v => [v.lat, v.lng])
  const m = metrico(P[0][0])
  const PX = P.map(m.xy)
  let mig = null
  for (const r of rings) {
    const RX = r.pts.map(m.xy)
    const pr = proiezioni(PX, RX)
    const n = pr.proj.filter(p => p.d <= tol).length
    if (!mig || n > mig.n) mig = { R: r.pts, RX, ...pr, n }
  }
  if (!mig || !mig.n) { allineamento.value = { messaggio: `Nessun punto del confine entro ${tol} m da quello del giro scelto` }; return }
  if (mig.n === P.length) { allineamento.value = { messaggio: 'Tutto il confine e\' vicino a quello del giro scelto: abbassa la distanza' }; return }
  const vic = mig.proj.map(p => p.d <= tol)
  const inizio = vic.findIndex(x => !x)
  const ordine = P.map((_, k) => (inizio + k) % P.length)
  const fra = (s0, lunghezza, avanti) => mig.RX.map((_, k) => k)
    .map(k => ({ k, o: avanti ? (mig.cum[k] - s0 + mig.L) % mig.L : (s0 - mig.cum[k] + mig.L) % mig.L }))
    .filter(x => x.o > 0.01 && x.o < lunghezza - 0.01).sort((a, b) => a.o - b.o).map(x => mig.R[x.k])
  const nuovo = [], cambiati = []
  let tratti = 0, sostituiti = 0, aggiunti = 0
  for (let k = 0; k < ordine.length;) {
    const i = ordine[k]
    if (!vic[i]) { nuovo.push(P[i]); k++; continue }
    let j = k
    while (j + 1 < ordine.length && vic[ordine[j + 1]]) j++
    const run = ordine.slice(k, j + 1)
    const p0 = mig.proj[run[0]], p1 = mig.proj[run[run.length - 1]]
    let tratto
    if (run.length === 1) tratto = [m.ll(p0.xy)]
    else {
      let lung = 0
      for (let q = 0; q + 1 < run.length; q++) lung += Math.hypot(PX[run[q + 1]][0] - PX[run[q]][0], PX[run[q + 1]][1] - PX[run[q]][1])
      const avanti = (p1.s - p0.s + mig.L) % mig.L, indietro = mig.L - avanti
      const versoAvanti = Math.abs(avanti - lung) <= Math.abs(indietro - lung)
      tratto = [m.ll(p0.xy), ...fra(p0.s, versoAvanti ? avanti : indietro, versoAvanti), m.ll(p1.xy)]
    }
    tratti++; sostituiti += run.length; aggiunti += tratto.length
    nuovo.push(...tratto); cambiati.push(tratto)
    k = j + 1
  }
  // niente punti doppi (meno di mezzo metro dal precedente)
  const anello = nuovo.filter((p, i) => {
    const q = nuovo[(i - 1 + nuovo.length) % nuovo.length]
    const a = m.xy(p), b = m.xy(q)
    return i === 0 || Math.hypot(a[0] - b[0], a[1] - b[1]) > 0.5
  })
  allineamento.value = { anello, tratti, sostituiti, aggiunti }
  L.polygon(anello, { color: '#111', weight: 2, dashArray: '4,4', fill: false }).addTo(allineaLayer)
  for (const t of cambiati) L.polyline(t, { color: '#00c853', weight: 6, opacity: 0.75 }).addTo(allineaLayer)
}
function applicaAllineamento() {
  const a = allineamento.value
  if (!a?.anello) return
  const nome = giri.value.find(g => g.idGiro === vicino.value)?.giro ?? ''
  svuotaDisegno()
  for (const [lat, lng] of a.anello) bordi.value.push({ lat, lng, marker: null })
  bordi.value.forEach((v, i) => creaMarker(v, i + 1))
  collegaCondivisi()
  ridisegnaBozza(true); aggiornaAnteprima()
  allineaLayer.clearLayers(); allineamento.value = null; vicino.value = null
  avviso('success', 'Confine', `Allineato a ${nome}: ${a.tratti} ${a.tratti === 1 ? 'tratto' : 'tratti'}. Controlla e salva.`)
}
function annullaAllineamento() { allineaLayer && allineaLayer.clearLayers(); allineamento.value = null; vicino.value = null }

// --- confine condiviso: i vertici in comune con i giri visibili si spostano nei due giri ---
const confineCondiviso = ref(true)
const viciniInModifica = new Map()    // idGiro -> { idGiro, giro, pts: [{lat, lng}], modificato }
const statoCondivisi = ref({ punti: 0, giri: [], modificati: [] })
// gli anelli di un giro: quello aggiornato se lo si sta spostando insieme, altrimenti quello del database
function anelliDi(idGiro) {
  const vic = viciniInModifica.get(idGiro)
  if (vic?.modificato) { const pts = vic.pts.map(q => [q.lat, q.lng]); return [{ pts, bounds: L.latLngBounds(pts) }] }
  return anelliGiri.get(idGiro) ?? []
}
function collegaCondivisi() {
  for (const v of bordi.value) v.condivisi = []
  if (confineCondiviso.value && bordi.value.length >= 3 && map) {
    const m = metrico(bordi.value[0].lat)
    const vicino05 = (a, b) => { const x = m.xy(a), y = m.xy(b); return Math.hypot(x[0] - y[0], x[1] - y[1]) <= 0.5 }
    for (const [idGiro, rings] of anelliGiri) {
      if (idGiro === form.value.idGiro || rings.length !== 1) continue      // solo giri a un anello (niente buchi o piu' parti)
      let vic = viciniInModifica.get(idGiro)
      if (!vic) {
        vic = { idGiro, giro: giri.value.find(x => x.idGiro === idGiro)?.giro ?? String(idGiro), pts: rings[0].pts.map(([lat, lng]) => ({ lat, lng })), modificato: false }
        viciniInModifica.set(idGiro, vic)
      }
      const riquadro = L.latLngBounds(vic.pts.map(q => [q.lat, q.lng])).pad(0.02)
      for (const v of bordi.value) {
        if (!riquadro.contains([v.lat, v.lng])) continue
        const p = vic.pts.find(q => vicino05([q.lat, q.lng], [v.lat, v.lng]))
        if (p) v.condivisi.push({ vic, p })
      }
      // gli estremi di un tratto comune stanno spesso a meta' di un lato del vicino (es. dopo l'allineamento):
      // il lato si spezza li', cosi' il tratto ha gli stessi vertici nei due giri
      const n = bordi.value.length
      bordi.value.forEach((v, i) => {
        if (v.condivisi.some(c => c.vic === vic)) return
        const accanto = [bordi.value[(i - 1 + n) % n], bordi.value[(i + 1) % n]].some(w => w.condivisi.some(c => c.vic === vic))
        if (!accanto) return
        const q = m.xy([v.lat, v.lng])
        for (let k = 0; k < vic.pts.length; k++) {
          const a = m.xy([vic.pts[k].lat, vic.pts[k].lng]), b = m.xy([vic.pts[(k + 1) % vic.pts.length].lat, vic.pts[(k + 1) % vic.pts.length].lng])
          const dx = b[0] - a[0], dy = b[1] - a[1], l2 = dx * dx + dy * dy
          const t = l2 ? ((q[0] - a[0]) * dx + (q[1] - a[1]) * dy) / l2 : -1
          if (t <= 0 || t >= 1 || Math.hypot(q[0] - (a[0] + t * dx), q[1] - (a[1] + t * dy)) > 0.5) continue
          const nuovo = { lat: v.lat, lng: v.lng }
          vic.pts.splice(k + 1, 0, nuovo)
          v.condivisi.push({ vic, p: nuovo })
          break
        }
      })
    }
  }
  const legati = new Set(bordi.value.flatMap(v => (v.condivisi ?? []).map(c => c.vic.idGiro)))
  statoCondivisi.value = {
    punti: bordi.value.filter(v => v.condivisi?.length).length,
    giri: [...viciniInModifica.values()].filter(x => legati.has(x.idGiro)).map(x => x.giro),
    modificati: [...viciniInModifica.values()].filter(x => x.modificato).map(x => x.giro),
  }
  refreshNumeri()
}
function seguiVicini(v) {
  if (!v.condivisi?.length) return
  for (const { vic, p } of v.condivisi) {
    p.lat = v.lat; p.lng = v.lng
    if (!vic.modificato) { vic.modificato = true; statoCondivisi.value = { ...statoCondivisi.value, modificati: [...statoCondivisi.value.modificati, vic.giro] } }
    ridisegnaVicino(vic)
  }
}
// un punto aggiunto a meta' di un lato comune va anche nel vicino, fra i due vertici corrispondenti
function inserisciNeiVicini(a, b, lat, lng) {
  for (const ca of a.condivisi ?? []) {
    const cb = (b.condivisi ?? []).find(c => c.vic === ca.vic)
    if (!cb) continue
    const pts = ca.vic.pts, ia = pts.indexOf(ca.p), ib = pts.indexOf(cb.p), n = pts.length
    if (ia < 0 || ib < 0) continue
    if ((ia + 1) % n === ib) pts.splice(ia + 1, 0, { lat, lng })
    else if ((ib + 1) % n === ia) pts.splice(ib + 1, 0, { lat, lng })
    else continue
    ca.vic.modificato = true
    ridisegnaVicino(ca.vic)
  }
}
function ridisegnaVicino(vic) {
  const grp = giriDisegnati.get(vic.idGiro)
  if (!grp) return
  grp.eachLayer(l => { if (l.setLatLngs) { l.setLatLngs(vic.pts.map(q => [q.lat, q.lng])); l.setStyle({ dashArray: '4,4', weight: 3 }) } })
}
function scartaVicini() {
  const modificati = [...viciniInModifica.values()].filter(x => x.modificato).map(x => x.idGiro)
  viciniInModifica.clear()
  statoCondivisi.value = { punti: 0, giri: [], modificati: [] }
  return modificati
}

// --- semplificazione (Douglas-Peucker) per i confini con troppi punti ---
function semplifica(punti, tol) {
  if (punti.length <= 2) return punti
  const dist = (p, a, b) => {
    const k = Math.cos(a[0] * Math.PI / 180)
    const x = p[1] * k, y = p[0], x1 = a[1] * k, y1 = a[0], x2 = b[1] * k, y2 = b[0]
    const dx = x2 - x1, dy = y2 - y1
    if (dx === 0 && dy === 0) return Math.hypot(x - x1, y - y1)
    const t = Math.max(0, Math.min(1, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)))
    return Math.hypot(x - (x1 + t * dx), y - (y1 + t * dy))
  }
  const keep = new Array(punti.length).fill(false)
  keep[0] = keep[punti.length - 1] = true
  const stack = [[0, punti.length - 1]]
  while (stack.length) {
    const [i, j] = stack.pop()
    let max = 0, idx = -1
    for (let k = i + 1; k < j; k++) { const d = dist(punti[k], punti[i], punti[j]); if (d > max) { max = d; idx = k } }
    if (max > tol && idx > 0) { keep[idx] = true; stack.push([i, idx], [idx, j]) }
  }
  return punti.filter((_, i) => keep[i])
}
function riduci(punti, massimo) {
  let tol = 0.00005, out = punti
  while (out.length > massimo && tol < 0.05) { out = semplifica(punti, tol); tol *= 1.6 }
  return out
}

// --- editor: nuovo / modifica ---
function nuovoGiro() {
  chiudiConfine()
  modo.value = 'nuovo'; dettaglio.value = null; form.value = vuoto(); semplificato.value = null
}
async function apriModifica(g) {
  try {
    chiudiConfine()
    const { data } = await api.get(`/giri/${g.idGiro}`)
    dettaglio.value = data
    modo.value = 'modifica'
    form.value = {
      idGiro: data.idGiro, giro: data.giro ?? '', colore: `${data.colore || '#3388ff'}`.replace('#', ''),
      cap: data.cap ?? '', belfiore: data.belfiore ?? null, idDriverDefault: data.idDriverDefault ?? null, attivo: !!data.attivo
    }
    semplificato.value = null
    await inquadra(g)
  } catch (e) { avviso('error', 'Giro', messaggio(e)) }
}
// il confine del giro in modifica diventa una bozza trascinabile (l'area originale resta sotto, sbiadita)
function modificaConfine() {
  const d = dettaglio.value
  if (!d?.anello?.length) return
  svuotaDisegno()
  let punti = d.anello.map(p => [p.lat, p.lng])
  if (punti.length > MAX_VERTICI) {
    const ridotti = riduci(punti, MAX_VERTICI)
    semplificato.value = { da: punti.length, a: ridotti.length }
    punti = ridotti
  } else semplificato.value = null
  for (const [lat, lng] of punti) bordi.value.push({ lat, lng, marker: null })
  bordi.value.forEach((v, i) => creaMarker(v, i + 1))
  const grp = giriDisegnati.get(d.idGiro)
  if (grp) grp.setStyle({ fillOpacity: 0.05, dashArray: '2,6' })
  confineInModifica.value = true
  collegaCondivisi()
  ridisegnaBozza(true); aggiornaAnteprima()
}
function chiudiConfine() {
  annullaAllineamento()
  // i vicini spostati e non salvati tornano come sono nel database
  for (const id of scartaVicini()) ridisegnaGiro(id)
  svuotaDisegno()
  attivoDisegno.value = false
  if (confineInModifica.value && dettaglio.value) {
    const grp = giriDisegnati.get(dettaglio.value.idGiro)
    if (grp) grp.setStyle({ fillOpacity: dettaglio.value.attivo ? 0.25 : 0.12, dashArray: dettaglio.value.attivo ? null : '6,6' })
  }
  confineInModifica.value = false
  semplificato.value = null
}

const corpoForm = () => ({
  giro: form.value.giro.trim(), colore: coloreHex.value, cap: form.value.cap?.trim() || null,
  belfiore: form.value.belfiore || null, idDriverDefault: form.value.idDriverDefault ?? null
})
async function creaGiro() {
  salvataggio.value = true
  try {
    const { data } = await api.post('/giri', { nome: form.value.giro.trim(), ...corpoForm(), vertici: bordi.value.map(v => ({ lat: v.lat, lng: v.lng })) })
    avviso('success', 'Giro creato', `${form.value.giro} (Id ${data.idGiro})`)
    await dopoCreazione(data.idGiro)
  } catch (e) { avviso('error', 'Creazione giro', messaggio(e), 5000) } finally { salvataggio.value = false }
}
async function creaGiroDaComuni() {
  salvataggio.value = true
  try {
    const { data } = await api.post('/giri/da-comuni', { nome: form.value.giro.trim(), ...corpoForm(), idComuni: comuniSel.value.map(c => c.idComune) })
    avviso('success', 'Giro da comuni', `${form.value.giro} (${comuniSel.value.length} comuni, Id ${data.idGiro})`)
    await dopoCreazione(data.idGiro)
  } catch (e) { avviso('error', 'Giro da comuni', messaggio(e), 5000) } finally { salvataggio.value = false }
}
async function dopoCreazione(idGiro) {
  svuotaDisegno(); attivoDisegno.value = false
  form.value = vuoto()
  await ricaricaGiri()
  const g = giri.value.find(x => x.idGiro === idGiro)
  if (g) { giriSel.value = [...giriSel.value, g]; await toggleGiri() }
}
async function salvaModifica() {
  salvataggio.value = true
  try {
    const corpo = { ...corpoForm(), attivo: form.value.attivo }
    if (confineInModifica.value) corpo.vertici = bordi.value.map(v => ({ lat: v.lat, lng: v.lng }))
    const vicini = confineInModifica.value ? [...viciniInModifica.values()].filter(x => x.modificato) : []
    if (vicini.length) corpo.vicini = vicini.map(x => ({ idGiro: x.idGiro, vertici: x.pts.map(q => ({ lat: q.lat, lng: q.lng })) }))
    await api.put(`/giri/${form.value.idGiro}`, corpo)
    avviso('success', 'Giro salvato', form.value.giro + (vicini.length ? ` e il confine di ${vicini.map(x => x.giro).join(', ')}` : ''))
    const id = form.value.idGiro
    chiudiConfine()
    await ricaricaGiri()
    await ridisegnaGiro(id)
    const g = giri.value.find(x => x.idGiro === id)
    if (g) await apriModifica(g); else nuovoGiro()
    if (visualizza.value) await aggiornaSpedizioni()
  } catch (e) { avviso('error', 'Salvataggio', messaggio(e), 5000) } finally { salvataggio.value = false }
}
async function sostituisciDaComuni() {
  if (!comuniSel.value.length) { avviso('warn', 'Comuni', 'Seleziona i comuni nell\'elenco in basso'); return }
  salvataggio.value = true
  try {
    await api.post(`/giri/${form.value.idGiro}/da-comuni`, { idComuni: comuniSel.value.map(c => c.idComune) })
    avviso('success', 'Confine rifatto', `${form.value.giro}: unione di ${comuniSel.value.length} comuni`)
    const id = form.value.idGiro
    chiudiConfine()
    await ricaricaGiri()
    await ridisegnaGiro(id)
    const g = giri.value.find(x => x.idGiro === id)
    if (g) await apriModifica(g)
  } catch (e) { avviso('error', 'Confine', messaggio(e), 5000) } finally { salvataggio.value = false }
}
// flag Attivo dall'elenco: attivare e' immediato, disattivare chiede conferma (il giro esce dalle
// pagine di assegnazione e dai piani di oggi e dei giorni dopo)
const testoDisattiva = g => `Il giro "${g.giro}" non sara' piu' assegnabile: sparisce dalle pagine di assegnazione ` +
  `(Spedizioni del giorno, Piano della giornata) e non riceve spedizioni. Se e' nel piano di oggi o dei prossimi giorni, ` +
  `viene tolto al driver.` + (g.nSped ? ` Le ${g.nSped} spedizioni di oggi restano sul giro finche' non le riassegni con "Aggiorna giri di sped".` : '') +
  ` Si riattiva quando vuoi.`
function cambiaAttivo(g, attivo) {
  if (attivo) return salvaAttivo(g, true)
  chiedi('Disattiva giro', testoDisattiva(g), () => salvaAttivo(g, false))
}
async function salvaAttivo(g, attivo) {
  try {
    const { data } = await api.put(`/giri/${g.idGiro}/attivo`, { attivo })
    avviso('success', attivo ? 'Giro attivo' : 'Giro non attivo',
      g.giro + (data.toltoDaiPiani ? ` · tolto dal piano di ${data.toltoDaiPiani} ${data.toltoDaiPiani === 1 ? 'giorno' : 'giorni'}` : ''))
    await ricaricaGiri()
    await ridisegnaGiro(g.idGiro)
    if (form.value.idGiro === g.idGiro) form.value.attivo = attivo
    if (dettaglio.value?.idGiro === g.idGiro) dettaglio.value.attivo = attivo
  } catch (e) { avviso('error', 'Giro', messaggio(e), 5000) }
}

// --- assegnazione delle spedizioni del giorno ai giri ---
const assegnazione = ref(false)
function chiediAssegnazione() {
  if (giriSel.value.length) return assegna({ idGiri: giriSel.value.map(g => g.idGiro) })
  chiedi('Aggiorna giri di sped', `Nessun giro selezionato: le spedizioni geolocalizzate di oggi della filiale (${contatori.value.totale}) vengono riassegnate a tutti i giri per CAP, comune e area. Procedo?`,
    () => assegna({ tutti: true }))
}
async function assegna(corpo) {
  assegnazione.value = true
  try {
    const { data } = await api.post('/giri/assegna', corpo)
    contatori.value = data.spedizioni
    avviso('success', 'Giri', `Giri aggiornati alle spedizioni: ${data.spedizioni.totale} geolocalizzate, ${data.spedizioni.senzaGiro} senza giro`)
    await ricaricaGiri()
    if (visualizza.value) await aggiornaSpedizioni()
  } catch (e) { avviso('error', 'Giri', messaggio(e)) } finally { assegnazione.value = false }
}
const etichettaCampo = { Giro: 'nome', Colore: 'colore', CAP: 'CAP fisso', Belfiore: 'comune fisso', IdDriverDefault: 'driver predefinito', Attivo: 'attivo', SHAPE: 'confine' }
</script>

<template>
  <div class="pagina">
    <div class="testata">
      <div>
        <h2>Giri <span class="filiale">{{ filiale }}</span></h2>
        <p class="sotto">Le aree di consegna dei driver: si disegnano, si creano dai comuni, si modificano; le spedizioni del giorno prendono il giro dal CAP o dal comune fisso, altrimenti dall'area.</p>
      </div>
      <div class="barra">
        <Button label="Aggiorna giri di sped" icon="pi pi-sync" size="small" outlined :loading="assegnazione"
          :title="giriSel.length ? `Riassegna le spedizioni di oggi ai ${giriSel.length} giri selezionati` : 'Riassegna le spedizioni di oggi a tutti i giri'" @click="chiediAssegnazione" />
        <Button icon="pi pi-refresh" text :loading="caricamento" title="Ricarica" @click="carica" />
      </div>
    </div>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="controlli">
      <label class="chk"><Checkbox v-model="visualizza" binary @change="aggiornaSpedizioni" /> Spedizioni di oggi
        <span class="nota">{{ contatori.totale }} geolocalizzate<template v-if="contatori.senzaGiro">, {{ contatori.senzaGiro }} senza giro</template></span></label>
      <label>Punti del giro
        <Select v-model="filtroGiro" :options="[{ idGiro: null, giro: '— tutti —' }, { idGiro: 0, giro: '— senza giro —' }, ...giri]" optionLabel="giro" optionValue="idGiro"
          size="small" class="sel-giro" @change="visualizza && aggiornaSpedizioni()" />
      </label>
      <label>CAP <InputText v-model="filtroCap" maxlength="5" size="small" class="cap" @update:modelValue="visualizza && aggiornaSpedizioni()" /></label>
      <span class="spazio"></span>
      <label>Giri <SelectButton v-model="filtroStato" :options="OPZIONI_STATO" optionLabel="label" optionValue="value" :allowEmpty="false" size="small" /></label>
    </div>

    <div class="corpo">
      <div ref="mapEl" class="mappa"></div>

      <aside class="pannello">
        <div class="pannello-titolo">
          <span v-if="modo === 'nuovo'">Nuovo giro</span>
          <span v-else>Modifica giro <span class="conteggio">Id {{ form.idGiro }}</span></span>
          <Button v-if="modo === 'modifica'" icon="pi pi-plus" text rounded size="small" class="chiaro" title="Nuovo giro" @click="nuovoGiro" />
        </div>
        <div class="form">
          <label>Nome</label>
          <InputText v-model="form.giro" maxlength="50" fluid size="small" />
          <div class="due">
            <div>
              <label>Colore</label>
              <div class="colore"><ColorPicker v-model="form.colore" @update:modelValue="ridisegnaBozza(true); refreshNumeri()" /> <span class="nota">{{ coloreHex }}</span></div>
            </div>
            <div>
              <label>CAP fisso</label>
              <InputText v-model="form.cap" maxlength="5" fluid size="small" placeholder="es. 50018" />
            </div>
          </div>
          <label>Comune fisso</label>
          <Select v-model="form.belfiore" :options="comuni" optionLabel="denominazione" optionValue="belfiore" filter showClear size="small" placeholder="nessuno" fluid />
          <label>Driver predefinito</label>
          <Select v-model="form.idDriverDefault" :options="driver" optionLabel="nome" optionValue="idUtente" filter showClear size="small" placeholder="nessuno" fluid />
          <small class="hint">CAP e comune fissi vincono sull'area: tutte le spedizioni con quel CAP o comune vanno a questo giro.</small>

          <!-- nuovo giro: disegno a mano o unione di comuni -->
          <template v-if="modo === 'nuovo'">
            <hr />
            <label class="chk"><Checkbox v-model="attivoDisegno" binary /> Disegna a mano (clic sulla mappa)</label>
            <Button label="Crea nuovo giro" icon="pi pi-check" size="small" :disabled="!puoCreare" :loading="salvataggio" @click="creaGiro" />
            <Button label="Crea da comuni selezionati" icon="pi pi-clone" severity="help" size="small" :disabled="!puoCreareDaComuni" :loading="salvataggio" @click="creaGiroDaComuni" />
            <small class="hint">{{ comuniSel.length }} comuni selezionati in basso</small>
          </template>

          <!-- giro esistente: confine, salvataggio, chiusura -->
          <template v-else>
            <hr />
            <div class="nota">{{ descrizioneArea }}</div>
            <div v-if="semplificato" class="attenzione">Confine semplificato da {{ semplificato.da }} a {{ semplificato.a }} punti per poterlo modificare.</div>
            <template v-if="!confineInModifica">
              <Button v-if="poligonoSemplice" label="Modifica confine" icon="pi pi-pencil" size="small" outlined @click="modificaConfine" />
              <Button v-else-if="!dettaglio?.tipoShape" label="Disegna il confine" icon="pi pi-pencil" size="small" outlined @click="confineInModifica = true; attivoDisegno = true" />
            </template>
            <template v-else>
              <label class="chk"><Checkbox v-model="attivoDisegno" binary /> Aggiungi punti col clic sulla mappa</label>
              <label class="chk" title="Un punto rilasciato a pochi pixel dal confine di un giro o comune visibile ci si attacca">
                <Checkbox v-model="aggancio" binary /> Aggancia ai confini visibili</label>
              <label class="chk" title="I punti in comune con un giro visibile (bordo doppio) si spostano anche nel vicino; Salva salva tutti e due">
                <Checkbox v-model="confineCondiviso" binary @change="collegaCondivisi" /> Sposta insieme il confine dei giri vicini</label>
              <small v-if="confineCondiviso && statoCondivisi.punti" class="hint">
                {{ statoCondivisi.punti }} punti in comune con {{ statoCondivisi.giri.join(', ') }} (bordo doppio)</small>
              <small v-if="statoCondivisi.modificati.length" class="attenzione">
                Salva salvera' anche il confine di {{ statoCondivisi.modificati.join(', ') }}</small>
              <div class="allinea">
                <label>Allinea al giro vicino</label>
                <div class="riga-allinea">
                  <Select v-model="vicino" :options="viciniPossibili" optionLabel="etichetta" optionValue="idGiro" size="small"
                    placeholder="giro visibile sulla mappa" showClear class="vicino" @change="calcolaAllineamento" />
                  <InputNumber v-model="tolleranzaAllinea" :min="5" :max="500" suffix=" m" size="small" inputClass="tolleranza"
                    title="Distanza massima dal confine del giro vicino" @update:modelValue="calcolaAllineamento" />
                </div>
                <small v-if="!viciniPossibili.length" class="hint">Spunta nell'elenco in basso il giro vicino per vederlo sulla mappa.</small>
                <small v-else-if="allineamento?.messaggio" class="attenzione">{{ allineamento.messaggio }}</small>
                <template v-else-if="allineamento">
                  <small class="hint">{{ allineamento.tratti }} {{ allineamento.tratti === 1 ? 'tratto' : 'tratti' }} (in verde):
                    {{ allineamento.sostituiti }} punti sostituiti da {{ allineamento.aggiunti }} del confine vicino</small>
                  <div class="riga-allinea">
                    <Button label="Applica" icon="pi pi-check" size="small" severity="success" @click="applicaAllineamento" />
                    <Button label="Annulla" size="small" text @click="annullaAllineamento" />
                  </div>
                </template>
              </div>
              <Button label="Annulla modifica confine" icon="pi pi-undo" size="small" text @click="chiudiConfine" />
            </template>
            <Button label="Sostituisci con i comuni selezionati" icon="pi pi-clone" severity="help" size="small" :disabled="!comuniSel.length" :loading="salvataggio" @click="sostituisciDaComuni" />
            <Button label="Salva" icon="pi pi-check" size="small" :disabled="!puoSalvare" :loading="salvataggio" @click="salvaModifica" />
            <label class="chk attivo-form" :title="form.attivo ? '' : 'Non attivo: non compare nelle pagine di assegnazione'">
              <ToggleSwitch v-model="form.attivo" /> {{ form.attivo ? 'Attivo' : 'Non attivo' }}
            </label>
          </template>
          <small v-if="nDentro" class="anteprima">≈ {{ nDentro }} spedizioni di oggi in quest'area</small>
        </div>

        <template v-if="bordi.length || modo === 'nuovo' || confineInModifica">
          <div class="pannello-titolo">
            Bordi <span class="conteggio">{{ bordi.length }} punti</span>
            <Button icon="pi pi-trash" text rounded size="small" class="chiaro" title="Svuota" :disabled="!bordi.length" @click="svuotaDisegno" />
          </div>
          <div class="bordi">
            <div v-for="(v, i) in bordi" :key="i" class="bordo">
              <span class="num" :style="{ background: coloreHex }">{{ i + 1 }}</span>
              <span class="coord" title="centra" @click="centraSuVertice(v)">{{ v.lat.toFixed(5) }}, {{ v.lng.toFixed(5) }}</span>
              <span class="azioni">
                <Button icon="pi pi-arrow-up" text rounded size="small" :disabled="i === 0" @click="sposta(i, -1)" />
                <Button icon="pi pi-arrow-down" text rounded size="small" :disabled="i === bordi.length - 1" @click="sposta(i, 1)" />
                <Button icon="pi pi-times" text rounded size="small" severity="danger" @click="rimuoviVertice(v)" />
              </span>
            </div>
            <p v-if="!bordi.length" class="vuoto">Attiva il disegno e clicca sulla mappa (i pin si trascinano, il + a metà lato aggiunge un punto, il tasto destro lo toglie), oppure crea il giro dai comuni.</p>
          </div>
        </template>

        <template v-if="modo === 'modifica' && dettaglio?.variazioni?.length">
          <div class="pannello-titolo">Ultime modifiche</div>
          <div class="variazioni">
            <div v-for="(v, i) in dettaglio.variazioni" :key="i" class="variazione">
              <span class="quando">{{ dataOra(v.dataOra) }}</span> <b>{{ etichettaCampo[v.campo] ?? v.campo }}</b>
              <template v-if="v.campo !== 'SHAPE'">: {{ v.prima ?? '—' }} → {{ v.dopo ?? '—' }}</template>
              <span v-if="v.utente" class="nota"> · {{ v.utente }}</span>
            </div>
          </div>
        </template>
      </aside>
    </div>

    <div class="tabelle">
      <div class="tab">
        <div class="tab-titolo">Comuni della filiale ({{ comuni.length }})
          <InputText v-model="filtroComuni" placeholder="cerca" size="small" class="cerca" /></div>
        <DataTable :value="comuniFiltrati" v-model:selection="comuniSel" dataKey="idComune"
          selectionMode="multiple" :metaKeySelection="false"
          @update:selection="toggleComuni" scrollable scrollHeight="240px" size="small" stripedRows>
          <Column selectionMode="multiple" style="width: 3rem" />
          <Column field="denominazione" header="Comune" />
          <Column field="belfiore" header="Belfiore" style="width: 6rem" />
          <Column field="cap" header="CAP" style="width: 5rem" />
        </DataTable>
      </div>
      <div class="tab">
        <div class="tab-titolo">Giri ({{ nAttivi }} attivi su {{ giri.length }})
          <span class="tab-azioni">
            <InputText v-model="filtroGiri" placeholder="cerca" size="small" class="cerca" />
            <Button label="Tutti" size="small" text @click="mostraTutti" title="Mostra tutti i giri sulla mappa" />
            <Button label="Nessuno" size="small" text @click="nascondiTutti" title="Togli tutti i giri dalla mappa" />
          </span>
        </div>
        <div v-if="giri.length > nAttivi" class="aiuto-attivi">
          {{ giri.length - nAttivi }} {{ giri.length - nAttivi === 1 ? 'giro non attivo' : 'giri non attivi' }}: restano qui
          (tratteggiati sulla mappa) e si riattivano con l'interruttore "Attivo"; nelle pagine di assegnazione non compaiono.
        </div>
        <DataTable :value="giriFiltrati" v-model:selection="giriSel" dataKey="idGiro"
          selectionMode="multiple" :metaKeySelection="false" :rowClass="d => [d.idGiro === form.idGiro ? 'riga-in-modifica' : '', d.attivo ? '' : 'riga-spenta']"
          @update:selection="toggleGiri" scrollable scrollHeight="240px" size="small" stripedRows>
          <Column selectionMode="multiple" style="width: 3rem" />
          <Column header="" style="width: 2.2rem">
            <template #body="{ data }"><span class="pallino" :style="{ background: data.colore || '#ccc' }" /></template>
          </Column>
          <Column header="Attivo" style="width: 4.5rem" headerClass="col-attivo">
            <template #body="{ data }">
              <span @click.stop><ToggleSwitch :modelValue="!!data.attivo" @update:modelValue="v => cambiaAttivo(data, v)" /></span>
            </template>
          </Column>
          <Column field="giro" header="Giro">
            <template #body="{ data }"><span :class="{ 'giro-spento': !data.attivo }">{{ data.giro }}</span> <Tag v-if="!data.attivo" value="non attivo" severity="secondary" /></template>
          </Column>
          <Column field="cap" header="CAP" style="width: 4.5rem" />
          <Column field="comune" header="Comune fisso" style="width: 9rem" />
          <Column field="driverDefault" header="Driver" style="width: 11rem" />
          <Column field="nSped" header="Sped. oggi" style="width: 5.5rem" class="num-col" />
          <Column header="" style="width: 5.5rem">
            <template #body="{ data }">
              <Button icon="pi pi-search" text rounded size="small" title="Inquadra sulla mappa" @click="inquadra(data)" />
              <Button icon="pi pi-pencil" text rounded size="small" title="Modifica" @click="apriModifica(data)" />
            </template>
          </Column>
        </DataTable>
      </div>
    </div>

    <Dialog :visible="!!conferma" modal :header="conferma?.titolo" :style="{ width: '32rem' }" @update:visible="conferma = null">
      <p>{{ conferma?.testo }}</p>
      <template #footer>
        <Button label="Annulla" text @click="conferma = null" />
        <Button label="Conferma" @click="confermato" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: .5rem; }
.testata { display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
.testata h2 { margin: 0; }
.filiale { font-weight: 400; color: var(--p-text-muted-color); font-size: 1rem; margin-left: .5rem; }
.sotto { margin: .15rem 0 0; color: var(--p-text-muted-color); font-size: .9rem; }
.barra { display: flex; align-items: center; gap: .5rem; }
.controlli { display: flex; align-items: center; gap: 1.25rem; flex-wrap: wrap; font-size: .9rem; }
.chk { display: inline-flex; align-items: center; gap: .4rem; cursor: pointer; }
.attivo-form { font-size: .85rem; }
.giro-spento { color: #9aa4ad; }
.aiuto-attivi { font-size: .78rem; color: #6b7785; padding: .3rem .75rem; background: var(--p-surface-50); border-bottom: 1px solid var(--p-surface-200); }
:deep(.riga-spenta) > td { background: repeating-linear-gradient(135deg, transparent 0 6px, rgba(0, 0, 0, .025) 6px 12px); }
.nota { color: var(--p-text-muted-color); font-size: .85rem; }
.attenzione { color: var(--p-orange-600); font-size: .85rem; }
.sel-giro { width: 15rem; margin-left: .3rem; }
.cap { width: 6rem; margin-left: .3rem; }
.spazio { flex: 1; }

.corpo { display: flex; gap: 1rem; align-items: stretch; }
.mappa { flex: 1; height: 62vh; min-height: 440px; border: 1px solid var(--p-surface-300); border-radius: 6px; z-index: 0; }
.pannello { flex: 0 0 320px; border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; display: flex; flex-direction: column; max-height: 62vh; }
.pannello-titolo { background: #00a5cf; color: #fff; padding: .35rem .75rem; font-weight: 600; font-size: .9rem; display: flex; align-items: center; justify-content: space-between; gap: .5rem; }
.pannello-titolo .chiaro { color: #fff; }
.conteggio { font-weight: 400; opacity: .9; font-size: .8rem; }
.form { display: flex; flex-direction: column; gap: .4rem; padding: .6rem .75rem; overflow-y: auto; }
.form > label, .form .due label { font-size: .8rem; color: #555; }
.form hr { width: 100%; border: none; border-top: 1px solid var(--p-surface-200); margin: .2rem 0; }
.due { display: grid; grid-template-columns: 1fr 1fr; gap: .5rem; }
.colore { display: flex; align-items: center; gap: .5rem; }
.hint { color: #888; font-size: .75rem; }
.anteprima { color: #1a7a1a; font-weight: 600; font-size: .8rem; }
.bordi { padding: .4rem .75rem; overflow-y: auto; min-height: 3rem; max-height: 24vh; }
.bordo { display: flex; align-items: center; gap: .4rem; font-size: .78rem; }
.bordo .num { flex: 0 0 1.4rem; height: 1.4rem; line-height: 1.4rem; text-align: center; color: #fff; border-radius: 50%; font-weight: 700; }
.bordo .coord { flex: 1; font-family: monospace; cursor: pointer; }
.bordo .azioni { display: flex; }
.vuoto { color: #888; font-size: .85rem; }
.variazioni { padding: .4rem .75rem; overflow-y: auto; max-height: 20vh; font-size: .78rem; }
.variazione { padding: .1rem 0; border-bottom: 1px dotted var(--p-surface-200); }
.variazione .quando { color: var(--p-text-muted-color); }

.tabelle { display: grid; grid-template-columns: 1fr 1.4fr; gap: 1rem; margin-top: .5rem; }
.tab { border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; }
.tab-titolo { background: var(--p-surface-50); padding: .3rem .75rem; font-weight: 600; font-size: .9rem; border-bottom: 1px solid var(--p-surface-200); display: flex; align-items: center; justify-content: space-between; gap: .5rem; }
.tab-azioni { display: flex; align-items: center; gap: .25rem; }
.cerca { width: 10rem; }
.pallino { display: inline-block; width: 14px; height: 14px; border-radius: 50%; border: 1px solid #999; }
:deep(.num-col) { text-align: right; }
:deep(.riga-in-modifica) { outline: 2px solid #00a5cf; outline-offset: -2px; }
@media (max-width: 1100px) {
  .corpo { flex-direction: column; }
  .pannello { flex: none; max-height: none; }
  .tabelle { grid-template-columns: 1fr; }
}
.allinea { display: flex; flex-direction: column; gap: .3rem; border: 1px dashed var(--p-surface-300); border-radius: 6px; padding: .4rem .5rem; }
.allinea > label { font-size: .8rem; font-weight: 600; color: #555; }
.riga-allinea { display: flex; align-items: center; gap: .4rem; }
.vicino { flex: 1; min-width: 0; }
:deep(.tolleranza) { width: 4.6rem; padding: .3rem .4rem; }
</style>

<style>
/* pin dei vertici e punti intermedi (icone globali, fuori da scoped) */
.vertice-num span {
  display: flex; align-items: center; justify-content: center;
  width: 24px; height: 24px; border-radius: 50%;
  color: #fff; font-weight: 700; font-size: 12px;
  border: 2px solid #fff; box-shadow: 0 1px 3px rgba(0,0,0,.4);
}
.vertice-mezzo span {
  display: flex; align-items: center; justify-content: center;
  width: 16px; height: 16px; border-radius: 50%;
  background: rgba(255,255,255,.85); color: #333; font-weight: 700; font-size: 12px; line-height: 1;
  border: 1px solid #666; cursor: pointer;
}
.sped-dot span {
  display: block; width: 12px; height: 12px; border-radius: 50%;
  border: 1px solid rgba(0,0,0,.4);
}
.sped-dot.senza-giro span { border: 2px solid #c62828; width: 10px; height: 10px; }
.vertice-num.condiviso span { box-shadow: 0 0 0 2px #fff, 0 0 0 4px #111; }
</style>
