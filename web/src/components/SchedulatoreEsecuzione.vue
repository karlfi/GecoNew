<script setup>
// Una esecuzione col suo log, in un dialog sopra la pagina: finche' e' in coda
// o in corso si ricarica da sola ogni due secondi.
import { ref, watch, onUnmounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import Tag from 'primevue/tag'
import ProgressBar from 'primevue/progressbar'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Message from 'primevue/message'
import { severitaStato, dataOra, oraSec, durata, messaggioErrore } from '../lib/schedulatore'

const props = defineProps({ visible: Boolean, idEsecuzione: Number })
const emit = defineEmits(['update:visible', 'cambiata'])
const toast = useToast()
const esec = ref(null)
const errore = ref('')
let timer = null

async function carica() {
  clearTimeout(timer)
  if (!props.visible || !props.idEsecuzione) return
  try {
    const { data } = await api.get(`/schedulatore/esecuzione/${props.idEsecuzione}`)
    esec.value = data
    errore.value = ''
    if (data.Stato === 0 || data.Stato === 1) timer = setTimeout(carica, 2000)
  } catch (e) { errore.value = messaggioErrore(e) }
}
watch(() => [props.visible, props.idEsecuzione], ([v]) => {
  esec.value = null
  if (v) carica(); else clearTimeout(timer)
}, { immediate: true })
onUnmounted(() => clearTimeout(timer))

async function annulla() {
  try {
    await api.post(`/schedulatore/esecuzione/${props.idEsecuzione}/annulla`)
    toast.add({ severity: 'info', summary: 'Esecuzione annullata', life: 2500 })
    emit('cambiata')
    await carica()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Annullamento fallito', detail: messaggioErrore(e), life: 5000 })
  }
}
const classeLivello = r => ({ ERRORE: 'liv-err', ERROR: 'liv-err', WARN: 'liv-warn' }[r.Livello] ?? '')
</script>

<template>
  <Dialog :visible="visible" @update:visible="v => emit('update:visible', v)" modal
    :header="esec ? `Esecuzione #${esec.IdEsecuzione} — ${esec.NomeWorkflow}` : 'Esecuzione'" :style="{ width: '62rem' }">
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>
    <template v-if="esec">
      <div class="meta">
        <span><b>Stato</b> <Tag :value="esec.StatoNome" :severity="severitaStato(esec.Stato)" /></span>
        <span><b>Origine</b> {{ esec.Origine }}<template v-if="esec.NomeUtente"> ({{ esec.NomeUtente }})</template></span>
        <span><b>Prevista</b> {{ dataOra(esec.DataOraPrevista) }}</span>
        <span><b>Inizio</b> {{ dataOra(esec.InizioUtc) }}</span>
        <span><b>Fine</b> {{ dataOra(esec.FineUtc) }}</span>
        <span><b>Durata</b> {{ durata(esec.InizioUtc, esec.FineUtc) }}</span>
        <span v-if="esec.MachineName"><b>Macchina</b> {{ esec.MachineName }}</span>
        <span v-if="esec.GruppoConcorrenza"><b>Gruppo</b> {{ esec.GruppoConcorrenza }}</span>
      </div>
      <ProgressBar :value="esec.Avanzamento ?? 0" style="height: 1.1rem" />
      <p v-if="esec.Stato === 0" class="nota">In coda: parte quando il motore la pesca.</p>
      <p v-if="esec.Esito" class="esito" :class="{ errore: esec.Stato === 3 }"><b>Esito:</b> {{ esec.Esito }}</p>
      <pre v-if="esec.Parametri && typeof esec.Parametri === 'object'" class="param">{{ JSON.stringify(esec.Parametri, null, 1) }}</pre>

      <h4>Log <small v-if="esec.Log?.length">({{ esec.Log.length }} righe)</small></h4>
      <DataTable v-if="esec.Log?.length" :value="esec.Log" size="small" stripedRows scrollable scrollHeight="22rem" :rowClass="classeLivello">
        <Column field="Sequenza" header="#" style="width: 4rem" />
        <Column field="Livello" header="Livello" style="width: 6rem" />
        <Column field="Messaggio" header="Messaggio" />
        <Column field="NumRecord" header="Rec" style="width: 5rem" />
        <Column header="Ora" style="width: 7rem"><template #body="{ data }">{{ oraSec(data.TimestampUtc) }}</template></Column>
      </DataTable>
      <p v-else class="nota">Nessuna riga di log.</p>
    </template>
    <template #footer>
      <Button v-if="esec && (esec.Stato === 0 || esec.Stato === 1)" label="Annulla esecuzione" icon="pi pi-times" severity="danger" text @click="annulla" />
      <Button label="Aggiorna" icon="pi pi-refresh" text @click="carica" />
      <Button label="Chiudi" @click="emit('update:visible', false)" />
    </template>
  </Dialog>
</template>

<style scoped>
.meta { display: flex; flex-wrap: wrap; gap: .4rem 1.2rem; margin-bottom: .75rem; }
.nota { color: var(--p-text-muted-color); margin: .5rem 0; }
.esito { margin: .5rem 0; }
.esito.errore { color: var(--p-red-600); }
.param { font-size: .8rem; background: var(--p-content-hover-background); padding: .4rem .6rem; border-radius: 6px; max-height: 8rem; overflow: auto; }
h4 { margin: .75rem 0 .4rem; }
h4 small { color: var(--p-text-muted-color); font-weight: normal; }
:deep(.liv-err) { color: var(--p-red-600); }
:deep(.liv-warn) { color: var(--p-orange-600); }
</style>
