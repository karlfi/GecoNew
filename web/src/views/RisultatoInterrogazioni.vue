<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { useNavStore } from '../stores/nav'
import { parseAzioneQuery } from '../lib/parametri'
import { navDaVideata } from '../config/tabelle'
import Dialog from 'primevue/dialog'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import ContextMenu from 'primevue/contextmenu'
import Message from 'primevue/message'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Select from 'primevue/select'
import IconField from 'primevue/iconfield'
import InputIcon from 'primevue/inputicon'
import ProgressSpinner from 'primevue/progressspinner'
import { FilterMatchMode, FilterService } from '@primevue/core/api'
import { rigaExcel } from '../lib/esporta'

const props = defineProps({
  idQuery: { type: Number, default: null },
  sWhere: { type: String, default: '' },
  // valori dei segnaposto &[...] (pagina "Ricerca con parametri")
  valori: { type: Object, default: null }
})

const nav = useNavStore()
const toast = useToast()

const caricamento = ref(false)
const errore = ref('')
const titolo = ref('')
const descrizione = ref('')
const colonne = ref([])
const righe = ref([])
const righeFiltrate = ref(null)
const filters = ref({ global: { value: null, matchMode: FilterMatchMode.CONTAINS } })

// --- filtri di colonna per tipo. Testo: contiene (predefinito), inizia con, finisce con,
// uguale, diverso, vuoto, non vuoto. Numeri e date: uguale (predefinito), diverso, maggiore,
// minore, intervallo, vuoto, non vuoto. Il tipo si ricava dai valori della colonna; per
// vuoto e non vuoto il valore del filtro e' un segnaposto (senza valore PrimeVue lo ignora).
const tipi = ref({})
const eIsoData = v => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}(T|$)/.test(v)
function tipiColonne(cols, righe) {
  const t = {}
  for (const c of cols) {
    const v = righe.map(r => r[c]).filter(x => x != null && x !== '')
    t[c] = !v.length ? 'testo' : v.every(x => typeof x === 'number') ? 'numero' : v.every(eIsoData) ? 'data' : 'testo'
  }
  return t
}
// valore confrontabile: numero, oppure istante per le date (dal valore ISO o dalla casella data)
const norm = v => {
  if (v == null || v === '') return null
  if (typeof v === 'number') return v
  const s = String(v).trim()
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) { const d = new Date(s.length > 10 ? s : s + 'T00:00:00'); return isNaN(d) ? null : d.getTime() }
  const n = Number(s.replace(',', '.'))
  return isNaN(n) ? null : n
}
const giorno = t => new Date(t).setHours(0, 0, 0, 0)
// con un filtro data si confronta il giorno, senza l'orario che la cella puo' avere
const cfr = (v, f) => { const a = norm(v), b = norm(f); return { a: a != null && eIsoData(String(f).trim()) ? giorno(a) : a, b: b != null && eIsoData(String(f).trim()) ? giorno(b) : b } }
const vuota = v => v == null || `${v}`.trim() === ''
FilterService.register('vuoto', v => vuota(v))
FilterService.register('pieno', v => !vuota(v))
FilterService.register('ugualeN', (v, f) => { const { a, b } = cfr(v, f); return b == null ? true : a != null && a === b })
FilterService.register('diversoN', (v, f) => { const { a, b } = cfr(v, f); return b == null ? true : a == null || a !== b })
FilterService.register('maggiore', (v, f) => { const { a, b } = cfr(v, f); return b == null ? true : a != null && a > b })
FilterService.register('minore', (v, f) => { const { a, b } = cfr(v, f); return b == null ? true : a != null && a < b })
FilterService.register('intervallo', (v, f) => {
  if (!Array.isArray(f)) return true
  const da = cfr(v, f[0]), a = cfr(v, f[1])
  if (da.b == null && a.b == null) return true
  if (norm(v) == null) return false
  return (da.b == null || da.a >= da.b) && (a.b == null || a.a <= a.b)
})
const MODI_TESTO = [
  { label: 'contiene', value: FilterMatchMode.CONTAINS }, { label: 'inizia con', value: FilterMatchMode.STARTS_WITH },
  { label: 'finisce con', value: FilterMatchMode.ENDS_WITH }, { label: 'uguale', value: FilterMatchMode.EQUALS },
  { label: 'diverso', value: FilterMatchMode.NOT_EQUALS }, { label: 'vuoto', value: 'vuoto' }, { label: 'non vuoto', value: 'pieno' }
]
const MODI_NUMERO = [
  { label: 'uguale', value: 'ugualeN' }, { label: 'diverso', value: 'diversoN' }, { label: 'maggiore', value: 'maggiore' },
  { label: 'minore', value: 'minore' }, { label: 'intervallo', value: 'intervallo' }, { label: 'vuoto', value: 'vuoto' }, { label: 'non vuoto', value: 'pieno' }
]
const modiPer = c => tipi.value[c] === 'testo' ? MODI_TESTO : MODI_NUMERO
const modoPredefinito = c => tipi.value[c] === 'testo' ? FilterMatchMode.CONTAINS : 'ugualeN'
const tipoInput = c => tipi.value[c] === 'data' ? 'date' : tipi.value[c] === 'numero' ? 'number' : 'text'
function cambiaModo(filterModel, filterCallback) {
  const m = filterModel.matchMode
  if (m === 'vuoto' || m === 'pieno') filterModel.value = '*'
  else if (m === 'intervallo') filterModel.value = ['', '']
  else if (filterModel.value === '*' || Array.isArray(filterModel.value)) filterModel.value = null
  filterCallback()
}


