<script setup>
// Piano della giornata: per il giorno scelto, i giri della filiale con le spedizioni caricate, il driver
// che li fa (proposto dal predefinito del giro) e il percorso ottimizzato con HERE: "Ottimizza" mette in
// coda la richiesta (workflow GEO-01_HERE dello schedulatore), la pagina segue lo stato e poi mostra il
// percorso sulla mappa, numerato, con km e minuti, e lo esporta in Excel. La sequenza finisce sulle
// spedizioni (SPED_ATTIVITA.Sequenza): e' quella che il palmare usera' per mettere in ordine le consegne.
// Sostituisce le videate legacy "Giri - Assegna a Driver" e "Giri - Ottimizza percorso".
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { useNavStore } from '../stores/nav'
import { scaricaDaApi } from '../lib/esporta'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
import Checkbox from 'primevue/checkbox'
import Dialog from 'primevue/dialog'
import Tag from 'primevue/tag'
import Message from 'primevue/message'

const toast = useToast()
const nav = useNavStore()
const errore = ref('')
const avviso = (severity, summary, detail, life = 4000) => toast.add({ severity, summary, detail, life })
const messaggio = e => e?.response?.data?.errore ?? e?.message ?? 'Errore'
const dataOra = v => v ? new Date(v).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' }) : ''
const ora = v => v ? new Date(v).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' }) : ''
const km = m => m == null ? '' : `${(m / 1000).toFixed(1)} km`
const minuti = s => s == null ? '' : s >= 3600 ? `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min` : `${Math.round(s / 60)} min`

// --- dati ---
const filiale = ref('')
const data = ref(new Date())
const giri = ref([])
const driver = ref([])
const senzaGiro = ref({ n: 0, geo: 0 })
const soloConSped = ref(true)
const caricamento = ref(false)
const lavoro = ref(false)
const dataIso = computed(() => {
  const d = data.value instanceof Date ? data.value : new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
})
const visibili = computed(() => soloConSped.value ? giri.value.filter(g => g.nSped > 0 || g.idPiano) : giri.value)
const riepilogo = computed(() => {
  const r = { giri: 0, sped: 0, geo: 0, conDriver: 0, ottimizzati: 0, inCorso: 0 }
  for (const g of giri.value) {
    if (!g.nSped) continue
    r.giri++; r.sped += g.nSped; r.geo += g.nGeo
    if (g.idDriver) r.conDriver++
    if (g.stato === 'FATTA') r.ottimizzati++
    if (g.stato === 'RICHIESTA' || g.stato === 'IN_CORSO') r.inCorso++
  }
  return r
})
let timer = null
onBeforeUnmount(() => { clearTimeout(timer); if (map) { map.remove(); map = null } })

async function carica(silenzioso = false) {
  if (!silenzioso) caricamento.value = true
  try {
    const { data: d } = await api.get('/piano', { params: { data: dataIso.value } })
    filiale.value = d.filiale ?? ''
    giri.value = d.giri; driver.value = d.driver; senzaGiro.value = d.senzaGiro
    if (!filialeCoord.value && d.lat) filialeCoord.value = { lat: d.lat, lng: d.lng }
    // se un'ottimizzazione e' in corso si continua a guardare; quando finisce si ricarica il percorso aperto
    clearTimeout(timer)
    if (giri.value.some(g => g.stato === 'RICHIESTA' || g.stato === 'IN_CORSO')) timer = setTimeout(() => carica(true), 4000)
    else if (attesa.value) { attesa.value = false; if (percorso.value) await apriPercorso(giri.value.find(g => g.idPiano === percorso.value.piano.idPiano) ?? percorso.value.piano) }
    if (giri.value.some(g => g.stato === 'RICHIESTA' || g.stato === 'IN_CORSO')) attesa.value = true
  } catch (e) { avviso('error', 'Piano', messaggio(e)) } finally { caricamento.value = false }
}
const attesa = ref(false)
onMounted(() => carica())

