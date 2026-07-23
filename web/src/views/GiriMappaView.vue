<script setup>
import { ref, onMounted, onBeforeUnmount, computed } from 'vue'
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
import Message from 'primevue/message'

// Videata legacy "Creazione giri su Mappa" (Sped2mappe) su Leaflet + OSM, con:
// - comuni/giri renderizzati dallo SHAPE (gestisce anche i MULTIPOLYGON)
// - creazione giro come UNIONE dei comuni selezionati (rapido e preciso)
// - disegno manuale con pin numerati riordinabili
// - anteprima: evidenzia le spedizioni che cadrebbero nel giro in disegno
// - clustering dei marker spedizioni

const toast = useToast()
const errore = ref('')

let map = null, resizeObs = null
let comuniLayer, giriLayer, spedizioniCluster, disegnoLayer, anteprimaLayer
const comuniDisegnati = new Map()   // idComune -> L.layerGroup
const giriDisegnati = new Map()     // idGiro   -> L.layerGroup
const mapEl = ref(null)

const comuni = ref([])
const giri = ref([])
const comuniSel = ref([])
const giriSel = ref([])

const visualizza = ref(false)
const filtroGiro = ref(null)
const filtroCap = ref('')
let spedData = []   // [{lat,lng,...}] per l'anteprima point-in-polygon

const nome = ref('')
const colore = ref('F44F22')
const attivoDisegno = ref(false)
const bordi = ref([])               // [{lat,lng, marker}]
const salvataggio = ref(false)
const salvataggioComuni = ref(false)

const puoSalvare = computed(() => nome.value.trim().length > 3 && bordi.value.length >= 3)
const puoSalvareComuni = computed(() => nome.value.trim().length > 3 && comuniSel.value.length > 0)
const coloreHex = computed(() => '#' + `${colore.value}`.replace('#', ''))

// --- parsing WKT (POLYGON / MULTIPOLYGON) -> anelli [[lat,lng],...] ---
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
    map = L.map(mapEl.value, { center: [init.lat, init.lng], zoom: 11 })
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19, attribution: '© OpenStreetMap'
    }).addTo(map)
    comuniLayer = L.layerGroup().addTo(map)
    giriLayer = L.layerGroup().addTo(map)
    spedizioniCluster = L.markerClusterGroup({ chunkedLoading: true, maxClusterRadius: 45 }).addTo(map)
    anteprimaLayer = L.layerGroup().addTo(map)
    disegnoLayer = L.layerGroup().addTo(map)
    map.on('click', onMapClick)
    resizeObs = new ResizeObserver(() => map && map.invalidateSize())
    resizeObs.observe(mapEl.value)
    setTimeout(() => map && map.invalidateSize(), 200)

    const [{ data: c }, { data: g }] = await Promise.all([api.get('/giri/comuni'), api.get('/giri/elenco')])
    comuni.value = c
    giri.value = g
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento della mappa'
  }
})
onBeforeUnmount(() => {
  if (resizeObs) { resizeObs.disconnect(); resizeObs = null }
  if (map) { map.remove(); map = null }
})

// --- comuni: confini (dallo SHAPE, multipolygon-safe) ---
async function toggleComuni() {
  const selIds = new Set(comuniSel.value.map(c => c.idComune))
  for (const [id, grp] of comuniDisegnati) {
    if (!selIds.has(id)) { comuniLayer.removeLayer(grp); comuniDisegnati.delete(id) }
  }
  for (const com of comuniSel.value) {
    if (comuniDisegnati.has(com.idComune)) continue
    try {
      const { data } = await api.get('/giri/shape', { params: { idComune: com.idComune } })
      const grp = disegnaShape(data.wkt, '#223344', 0.12, com.denominazione)
      if (grp) { comuniLayer.addLayer(grp); comuniDisegnati.set(com.idComune, grp) }
    } catch { /* comune senza geometria */ }
  }
}

// --- giri: area + perimetro (dallo SHAPE) ---
async function toggleGiri() {
  const selIds = new Set(giriSel.value.map(g => g.idGiro))
  for (const [id, grp] of giriDisegnati) {
    if (!selIds.has(id)) { giriLayer.removeLayer(grp); giriDisegnati.delete(id) }
  }
  for (const g of giriSel.value) {
    if (giriDisegnati.has(g.idGiro)) continue
    try {
      const { data } = await api.get('/giri/shape', { params: { idGiro: g.idGiro } })
      const grp = disegnaShape(data.wkt, g.colore || '#3388ff', 0.25, g.giro)
      if (grp) { giriLayer.addLayer(grp); giriDisegnati.set(g.idGiro, grp) }
    } catch { /* giro senza geometria */ }
  }
}