// colonne speciali: query1#.., report1#.., web1#.., pagina1#.. = azioni del tasto destro
const RX_AZIONE = /^(query|report|web|pagina)(\d)#(.*)$/i

const visibili = computed(() =>
  colonne.value.filter(c => c.toLowerCase() !== 'color#' && !RX_AZIONE.test(c)))
const colonneAzione = computed(() => colonne.value.filter(c => RX_AZIONE.test(c)))
const colonnaColore = computed(() => colonne.value.find(c => c.toLowerCase() === 'color#'))

function initFiltri(cols) {
  const f = { global: { value: null, matchMode: FilterMatchMode.CONTAINS } }
  for (const c of cols) f[c] = { value: null, matchMode: modoPredefinito(c) }
  filters.value = f
}

async function carica() {
  errore.value = ''
  if (!props.idQuery) {
    errore.value = 'Parametri non validi: IdQuery mancante'
    return
  }
  caricamento.value = true
  try {
    const { data } = await api.post('/interrogazioni/esegui', {
      idQuery: props.idQuery,
      sWhere: props.sWhere,
      valori: props.valori ?? undefined
    })
    titolo.value = data.titolo
    descrizione.value = data.descrizione
    colonne.value = data.colonne
    righe.value = data.righe.map(arr =>
      Object.fromEntries(data.colonne.map((c, i) => [c, arr[i]])))
    tipi.value = tipiColonne(data.colonne, righe.value)
    initFiltri(data.colonne)
    righeFiltrate.value = null
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei dati'
  } finally {
    caricamento.value = false
  }
}

onMounted(carica)

// --- colore riga dal campo color# ---
function parseColore(v) {
  if (v == null || v === '') return null
  const s = String(v).trim()
  if (s.startsWith('#')) return s
  if (/^\d{1,3},\s*\d{1,3},\s*\d{1,3}$/.test(s)) return `rgb(${s})`
  if (/^\d+$/.test(s)) {
    // intero stile Delphi/InDe: byte order BGR
    const n = Number(s)
    return `rgb(${n & 0xFF},${(n >> 8) & 0xFF},${(n >> 16) & 0xFF})`
  }
  return s
}
function stileRiga(r) {
  if (!colonnaColore.value) return undefined
  const c = parseColore(r[colonnaColore.value])
  return c ? { background: c } : undefined
}

// --- formattazione celle (date ISO -> formato italiano) ---
function formatta(v) {
  if (v == null) return ''
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v)) {
    const d = new Date(v)
    if (isNaN(d)) return v
    const data = d.toLocaleDateString('it-IT')
    const ore = d.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })
    return ore === '00:00' ? data : `${data} ${ore}`
  }
  return v
}

// --- esportazione Excel (righe filtrate, solo colonne visibili) ---
const esportazione = ref(false)
async function esportaExcel() {
  esportazione.value = true
  try {
    const ExcelJS = await import('exceljs').then(m => m.default ?? m)
    const wb = new ExcelJS.Workbook()
    const ws = wb.addWorksheet((titolo.value || 'Export').slice(0, 31))
    const cols = visibili.value
    ws.addRow(cols)
    ws.getRow(1).font = { bold: true }
    const dati = righeFiltrate.value ?? righe.value
    for (const r of dati) rigaExcel(ws, cols.map(c => r[c] ?? ''))
    cols.forEach((c, i) => {
      ws.getColumn(i + 1).width = Math.min(45, Math.max(12, c.length + 4))
    })
    const buf = await wb.xlsx.writeBuffer()
    const blob = new Blob([buf], {
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    })
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `${(titolo.value || 'interrogazione').replace(/[^\w\- ]/g, '').trim() || 'export'}.xlsx`
    a.click()
    URL.revokeObjectURL(a.href)
  } finally {
    esportazione.value = false
  }
}

