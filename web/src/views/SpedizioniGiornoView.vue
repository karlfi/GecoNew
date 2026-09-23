<script setup>
// Spedizioni del giorno: le spedizioni caricate in un giorno per la filiale, sulla mappa e in griglia,
// con il giro assegnato. Da qui si verifica e si corregge l'assegnazione ai giri: automatica (CAP fisso,
// comune fisso, poi l'area del giro), a mano su una selezione (dalla griglia o con un'area disegnata
// sulla mappa), e si sistema il punto di consegna sbagliato o mancante trascinandolo o mettendolo sulla
// mappa. Sostituisce le videate legacy "Giri - Assegnazione" e "Giri - Modifica punti".
import { ref, computed, onMounted, onBeforeUnmount, watch, nextTick } from 'vue'
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
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
import Checkbox from 'primevue/checkbox'
import Dialog from 'primevue/dialog'
import Tag from 'primevue/tag'
import Message from 'primevue/message'

const toast = useToast()
const errore = ref('')
const avviso = (severity, summary, detail, life = 4000) => toast.add({ severity, summary, detail, life })
const messaggio = e => e?.response?.data?.errore ?? e?.message ?? 'Errore'
const dataOra = v => v ? new Date(v).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' }) : ''
const GRIGIO = '#8d8d8d'

// --- dati ---
const filiale = ref('')
const geoAttiva = ref(true)
const data = ref(new Date())
const spedizioni = ref([])
const giri = ref([])
const caricamento = ref(false)
const dataIso = computed(() => {
  const d = data.value instanceof Date ? data.value : new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
})

// --- filtri e selezione ---
const idCliente = ref(null)
const filtroStato = ref('tutte')      // tutte | conGiro | senzaGiro | senzaCoordinate
const filtroGiro = ref(null)
const filtroTesto = ref('')
const selezionate = ref([])           // righe scelte nella griglia
const idSel = computed(() => new Set(selezionate.value.map(s => s.idSpedizione)))
const STATI = [
  { valore: 'tutte', nome: 'tutte' }, { valore: 'conGiro', nome: 'con giro' },
  { valore: 'senzaGiro', nome: 'senza giro' }, { valore: 'senzaCoordinate', nome: 'senza coordinate' },
]

const clienti = computed(() => {
  const m = new Map()
  for (const s of spedizioni.value) {
    const c = m.get(s.idCliente) ?? { idCliente: s.idCliente, nome: s.cliente ?? `cliente ${s.idCliente}`, n: 0 }
    c.n++; m.set(s.idCliente, c)
  }
  return [...m.values()].sort((a, b) => b.n - a.n).map(c => ({ ...c, etichetta: `${c.nome} (${c.n})` }))
})
const delCliente = computed(() => idCliente.value == null ? spedizioni.value : spedizioni.value.filter(s => s.idCliente === idCliente.value))
const riepilogo = computed(() => {
  const r = { totale: 0, conGiro: 0, senzaGiro: 0, senzaCoordinate: 0 }
  for (const s of delCliente.value) {
    r.totale++
    if (s.lat == null) r.senzaCoordinate++
    if (s.idGiro) r.conGiro++; else r.senzaGiro++
  }
  return r
})
const conteggiGiro = computed(() => {
  const m = new Map()
  for (const s of delCliente.value) if (s.idGiro) m.set(s.idGiro, (m.get(s.idGiro) ?? 0) + 1)
  return m
})
const giriConConteggio = computed(() => giri.value.map(g => ({ ...g, n: conteggiGiro.value.get(g.idGiro) ?? 0 })))
const visibili = computed(() => {
  const q = filtroTesto.value.trim().toLowerCase()
  return delCliente.value.filter(s => {
    if (filtroStato.value === 'conGiro' && !s.idGiro) return false
    if (filtroStato.value === 'senzaGiro' && s.idGiro) return false
    if (filtroStato.value === 'senzaCoordinate' && s.lat != null) return false
    if (filtroGiro.value != null && s.idGiro !== filtroGiro.value) return false
    if (q && !`${s.barcode} ${s.destinatario ?? ''} ${s.indirizzo ?? ''} ${s.cap ?? ''} ${s.localita ?? ''} ${s.giro ?? ''}`.toLowerCase().includes(q)) return false
    return true
  })
})
const senzaCoordinateVisibili = computed(() => visibili.value.filter(s => s.lat == null).length)
watch(visibili, () => disegnaPunti())
watch(idSel, () => aggiornaStilePunti())