function disegnaShape(wkt, col, opacity, tooltip) {
  const rings = wktToRings(wkt)
  if (!rings.length) return null
  const grp = L.layerGroup()
  for (const ring of rings) {
    L.polygon(ring, { color: col, weight: 2, fillColor: col, fillOpacity: opacity })
      .bindTooltip(tooltip).on('click', onRefClick).addTo(grp)
  }
  return grp
}

// --- spedizioni (cluster) ---
async function aggiornaSpedizioni() {
  spedizioniCluster.clearLayers()
  spedData = []
  if (!visualizza.value) { anteprimaLayer.clearLayers(); return }
  try {
    const { data: sped } = await api.get('/giri/spedizioni', {
      params: {
        idGiro: filtroGiro.value ?? undefined,
        cap: filtroCap.value?.length === 5 ? filtroCap.value : undefined
      }
    })
    const markers = []
    for (const s of sped) {
      if (s.lat == null || s.lng == null) continue
      spedData.push(s)
      const col = (s.colore && `${s.colore}`.trim()) || '#e53935'
      // L.marker (non circleMarker) per compatibilita' con il clustering
      markers.push(L.marker([s.lat, s.lng], { icon: dotIcon(col) })
        .bindTooltip(`<b>${s.barcode ?? ''}</b><br>${s.indirizzo ?? ''}<br>${s.cap ?? ''} ${s.localita ?? ''}${s.giro ? '<br>Giro: ' + s.giro : ''}`))
    }
    spedizioniCluster.addLayers(markers)
    if (!sped.length) toast.add({ severity: 'info', summary: 'Spedizioni', detail: 'Nessuna spedizione da mostrare', life: 2500 })
    aggiornaAnteprima()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Spedizioni', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  }
}

// pallino colorato per la spedizione (icona compatibile col clustering)
function dotIcon(col) {
  return L.divIcon({ className: 'sped-dot', html: `<span style="background:${col}"></span>`, iconSize: [12, 12], iconAnchor: [6, 6] })
}

// --- anteprima assegnazione: evidenzia le spedizioni dentro il giro in disegno ---
function puntoInPoligono(lat, lng, ring) {
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const yi = ring[i][0], xi = ring[i][1], yj = ring[j][0], xj = ring[j][1]
    if (((yi > lat) !== (yj > lat)) && (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)) inside = !inside
  }
  return inside
}
const nDentro = ref(0)
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

// --- disegno manuale con pin numerati ---
function iconaNum(n) {
  return L.divIcon({ className: 'vertice-num', html: `<span>${n}</span>`, iconSize: [24, 24], iconAnchor: [12, 12] })
}
function onMapClick(e) { if (attivoDisegno.value) aggiungiVertice(e.latlng.lat, e.latlng.lng) }
function onRefClick(e) {
  if (!attivoDisegno.value) return
  aggiungiVertice(e.latlng.lat, e.latlng.lng)
  L.DomEvent.stopPropagation(e)
}
function aggiungiVertice(lat, lng) {
  const marker = L.marker([lat, lng], { draggable: true, icon: iconaNum(bordi.value.length + 1) })
  const v = { lat, lng, marker }
  marker.on('drag', ev => { const ll = ev.target.getLatLng(); v.lat = ll.lat; v.lng = ll.lng; ridisegnaBozza(); aggiornaAnteprima() })
  bordi.value.push(v)
  disegnoLayer.addLayer(marker)
  ridisegnaBozza(); aggiornaAnteprima()
}
let bozzaPoly = null
function ridisegnaBozza() {
  if (bozzaPoly) { disegnoLayer.removeLayer(bozzaPoly); bozzaPoly = null }
  if (bordi.value.length >= 2) {
    bozzaPoly = L.polygon(bordi.value.map(v => [v.lat, v.lng]), {
      color: coloreHex.value, weight: 2, fillColor: coloreHex.value, fillOpacity: 0.2, dashArray: '5,5'
    })
    disegnoLayer.addLayer(bozzaPoly)
  }
}
function refreshNumeri() { bordi.value.forEach((v, i) => v.marker.setIcon(iconaNum(i + 1))) }
function sposta(i, dir) {
  const j = i + dir
  if (j < 0 || j >= bordi.value.length) return
  const arr = [...bordi.value]
  ;[arr[i], arr[j]] = [arr[j], arr[i]]
  bordi.value = arr
  refreshNumeri(); ridisegnaBozza(); aggiornaAnteprima()
}
function rimuoviVertice(v) {
  disegnoLayer.removeLayer(v.marker)
  bordi.value = bordi.value.filter(x => x !== v)
  refreshNumeri(); ridisegnaBozza(); aggiornaAnteprima()
}
function svuotaDisegno() {
  bordi.value.forEach(v => disegnoLayer.removeLayer(v.marker))
  bordi.value = []
  ridisegnaBozza(); aggiornaAnteprima()
}