// --- menu del tasto destro ---
const cm = ref()
const rigaCm = ref(null)
const ICONE = {
  query: 'pi pi-table',
  report: 'pi pi-print',
  web: 'pi pi-external-link',
  pagina: 'pi pi-window-maximize'
}
const vociCm = computed(() => {
  if (!rigaCm.value) return []
  return colonneAzione.value
    .map(c => ({ valore: rigaCm.value[c], m: c.match(RX_AZIONE) }))
    .filter(x => x.valore)
    .map(x => ({
      label: x.m[3] || x.m[0],
      icon: ICONE[x.m[1].toLowerCase()],
      command: () => eseguiAzione(x.m[1].toLowerCase(), x.valore, x.m[3] || x.m[0])
    }))
})

function onRowContextMenu(ev) {
  rigaCm.value = ev.data
  if (colonneAzione.value.length) cm.value.show(ev.originalEvent)
}

// --- visore in dialog per report (PDF) e pagine web ---
const visore = ref({ visibile: false, titolo: '', src: '', urlEsterno: '', caricamento: false })
let blobCorrente = null

function apriEsterno() {
  if (visore.value.urlEsterno) window.open(visore.value.urlEsterno, '_blank')
}
function chiudiVisore() {
  visore.value.visibile = false
  if (blobCorrente) { URL.revokeObjectURL(blobCorrente); blobCorrente = null }
}

// Il report server non e' raggiungibile dai client: il PDF lo scarica l'API
// (proxy /api/report) e qui lo si mostra in un frame via blob URL.
async function apriReport(valore, etichetta) {
  visore.value = { visibile: true, titolo: etichetta, src: '', urlEsterno: '', caricamento: true }
  try {
    const { data } = await api.get('/report', {
      params: { src: valore },
      responseType: 'blob'
    })
    if (blobCorrente) URL.revokeObjectURL(blobCorrente)
    blobCorrente = URL.createObjectURL(data)
    visore.value.src = blobCorrente
  } catch (e) {
    chiudiVisore()
    // l'errore JSON arriva come blob: lo si decodifica per il messaggio
    let msg = 'Errore nella generazione del report'
    try { msg = JSON.parse(await e.response?.data?.text())?.errore ?? msg } catch {}
    toast.add({ severity: 'error', summary: etichetta, detail: msg, life: 5000 })
  } finally {
    visore.value.caricamento = false
  }
}

function eseguiAzione(tipo, valore, etichetta) {
  if (tipo === 'query') {
    // valore cella: "1020| and x.IdUtente=123" (numero secco prima del |)
    const { idQuery, sWhere } = parseAzioneQuery(valore)
    if (!idQuery) {
      toast.add({ severity: 'warn', summary: 'Query', detail: `Valore azione non valido: ${valore}`, life: 3000 })
      return
    }
    nav.drill({ tipo: 'interrogazioni', idQuery, sWhere })
    return
  }
  if (tipo === 'report') {
    // valore cella: "<nome>.fr3|par=valore|..." (URL composto dal ReportServer, lato API)
    apriReport(valore, etichetta)
    return
  }
  if (tipo === 'web') {
    // valore cella: URL pubblico completo -> frame nella pagina (+ apertura esterna)
    visore.value = { visibile: true, titolo: etichetta, src: valore, urlEsterno: valore, caricamento: false }
    return
  }
  if (tipo === 'pagina') {
    // valore cella: "Videata#Parametri" -> stesso routing delle voci di menu
    const [videata, ...resto] = valore.split('#')
    nav.drill(navDaVideata(videata, resto.join('#')))
    return
  }
}
</script>

