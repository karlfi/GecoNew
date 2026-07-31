<script setup>
import { ref, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Select from 'primevue/select'
import Textarea from 'primevue/textarea'
import Dialog from 'primevue/dialog'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Nuovo Pickup su richiesta (gruppo Ministero GG): la stored legacy PICKUP_Genera
// crea la spedizione di ritiro PCK# verso l'ufficio speditore (procura/tribunale)
// e stampa la ricevuta DELIVERY_Pickup.fr3.

const toast = useToast()
const errore = ref('')
const uffici = ref([])
const destinazioni = ref([])
const ufficio = ref(null)
const destinazione = ref(null)
const nota = ref('')
const creazione = ref(false)
const creato = ref(null)
const righe = ref([])
const caricamento = ref(false)

// visore PDF della ricevuta (il report server parla solo col backend)
const pdf = ref({ visibile: false, url: null, caricamento: false })

onMounted(async () => {
  try {
    const { data } = await api.get('/pickup/lookups')
    uffici.value = data.uffici
    destinazioni.value = data.destinazioni
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento iniziale'
  }
  carica()
})

async function carica() {
  caricamento.value = true
  try {
    const { data } = await api.get('/pickup/elenco')
    righe.value = data
  } catch { /* elenco best-effort */ }
  finally { caricamento.value = false }
}

async function crea() {
  creazione.value = true
  creato.value = null
  try {
    const { data } = await api.post('/pickup', {
      idMittente: ufficio.value,
      idFilialeDestinazione: destinazione.value,
      notaConsegna: nota.value
    })
    creato.value = data
    toast.add({ severity: 'success', summary: 'Pickup', detail: `Creato pickup ${data.barcode}`, life: 5000 })
    ufficio.value = null; nota.value = ''
    carica()
    stampa(data.idSpedizione)     // il legacy stampa subito la ricevuta
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Pickup', detail: e.response?.data?.errore ?? 'Errore', life: 6000 })
  } finally {
    creazione.value = false
  }
}

async function stampa(idSpedizione) {
  pdf.value = { visibile: true, url: null, caricamento: true }
  try {
    const { data } = await api.get('/report', {
      params: { src: `DELIVERY_Pickup.fr3|IdSpedizione=${idSpedizione}` },
      responseType: 'blob'
    })
    if (pdf.value.url) URL.revokeObjectURL(pdf.value.url)
    pdf.value.url = URL.createObjectURL(data)
  } catch (e) {
    pdf.value.visibile = false
    let msg = 'Errore nella generazione della ricevuta'
    try { msg = JSON.parse(await e.response.data.text()).errore ?? msg } catch { /* risposta non JSON */ }
    toast.add({ severity: 'error', summary: 'Ricevuta pickup', detail: msg, life: 5000 })
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
    <h2 class="titolo">Nuovo Pickup su richiesta</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Nuovo pickup</div>
      <div class="corpo">
        <div class="griglia-form">
          <label>Ufficio speditore *
            <Select v-model="ufficio" :options="uffici" optionValue="idMittente" filter fluid
              placeholder="— scegli l'ufficio —" :optionLabel="o => `${o.ufficio} (${o.comune})`" />
          </label>
          <label>Filiale di destinazione *
            <Select v-model="destinazione" :options="destinazioni" optionLabel="Filiale"
              optionValue="IdFiliale" filter fluid placeholder="—" />
          </label>
          <label>Nota
            <Textarea v-model="nota" rows="1" autoResize fluid />
          </label>
          <div class="azione">
            <Button label="Crea e stampa" icon="pi pi-plus" :disabled="!ufficio || !destinazione"
              :loading="creazione" @click="crea" />
          </div>
        </div>
        <div v-if="creato" class="riga-esito">
          <Tag severity="success" :value="`Pickup ${creato.barcode} creato`" />
          <Button label="Ristampa ricevuta" icon="pi pi-print" outlined size="small"
            @click="stampa(creato.idSpedizione)" />
        </div>
      </div>
    </section>

    <section class="card">
      <div class="card-titolo">Ultimi pickup della filiale</div>
      <DataTable :value="righe" size="small" stripedRows :loading="caricamento" paginator :rows="15">
        <Column field="barcode" header="Barcode" style="width: 8.5rem" />
        <Column field="inserita" header="Creato" style="width: 8.5rem" />
        <Column field="ufficio" header="Ufficio" />
        <Column field="utente" header="Utente" />
        <Column field="nota" header="Nota" />
        <Column header="Stato" style="width: 8rem">
          <template #body="{ data }">
            <Tag v-if="data.stato" severity="info" :value="data.statoDescrizione ?? data.stato" />
            <span v-else>—</span>
          </template>
        </Column>
        <Column header="" style="width: 4rem">
          <template #body="{ data }">
            <Button icon="pi pi-print" text rounded size="small" title="Ristampa ricevuta"
              @click="stampa(data.idSpedizione)" />
          </template>
        </Column>
        <template #empty>Nessun pickup per la filiale.</template>
      </DataTable>
    </section>

    <!-- ricevuta: PDF servito dal backend, mostrato in un frame interno -->
    <Dialog :visible="pdf.visibile" @update:visible="v => { if (!v) chiudiPdf() }"
      modal maximizable header="Ricevuta pickup" :style="{ width: '62rem' }">
      <div v-if="pdf.caricamento" class="pdf-attesa">Generazione in corso…</div>
      <iframe v-else-if="pdf.url" :src="pdf.url" class="pdf-frame" title="Ricevuta pickup"></iframe>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1150px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0;
}
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.griglia-form {
  display: grid; grid-template-columns: minmax(18rem, 26rem) 15rem 1fr auto;
  gap: .8rem; align-items: end;
}
.griglia-form label { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.azione { display: flex; align-items: flex-end; }
.riga-esito { display: flex; align-items: center; gap: .8rem; }
.pdf-frame { width: 100%; height: 75vh; border: 0; }
.pdf-attesa { padding: 3rem; text-align: center; color: #666; }
</style>