async function ricaricaGiri() { const { data } = await api.get('/giri/elenco'); giri.value = data }

async function creaGiro() {
  salvataggio.value = true
  try {
    const { data } = await api.post('/giri', {
      nome: nome.value.trim(), colore: coloreHex.value,
      vertici: bordi.value.map(v => ({ lat: v.lat, lng: v.lng }))
    })
    toast.add({ severity: 'success', summary: 'Giro creato', detail: `${nome.value} (Id ${data.idGiro})`, life: 3500 })
    svuotaDisegno(); nome.value = ''; attivoDisegno.value = false
    await ricaricaGiri()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Creazione giro', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally { salvataggio.value = false }
}

async function creaGiroDaComuni() {
  salvataggioComuni.value = true
  try {
    const { data } = await api.post('/giri/da-comuni', {
      nome: nome.value.trim(), colore: coloreHex.value,
      idComuni: comuniSel.value.map(c => c.idComune)
    })
    toast.add({ severity: 'success', summary: 'Giro da comuni', detail: `${nome.value} (${comuniSel.value.length} comuni, Id ${data.idGiro})`, life: 4000 })
    nome.value = ''
    await ricaricaGiri()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Giro da comuni', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally { salvataggioComuni.value = false }
}

const assegnazione = ref(false)
async function aggiornaGiriDiSped() {
  if (!giriSel.value.length) {
    toast.add({ severity: 'warn', summary: 'Giri', detail: 'Seleziona uno o più giri nell\'elenco', life: 3000 })
    return
  }
  assegnazione.value = true
  try {
    await api.post('/giri/assegna', { idGiri: giriSel.value.map(g => g.idGiro) })
    toast.add({ severity: 'success', summary: 'Giri', detail: 'Giri aggiornati alle spedizioni', life: 3000 })
    if (visualizza.value) aggiornaSpedizioni()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Giri', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  } finally { assegnazione.value = false }
}
</script>

<template>
  <div class="pagina">
    <div class="testata">
      <h2>Giri — Creazione giri su Mappa</h2>
      <Button label="Aggiorna Giri di Sped" icon="pi pi-sync" size="small" outlined
        :loading="assegnazione" @click="aggiornaGiriDiSped" />
    </div>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="controlli">
      <label class="chk"><Checkbox v-model="visualizza" binary @change="aggiornaSpedizioni" /> Visualizza spedizioni</label>
      <label>Punti del giro:
        <select v-model="filtroGiro" @change="visualizza && aggiornaSpedizioni()" class="sel-giro">
          <option :value="null">— tutti —</option>
          <option v-for="g in giri" :key="g.idGiro" :value="g.idGiro">{{ g.giro }}</option>
        </select>
      </label>
      <label>CAP <InputText v-model="filtroCap" maxlength="5" class="cap" @update:modelValue="visualizza && aggiornaSpedizioni()" /></label>
    </div>

    <div class="corpo">
      <div ref="mapEl" class="mappa"></div>

      <aside class="pannello">
        <div class="pannello-titolo">Nuovo Giro</div>
        <div class="form">
          <label>Nome</label>
          <InputText v-model="nome" maxlength="200" fluid />
          <label>Colore</label>
          <ColorPicker v-model="colore" />
          <Button label="Crea da comuni selezionati" icon="pi pi-clone" severity="help"
            :disabled="!puoSalvareComuni" :loading="salvataggioComuni" @click="creaGiroDaComuni" />
          <small class="hint">{{ comuniSel.length }} comuni selezionati in basso</small>
          <hr />
          <label class="chk"><Checkbox v-model="attivoDisegno" binary /> Disegna a mano (clic sulla mappa)</label>
          <Button label="Crea Nuovo Giro" icon="pi pi-check" :disabled="!puoSalvare" :loading="salvataggio" @click="creaGiro" />
          <small v-if="nDentro" class="anteprima">≈ {{ nDentro }} spedizioni in quest'area</small>
        </div>

        <div class="pannello-titolo">
          Bordi <span class="conteggio">{{ bordi.length }} punti</span>
          <Button icon="pi pi-trash" text rounded size="small" title="Svuota" :disabled="!bordi.length" @click="svuotaDisegno" />
        </div>
        <div class="bordi">
          <div v-for="(v, i) in bordi" :key="i" class="bordo">
            <span class="num">{{ i + 1 }}</span>
            <span class="coord">{{ v.lat.toFixed(5) }}, {{ v.lng.toFixed(5) }}</span>
            <span class="azioni">
              <Button icon="pi pi-arrow-up" text rounded size="small" :disabled="i === 0" @click="sposta(i, -1)" />
              <Button icon="pi pi-arrow-down" text rounded size="small" :disabled="i === bordi.length - 1" @click="sposta(i, 1)" />
              <Button icon="pi pi-times" text rounded size="small" severity="danger" @click="rimuoviVertice(v)" />
            </span>
          </div>
          <p v-if="!bordi.length" class="vuoto">Attiva il disegno e clicca sulla mappa, oppure crea il giro dai comuni.</p>
        </div>
      </aside>
    </div>

    <div class="tabelle">
      <div class="tab">
        <div class="tab-titolo">Comuni ({{ comuni.length }})</div>
        <DataTable :value="comuni" v-model:selection="comuniSel" dataKey="idComune"
          selectionMode="multiple" :metaKeySelection="false"
          @update:selection="toggleComuni" scrollable scrollHeight="220px" size="small" stripedRows>
          <Column selectionMode="multiple" style="width: 3rem" />
          <Column field="denominazione" header="Denominazione" />
          <Column field="belfiore" header="Belfiore" style="width: 6rem" />
          <Column field="cap" header="CAP" style="width: 5rem" />
        </DataTable>
      </div>
      <div class="tab">
        <div class="tab-titolo">Elenco Giri ({{ giri.length }})</div>
        <DataTable :value="giri" v-model:selection="giriSel" dataKey="idGiro"
          selectionMode="multiple" :metaKeySelection="false"
          @update:selection="toggleGiri" scrollable scrollHeight="220px" size="small" stripedRows>
          <Column selectionMode="multiple" style="width: 3rem" />
          <Column header="" style="width: 2.5rem">
            <template #body="{ data }"><span class="pallino" :style="{ background: data.colore || '#ccc' }" /></template>
          </Column>
          <Column field="giro" header="Giro" />
          <Column field="cap" header="CAP" style="width: 5rem" />
        </DataTable>
      </div>
    </div>
  </div>
</template>

<style scoped>
.testata { display: flex; align-items: center; justify-content: space-between; gap: 1rem; margin-bottom: .5rem; }
.testata h2 { margin: 0; }
.controlli { display: flex; align-items: center; gap: 1.5rem; margin-bottom: .5rem; flex-wrap: wrap; font-size: .9rem; }
.chk { display: inline-flex; align-items: center; gap: .4rem; cursor: pointer; }
.sel-giro { padding: .3rem; border: 1px solid var(--p-surface-300); border-radius: 4px; max-width: 240px; }
.cap { width: 6rem; }

.corpo { display: flex; gap: 1rem; align-items: stretch; }
.mappa { flex: 1; height: 60vh; min-height: 420px; border: 1px solid var(--p-surface-300); border-radius: 6px; z-index: 0; }
.pannello { flex: 0 0 300px; border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; display: flex; flex-direction: column; }
.pannello-titolo { background: #00a5cf; color: #fff; padding: .4rem .75rem; font-weight: 600; font-size: .9rem; display: flex; align-items: center; justify-content: space-between; }
.conteggio { font-weight: 400; opacity: .9; font-size: .8rem; }
.form { display: flex; flex-direction: column; gap: .5rem; padding: .75rem; }
.form > label { font-size: .85rem; color: #555; }
.form hr { width: 100%; border: none; border-top: 1px solid var(--p-surface-200); margin: .25rem 0; }
.hint { color: #888; font-size: .75rem; }
.anteprima { color: #1a7a1a; font-weight: 600; font-size: .8rem; }
.bordi { padding: .5rem .75rem; overflow-y: auto; max-height: 32vh; }
.bordo { display: flex; align-items: center; gap: .4rem; font-size: .78rem; }
.bordo .num { flex: 0 0 1.4rem; height: 1.4rem; line-height: 1.4rem; text-align: center; background: #00628f; color: #fff; border-radius: 50%; font-weight: 700; }
.bordo .coord { flex: 1; font-family: monospace; }
.bordo .azioni { display: flex; }
.vuoto { color: #888; font-size: .85rem; }

.tabelle { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-top: 1rem; }
.tab { border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; }
.tab-titolo { background: var(--p-surface-50); padding: .4rem .75rem; font-weight: 600; font-size: .9rem; border-bottom: 1px solid var(--p-surface-200); }
.pallino { display: inline-block; width: 14px; height: 14px; border-radius: 50%; border: 1px solid #999; }
</style>

<style>
/* pin numerati del disegno (icona globale, fuori da scoped) */
.vertice-num span {
  display: flex; align-items: center; justify-content: center;
  width: 24px; height: 24px; border-radius: 50%;
  background: #f44f22; color: #fff; font-weight: 700; font-size: 12px;
  border: 2px solid #fff; box-shadow: 0 1px 3px rgba(0,0,0,.4);
}
.sped-dot span {
  display: block; width: 12px; height: 12px; border-radius: 50%;
  border: 1px solid rgba(0,0,0,.4);
}
</style>
