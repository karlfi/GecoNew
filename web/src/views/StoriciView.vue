<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount } from 'vue'
import api from '../api'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
import Checkbox from 'primevue/checkbox'
import Button from 'primevue/button'
import Message from 'primevue/message'

// Dati storici Speedy: consegne NEXIVE (ott 2019 - set 2020) sulla mappa.
// Si sceglie filiale e giorno, i punti di consegna si colorano per postino;
// selezionando uno o piu' postini la mappa mostra solo i loro punti uniti in
// sequenza oraria e la tabella laterale elenca il percorso orario.

const errore = ref('')
const caricamento = ref(false)
const filiali = ref([])
const filiale = ref(null)      // riga di /storici/init
const giorno = ref(null)       // Date
const soloConsegne = ref(true)
const righe = ref([])          // eventi del giorno (raw)
const selezione = ref({})      // postino -> bool

let map = null, resizeObs = null, puntiLayer = null, lineeLayer = null, canvas = null
const markerById = new Map()
const mapEl = ref(null)

const minData = computed(() => filiale.value ? new Date(filiale.value.dal) : null)
const maxData = computed(() => filiale.value ? new Date(filiale.value.al) : null)

// colore stabile per postino (angolo aureo, indipendente dai filtri)
const coloriPostino = computed(() => {
  const nomi = [...new Set(righe.value.map(r => r.postino ?? '?'))].sort()
  const m = {}
  nomi.forEach((p, i) => { m[p] = `hsl(${Math.round(i * 137.508) % 360}, 68%, 40%)` })
  return m
})

const righeFiltrate = computed(() =>
  soloConsegne.value ? righe.value.filter(r => r.consegnato) : righe.value)

// l'orario a mezzanotte esatta e' un "senza orario" dell'export NEXIVE
const haOrario = r => r.orario && !r.orario.endsWith('00:00:00')
const ora = r => haOrario(r) ? r.orario.slice(11) : '—'
const nomePostino = p => (p ?? '?').replace(/_\d+$/, '')

const drivers = computed(() => {
  const gruppi = new Map()
  for (const r of righeFiltrate.value) {
    const key = r.postino ?? '?'
    if (!gruppi.has(key)) gruppi.set(key, [])
    gruppi.get(key).push(r)
  }
  return [...gruppi.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([postino, punti]) => {
    const conOrario = punti.filter(haOrario).sort((a, b) => a.orario.localeCompare(b.orario))
    return {
      postino,
      nome: nomePostino(postino),
      colore: coloriPostino.value[postino],
      punti,
      conOrario,
      senzaOrario: punti.length - conOrario.length,
      oraMin: conOrario.length ? conOrario[0].orario.slice(11, 16) : '—',
      oraMax: conOrario.length ? conOrario[conOrario.length - 1].orario.slice(11, 16) : '—'
    }
  })
})

const selezionati = computed(() => drivers.value.filter(d => selezione.value[d.postino]))
const visibili = computed(() => selezionati.value.length ? selezionati.value : drivers.value)

// dal 2020-01 l'export NEXIVE non riporta piu' l'ora del recapito: in quei
// giorni niente sequenza ne' percorso, restano i punti per driver
const senzaOrari = computed(() =>
  righeFiltrate.value.length > 0 && righeFiltrate.value.every(r => !haOrario(r)))

// tabella laterale: sequenza oraria dei postini selezionati
const sequenza = computed(() => {
  const out = []
  for (const d of selezionati.value) {
    d.conOrario.forEach((r, i) => out.push({ ...r, seq: i + 1, colore: d.colore, nome: d.nome }))
    d.punti.filter(r => !haOrario(r)).forEach(r => out.push({ ...r, seq: '—', colore: d.colore, nome: d.nome }))
  }
  return out
})

onMounted(async () => {
  map = L.map(mapEl.value, { center: [43.5, 11.0], zoom: 8, preferCanvas: true })
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19, attribution: '© OpenStreetMap'
  }).addTo(map)
  canvas = L.canvas({ padding: 0.3 })
  lineeLayer = L.layerGroup().addTo(map)
  puntiLayer = L.layerGroup().addTo(map)
  resizeObs = new ResizeObserver(() => map && map.invalidateSize())
  resizeObs.observe(mapEl.value)
  setTimeout(() => map && map.invalidateSize(), 200)
  try {
    const { data } = await api.get('/storici/init')
    filiali.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle filiali storiche'
  }
})
onBeforeUnmount(() => {
  if (resizeObs) { resizeObs.disconnect(); resizeObs = null }
  if (map) { map.remove(); map = null }
})

// data locale -> yyyy-MM-dd senza sorprese di fuso orario
const fmtData = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

