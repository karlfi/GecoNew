<script setup>
import { ref, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Checkbox from 'primevue/checkbox'
import DatePicker from 'primevue/datepicker'
import Dialog from 'primevue/dialog'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Distinta Riepilogativa Giornaliera: replica della videata legacy del gruppo
// Ministero GG. Elenca le distinte che contengono atti del cliente MGG e stampa
// il modello ministeriale (una sezione per ufficio speditore, con tariffe e area
// per il timbro del comune): MG_DistRiepGiornaliera.fr3|IdDistinta=N.

const props = defineProps({
  // la videata "Distinta Riepilogativa Notifiche" usera' un altro cliente/report
  idCliente: { type: Number, default: 5318 },
  template: { type: String, default: 'MG_DistRiepGiornaliera.fr3' }
})

const toast = useToast()
const errore = ref('')
const caricamento = ref(false)
const righe = ref([])
const tutteFiliali = ref(false)
const dal = ref(new Date(Date.now() - 7 * 864e5))
const al = ref(new Date())

// visore PDF (il report server parla solo col backend)
const pdf = ref({ visibile: false, url: null, caricamento: false })

function ymd(d) {
  return d ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` : null
}

async function carica() {
  caricamento.value = true
  errore.value = ''
  try {
    const { data } = await api.get('/distintariepilogativa/elenco', {
      params: {
        dal: ymd(dal.value), al: ymd(al.value),
        tutte: tutteFiliali.value || undefined, idCliente: props.idCliente
      }
    })
    righe.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle distinte'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)

async function stampa(r) {
  pdf.value = { visibile: true, url: null, caricamento: true }
  try {
    const { data } = await api.get('/report', {
      params: { src: `${props.template}|IdDistinta=${r.idDistinta}` },
      responseType: 'blob'
    })
    if (pdf.value.url) URL.revokeObjectURL(pdf.value.url)
    pdf.value.url = URL.createObjectURL(data)
  } catch (e) {
    pdf.value.visibile = false
    let msg = 'Errore nella generazione della distinta'
    try { msg = JSON.parse(await e.response.data.text()).errore ?? msg } catch { /* risposta non JSON */ }
    toast.add({ severity: 'error', summary: 'Distinta riepilogativa', detail: msg, life: 5000 })
  } finally {
    pdf.value.caricamento = false
  }
}
function chiudiPdf() {
  if (pdf.value.url) URL.revokeObjectURL(pdf.value.url)
  pdf.value = { visibile: false, url: null, caricamento: false }
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Distinta Riepilogativa Giornaliera</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Distinte con atti del cliente
        <span class="chk-testata"><Checkbox v-model="tutteFiliali" binary @change="carica" /> tutte le filiali</span>
      </div>
      <div class="corpo">
        <div class="barra">
          <label class="campo-data">Dal
            <DatePicker v-model="dal" dateFormat="dd/mm/yy" showIcon />
          </label>
          <label class="campo-data">Al
            <DatePicker v-model="al" dateFormat="dd/mm/yy" showIcon />
          </label>
          <Button label="Aggiorna" icon="pi pi-refresh" :loading="caricamento" @click="carica" />
          <span class="spazio"></span>
          <span v-if="righe.length" class="conta">{{ righe.length }} distinte</span>
        </div>

        <DataTable :value="righe" size="small" stripedRows :loading="caricamento"
          paginator :rows="20">
          <Column field="idDistinta" header="Id" style="width: 6rem" />
          <Column field="barcode" header="Barcode" style="width: 9rem" />
          <Column field="data" header="Data" style="width: 8.5rem" />
          <Column field="azione" header="Azione" />
          <Column field="filiale" header="Filiale" />
          <Column field="atti" header="Atti" style="width: 4.5rem" />
          <Column field="uffici" header="Uffici" style="width: 4.5rem" />
          <Column header="" style="width: 11rem">
            <template #body="{ data }">
              <Button label="Stampa riepilogativa" icon="pi pi-print" outlined size="small"
                @click="stampa(data)" />
            </template>
          </Column>
          <template #empty>Nessuna distinta con atti del cliente nel periodo.</template>
        </DataTable>
      </div>
    </section>

    <!-- PDF servito dal backend, mostrato in un frame interno -->
    <Dialog :visible="pdf.visibile" @update:visible="v => { if (!v) chiudiPdf() }"
      modal maximizable header="Distinta Riepilogativa Giornaliera" :style="{ width: '68rem' }">
      <div v-if="pdf.caricamento" class="pdf-attesa">Generazione in corso…</div>
      <iframe v-else-if="pdf.url" :src="pdf.url" class="pdf-frame" title="Distinta Riepilogativa"></iframe>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1200px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center;
}
.chk-testata { display: flex; align-items: center; gap: .4rem; font-size: .82rem; font-weight: 400; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.barra { display: flex; align-items: center; gap: .8rem; flex-wrap: wrap; }
.barra .spazio { flex: 1; }
.campo-data { display: flex; align-items: center; gap: .5rem; font-size: .85rem; color: #555; }
.conta { color: #666; font-size: .85rem; }
.pdf-frame { width: 100%; height: 75vh; border: 0; }
.pdf-attesa { padding: 3rem; text-align: center; color: #666; }
</style>
