<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Checkbox from 'primevue/checkbox'
import DatePicker from 'primevue/datepicker'
import Dialog from 'primevue/dialog'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Checkin lotti: replica della videata legacy "Checkin". I lotti caricati (da file,
// gia' videocodificati, o da banco) vengono accettati in filiale: la stored legacy
// Lotto_Checkin imposta la DataAccettazione e, a richiesta, crea la distinta con
// l'esito di accettazione (InserimentoEsiti), da cui si stampa il documento.
// Le varianti legacy "Checkin MGG"/"Checkindb" passano idCliente nei parametri.

const props = defineProps({ parametri: { type: String, default: '' } })
// regex sulla stringa grezza: il legacy scrive "idCliente=5318" ma anche
// 'IdCliente=5377|sWhere="IdCliente=5377"' (chiave ripetuta dentro sWhere)
const idClienteParam = parseInt(/IdCliente\s*=\s*["']*(\d+)/i.exec(props.parametri)?.[1], 10) || null

const toast = useToast()
const errore = ref('')
const clienti = ref([])
const caricamento = ref(false)
const tutteFiliali = ref(false)

const cliente = ref(null)         // riga cliente aperta
const lotti = ref([])
const selezionati = ref([])
const dataCheckin = ref(new Date())
const creaDistinta = ref(true)
const checkinInCorso = ref(false)
const esito = ref(null)           // { idDistinta, webReport } dell'ultimo checkin

// visore PDF della distinta (il report server parla solo col backend)
const pdfUrl = ref(null)
const pdfVisibile = ref(false)
const stampando = ref(false)

async function caricaClienti() {
  caricamento.value = true
  errore.value = ''
  try {
    const { data } = await api.get('/checkin/clienti', {
      params: { tutte: tutteFiliali.value || undefined, idCliente: idClienteParam || undefined }
    })
    clienti.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento'
  } finally {
    caricamento.value = false
  }
}
onMounted(caricaClienti)

async function apriCliente(c) {
  cliente.value = c
  lotti.value = []
  selezionati.value = []
  esito.value = null
  try {
    const { data } = await api.get('/checkin/lotti', {
      params: { idCliente: c.idCliente, tutte: tutteFiliali.value || undefined }
    })
    lotti.value = data
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Lotti', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  }
}
function tornaAiClienti() {
  cliente.value = null
  lotti.value = []
  selezionati.value = []
  esito.value = null
  caricaClienti()
}

const puoCheckin = computed(() => selezionati.value.length > 0 && dataCheckin.value && !checkinInCorso.value)

async function checkin() {
  checkinInCorso.value = true
  esito.value = null
  try {
    const { data } = await api.post('/checkin', {
      idLotti: selezionati.value.map(l => l.IdLotto),
      creaDistinta: creaDistinta.value,
      dataCheckin: dataCheckin.value
        ? `${dataCheckin.value.getFullYear()}-${String(dataCheckin.value.getMonth() + 1).padStart(2, '0')}-${String(dataCheckin.value.getDate()).padStart(2, '0')}`
        : null
    })
    esito.value = data
    toast.add({ severity: 'success', summary: 'Checkin',
      detail: `${selezionati.value.length} lotto/i accettati${data.idDistinta ? ` — distinta ${data.idDistinta}` : ''}`, life: 6000 })
    selezionati.value = []
    // ricarico i lotti rimasti del cliente
    const { data: rimasti } = await api.get('/checkin/lotti', {
      params: { idCliente: cliente.value.idCliente, tutte: tutteFiliali.value || undefined }
    })
    lotti.value = rimasti
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Checkin', detail: e.response?.data?.errore ?? 'Errore imprevisto', life: 8000 })
  } finally {
    checkinInCorso.value = false
  }
}

// il PDF arriva dal backend (proxy del report server) e si mostra in un iframe:
// l'URL della pagina non cambia e il report server resta invisibile
async function stampaDistinta() {
  stampando.value = true
  try {
    const { data } = await api.get(`/distinte/${esito.value.idDistinta}/stampa`, { responseType: 'blob' })
    if (pdfUrl.value) URL.revokeObjectURL(pdfUrl.value)
    pdfUrl.value = URL.createObjectURL(data)
    pdfVisibile.value = true
  } catch (e) {
    let msg = 'Errore nella stampa'
    try { msg = JSON.parse(await e.response.data.text()).errore ?? msg } catch { /* risposta non JSON */ }
    toast.add({ severity: 'error', summary: 'Distinta', detail: msg, life: 6000 })
  } finally {
    stampando.value = false
  }
}
function chiudiPdf() {
  if (pdfUrl.value) URL.revokeObjectURL(pdfUrl.value)
  pdfUrl.value = null
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Checkin lotti</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <!-- clienti con lotti in attesa di checkin -->
    <section v-if="!cliente" class="card">
      <div class="card-titolo">Clienti con lotti da accettare
        <span class="chk-testata"><Checkbox v-model="tutteFiliali" binary @change="caricaClienti" /> tutte le filiali</span>
      </div>
      <DataTable :value="clienti" size="small" stripedRows :loading="caricamento" :rowHover="true"
        paginator :rows="15" @row-click="e => apriCliente(e.data)" class="tab-clienti">
        <Column field="cliente" header="Cliente" />
        <Column field="famiglia" header="Famiglia" />
        <Column field="numDoc" header="Documenti" style="width: 6.5rem" />
        <Column field="filiale" header="Filiale" />
        <Column field="utente" header="Inserito da" />
        <template #empty>Nessun lotto in attesa di checkin.</template>
      </DataTable>
    </section>

    <!-- lotti del cliente -->
    <template v-else>
      <section class="card">
        <div class="card-titolo">Lotti da accettare — {{ cliente.cliente }}</div>
        <div class="corpo">
          <div class="barra">
            <Button label="Torna ai clienti" icon="pi pi-arrow-left" text @click="tornaAiClienti" />
            <span class="spazio"></span>
            <label class="campo-data">Data checkin
              <DatePicker v-model="dataCheckin" dateFormat="dd/mm/yy" showIcon />
            </label>
            <span class="chk"><Checkbox v-model="creaDistinta" binary /> crea distinta di accettazione</span>
            <Button :label="`Checkin${selezionati.length ? ` (${selezionati.length})` : ''}`"
              icon="pi pi-check" :disabled="!puoCheckin" :loading="checkinInCorso" @click="checkin" />
          </div>

          <div v-if="esito?.idDistinta" class="riga-esito">
            <Tag severity="success" :value="`Distinta ${esito.idDistinta} creata`" />
            <Button label="Stampa distinta" icon="pi pi-print" outlined :loading="stampando" @click="stampaDistinta" />
          </div>

          <DataTable :value="lotti" size="small" stripedRows dataKey="IdLotto"
            v-model:selection="selezionati" paginator :rows="20">
            <Column selectionMode="multiple" style="width: 2.5rem" />
            <Column field="IdLotto" header="Id" style="width: 5.5rem" />
            <Column field="Lotto" header="Lotto" />
            <Column field="CodFamiglia" header="Fam." style="width: 3.5rem" />
            <Column field="Prodotto" header="Prodotto" />
            <Column field="NumeroAtti" header="Atti" style="width: 4rem" />
            <Column field="Righe" header="Righe" style="width: 4.5rem" />
            <Column header="VideoCod." style="width: 6.5rem">
              <template #body="{ data }">
                <Tag v-if="data.DataVideoCodifica" severity="success" value="fatta" />
                <span v-else>—</span>
              </template>
            </Column>
            <Column field="DataInserimento" header="Inserito" style="width: 8.5rem" />
            <Column field="Filiale" header="Filiale" />
            <Column field="Utente" header="Da" />
            <template #empty>Nessun lotto da accettare per questo cliente.</template>
          </DataTable>
        </div>
      </section>
    </template>

    <!-- distinta: PDF servito dal backend, mostrato in un frame interno -->
    <Dialog v-model:visible="pdfVisibile" modal maximizable header="Distinta di accettazione"
      :style="{ width: '62rem' }" @hide="chiudiPdf">
      <iframe v-if="pdfUrl" :src="pdfUrl" class="pdf-frame" title="Distinta di accettazione"></iframe>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1300px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center;
}
.chk-testata { display: flex; align-items: center; gap: .4rem; font-size: .82rem; font-weight: 400; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.barra { display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
.barra .spazio { flex: 1; }
.campo-data { display: flex; align-items: center; gap: .5rem; font-size: .85rem; color: #555; }
.chk { display: flex; align-items: center; gap: .4rem; font-size: .85rem; color: #555; }
.riga-esito { display: flex; align-items: center; gap: .8rem; }
.tab-clienti :deep(.p-datatable-tbody > tr) { cursor: pointer; }
.pdf-frame { width: 100%; height: 75vh; border: 0; }
</style>