watch(filiale, f => {
  if (!f) return
  // riporta il giorno dentro il periodo coperto dalla filiale
  if (!giorno.value || giorno.value < new Date(f.dal) || giorno.value > new Date(f.al)) {
    giorno.value = new Date(f.al)
  } else {
    carica()
  }
})
watch(giorno, () => carica())

let reqSeq = 0
async function carica() {
  if (!filiale.value || !giorno.value) return
  const mia = ++reqSeq
  caricamento.value = true
  errore.value = ''
  try {
    const { data } = await api.get('/storici/consegne', {
      params: { filiale: filiale.value.filiale, data: fmtData(giorno.value) }
    })
    if (mia !== reqSeq) return   // superata da una richiesta piu' recente
    righe.value = data
    selezione.value = {}
  } catch (e) {
    if (mia !== reqSeq) return
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle consegne'
  } finally {
    if (mia === reqSeq) caricamento.value = false
  }
}

watch(visibili, ridisegna)

function ridisegna() {
  if (!map) return
  puntiLayer.clearLayers()
  lineeLayer.clearLayers()
  markerById.clear()
  const conLinee = selezionati.value.length > 0
  const bounds = []
  for (const d of visibili.value) {
    for (const r of d.punti) {
      bounds.push([r.lat, r.lng])
      const m = L.circleMarker([r.lat, r.lng], {
        renderer: canvas, radius: conLinee ? 5 : 4, color: d.colore,
        weight: 1, fillColor: d.colore, fillOpacity: r.consegnato ? 0.85 : 0.3
      }).bindTooltip(
        `<b>${d.nome}</b> — ${ora(r)}<br>${r.indirizzo ?? ''}<br>${r.cap ?? ''} ${r.localita ?? ''}` +
        `<br>${r.esito}${r.consegnato ? '' : ' ⚠'}${r.servizio ? '<br><i>' + r.servizio + '</i>' : ''}`
      )
      m.addTo(puntiLayer)
      markerById.set(r.id, m)
    }
    // percorso del postino: punti con orario uniti in sequenza di consegna
    if (conLinee && d.conOrario.length > 1) {
      L.polyline(d.conOrario.map(r => [r.lat, r.lng]), {
        renderer: canvas, color: d.colore, weight: 2, opacity: 0.6
      }).addTo(lineeLayer)
    }
  }
  if (bounds.length) map.fitBounds(bounds, { padding: [30, 30], maxZoom: 15 })
}

function toggleDriver(d) { selezione.value = { ...selezione.value, [d.postino]: !selezione.value[d.postino] } }
function tutti(val) {
  const s = {}
  if (val) for (const d of drivers.value) s[d.postino] = true
  selezione.value = s
}

function vaiAlPunto(r) {
  const m = markerById.get(r.id)
  if (!m) return
  map.setView(m.getLatLng(), Math.max(map.getZoom(), 15))
  m.openTooltip()
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Dati storici Speedy — consegne NEXIVE</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="controlli">
      <label>Filiale
        <Select v-model="filiale" :options="filiali" optionLabel="filiale" filter
          placeholder="— scegli —" class="sel-filiale" :loading="!filiali.length && !errore">
          <template #option="{ option }">
            <div class="opt-filiale">
              <b>{{ option.filiale }}</b>
              <small>{{ option.dal }} → {{ option.al }} · {{ option.eventi.toLocaleString('it-IT') }} eventi</small>
            </div>
          </template>
        </Select>
      </label>
      <label>Giorno
        <DatePicker v-model="giorno" dateFormat="dd/mm/yy" showIcon
          :minDate="minData" :maxDate="maxData" :disabled="!filiale" />
      </label>
      <label class="chk"><Checkbox v-model="soloConsegne" binary /> solo consegne effettuate</label>
      <span v-if="caricamento" class="stato"><i class="pi pi-spin pi-spinner"></i> caricamento…</span>
      <span v-else-if="righe.length" class="stato">
        {{ righeFiltrate.length.toLocaleString('it-IT') }} punti · {{ drivers.length }} driver
      </span>
    </div>

    <div class="corpo">
      <div ref="mapEl" class="mappa"></div>

      <aside class="pannello">
        <div class="pannello-titolo">
          Driver <span class="conteggio">{{ drivers.length }}</span>
          <span class="azioni-driver">
            <Button label="tutti" size="small" text @click="tutti(true)" :disabled="!drivers.length" />
            <Button label="nessuno" size="small" text @click="tutti(false)" :disabled="!selezionati.length" />
          </span>
        </div>
        <div class="lista-driver">
          <div v-for="d in drivers" :key="d.postino" class="driver" @click="toggleDriver(d)">
            <Checkbox :modelValue="!!selezione[d.postino]" binary @click.stop @update:modelValue="toggleDriver(d)" />
            <span class="pallino" :style="{ background: d.colore }" />
            <span class="nome">{{ d.nome }}</span>
            <span class="dett">{{ d.punti.length }} punti{{ d.conOrario.length ? ` · ${d.oraMin}–${d.oraMax}` : '' }}</span>
          </div>
          <p v-if="!drivers.length && !caricamento" class="vuoto">Scegli filiale e giorno per vedere le consegne.</p>
        </div>
      </aside>
    </div>

    <Message v-if="senzaOrari" severity="warn" :closable="false">
      In questo giorno l'export NEXIVE non riporta l'orario di consegna (succede da gennaio 2020 in poi):
      i punti sono visibili per driver, ma senza sequenza oraria né percorso.
    </Message>

    <div v-if="selezionati.length" class="tab">
      <div class="tab-titolo">
        Sequenza di consegna — {{ selezionati.map(d => d.nome).join(', ') }}
        <span class="conteggio">{{ sequenza.length }} punti</span>
      </div>
      <DataTable :value="sequenza" scrollable scrollHeight="320px" size="small" stripedRows
        @row-click="e => vaiAlPunto(e.data)" :rowHover="true">
        <Column header="#" style="width: 3.5rem">
          <template #body="{ data }">
            <span class="seq" :style="{ background: data.colore }">{{ data.seq }}</span>
          </template>
        </Column>
        <Column v-if="selezionati.length > 1" field="nome" header="Driver" style="width: 10rem" />
        <Column header="Orario" style="width: 6.5rem">
          <template #body="{ data }">{{ ora(data) }}</template>
        </Column>
        <Column field="indirizzo" header="Indirizzo" />
        <Column field="localita" header="Località" style="width: 12rem" />
        <Column field="esito" header="Esito" style="width: 11rem">
          <template #body="{ data }">
            <span :class="{ anomalia: !data.consegnato }">{{ data.esito === 'C' ? 'Consegnato' : data.esito }}</span>
          </template>
        </Column>
        <Column field="servizio" header="Servizio" style="width: 14rem" />
      </DataTable>
    </div>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.75rem; }