// --- mappa ---
let map = null, resizeObs = null
let cluster, areeLayer, lassoLayer, spostaLayer
const markers = new Map()             // idSpedizione -> L.marker
const mapEl = ref(null)
const mostraAree = ref(false)
let areeCaricate = false

onMounted(async () => {
  try {
    map = L.map(mapEl.value, { center: [43.84, 11.11], zoom: 10 })
    const osm = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map)
    const satellite = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', { maxZoom: 19, attribution: 'Tiles © Esri' })
    L.control.layers({ Mappa: osm, Satellite: satellite }, null, { position: 'topright' }).addTo(map)
    areeLayer = L.layerGroup().addTo(map)
    cluster = L.markerClusterGroup({ chunkedLoading: true, maxClusterRadius: 35, disableClusteringAtZoom: 14 }).addTo(map)
    lassoLayer = L.layerGroup().addTo(map)
    spostaLayer = L.layerGroup().addTo(map)
    map.on('click', onMapClick)
    resizeObs = new ResizeObserver(() => map && map.invalidateSize())
    resizeObs.observe(mapEl.value)
    setTimeout(() => map && map.invalidateSize(), 200)
    await carica(true)
  } catch (e) { errore.value = messaggio(e) }
})
onBeforeUnmount(() => {
  if (resizeObs) { resizeObs.disconnect(); resizeObs = null }
  if (map) { map.remove(); map = null }
})

async function carica(inquadra = false) {
  caricamento.value = true
  try {
    const { data: d } = await api.get('/sped-giri', { params: { data: dataIso.value } })
    filiale.value = d.filiale ?? ''
    geoAttiva.value = !!d.geoAttiva
    spedizioni.value = d.spedizioni
    giri.value = d.giri
    selezionate.value = []
    annullaLasso(); annullaSpostamento()
    if (idCliente.value != null && !clienti.value.some(c => c.idCliente === idCliente.value)) idCliente.value = null
    await nextTick()
    disegnaPunti()
    if (inquadra) {
      const b = cluster.getBounds()
      if (b.isValid()) map.fitBounds(b, { padding: [20, 20] })
      else if (d.lat && d.lng) map.setView([d.lat, d.lng], 11)
    }
  } catch (e) { avviso('error', 'Spedizioni', messaggio(e)) } finally { caricamento.value = false }
}

// --- punti sulla mappa: colore del giro, grigio senza giro, anello per le selezionate ---
function icona(s) {
  const col = s.idGiro ? ((s.colore && `${s.colore}`.trim()) || '#e53935') : GRIGIO
  const cls = 'sped-punto' + (s.idGiro ? '' : ' senza-giro') + (idSel.value.has(s.idSpedizione) ? ' scelta' : '')
  return L.divIcon({ className: cls, html: `<span style="background:${col}"></span>`, iconSize: [14, 14], iconAnchor: [7, 7] })
}
function tooltip(s) {
  return `<b>${s.barcode ?? ''}</b> ${s.destinatario ?? ''}<br>${s.indirizzo ?? ''} ${s.civico ?? ''}<br>${s.cap ?? ''} ${s.localita ?? ''}<br>${s.giro ? 'Giro: ' + s.giro : '<i>senza giro</i>'}${s.sequenza ? ' · seq. ' + s.sequenza : ''}`
}
function disegnaPunti() {
  if (!cluster) return
  cluster.clearLayers(); markers.clear()
  const ms = []
  for (const s of visibili.value) {
    if (s.lat == null || s.lng == null) continue
    const m = L.marker([s.lat, s.lng], { icon: icona(s) }).bindTooltip(tooltip(s))
    m.on('click', ev => { L.DomEvent.stopPropagation(ev); if (!lassoAttivo.value) togglaSelezione(s) })
    markers.set(s.idSpedizione, m)
    ms.push(m)
  }
  cluster.addLayers(ms)
}
function aggiornaStilePunti() {
  for (const s of visibili.value) {
    const m = markers.get(s.idSpedizione)
    if (m) m.setIcon(icona(s))
  }
}
function aggiornaPunto(s) {
  const m = markers.get(s.idSpedizione)
  if (m) { m.setIcon(icona(s)); m.setTooltipContent(tooltip(s)); if (s.lat != null) m.setLatLng([s.lat, s.lng]) }
  else if (s.lat != null) disegnaPunti()
}
function togglaSelezione(s) {
  selezionate.value = idSel.value.has(s.idSpedizione) ? selezionate.value.filter(x => x.idSpedizione !== s.idSpedizione) : [...selezionate.value, s]
}
function centra(s) {
  if (s.lat == null) { avviso('info', s.barcode, 'Questa spedizione non ha coordinate: usa "Metti sulla mappa"'); return }
  map.setView([s.lat, s.lng], Math.max(map.getZoom(), 15))
  const m = markers.get(s.idSpedizione)
  if (m) setTimeout(() => m.openTooltip(), 300)
}
function inquadraTutte() { const b = cluster.getBounds(); if (b.isValid()) map.fitBounds(b, { padding: [20, 20] }) }