<template>
  <div class="pagina-interrogazione">
    <div class="testata">
      <div class="testata-sinistra">
        <Button
          v-if="nav.puoTornare"
          icon="pi pi-arrow-left"
          text
          rounded
          title="Torna indietro"
          @click="nav.indietro()"
        />
        <div>
          <h2>{{ titolo || 'Interrogazione' }}</h2>
          <p v-if="descrizione" class="sottotitolo">{{ descrizione }}</p>
        </div>
      </div>
      <div class="testata-destra">
        <span v-if="righe.length" class="conta">
          {{ (righeFiltrate ?? righe).length }} righe
        </span>
        <IconField v-if="righe.length">
          <InputIcon class="pi pi-search" />
          <InputText v-model="filters.global.value" placeholder="Filtra ovunque..." size="small" />
        </IconField>
        <Button
          v-if="righe.length"
          label="Excel"
          icon="pi pi-file-excel"
          severity="success"
          size="small"
          :loading="esportazione"
          @click="esportaExcel"
        />
      </div>
    </div>

    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div v-if="caricamento" class="centro">
      <ProgressSpinner />
    </div>

    <DataTable
      v-else-if="colonne.length"
      :value="righe"
      v-model:filters="filters"
      filterDisplay="row"
      :globalFilterFields="visibili"
      :rowStyle="stileRiga"
      paginator
      :rows="50"
      :rowsPerPageOptions="[20, 50, 100, 500]"
      sortMode="single"
      removableSort
      scrollable
      scrollHeight="flex"
      size="small"
      stripedRows
      showGridlines
      @row-contextmenu="onRowContextMenu"
      @filter="ev => righeFiltrate = ev.filteredValue"
      class="griglia"
    >
      <Column
        v-for="c in visibili"
        :key="c"
        :field="c"
        :header="c"
        sortable
        :showFilterMenu="false"
      >
        <template #body="{ data }">{{ formatta(data[c]) }}</template>
        <template #filter="{ filterModel, filterCallback }">
          <div class="filtro-cella">
            <select v-model="filterModel.matchMode" class="modo-filtro" :title="'Colonna di tipo ' + (tipi[c] || 'testo') + ': come filtrare'"
              @change="cambiaModo(filterModel, filterCallback)">
              <option v-for="m in modiPer(c)" :key="m.value" :value="m.value">{{ m.label }}</option>
            </select>
            <template v-if="filterModel.matchMode === 'intervallo'">
              <InputText v-model="filterModel.value[0]" :type="tipoInput(c)" step="any" placeholder="da" @input="filterCallback()" size="small" class="filtro-colonna corto" />
              <InputText v-model="filterModel.value[1]" :type="tipoInput(c)" step="any" placeholder="a" @input="filterCallback()" size="small" class="filtro-colonna corto" />
            </template>
            <InputText v-else-if="filterModel.matchMode !== 'vuoto' && filterModel.matchMode !== 'pieno'"
              v-model="filterModel.value" :type="tipoInput(c)" step="any" @input="filterCallback()" size="small" class="filtro-colonna" />
          </div>
        </template>
      </Column>
      <template #empty>Nessun dato trovato</template>
    </DataTable>

    <ContextMenu ref="cm" :model="vociCm" />

    <!-- visore report PDF / pagina web -->
    <Dialog
      :visible="visore.visibile"
      @update:visible="v => { if (!v) chiudiVisore() }"
      modal maximizable
      :header="visore.titolo"
      :style="{ width: '80vw', height: '85vh' }"
      contentClass="visore-contenuto"
    >
      <div v-if="visore.caricamento" class="centro"><ProgressSpinner /></div>
      <iframe v-else-if="visore.src" :src="visore.src" class="visore-frame" />
      <template #footer>
        <Button
          v-if="visore.urlEsterno"
          label="Apri in nuova scheda" icon="pi pi-external-link" text
          @click="apriEsterno"
        />
        <Button label="Chiudi" @click="chiudiVisore" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina-interrogazione {
  display: flex;
  flex-direction: column;
  height: 100%;
  gap: .5rem;
}
.testata {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
}
.testata-sinistra {
  display: flex;
  align-items: center;
  gap: .25rem;
}
.testata h2 { margin: 0; }
.sottotitolo {
  margin: .15rem 0 0;
  color: #666;
  font-size: .9rem;
}
.testata-destra {
  display: flex;
  align-items: center;
  gap: .75rem;
}
.conta {
  color: #666;
  font-size: .85rem;
  white-space: nowrap;
}
.centro {
  display: flex;
  justify-content: center;
  padding: 3rem;
}
.griglia {
  flex: 1;
  min-height: 0;
}
.griglia :deep(.p-datatable-tbody > tr > td) {
  padding: .35rem .6rem;
  font-size: .85rem;
}
.griglia :deep(.p-datatable-thead > tr > th) {
  padding: .45rem .6rem;
  font-size: .85rem;
}
.filtro-colonna {
  width: 100%;
  min-width: 5rem;
}
:global(.visore-contenuto) {
  height: 100%;
  display: flex;
  flex-direction: column;
}
.visore-frame {
  flex: 1;
  width: 100%;
  height: 100%;
  min-height: 60vh;
  border: 0;
}
.filtro-cella { display: flex; align-items: center; gap: .25rem; }
.modo-filtro { flex: none; font: inherit; font-size: .78rem; padding: .25rem .2rem; border: 1px solid var(--p-inputtext-border-color); border-radius: 6px; background: var(--p-inputtext-background); color: var(--p-inputtext-color); }
.filtro-colonna { min-width: 5rem; flex: 1; }
.filtro-colonna.corto { min-width: 4rem; }
.filtro-colonna[type="date"] { min-width: 8.5rem; }
</style>