// --- driver ---
async function cambiaDriver(g, idDriver) {
  try {
    const { data: r } = await api.post('/piano/driver', { data: dataIso.value, idGiro: g.idGiro, idDriver: idDriver ?? null })
    g.idPiano = r.IdPiano; g.idDriver = r.IdDriver; g.driver = r.Driver
    avviso('success', g.giro, r.Driver ? `Driver: ${r.Driver}` : 'Driver tolto', 2500)
  } catch (e) { avviso('error', 'Driver', messaggio(e)); await carica(true) }
}
async function driverPredefiniti() {
  lavoro.value = true
  try {
    const { data: r } = await api.post('/piano/driver-predefiniti', { data: dataIso.value })
    avviso('success', 'Driver predefiniti', `${r.assegnati} giri hanno preso il driver predefinito`)
    await carica(true)
  } catch (e) { avviso('error', 'Driver predefiniti', messaggio(e)) } finally { lavoro.value = false }
}

// --- ottimizzazione ---
const conferma = ref(null)
function chiedi(titolo, testo, azione) { conferma.value = { titolo, testo, azione } }
async function confermato() { const c = conferma.value; conferma.value = null; if (c) await c.azione() }
async function ottimizza(g) {
  if (g.stato === 'FATTA') return chiedi('Rifai l\'ottimizzazione', `Il giro ${g.giro} ha gia' un percorso ottimizzato: lo rifaccio con le spedizioni di adesso?`, () => ottimizzaDavvero(g))
  await ottimizzaDavvero(g)
}
async function ottimizzaDavvero(g) {
  lavoro.value = true
  try {
    const { data: r } = await api.post('/piano/ottimizza', { data: dataIso.value, idGiro: g.idGiro })
    avviso('info', g.giro, `Richiesta a HERE per ${r.nPunti} consegne${r.nSenzaCoordinate ? ` (${r.nSenzaCoordinate} senza coordinate restano fuori)` : ''}: esecuzione ${r.idEsecuzione} dello schedulatore`, 6000)
    await carica(true)
  } catch (e) { avviso('error', 'Ottimizzazione', messaggio(e), 6000) } finally { lavoro.value = false }
}
function chiediOttimizzaTutti() {
  const daFare = giri.value.filter(g => g.nGeo > 0 && !['FATTA', 'RICHIESTA', 'IN_CORSO'].includes(g.stato ?? '')).length
  chiedi('Ottimizza tutti', daFare ? `Chiedo a HERE il percorso per i ${daFare} giri del giorno con spedizioni geolocalizzate e ancora senza percorso (${daFare} chiamate). Procedo?` : 'Tutti i giri con spedizioni geolocalizzate hanno gia\' il percorso o lo stanno aspettando: rifaccio tutti?',
    () => ottimizzaTutti(!!daFare))
}
async function ottimizzaTutti(soloDaFare) {
  lavoro.value = true
  try {
    const { data: r } = await api.post('/piano/ottimizza-tutti', { data: dataIso.value, soloDaFare })
    avviso('info', 'Ottimizza tutti', `${r.richieste} richieste in coda${r.saltati.length ? `, ${r.saltati.length} giri saltati` : ''}${r.idEsecuzione ? ` (esecuzione ${r.idEsecuzione})` : ''}`, 6000)
    await carica(true)
  } catch (e) { avviso('error', 'Ottimizza tutti', messaggio(e), 6000) } finally { lavoro.value = false }
}
const STATO = { RICHIESTA: { nome: 'in coda', sev: 'info' }, IN_CORSO: { nome: 'in corso', sev: 'info' }, FATTA: { nome: 'ottimizzato', sev: 'success' }, ERRORE: { nome: 'errore', sev: 'danger' } }