// --- aree dei giri come sfondo ---
async function toggleAree() {
  areeLayer.clearLayers()
  if (!mostraAree.value) return
  try {
    const { data: shapes } = await api.get('/giri/shapes')
    for (const g of shapes) {
      for (const ring of wktToRings(g.wkt))
        L.polygon(ring, { color: g.colore || '#3388ff', weight: 1.5, fillColor: g.colore || '#3388ff', fillOpacity: 0.08, interactive: false }).bindTooltip(g.giro).addTo(areeLayer)
    }
    areeCaricate = true
  } catch (e) { avviso('error', 'Aree dei giri', messaggio(e)) }
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

// --- selezione con un'area disegnata sulla mappa ---
const lassoAttivo = ref(false)
const lasso = ref([])                 // [[lat,lng],...]
let lassoPoly = null
function iniziaLasso() { lassoAttivo.value = true; lasso.value = []; ridisegnaLasso() }
function onMapClick(e) {
  if (spostamento.value && spostamento.value.lat == null) { mettiPunto(e.latlng.lat, e.latlng.lng); return }
  if (!lassoAttivo.value) return
  lasso.value.push([e.latlng.lat, e.latlng.lng])
  ridisegnaLasso()
}
function ridisegnaLasso() {
  lassoLayer.clearLayers(); lassoPoly = null
  for (const p of lasso.value) L.circleMarker(p, { radius: 4, color: '#1565c0', fillOpacity: 1 }).addTo(lassoLayer)
  if (lasso.value.length >= 2) lassoPoly = L.polygon(lasso.value, { color: '#1565c0', weight: 2, dashArray: '5,5', fillOpacity: 0.1 }).addTo(lassoLayer)
}
const nelLasso = computed(() => lasso.value.length >= 3 ? visibili.value.filter(s => s.lat != null && puntoInPoligono(s.lat, s.lng, lasso.value)).length : 0)
function puntoInPoligono(lat, lng, ring) {
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const yi = ring[i][0], xi = ring[i][1], yj = ring[j][0], xj = ring[j][1]
    if (((yi > lat) !== (yj > lat)) && (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)) inside = !inside
  }
  return inside
}
function applicaLasso() {
  if (lasso.value.length < 3) { avviso('warn', 'Selezione', 'Clicca almeno 3 punti sulla mappa per chiudere l\'area'); return }
  const dentro = visibili.value.filter(s => s.lat != null && puntoInPoligono(s.lat, s.lng, lasso.value))
  const gia = idSel.value
  selezionate.value = [...selezionate.value, ...dentro.filter(s => !gia.has(s.idSpedizione))]
  avviso('info', 'Selezione', `${dentro.length} spedizioni nell'area, ${selezionate.value.length} selezionate in tutto`, 3000)
  annullaLasso()
}
function annullaLasso() { lassoAttivo.value = false; lasso.value = []; if (lassoLayer) lassoLayer.clearLayers() }

