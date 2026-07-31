<script setup>
import { ref, onMounted, watch } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Select from 'primevue/select'
import InputText from 'primevue/inputtext'
import Textarea from 'primevue/textarea'
import Dialog from 'primevue/dialog'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Creazione Scatole: replica della videata legacy "Scatola". La stored legacy
// SCATOLA_Crea genera la scatola del tipo scelto (cesta blu BOX@, restituzioni
// SNM@/KNE@/ADE@) con l'etichetta da stampare e apporre; sotto, l'elenco delle
// scatole ancora aperte per tipo (ElencoScatoleAperte).

const toast = useToast()
const errore = ref('')
const tipi = ref([])
const tipo = ref(null)
const destinazioni = ref([])
const destinazione = ref(null)
const nota = ref('')
const riferimento = ref('')
const creazione = ref(false)
const creata = ref(null)          // ultima scatola creata { idSpedizione, barcode, webReport }
const aperte = ref([])
const caricamentoAperte = ref(false)

// visore PDF dell'etichetta (il report server parla solo col backend)
const pdf = ref({ visibile: false, url: null, caricamento: false })

onMounted(async () => {
  try {
    const [{ data: t }, { data: l }] = await Promise.all([
      api.get('/scatole/tipi'),
      api.get('/spedinterna/lookups')
    ])
    tipi.value = t
    destinazioni.value = l.destinazioni
    tipo.value = t[0]?.idTipoScatola ?? null
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento iniziale'
  }
})

watch(tipo, caricaAperte)
async function caricaAperte() {
  if (tipo.value == null) return
  caricamentoAperte.value = true
  try {
    const { data } = await api.get('/scatole/aperte', { params: { idTipoScatola: tipo.value } })
    aperte.value = data.filter(r => r.barcode)
  } catch {
    aperte.value = []
  } finally {
    caricamentoAperte.value = false
  }
}

async function crea() {
  creazione.value = true
  creata.value = null
  try {
    const { data } = await api.post('/scatole', {
      idTipoScatola: tipo.value,
      idFilialeDestinazione: destinazione.value,
      notaConsegna: nota.value,
      riferimentoEsterno1: riferimento.value || null
    })
    creata.value = data
    toast.add({ severity: 'success', summary: 'Scatola', detail: `Creata scatola ${data.barcode}`, life: 5000 })
    nota.value = ''; riferimento.value = ''
    caricaAperte()
    stampa(data)                  // il legacy stampa subito l'etichetta
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Scatola', detail: e.response?.data?.errore ?? 'Errore', life: 6000 })
  } finally {
    creazione.value = false
  }
}

async function stampa(s) {
  if (!s.webReport) return
  pdf.value = { visibile: true, url: null, caricamento: true }
  try {
    const { data } = await api.get('/report', {
      params: { src: `${s.webReport}|IdDistinta=${s.idSpedizione}` },
      responseType: 'blob'
    })
    if (pdf.value.url) URL.revokeObjectURL(pdf.value.url)
    pdf.value.url = URL.createObjectURL(data)
  } catch (e) {
    pdf.value.visibile = false
    let msg = 'Errore nella generazione dell\'etichetta'
    try { msg = JSON.parse(await e.response.data.text()).errore ?? msg } catch { /* risposta non JSON */ }
    toast.add({ severity: 'error', summary: 'Etichetta', detail: msg, life: 5000 })
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
    <h2 class="titolo">Creazione Scatole</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Nuova scatola</div>
      <div class="corpo">
        <div class="griglia-form">
          <label>Tipo scatola *
            <Select v-model="tipo" :options="tipi" optionLabel="descrizione" optionValue="idTipoScatola" fluid />
          </label>
          <label>Filiale di destinazione
            <Select v-model="destinazione" :options="destinazioni" optionLabel="Filiale"
              optionValue="IdFiliale" filter showClear fluid placeholder="—" />
          </label>
          <label>Riferimento
            <InputText v-model="riferimento" fluid />
          </label>
          <label class="campo-nota">Nota / contenuto
            <Textarea v-model="nota" rows="1" autoResize fluid />
          </label>
          <div class="azione">
            <Button label="Crea e stampa" icon="pi pi-plus" :disabled="tipo == null"
              :loading="creazione" @click="crea" />
          </div>
        </div>
        <div v-if="creata" class="riga-esito">
          <Tag severity="success" :value="`Scatola ${creata.barcode} creata`" />
          <Button label="Ristampa etichetta" icon="pi pi-print" outlined size="small" @click="stampa(creata)" />
        </div>
      </div>
    </section>

    <section class="card">
      <div class="card-titolo">Scatole aperte del tipo scelto
        <span class="conteggio">{{ aperte.length }}</span>
      </div>
      <DataTable :value="aperte" size="small" stripedRows :loading="caricamentoAperte"
        paginator :rows="15">
        <Column field="barcode" header="Barcode" />
        <template #empty>Nessuna scatola aperta per questo tipo.</template>
      </DataTable>
    </section>

    <!-- etichetta: PDF servito dal backend, mostrato in un frame interno -->
    <Dialog :visible="pdf.visibile" @update:visible="v => { if (!v) chiudiPdf() }"
      modal maximizable header="Etichetta scatola" :style="{ width: '62rem' }">
      <div v-if="pdf.caricamento" class="pdf-attesa">Generazione in corso…</div>
      <iframe v-else-if="pdf.url" :src="pdf.url" class="pdf-frame" title="Etichetta scatola"></iframe>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1100px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center;
}
.conteggio { font-size: .8rem; font-weight: 400; opacity: .9; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.griglia-form {
  display: grid; grid-template-columns: 15rem 16rem 10rem 1fr auto;
  gap: .8rem; align-items: end;
}
.griglia-form label { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.azione { display: flex; align-items: flex-end; }
.riga-esito { display: flex; align-items: center; gap: .8rem; }
.pdf-frame { width: 100%; height: 75vh; border: 0; }
.pdf-attesa { padding: 3rem; text-align: center; color: #666; }
</style>