// --- percorso sulla mappa ---
const percorso = ref(null)          // { piano, filiale, punti }
const filialeCoord = ref(null)
let map = null, resizeObs = null, strato = null, areaLayer = null
const mapEl = ref(null)
function preparaMappa() {
  if (map || !mapEl.value) return
  map = L.map(mapEl.value, { center: [filialeCoord.value?.lat ?? 43.84, filialeCoord.value?.lng ?? 11.11], zoom: 11 })
  const osm = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map)
  const satellite = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', { maxZoom: 19, attribution: 'Tiles © Esri' })
  L.control.layers({ Mappa: osm, Satellite: satellite }, null, { position: 'topright' }).addTo(map)
  areaLayer = L.layerGroup().addTo(map)
  strato = L.featureGroup().addTo(map)
  resizeObs = new ResizeObserver(() => map && map.invalidateSize())
  resizeObs.observe(mapEl.value)
  setTimeout(() => map && map.invalidateSize(), 200)
}
async function apriPercorso(g) {
  if (!g.idPiano) {
    // nessun piano ancora: lo crea l'assegnazione del driver o l'ottimizzazione; intanto si mostra il giro
    avviso('info', g.giro, 'Nessun percorso ancora: assegna un driver o premi Ottimizza', 3500)
  }
  try {
    const { data: d } = g.idPiano ? await api.get(`/piano/${g.idPiano}/percorso`) : { data: null }
    if (!d) return
    percorso.value = d
    await disegnaPercorso(d)
  } catch (e) { avviso('error', 'Percorso', messaggio(e)) }
}
async function disegnaPercorso(d) {
  preparaMappa()
  strato.clearLayers(); areaLayer.clearLayers()
  try {
    const { data: s } = await api.get('/giri/shape', { params: { idGiro: d.piano.idGiro } })
    for (const ring of wktToRings(s.wkt)) L.polygon(ring, { color: d.piano.colore || '#3388ff', weight: 1.5, fillOpacity: 0.06, interactive: false }).addTo(areaLayer)
  } catch { /* senza area */ }
  const col = d.piano.colore || '#1565c0'
  const linea = []
  if (d.filiale.lat) {
    L.marker([d.filiale.lat, d.filiale.lng], { icon: L.divIcon({ className: 'tappa-filiale', html: '<span>⌂</span>', iconSize: [26, 26], iconAnchor: [13, 13] }) }).bindTooltip(`${d.filiale.nome}: partenza e ritorno`).addTo(strato)
    linea.push([d.filiale.lat, d.filiale.lng])
  }
  for (const p of d.punti) {
    if (p.lat == null || p.tipo !== 'consegna') continue
    const n = p.sequenza
    const m = L.marker([p.lat, p.lng], { icon: L.divIcon({ className: 'tappa', html: `<span style="background:${col}">${n ?? '·'}</span>`, iconSize: [22, 22], iconAnchor: [11, 11] }) })
      .bindTooltip(`<b>${n ? n + '. ' : ''}${p.barcode ?? ''}</b> ${p.destinatario ?? ''}<br>${p.indirizzo ?? ''}<br>${p.cap ?? ''} ${p.localita ?? ''}${p.arrivo ? '<br>arrivo stimato ' + ora(p.arrivo) : ''}${p.km != null ? ' · ' + p.km + ' km dal punto prima' : ''}`)
    m.on('click', () => evidenzia(p))
    m.addTo(strato)
    if (n) linea.push([p.lat, p.lng])
  }
  if (d.piano.stato === 'FATTA' && d.filiale.lat) linea.push([d.filiale.lat, d.filiale.lng])
  if (d.piano.stato === 'FATTA' && linea.length > 1) L.polyline(linea, { color: col, weight: 3, opacity: 0.8 }).addTo(strato)
  const b = strato.getBounds()
  if (b.isValid()) map.fitBounds(b, { padding: [20, 20] })
}
const puntoScelto = ref(null)
function evidenzia(p) {
  puntoScelto.value = p.idSpedizione
  if (map && p.lat != null) map.panTo([p.lat, p.lng])
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
const consegne = computed(() => (percorso.value?.punti ?? []).filter(p => p.tipo === 'consegna'))
const ritorno = computed(() => (percorso.value?.punti ?? []).find(p => p.tipo === 'ritorno'))
function esporta() {
  if (!percorso.value) return
  scaricaDaApi(api, `/piano/${percorso.value.piano.idPiano}/export`, {}, `percorso_${percorso.value.piano.giro}_${percorso.value.piano.data}.xlsx`).catch(e => avviso('error', 'Excel', messaggio(e)))
}

// --- storico ---
const storico = ref(null)
async function apriStorico(g) {
  if (!g.idPiano) { avviso('info', g.giro, 'Nessuna modifica registrata'); return }
  try {
    const { data: righe } = await api.get(`/piano/${g.idPiano}/storico`)
    storico.value = { giro: g, righe }
  } catch (e) { avviso('error', 'Storico', messaggio(e)) }
}
function vaiSpedizioni() { nav.drill({ tipo: 'sped-giorno' }) }
</script>

<template>
  <div class="pagina">
    <div class="testata">
      <div>
        <h2>Piano della giornata <span class="filiale">{{ filiale }}</span></h2>
        <p class="sotto">I giri del giorno con le spedizioni, il driver che li fa e il percorso ottimizzato con HERE: la sequenza va sulle spedizioni ed e' quella che il palmare seguira'.</p>
      </div>
      <div class="barra">
        <DatePicker v-model="data" dateFormat="dd/mm/yy" showIcon size="small" class="data" @update:modelValue="percorso = null; carica()" />
        <Button label="Driver predefiniti" icon="pi pi-users" size="small" outlined :loading="lavoro" title="Mette il driver predefinito del giro dove manca" @click="driverPredefiniti" />
        <Button label="Ottimizza tutti" icon="pi pi-directions" size="small" :loading="lavoro" :disabled="!riepilogo.geo" @click="chiediOttimizzaTutti" />
        <Button icon="pi pi-refresh" text :loading="caricamento" title="Ricarica" @click="carica()" />
      </div>
    </div>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="riepilogo">
      <span class="chip">{{ riepilogo.giri }} giri con spedizioni</span>
      <span class="chip">{{ riepilogo.sped }} spedizioni, {{ riepilogo.geo }} con coordinate</span>
      <span class="chip" :class="{ ok: riepilogo.conDriver === riepilogo.giri && riepilogo.giri }">{{ riepilogo.conDriver }} con driver</span>
      <span class="chip" :class="{ ok: riepilogo.ottimizzati === riepilogo.giri && riepilogo.giri }">{{ riepilogo.ottimizzati }} ottimizzati<template v-if="riepilogo.inCorso">, {{ riepilogo.inCorso }} in corso</template></span>
      <button v-if="senzaGiro.n" class="chip attenzione" title="Apri Spedizioni del giorno" @click="vaiSpedizioni">{{ senzaGiro.n }} senza giro</button>
      <span class="spazio"></span>
      <label class="chk"><Checkbox v-model="soloConSped" binary /> Solo giri con spedizioni</label>
    </div>

    <div class="corpo">
      <div class="griglia">
        <DataTable :value="visibili" dataKey="idGiro" size="small" stripedRows scrollable scrollHeight="flex"
          :rowClass="g => (percorso && percorso.piano.idGiro === g.idGiro ? 'riga-aperta ' : '') + (!g.nSped ? 'riga-vuota' : '')">
          <Column header="Giro">
            <template #body="{ data: g }"><span class="pallino" :style="{ background: g.colore || '#ccc' }"></span>{{ g.giro }} <Tag v-if="!g.attivo" value="chiuso" severity="secondary" /></template>
          </Column>
          <Column header="Sped." style="width: 5.5rem" class="num-col">
            <template #body="{ data: g }"><b>{{ g.nSped }}</b><span v-if="g.nSped && g.nGeo < g.nSped" class="attenzione" :title="`${g.nSped - g.nGeo} senza coordinate`"> ({{ g.nGeo }})</span></template>
          </Column>
          <Column header="Driver" style="width: 14rem">
            <template #body="{ data: g }">
              <Select :modelValue="g.idDriver" :options="driver" optionLabel="nome" optionValue="idUtente" filter showClear size="small" fluid
                :placeholder="g.driverDefault ? `predef.: ${g.driverDefault}` : 'nessuno'" @update:modelValue="v => cambiaDriver(g, v)" />
            </template>
          </Column>
          <Column header="Percorso" style="width: 13rem">
            <template #body="{ data: g }">
              <template v-if="g.stato">
                <Tag :value="STATO[g.stato]?.nome ?? g.stato" :severity="STATO[g.stato]?.sev ?? 'secondary'" />
                <span v-if="g.stato === 'FATTA'" class="nota"> {{ km(g.distanzaM) }} · {{ minuti(g.tempoS) }}<span v-if="g.nSequenza < g.nGeo" class="attenzione" title="Spedizioni cambiate dopo l'ottimizzazione: da rifare"> · da rifare</span></span>
                <i v-else-if="g.stato === 'RICHIESTA' || g.stato === 'IN_CORSO'" class="pi pi-spin pi-spinner nota"></i>
                <div v-if="g.stato === 'ERRORE'" class="attenzione piccolo">{{ g.errore }}</div>
              </template>
              <span v-else class="nota">—</span>
            </template>
          </Column>
          <Column header="" style="width: 8.5rem">
            <template #body="{ data: g }">
              <Button icon="pi pi-directions" text rounded size="small" title="Ottimizza con HERE" :disabled="!g.nGeo || g.stato === 'RICHIESTA' || g.stato === 'IN_CORSO' || lavoro" @click="ottimizza(g)" />
              <Button icon="pi pi-map" text rounded size="small" title="Vedi il percorso" :disabled="!g.idPiano" @click="apriPercorso(g)" />
              <Button icon="pi pi-history" text rounded size="small" title="Storico" @click="apriStorico(g)" />
            </template>
          </Column>
          <template #empty><span class="nota">Nessun giro con spedizioni per il giorno scelto.</span></template>
        </DataTable>
      </div>

      <div class="dettaglio">
        <div v-if="percorso" class="intestazione">
          <div>
            <b><span class="pallino" :style="{ background: percorso.piano.colore || '#ccc' }"></span>{{ percorso.piano.giro }}</b>
            <span class="nota"> · {{ percorso.piano.driver || 'senza driver' }}</span>
            <span v-if="percorso.piano.stato === 'FATTA'" class="nota"> · {{ consegne.length }} consegne, {{ km(percorso.piano.distanzaM) }}, {{ minuti(percorso.piano.tempoS) }} con le soste</span>
            <span v-else class="nota"> · {{ consegne.length }} spedizioni con coordinate, percorso non ancora ottimizzato</span>
          </div>
          <Button label="Excel" icon="pi pi-file-excel" size="small" text :disabled="percorso.piano.stato !== 'FATTA'" @click="esporta" />
        </div>
        <div v-else class="nota vuoto">Scegli un giro (icona mappa) per vedere il percorso.</div>
        <div ref="mapEl" class="mappa"></div>
        <div v-if="percorso" class="tappe">
          <table>
            <thead><tr><th>#</th><th>Barcode</th><th>Destinatario</th><th>Indirizzo</th><th>Arrivo</th><th>km</th></tr></thead>
            <tbody>
              <tr v-for="p in consegne" :key="p.idSpedizione" :class="{ scelta: puntoScelto === p.idSpedizione }" @click="evidenzia(p)">
                <td class="num">{{ p.sequenza ?? '' }}</td><td class="mono">{{ p.barcode }}</td><td>{{ p.destinatario }}</td>
                <td>{{ p.indirizzo }}<span class="nota"> {{ p.cap }} {{ p.localita }}</span></td>
                <td>{{ ora(p.arrivo) }}</td><td class="num">{{ p.kmProgressivi ?? '' }}</td>
              </tr>
              <tr v-if="ritorno" class="ritorno"><td></td><td colspan="3">Ritorno in filiale</td><td>{{ ora(ritorno.arrivo) }}</td><td class="num">{{ ritorno.kmProgressivi ?? '' }}</td></tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>

    <Dialog :visible="!!conferma" modal :header="conferma?.titolo" :style="{ width: '34rem' }" @update:visible="conferma = null">
      <p>{{ conferma?.testo }}</p>
      <template #footer>
        <Button label="Annulla" text @click="conferma = null" />
        <Button label="Conferma" @click="confermato" />
      </template>
    </Dialog>

    <Dialog :visible="!!storico" modal :header="storico ? `Storico ${storico.giro.giro}` : ''" :style="{ width: '40rem' }" @update:visible="storico = null">
      <DataTable v-if="storico" :value="storico.righe" size="small" stripedRows>
        <Column header="Quando" style="width: 9rem"><template #body="{ data: r }">{{ dataOra(r.dataOra) }}</template></Column>
        <Column field="campo" header="Cosa" style="width: 8rem" />
        <Column header="Prima → dopo"><template #body="{ data: r }">{{ r.campo === 'Driver' ? `${r.prima ?? '—'} → ${r.dopo ?? '—'}` : r.dopo }}</template></Column>
        <Column field="utente" header="Chi" style="width: 8rem" />
        <template #empty><span class="nota">Nessuna modifica registrata.</span></template>
      </DataTable>
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
.riepilogo { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.chip { border: 1px solid var(--p-surface-300); background: var(--p-surface-0); border-radius: 999px; padding: .2rem .7rem; font-size: .85rem; }
.chip.ok { color: #1a7a1a; border-color: #1a7a1a; }
.chip.attenzione { color: var(--p-orange-600); cursor: pointer; }
.chk { display: inline-flex; align-items: center; gap: .4rem; cursor: pointer; font-size: .9rem; }
.nota { color: var(--p-text-muted-color); font-size: .85rem; }
.attenzione { color: var(--p-orange-600); }
.piccolo { font-size: .78rem; }
.spazio { flex: 1; }
.mono { font-family: monospace; }
.pallino { display: inline-block; width: 11px; height: 11px; border-radius: 50%; border: 1px solid #999; margin-right: .35rem; }

.corpo { display: flex; gap: .75rem; flex: 1; min-height: 0; }
.griglia { flex: 1; min-width: 0; border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; display: flex; flex-direction: column; }
:deep(.p-datatable) { flex: 1; min-height: 0; display: flex; flex-direction: column; }
:deep(.num-col) { text-align: right; }
:deep(.riga-aperta) { outline: 2px solid #00a5cf; outline-offset: -2px; }
:deep(.riga-vuota) { opacity: .55; }
.dettaglio { flex: 1.1; min-width: 0; display: flex; flex-direction: column; gap: .35rem; }
.intestazione { display: flex; align-items: center; justify-content: space-between; gap: .5rem; flex-wrap: wrap; }
.vuoto { padding: .3rem 0; }
.mappa { flex: 1; min-height: 300px; border: 1px solid var(--p-surface-300); border-radius: 6px; z-index: 0; }
.tappe { max-height: 32%; overflow-y: auto; border: 1px solid var(--p-surface-200); border-radius: 6px; font-size: .82rem; }
.tappe table { width: 100%; border-collapse: collapse; }
.tappe th { text-align: left; padding: .25rem .4rem; background: var(--p-surface-50); position: sticky; top: 0; }
.tappe td { padding: .2rem .4rem; border-top: 1px solid var(--p-surface-100); cursor: pointer; }
.tappe td.num, .tappe th.num { text-align: right; }
.tappe tr.scelta td { background: #e3f2fd; }
.tappe tr.ritorno td { color: var(--p-text-muted-color); font-style: italic; }
@media (max-width: 1100px) {
  .pagina { height: auto; }
  .corpo { flex-direction: column; }
  .griglia { min-height: 20rem; }
  .mappa { height: 45vh; }
  .tappe { max-height: 20rem; }
}
</style>

<style>
.tappa span { display: flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 50%; color: #fff; font-weight: 700; font-size: 11px; border: 2px solid #fff; box-shadow: 0 1px 3px rgba(0,0,0,.45); }
.tappa-filiale span { display: flex; align-items: center; justify-content: center; width: 26px; height: 26px; border-radius: 6px; background: #333; color: #fff; font-size: 16px; border: 2px solid #fff; box-shadow: 0 1px 3px rgba(0,0,0,.45); }
</style>