// --- assegnazione ---
const giroScelto = ref(null)
const lavoro = ref(false)
const conferma = ref(null)            // { titolo, testo, azione }
function chiedi(titolo, testo, azione) { conferma.value = { titolo, testo, azione } }
async function confermato() { const c = conferma.value; conferma.value = null; if (c) await c.azione() }

async function assegnaSelezionate(idGiro) {
  if (!selezionate.value.length) { avviso('warn', 'Assegnazione', 'Seleziona le spedizioni nella griglia o con un\'area sulla mappa'); return }
  if (idGiro == null && giroScelto.value == null) { avviso('warn', 'Assegnazione', 'Scegli il giro'); return }
  const giro = idGiro === null ? null : giri.value.find(g => g.idGiro === (idGiro ?? giroScelto.value))
  lavoro.value = true
  try {
    const ids = selezionate.value.map(s => s.idSpedizione)
    const { data: r } = await api.post('/sped-giri/assegna', { idSpedizioni: ids, idGiro: giro ? giro.idGiro : null })
    for (const s of spedizioni.value) {
      if (!ids.includes(s.idSpedizione)) continue
      s.idGiro = giro ? giro.idGiro : null; s.giro = giro?.giro ?? null; s.colore = giro?.colore ?? null; s.sequenza = null
      aggiornaPunto(s)
    }
    avviso('success', giro ? `Assegnate a ${giro.giro}` : 'Giro tolto', `${r.cambiate} spedizioni cambiate su ${ids.length}`)
    selezionate.value = []
  } catch (e) { avviso('error', 'Assegnazione', messaggio(e), 5000) } finally { lavoro.value = false }
}
async function assegnaAuto(forza) {
  lavoro.value = true
  try {
    const { data: r } = await api.post('/sped-giri/assegna-auto', { data: dataIso.value, idCliente: idCliente.value ?? undefined, forza })
    avviso('success', 'Assegnazione automatica', `${r.Assegnate} spedizioni assegnate; ${r.SenzaGiro} restano senza giro su ${r.Totale}${r.SenzaCoordinate ? ` (${r.SenzaCoordinate} senza coordinate)` : ''}`, 7000)
    await carica()
  } catch (e) { avviso('error', 'Assegnazione automatica', messaggio(e), 5000) } finally { lavoro.value = false }
}
function chiediRiassegna() {
  chiedi('Riassegna tutte', `Tutte le ${riepilogo.value.totale} spedizioni del ${data.value.toLocaleDateString('it-IT')}${idCliente.value != null ? ' del cliente scelto' : ''} vengono riassegnate ai giri per CAP fisso, comune fisso e area: le assegnazioni fatte a mano vanno perse. Procedo?`, () => assegnaAuto(true))
}

