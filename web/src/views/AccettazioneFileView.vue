<script setup>
import { ref, computed, watch, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { parseParametriComando } from '../lib/parametri'
import Select from 'primevue/select'
import Button from 'primevue/button'
import Checkbox from 'primevue/checkbox'
import InputText from 'primevue/inputtext'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Dialog from 'primevue/dialog'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Accettazione da file: replica della videata legacy "AccettazioneDaFile[Famiglia]".
// Clienti da ElencoClienti, famiglie da ElencoFamiglie, tracciati da FILE_TRACCIATO;
// il file viene letto nel browser, messo in staging su FILE_LOAD e caricato con la
// stored legacy LoadFromFile. Il tipo di tracciato viene riconosciuto in automatico
// confrontando separatore e numero colonne di ogni riga.

const props = defineProps({ parametri: { type: String, default: '' } })
const codFamigliaParam = (parseParametriComando(props.parametri).CodFamiglia ?? '')
  .replace(/^"|"$/g, '').trim()

const toast = useToast()
const errore = ref('')
const clienti = ref([])
const cliente = ref(null)
const famiglie = ref([])
const famiglia = ref(null)
const prodotti = ref([])
const prodotto = ref(null)
const tracciati = ref([])
const tracciato = ref(null)

const nomeFile = ref('')
const righe = ref([])
const riconosciuti = ref([])      // tracciati compatibili col file
const soloVerifica = ref(false)
const caricamento = ref(false)
const esito = ref(null)           // risposta del POST
const trascina = ref(false)
const fileInput = ref(null)

// popup di ricerca fine
const ricercaVisibile = ref(false)
const ricercaTesto = ref('')
const ricercaRighe = ref([])
const ricercaInCorso = ref(false)

onMounted(async () => {
  try {
    const { data } = await api.get('/accettazione/init', {
      params: { codFamiglia: codFamigliaParam || undefined }
    })
    clienti.value = data.clienti
    tracciati.value = data.tracciati
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento iniziale'
  }
})

watch(cliente, async c => {
  famiglie.value = []; famiglia.value = null
  prodotti.value = []; prodotto.value = null
  esito.value = null
  if (!c) return
  try {
    const { data } = await api.get('/accettazione/famiglie', { params: { idCliente: c.IdCliente } })
    famiglie.value = data
    famiglia.value =
      data.find(f => f.Valore === codFamigliaParam) ?? (data.length === 1 ? data[0] : null)
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Famiglie', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  }
})

watch(famiglia, async f => {
  prodotti.value = []; prodotto.value = null
  if (!f || !cliente.value) return
  try {
    const { data } = await api.get('/accettazione/prodotti', {
      params: { idCliente: cliente.value.IdCliente, codFamiglia: f.Valore }
    })
    prodotti.value = data
    if (data.length === 1) prodotto.value = data[0]
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Prodotti', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  }
})

// tracciati proposti: generici + quelli legati al cliente scelto
const tracciatiVisibili = computed(() =>
  tracciati.value.filter(t => !t.idCliente || t.idCliente === cliente.value?.IdCliente))

// --- lettura del file nel browser ---
async function leggiFile(file) {
  if (!file) return
  const buf = await file.arrayBuffer()
  let testo
  try {
    testo = new TextDecoder('utf-8', { fatal: true }).decode(buf)
  } catch {
    // i file legacy sono spesso ANSI (accentate) -> ripiego windows-1252
    testo = new TextDecoder('windows-1252').decode(buf)
  }
  const tutte = testo.split(/\r\n|\n|\r/)
  while (tutte.length && tutte[tutte.length - 1].trim() === '') tutte.pop()
  if (!tutte.length) {
    toast.add({ severity: 'warn', summary: 'File', detail: 'Il file è vuoto', life: 3000 })
    return
  }
  nomeFile.value = file.name
  righe.value = tutte
  esito.value = null
  riconosci()
}
function onFile(e) { leggiFile(e.target.files[0]); e.target.value = '' }
function onDrop(e) { trascina.value = false; leggiFile(e.dataTransfer.files[0]) }

// --- autoriconoscimento del tracciato: ogni riga (fuori intestazione/footer)
// deve produrre esattamente "colonne" campi col separatore del tracciato ---
function compatibile(t) {
  if (!t.separatore || !t.colonne) return false
  const da = t.intestazione, a = righe.value.length - t.footer
  if (a - da < 1) return false
  const campione = righe.value.slice(da, Math.min(a, da + 80))
  return campione.every(r => r.split(t.separatore).length === t.colonne)
}
function riconosci() {
  riconosciuti.value = tracciatiVisibili.value.filter(compatibile)
  if (riconosciuti.value.length === 1) {
    tracciato.value = riconosciuti.value[0]
    toast.add({ severity: 'info', summary: 'Tracciato riconosciuto', detail: riconosciuti.value[0].tracciato, life: 3000 })
  } else if (!riconosciuti.value.some(t => t.idTracciato === tracciato.value?.idTracciato)) {
    tracciato.value = null
  }
}
watch(tracciatiVisibili, () => { if (righe.value.length) riconosci() })

// --- ricerca fine (popup) ---
let timerRicerca = null
watch(ricercaTesto, q => {
  clearTimeout(timerRicerca)
  timerRicerca = setTimeout(async () => {
    if (!q || q.trim().length < 2) { ricercaRighe.value = []; return }
    ricercaInCorso.value = true
    try {
      const { data } = await api.get('/accettazione/clienti-ricerca', {
        params: { q, codFamiglia: codFamigliaParam || undefined }
      })
      ricercaRighe.value = data
    } catch { ricercaRighe.value = [] }
    finally { ricercaInCorso.value = false }
  }, 350)
})
function scegliDaRicerca(r) {
  ricercaVisibile.value = false
  ricercaTesto.value = ''
  ricercaRighe.value = []
  let c = clienti.value.find(x => x.IdCliente === r.idCliente)
  if (!c) {
    c = { IdCliente: r.idCliente, RagioneSociale: r.ragioneSociale }
    clienti.value = [...clienti.value, c].sort((a, b) => a.RagioneSociale.localeCompare(b.RagioneSociale))
  }
  cliente.value = c
}

const puoCaricare = computed(() =>
  cliente.value && tracciato.value && righe.value.length > 0
  && (soloVerifica.value || prodotto.value))

async function carica() {
  caricamento.value = true
  esito.value = null
  try {
    const { data } = await api.post('/accettazione/carica', {
      idCliente: cliente.value.IdCliente,
      idProdotto: prodotto.value?.idProdotto ?? 0,
      idTracciato: tracciato.value.idTracciato,
      nomeFile: nomeFile.value,
      soloVerifica: soloVerifica.value,
      righe: righe.value
    })
    esito.value = data
    if (data.ok && !soloVerifica.value) {
      // file caricato: pronta per il successivo, mantengo cliente e prodotto
      righe.value = []; nomeFile.value = ''; riconosciuti.value = []
    }
  } catch (e) {
    esito.value = { ok: false, result: e.response?.data?.errore ?? 'Errore imprevisto' }
  } finally {
    caricamento.value = false
  }
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Accettazione da file{{ codFamigliaParam ? ` — famiglia ${codFamigliaParam}` : '' }}</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Cliente e prodotto</div>
      <div class="griglia">
        <label class="span2">Cliente *
          <div class="riga-cliente">
            <Select v-model="cliente" :options="clienti" optionLabel="RagioneSociale" filter fluid
              placeholder="— scegli il cliente —" :loading="!clienti.length && !errore" />
            <Button label="Ricerca" icon="pi pi-search" outlined @click="ricercaVisibile = true" />
          </div>
        </label>
        <label>Famiglia *
          <Select v-model="famiglia" :options="famiglie" optionLabel="Nome" fluid
            :disabled="!cliente" :placeholder="cliente ? '— scegli —' : 'prima il cliente'" />
        </label>
        <label>Prodotto {{ soloVerifica ? '' : '*' }}
          <Select v-model="prodotto" :options="prodotti" optionLabel="prodotto" fluid
            :disabled="!famiglia" :placeholder="famiglia ? (prodotti.length ? '— scegli —' : 'nessun prodotto abilitato') : 'prima la famiglia'" />
        </label>
      </div>
    </section>

    <section class="card">
      <div class="card-titolo">File da caricare</div>
      <div class="corpo">
        <div class="dropzone" :class="{ attiva: trascina }"
          @dragover.prevent="trascina = true" @dragleave="trascina = false" @drop.prevent="onDrop"
          @click="fileInput.click()">
          <input ref="fileInput" type="file" hidden @change="onFile" />
          <i class="pi pi-file-import" style="font-size: 1.5rem"></i>
          <span v-if="nomeFile"><b>{{ nomeFile }}</b> — {{ righe.length.toLocaleString('it-IT') }} righe · clicca o trascina per cambiare</span>
          <span v-else>Trascina qui il file, o clicca per sceglierlo</span>
        </div>

        <div v-if="righe.length" class="riconoscimento">
          <span v-if="riconosciuti.length === 1">Tracciato riconosciuto:</span>
          <span v-else-if="riconosciuti.length > 1">Tracciati compatibili con il file:</span>
          <span v-else>Nessun tracciato riconosciuto automaticamente:</span>
          <Tag v-for="t in riconosciuti" :key="t.idTracciato"
            :severity="tracciato?.idTracciato === t.idTracciato ? 'success' : 'secondary'"
            :value="t.tracciato" class="tag-tracciato" @click="tracciato = t" />
        </div>

        <div class="griglia">
          <label class="span2">Tracciato *
            <Select v-model="tracciato" :options="tracciatiVisibili" optionLabel="tracciato" fluid
              placeholder="— scegli il tracciato —">
              <template #option="{ option }">
                <div class="opt-tracciato">
                  <b>{{ option.tracciato }}</b>
                  <small>{{ option.colonne ?? '?' }} colonne · separatore "{{ option.separatore ?? '—' }}"
                    {{ option.intestazione ? `· ${option.intestazione} riga/e intestazione` : '' }}</small>
                </div>
              </template>
            </Select>
          </label>
          <label class="chk-col">Modalità
            <span class="chk"><Checkbox v-model="soloVerifica" binary /> solo verifica (non carica)</span>
          </label>
          <div class="azione">
            <Button :label="soloVerifica ? 'Verifica il file' : 'Carica il file'"
              :icon="soloVerifica ? 'pi pi-shield' : 'pi pi-upload'"
              :disabled="!puoCaricare" :loading="caricamento" @click="carica" />
          </div>
        </div>

        <Message v-if="esito" :severity="esito.ok ? (esito.idLotto ? 'success' : 'info') : 'error'" :closable="false">
          <b>{{ esito.result }}</b>
          <template v-if="esito.idLotto"> — lotto {{ esito.idLotto }} creato ({{ esito.righe?.toLocaleString('it-IT') }} righe)</template>
        </Message>
      </div>
    </section>

    <Dialog v-model:visible="ricercaVisibile" header="Ricerca cliente" modal :style="{ width: '46rem' }">
      <div class="ricerca-corpo">
        <InputText v-model="ricercaTesto" fluid autofocus
          placeholder="ragione sociale, partita IVA, codice cliente o comune (min 2 caratteri)" />
        <DataTable :value="ricercaRighe" size="small" stripedRows scrollable scrollHeight="320px"
          :loading="ricercaInCorso" @row-click="e => scegliDaRicerca(e.data)" :rowHover="true">
          <Column field="ragioneSociale" header="Ragione sociale" />
          <Column field="partitaIva" header="P.IVA" style="width: 8.5rem" />
          <Column field="codiceCliente" header="Codice" style="width: 6.5rem" />
          <Column header="Sede">
            <template #body="{ data }">{{ data.comune }} {{ data.prov ? `(${data.prov})` : '' }}</template>
          </Column>
        </DataTable>
        <small v-if="ricercaTesto.length >= 2 && !ricercaRighe.length && !ricercaInCorso" class="vuoto">
          Nessun cliente trovato.
        </small>
      </div>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1000px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo { background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600; border-radius: 8px 8px 0 0; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.griglia { display: grid; grid-template-columns: repeat(4, 1fr); gap: .6rem .8rem; padding: .8rem; align-items: end; }
.corpo .griglia { padding: 0; }
.griglia label { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.span2 { grid-column: span 2; }
.riga-cliente { display: flex; gap: .5rem; }
.riga-cliente > :first-child { flex: 1; }
.chk-col .chk { display: flex; align-items: center; gap: .5rem; min-height: 2.4rem; }
.azione { display: flex; align-items: flex-end; }
.dropzone {
  display: flex; align-items: center; gap: .75rem; padding: 1.1rem;
  border: 2px dashed var(--p-surface-400); border-radius: 8px;
  cursor: pointer; color: var(--p-text-muted-color);
}
.dropzone.attiva { border-color: var(--p-primary-color); background: var(--p-highlight-background); }
.riconoscimento { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; font-size: .85rem; color: #555; }
.tag-tracciato { cursor: pointer; }
.opt-tracciato { display: flex; flex-direction: column; }
.opt-tracciato small { color: var(--p-text-muted-color); }
.ricerca-corpo { display: flex; flex-direction: column; gap: .75rem; }
.ricerca-corpo :deep(.p-datatable-tbody > tr) { cursor: pointer; }
.vuoto { color: var(--p-text-muted-color); }
</style>
