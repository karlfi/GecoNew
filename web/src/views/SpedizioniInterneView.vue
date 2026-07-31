<script setup>
import { ref, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Checkbox from 'primevue/checkbox'
import Select from 'primevue/select'
import Textarea from 'primevue/textarea'
import DatePicker from 'primevue/datepicker'
import Dialog from 'primevue/dialog'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Spedizioni Interne: replica della videata legacy (azione 1036). Trasferimenti
// di materiale tra filiali: si sceglie la destinazione, si descrive il contenuto
// e la SP legacy SPED_INTERNA crea la spedizione (barcode 6xxxxxxxxxxx) con la
// lettera di vettura da stampare e apporre sul collo.

const toast = useToast()
const errore = ref('')
const destinazioni = ref([])
const destinazione = ref(null)
const nota = ref('')
const creazione = ref(false)
const creata = ref(null)          // { idSpedizione, barcode } dell'ultima creazione

const righe = ref([])
const caricamento = ref(false)
const tutteFiliali = ref(false)
const dal = ref(new Date(Date.now() - 15 * 864e5))
const al = ref(new Date())

// visore PDF della lettera di vettura (il report server parla solo col backend)
const pdf = ref({ visibile: false, url: null, caricamento: false })

function ymd(d) {
  return d ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` : null
}

onMounted(async () => {
  try {
    const { data } = await api.get('/spedinterna/lookups')
    destinazioni.value = data.destinazioni
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle filiali'
  }
  carica()
})

async function carica() {
  caricamento.value = true
  try {
    const { data } = await api.get('/spedinterna/elenco', {
      params: { dal: ymd(dal.value), al: ymd(al.value), tutte: tutteFiliali.value || undefined }
    })
    righe.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle spedizioni'
  } finally {
    caricamento.value = false
  }
}

async function crea() {
  creazione.value = true
  creata.value = null
  try {
    const { data } = await api.post('/spedinterna', {
      idFilialeDestinazione: destinazione.value,
      notaConsegna: nota.value
    })
    creata.value = data
    toast.add({ severity: 'success', summary: 'Spedizione interna',
      detail: `Creata spedizione ${data.barcode}`, life: 5000 })
    destinazione.value = null
    nota.value = ''
    carica()
    stampa(data.idSpedizione)   // il legacy stampa subito la lettera di vettura
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Spedizione interna',
      detail: e.response?.data?.errore ?? 'Errore nella creazione', life: 6000 })
  } finally {
    creazione.value = false
  }
}

async function stampa(idSpedizione) {
  pdf.value = { visibile: true, url: null, caricamento: true }
  try {
    const { data } = await api.get('/report', {
      params: { src: `DELIVERY_SpedInterna.fr3|IdSpedizione=${idSpedizione}` },
      responseType: 'blob'
    })
    if (pdf.value.url) URL.revokeObjectURL(pdf.value.url)
    pdf.value.url = URL.createObjectURL(data)
  } catch (e) {
    pdf.value.visibile = false
    let msg = 'Errore nella generazione della lettera di vettura'
    try { msg = JSON.parse(await e.response.data.text()).errore ?? msg } catch { /* risposta non JSON */ }
    toast.add({ severity: 'error', summary: 'Lettera di vettura', detail: msg, life: 5000 })
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
    <h2 class="titolo">Spedizioni Interne</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <!-- nuova spedizione -->
    <section class="card">
      <div class="card-titolo">Nuova spedizione interna</div>
      <div class="corpo">
        <div class="griglia-form">
          <label>Filiale di destinazione *
            <Select v-model="destinazione" :options="destinazioni" optionLabel="Filiale"
              optionValue="IdFiliale" filter fluid placeholder="— scegli la filiale —" />
          </label>
          <label>Contenuto / riferimenti
            <Textarea v-model="nota" rows="2" autoResize fluid
              placeholder="es. resi raccomandate, palmari, cancelleria..." />
          </label>
          <div class="azione">
            <Button label="Crea e stampa" icon="pi pi-plus" :disabled="!destinazione"
              :loading="creazione" @click="crea" />
          </div>
        </div>
        <div v-if="creata" class="riga-esito">
          <Tag severity="success" :value="`Spedizione ${creata.barcode} creata`" />
          <Button label="Ristampa lettera di vettura" icon="pi pi-print" outlined size="small"
            @click="stampa(creata.idSpedizione)" />
        </div>
      </div>
    </section>

    <!-- elenco -->
    <section class="card">
      <div class="card-titolo">Spedizioni interne della filiale
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
          <span v-if="righe.length" class="conta">{{ righe.length }} spedizioni</span>
        </div>

        <DataTable :value="righe" size="small" stripedRows :loading="caricamento"
          paginator :rows="20">
          <Column field="barcode" header="Barcode" style="width: 8.5rem" />
          <Column field="inserita" header="Creata" style="width: 8.5rem" />
          <Column field="filialeMittente" header="Da" />
          <Column field="filialeDestinazione" header="A" />
          <Column field="utente" header="Utente" />
          <Column field="nota" header="Contenuto">
            <template #body="{ data }">
              <span class="nota-cella" :title="data.nota">{{ data.nota }}</span>
            </template>
          </Column>
          <Column header="Stato" style="width: 8rem">
            <template #body="{ data }">
              <Tag v-if="data.stato" :severity="data.stato === 'XX' ? 'success' : 'info'"
                :value="data.statoDescrizione ?? data.stato" />
              <span v-else>—</span>
            </template>
          </Column>
          <Column header="" style="width: 4rem">
            <template #body="{ data }">
              <Button icon="pi pi-print" text rounded size="small" title="Stampa lettera di vettura"
                @click="stampa(data.idSpedizione)" />
            </template>
          </Column>
          <template #empty>Nessuna spedizione interna nel periodo.</template>
        </DataTable>
      </div>
    </section>

    <!-- lettera di vettura: PDF servito dal backend, mostrato in un frame interno -->
    <Dialog :visible="pdf.visibile" @update:visible="v => { if (!v) chiudiPdf() }"
      modal maximizable header="Lettera di vettura" :style="{ width: '62rem' }">
      <div v-if="pdf.caricamento" class="pdf-attesa">Generazione in corso…</div>
      <iframe v-else-if="pdf.url" :src="pdf.url" class="pdf-frame" title="Lettera di vettura"></iframe>
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
.griglia-form {
  display: grid; grid-template-columns: minmax(16rem, 22rem) 1fr auto;
  gap: .8rem; align-items: end;
}
.griglia-form label { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.azione { display: flex; align-items: flex-end; }
.riga-esito { display: flex; align-items: center; gap: .8rem; }
.barra { display: flex; align-items: center; gap: .8rem; flex-wrap: wrap; }
.barra .spazio { flex: 1; }
.campo-data { display: flex; align-items: center; gap: .5rem; font-size: .85rem; color: #555; }
.conta { color: #666; font-size: .85rem; }
.nota-cella {
  display: inline-block; max-width: 26rem; overflow: hidden;
  text-overflow: ellipsis; white-space: nowrap; vertical-align: bottom;
}
.pdf-frame { width: 100%; height: 75vh; border: 0; }
.pdf-attesa { padding: 3rem; text-align: center; color: #666; }
</style>