// --- punto di consegna: trascinato (se c'e') o messo sulla mappa (se manca) ---
const spostamento = ref(null)         // la spedizione in spostamento
let markerSposta = null
const nuovaPosizione = ref(null)      // { lat, lng }
function iniziaSpostamento(s) {
  annullaSpostamento(); annullaLasso()
  spostamento.value = s; nuovaPosizione.value = null
  if (s.lat != null) {
    markerSposta = L.marker([s.lat, s.lng], { draggable: true, zIndexOffset: 1000, icon: L.divIcon({ className: 'sped-sposta', html: '<span></span>', iconSize: [22, 22], iconAnchor: [11, 11] }) })
      .bindTooltip('trascina nel punto giusto', { permanent: true, direction: 'top', offset: [0, -12] })
    markerSposta.on('dragend', ev => { const ll = ev.target.getLatLng(); nuovaPosizione.value = { lat: ll.lat, lng: ll.lng } })
    spostaLayer.addLayer(markerSposta)
    const m = markers.get(s.idSpedizione); if (m) cluster.removeLayer(m)
    map.setView([s.lat, s.lng], Math.max(map.getZoom(), 16))
  } else avviso('info', 'Metti sulla mappa', `Clicca sulla mappa nel punto di consegna di ${s.barcode} (${s.indirizzo ?? ''} ${s.cap ?? ''} ${s.localita ?? ''})`, 6000)
}
function mettiPunto(lat, lng) {
  nuovaPosizione.value = { lat, lng }
  spostaLayer.clearLayers()
  markerSposta = L.marker([lat, lng], { draggable: true, zIndexOffset: 1000, icon: L.divIcon({ className: 'sped-sposta', html: '<span></span>', iconSize: [22, 22], iconAnchor: [11, 11] }) })
    .bindTooltip('trascina per aggiustare, poi Salva', { permanent: true, direction: 'top', offset: [0, -12] })
  markerSposta.on('dragend', ev => { const ll = ev.target.getLatLng(); nuovaPosizione.value = { lat: ll.lat, lng: ll.lng } })
  spostaLayer.addLayer(markerSposta)
}
async function salvaPosizione() {
  const s = spostamento.value, p = nuovaPosizione.value
  if (!s || !p) return
  lavoro.value = true
  try {
    const { data: r } = await api.post(`/sped-giri/${s.idSpedizione}/posizione`, { lat: p.lat, lng: p.lng, riassegna: true })
    const giroPrima = s.giro
    s.lat = r.Lat; s.lng = r.Lng; s.idGiro = r.IdGiro; s.giro = r.Giro; s.colore = r.Colore
    if (r.IdGiro && r.Giro !== giroPrima) s.sequenza = null
    avviso('success', 'Posizione salvata', `${s.barcode}: ${r.Giro ? (r.Giro !== giroPrima ? 'ora nel giro ' + r.Giro : 'giro ' + r.Giro) : 'nessun giro copre il punto'}`, 5000)
    annullaSpostamento()
    disegnaPunti()
  } catch (e) { avviso('error', 'Posizione', messaggio(e), 5000) } finally { lavoro.value = false }
}
function annullaSpostamento() {
  if (spostaLayer) spostaLayer.clearLayers()
  markerSposta = null
  if (spostamento.value) { const m = markers.get(spostamento.value.idSpedizione); if (m && !cluster.hasLayer(m)) cluster.addLayer(m) }
  spostamento.value = null; nuovaPosizione.value = null
}

// --- storico di una spedizione ---
const storico = ref(null)             // { sped, righe }
async function apriStorico(s) {
  try {
    const { data: righe } = await api.get(`/sped-giri/${s.idSpedizione}/variazioni`)
    storico.value = { sped: s, righe }
  } catch (e) { avviso('error', 'Storico', messaggio(e)) }
}
const ORIGINI = { AUTO: 'automatica', MANUALE: 'a mano', POSIZIONE: 'dal punto spostato' }
function selezionaDaFiltro(stato) { filtroStato.value = stato; filtroGiro.value = null }
</script>

