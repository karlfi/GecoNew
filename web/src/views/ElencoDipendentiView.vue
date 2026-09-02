<script setup>
// Elenco Dipendenti: stessa griglia delle interrogazioni (query e where dal
// campo Parametri della voce di menu, tasto destro, colore riga da color#,
// filtri e ordinamento), con in piu' la colonna "Stato" modificabile.
//
// E' una pagina a se' e non una variante di RisultatoInterrogazioni perche'
// quella videata la condividiamo con tweb: la voce di menu resta
// Videata=RisultatoInterrogazioni per il vecchio programma, mentre qui si
// arriva dal campo Link (/elenco-dipendenti), che tweb non legge.
//
// Dalla griglia si cambia solo lo stato: ogni altra modifica si fa entrando
// nella scheda del dipendente (tasto destro -> Scheda Utente).
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
import { FilterMatchMode } from '@primevue/core/api'

const props = defineProps({
  idQuery: { type: Number, default: null },
  sWhere: { type: String, default: '' }
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

// colonne speciali: query1#.., report1#.., web1#.., pagina1#.. = azioni del tasto destro
const RX_AZIONE = /^(query|report|web|pagina)(\d)#(.*)$/i

const visibili = computed(() =>
  colonne.value.filter(c => c.toLowerCase() !== 'color#' && !RX_AZIONE.test(c)))
const colonneAzione = computed(() => colonne.value.filter(c => RX_AZIONE.test(c)))
const colonnaColore = computed(() => colonne.value.find(c => c.toLowerCase() === 'color#'))

function initFiltri(cols) {
  const f = { global: { value: null, matchMode: FilterMatchMode.CONTAINS } }
  for (const c of cols) f[c] = { value: null, matchMode: FilterMatchMode.CONTAINS }
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
      sWhere: props.sWhere
    })
    titolo.value = data.titolo
    descrizione.value = data.descrizione
    colonne.value = data.colonne
    initFiltri(data.colonne)
    righe.value = data.righe.map(arr =>
      Object.fromEntries(data.colonne.map((c, i) => [c, arr[i]])))
    righeFiltrate.value = null
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei dati'
  } finally {
    caricamento.value = false
  }
}

onMounted(carica)

// --- colonna "Stato": l'unica modificabile dalla griglia ---
// I valori ammessi sono i quattro usati in azienda; li ricontrolla anche la
// stored, cosi' la colonna non si sporca nemmeno se la chiamata arrivasse da
// fuori questa pagina.
const STATI = ['SI', 'da archiviare', 'da togliere', 'CESSATO']
const colonnaStato = computed(() =>
  colonne.value.find(c => c.toLowerCase() === 'stato'))
const colonnaIdUtente = computed(() =>
  colonne.value.find(c => c.toLowerCase() === 'idutente'))
// senza IdUtente non si saprebbe chi aggiornare: la colonna resta di sola lettura
const statoModificabile = computed(() => !!colonnaStato.value && !!colonnaIdUtente.value)

const classeStato = v => {
  const s = `${v ?? ''}`.trim().toLowerCase()
  return s === 'si' ? 'stato-si'
    : s === 'da archiviare' ? 'stato-archiviare'
    : s === 'da togliere' ? 'stato-togliere'
    : s === 'cessato' ? 'stato-cessato' : ''
}

async function salvaStato(e) {
  const { data, newValue } = e
  const campo = colonnaStato.value
  const precedente = data[campo]
  if (`${precedente ?? ''}` === `${newValue ?? ''}`) return
  data[campo] = newValue
  try {
    await api.post('/hr/utente-stato', {
      idUtente: data[colonnaIdUtente.value],
      stato: newValue || null
    })
  } catch (err) {
    data[campo] = precedente          // rimette il valore di prima
    toast.add({
      severity: 'error', summary: 'Stato non salvato',
      detail: err.response?.data?.errore ?? 'Errore imprevisto', life: 5000
    })
  }
}

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
    for (const r of dati) ws.addRow(cols.map(c => valoreExcel(r[c])))
    cols.forEach((c, i) => {
      ws.getColumn(i + 1).width = Math.min(45, Math.max(12, c.length + 4))
    })
    const buf = await wb.xlsx.writeBuffer()
    const blob = new Blob([buf], {
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    })
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `${(titolo.value || 'dipendenti').replace(/[^\w\- ]/g, '').trim() || 'export'}.xlsx`
    a.click()
    URL.revokeObjectURL(a.href)
  } finally {
    esportazione.value = false
  }
}
function valoreExcel(v) {
  if (v == null) return ''
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v)) {
    const d = new Date(v)
    return isNaN(d) ? v : d
  }
  return v
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
          <h2>{{ titolo || 'Elenco Dipendenti' }}</h2>
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
      :editMode="statoModificabile ? 'cell' : undefined"
      @cell-edit-complete="salvaStato"
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
        <template #body="{ data }">
          <span v-if="statoModificabile && c === colonnaStato" :class="['pill', classeStato(data[c])]">
            {{ data[c] || '—' }}
          </span>
          <template v-else>{{ formatta(data[c]) }}</template>
        </template>
        <template v-if="statoModificabile && c === colonnaStato" #editor="{ data, field }">
          <Select
            v-model="data[field]" :options="STATI" showClear
            placeholder="—" size="small" fluid autofocus
          >
            <template #option="{ option }">
              <span :class="['pill', classeStato(option)]">{{ option }}</span>
            </template>
          </Select>
        </template>
        <template #filter="{ filterModel, filterCallback }">
          <InputText
            v-model="filterModel.value"
            @input="filterCallback()"
            size="small"
            class="filtro-colonna"
          />
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

/* stati del dipendente: stessi colori del foglio da cui nasce questo elenco */
.pill {
  display: inline-block;
  padding: .1rem .5rem;
  border-radius: 10px;
  font-size: .82rem;
  line-height: 1.35;
  white-space: nowrap;
  /* le righe hanno gia' un colore loro (campo color# della query): senza bordo
     il chip "da archiviare", che e' dello stesso salmone, sparirebbe dentro */
  border: 1px solid rgba(0, 0, 0, .22);
}
.stato-si         { background: #0f7b5f; color: #fff; font-weight: 600; }
.stato-archiviare { background: #f4c7b8; color: #6b2b13; }
.stato-togliere   { background: #fce8b2; color: #6b5300; }
.stato-cessato    { background: #b71c1c; color: #fff; font-weight: 600; }
</style>