.titolo { margin: 0; }
.controlli { display: flex; align-items: flex-end; gap: 1.25rem; flex-wrap: wrap; font-size: .9rem; }
.controlli > label { display: flex; flex-direction: column; gap: .25rem; color: #555; }
.controlli .chk { flex-direction: row; align-items: center; gap: .4rem; cursor: pointer; padding-bottom: .5rem; }
.sel-filiale { min-width: 22rem; }
.opt-filiale { display: flex; flex-direction: column; }
.opt-filiale small { color: var(--p-text-muted-color); }
.stato { color: var(--p-text-muted-color); padding-bottom: .6rem; }

.corpo { display: flex; gap: 1rem; align-items: stretch; }
.mappa { flex: 1; height: 62vh; min-height: 420px; border: 1px solid var(--p-surface-300); border-radius: 6px; z-index: 0; }
.pannello { flex: 0 0 320px; border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; display: flex; flex-direction: column; }
.pannello-titolo { background: #00a5cf; color: #fff; padding: .4rem .75rem; font-weight: 600; font-size: .9rem; display: flex; align-items: center; gap: .5rem; }
.pannello-titolo .conteggio { font-weight: 400; opacity: .9; font-size: .8rem; flex: 1; }
.azioni-driver :deep(.p-button) { color: #fff; padding: 0 .4rem; }
.lista-driver { overflow-y: auto; flex: 1; padding: .25rem 0; }
.driver { display: flex; align-items: center; gap: .5rem; padding: .3rem .6rem; cursor: pointer; font-size: .85rem; }
.driver:hover { background: var(--p-surface-100); }
.driver .nome { font-weight: 600; }
.driver .dett { margin-left: auto; color: var(--p-text-muted-color); font-size: .75rem; white-space: nowrap; }
.pallino { display: inline-block; width: 12px; height: 12px; border-radius: 50%; border: 1px solid rgba(0,0,0,.35); flex: 0 0 12px; }
.vuoto { color: #888; font-size: .85rem; padding: .75rem; }

.tab { border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; }
.tab-titolo { background: var(--p-surface-50); padding: .4rem .75rem; font-weight: 600; font-size: .9rem; border-bottom: 1px solid var(--p-surface-200); display: flex; gap: .5rem; align-items: center; }
.tab-titolo .conteggio { font-weight: 400; color: var(--p-text-muted-color); font-size: .8rem; }
.seq { display: inline-block; min-width: 1.6rem; text-align: center; color: #fff; border-radius: 999px; font-size: .75rem; font-weight: 700; padding: .1rem .3rem; }
.anomalia { color: #c0392b; }
:deep(.p-datatable-tbody > tr) { cursor: pointer; }
</style>