<template>
  <div class="pagina">
    <div class="testata">
      <div>
        <h2>Spedizioni del giorno <span class="filiale">{{ filiale }}</span></h2>
        <p class="sotto">Le spedizioni caricate nel giorno scelto con il giro assegnato: qui si verifica, si assegna e si corregge il punto di consegna.</p>
      </div>
      <div class="barra">
        <DatePicker v-model="data" dateFormat="dd/mm/yy" showIcon size="small" class="data" @update:modelValue="carica(true)" />
        <Select v-model="idCliente" :options="clienti" optionLabel="etichetta" optionValue="idCliente" showClear placeholder="tutti i clienti" size="small" class="cliente" />
        <Button label="Assegna le senza giro" icon="pi pi-directions" size="small" :loading="lavoro" :disabled="!riepilogo.senzaGiro" title="Assegnazione automatica delle spedizioni ancora senza giro" @click="assegnaAuto(false)" />
        <Button label="Riassegna tutte" icon="pi pi-sync" size="small" outlined :loading="lavoro" :disabled="!riepilogo.totale" @click="chiediRiassegna" />
        <Button icon="pi pi-refresh" text :loading="caricamento" title="Ricarica" @click="carica()" />
      </div>
    </div>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>
    <Message v-if="!geoAttiva && spedizioni.length" severity="warn" :closable="false">Per questa filiale la geocodifica degli indirizzi non è attiva: le spedizioni non hanno coordinate e i giri si assegnano solo per CAP o comune fisso.</Message>

    <div class="riepilogo">
      <button class="chip" :class="{ attiva: filtroStato === 'tutte' }" @click="selezionaDaFiltro('tutte')">{{ riepilogo.totale }} spedizioni</button>
      <button class="chip ok" :class="{ attiva: filtroStato === 'conGiro' }" @click="selezionaDaFiltro('conGiro')">{{ riepilogo.conGiro }} con giro</button>
      <button class="chip attenzione" :class="{ attiva: filtroStato === 'senzaGiro' }" @click="selezionaDaFiltro('senzaGiro')">{{ riepilogo.senzaGiro }} senza giro</button>
      <button class="chip errore" :class="{ attiva: filtroStato === 'senzaCoordinate' }" @click="selezionaDaFiltro('senzaCoordinate')">{{ riepilogo.senzaCoordinate }} senza coordinate</button>
      <span class="spazio"></span>
      <label class="chk"><Checkbox v-model="mostraAree" binary @change="toggleAree" /> Aree dei giri</label>
      <Button icon="pi pi-expand" text size="small" title="Inquadra tutte le spedizioni" @click="inquadraTutte" />
    </div>

    <div class="corpo">
      <div class="mappa-box">
        <div ref="mapEl" class="mappa"></div>
        <div class="strumenti">
          <template v-if="spostamento">
            <span class="nota"><b>{{ spostamento.barcode }}</b>: {{ spostamento.lat == null ? 'clicca sulla mappa nel punto di consegna' : 'trascina il pin nel punto giusto' }}</span>
            <Button label="Salva posizione" icon="pi pi-check" size="small" :disabled="!nuovaPosizione" :loading="lavoro" @click="salvaPosizione" />
            <Button label="Annulla" size="small" text @click="annullaSpostamento" />
          </template>
          <template v-else-if="lassoAttivo">
            <span class="nota">Clicca i vertici dell'area: {{ lasso.length }} punti<template v-if="nelLasso">, {{ nelLasso }} spedizioni dentro</template></span>
            <Button label="Seleziona" icon="pi pi-check" size="small" :disabled="lasso.length < 3" @click="applicaLasso" />
            <Button label="Annulla" size="small" text @click="annullaLasso" />
          </template>
          <template v-else>
            <Button label="Seleziona con un'area" icon="pi pi-pencil" size="small" outlined @click="iniziaLasso" />
            <Button v-if="selezionate.length === 1" :label="selezionate[0].lat == null ? 'Metti sulla mappa' : 'Sposta il punto'" icon="pi pi-map-marker" size="small" outlined @click="iniziaSpostamento(selezionate[0])" />
            <span v-if="selezionate.length" class="nota">{{ selezionate.length }} selezionate</span>
          </template>
        </div>
        <div class="legenda">
          <button v-for="g in giriConConteggio" :key="g.idGiro" class="voce" :class="{ attiva: filtroGiro === g.idGiro, vuota: !g.n }" :title="g.giro" @click="filtroGiro = filtroGiro === g.idGiro ? null : g.idGiro">
            <span class="pallino" :style="{ background: g.colore || '#ccc' }"></span>{{ g.giro }} <b>{{ g.n }}</b>
          </button>
          <button class="voce" :class="{ attiva: filtroStato === 'senzaGiro' }" @click="selezionaDaFiltro(filtroStato === 'senzaGiro' ? 'tutte' : 'senzaGiro')"><span class="pallino" :style="{ background: GRIGIO }"></span>senza giro <b>{{ riepilogo.senzaGiro }}</b></button>
        </div>
      </div>

      <div class="griglia">
        <div class="azioni">
          <InputText v-model="filtroTesto" placeholder="cerca barcode, destinatario, via, CAP" size="small" class="cerca" />
          <Select v-model="filtroStato" :options="STATI" optionLabel="nome" optionValue="valore" size="small" class="stato" />
          <span class="spazio"></span>
          <Select v-model="giroScelto" :options="giri" optionLabel="giro" optionValue="idGiro" filter placeholder="giro" size="small" class="giro" />
          <Button label="Assegna" icon="pi pi-arrow-right" size="small" :disabled="!selezionate.length || giroScelto == null" :loading="lavoro" :title="`Assegna le ${selezionate.length} selezionate al giro scelto`" @click="assegnaSelezionate()" />
          <Button label="Togli giro" size="small" text severity="danger" :disabled="!selezionate.length" :loading="lavoro" @click="assegnaSelezionate(null)" />
        </div>
        <DataTable :value="visibili" v-model:selection="selezionate" dataKey="idSpedizione" selectionMode="multiple" :metaKeySelection="false"
          paginator :rows="100" :rowsPerPageOptions="[50, 100, 250, 500]" scrollable scrollHeight="flex" size="small" stripedRows
          :rowClass="d => d.lat == null ? 'riga-senza-coord' : ''" @row-click="e => centra(e.data)">
          <Column selectionMode="multiple" style="width: 2.5rem" />
          <Column field="barcode" header="Barcode" style="width: 8.5rem">
            <template #body="{ data }"><span class="mono">{{ data.barcode }}</span><i v-if="data.lat == null" class="pi pi-exclamation-triangle senza-coord" title="senza coordinate"></i></template>
          </Column>
          <Column field="destinatario" header="Destinatario" />
          <Column header="Indirizzo">
            <template #body="{ data }">{{ data.indirizzo }} {{ data.civico ?? '' }}<div class="nota">{{ data.cap }} {{ data.localita }}</div></template>
          </Column>
          <Column header="Giro" style="width: 11rem">
            <template #body="{ data }">
              <span v-if="data.idGiro" class="giro-cella"><span class="pallino" :style="{ background: data.colore || '#ccc' }"></span>{{ data.giro }}<span v-if="data.sequenza" class="nota"> · {{ data.sequenza }}</span></span>
              <Tag v-else value="senza giro" severity="secondary" />
            </template>
          </Column>
          <Column header="" style="width: 4.5rem">
            <template #body="{ data }">
              <Button icon="pi pi-map-marker" text rounded size="small" :title="data.lat == null ? 'Metti sulla mappa' : 'Sposta il punto'" @click.stop="selezionate = [data]; iniziaSpostamento(data)" />
              <Button icon="pi pi-history" text rounded size="small" title="Storico" @click.stop="apriStorico(data)" />
            </template>
          </Column>
          <template #empty><span class="nota">Nessuna spedizione per i filtri scelti.</span></template>
        </DataTable>
        <div v-if="senzaCoordinateVisibili && filtroStato !== 'senzaCoordinate'" class="nota piede">{{ senzaCoordinateVisibili }} delle spedizioni in elenco non hanno coordinate e non sono sulla mappa.</div>
      </div>
    </div>

    <Dialog :visible="!!conferma" modal :header="conferma?.titolo" :style="{ width: '34rem' }" @update:visible="conferma = null">
      <p>{{ conferma?.testo }}</p>
      <template #footer>
        <Button label="Annulla" text @click="conferma = null" />
        <Button label="Conferma" @click="confermato" />
      </template>
    </Dialog>

    <Dialog :visible="!!storico" modal :header="storico ? `Storico ${storico.sped.barcode}` : ''" :style="{ width: '40rem' }" @update:visible="storico = null">
      <template v-if="storico">
        <p class="nota">{{ storico.sped.destinatario }} · {{ storico.sped.indirizzo }} {{ storico.sped.civico ?? '' }} · {{ storico.sped.cap }} {{ storico.sped.localita }}</p>
        <DataTable :value="storico.righe" size="small" stripedRows>
          <Column header="Quando" style="width: 9rem"><template #body="{ data }">{{ dataOra(data.dataOra) }}</template></Column>
          <Column field="campo" header="Cosa" style="width: 6rem" />
          <Column header="Prima → dopo"><template #body="{ data }">{{ data.prima ?? '—' }} → {{ data.dopo ?? '—' }}</template></Column>
          <Column header="Come" style="width: 9rem"><template #body="{ data }">{{ ORIGINI[data.origine] ?? data.origine }}<div v-if="data.utente" class="nota">{{ data.utente }}</div></template></Column>
          <template #empty><span class="nota">Nessuna modifica registrata.</span></template>
        </DataTable>
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: .5rem; height: calc(100vh - 7rem); min-height: 560px; }
.testata { display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
.testata h2 { margin: 0; }
.filiale { font-weight: 400; color: var(--p-text-muted-color); font-size: 1rem; margin-left: .5rem; }
.sotto { margin: .15rem 0 0; color: var(--p-text-muted-color); font-size: .9rem; }
.barra { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.data { width: 9.5rem; }
.cliente { width: 15rem; }
.riepilogo { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.chip { border: 1px solid var(--p-surface-300); background: var(--p-surface-0); border-radius: 999px; padding: .2rem .7rem; font-size: .85rem; cursor: pointer; }
.chip.attiva { border-color: var(--p-primary-color); box-shadow: 0 0 0 2px var(--p-primary-100); }
.chip.ok { color: #1a7a1a; } .chip.attenzione { color: var(--p-orange-600); } .chip.errore { color: #c62828; }
.chk { display: inline-flex; align-items: center; gap: .4rem; cursor: pointer; font-size: .9rem; }
.nota { color: var(--p-text-muted-color); font-size: .85rem; }
.spazio { flex: 1; }
.mono { font-family: monospace; }

.corpo { display: flex; gap: .75rem; flex: 1; min-height: 0; }
.mappa-box { flex: 1.1; display: flex; flex-direction: column; min-width: 0; }
.mappa { flex: 1; min-height: 360px; border: 1px solid var(--p-surface-300); border-radius: 6px; z-index: 0; }
.strumenti { display: flex; align-items: center; gap: .5rem; padding: .35rem 0; flex-wrap: wrap; min-height: 2.4rem; }
.legenda { display: flex; flex-wrap: wrap; gap: .25rem; max-height: 5.5rem; overflow-y: auto; }
.voce { display: inline-flex; align-items: center; gap: .3rem; border: 1px solid var(--p-surface-200); background: var(--p-surface-0); border-radius: 4px; padding: .1rem .45rem; font-size: .78rem; cursor: pointer; }
.voce.attiva { border-color: var(--p-primary-color); box-shadow: 0 0 0 2px var(--p-primary-100); }
.voce.vuota { opacity: .5; }
.pallino { display: inline-block; width: 11px; height: 11px; border-radius: 50%; border: 1px solid #999; margin-right: .25rem; }
.griglia { flex: 1; display: flex; flex-direction: column; min-width: 0; border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; }
.azioni { display: flex; align-items: center; gap: .4rem; padding: .4rem .5rem; border-bottom: 1px solid var(--p-surface-200); flex-wrap: wrap; }
.cerca { width: 15rem; } .stato { width: 10rem; } .giro { width: 12rem; }
.giro-cella { display: inline-flex; align-items: center; }
.senza-coord { color: #c62828; margin-left: .3rem; font-size: .8rem; }
.piede { padding: .3rem .6rem; border-top: 1px solid var(--p-surface-200); }
:deep(.riga-senza-coord) { background: #fff5f5 !important; }
:deep(.p-datatable) { flex: 1; min-height: 0; display: flex; flex-direction: column; }
@media (max-width: 1100px) {
  .pagina { height: auto; }
  .corpo { flex-direction: column; }
  .mappa { height: 50vh; }
  .griglia { min-height: 24rem; }
}
</style>

<style>
.sped-punto span { display: block; width: 14px; height: 14px; border-radius: 50%; border: 1px solid rgba(0,0,0,.45); box-sizing: border-box; }
.sped-punto.senza-giro span { border: 2px solid #c62828; }
.sped-punto.scelta span { box-shadow: 0 0 0 3px #1565c0, 0 0 0 5px #fff; }
.sped-sposta span { display: block; width: 22px; height: 22px; border-radius: 50%; background: #1565c0; border: 3px solid #fff; box-shadow: 0 1px 4px rgba(0,0,0,.5); cursor: move; }
</style>
