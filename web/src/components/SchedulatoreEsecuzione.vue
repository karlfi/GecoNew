<script setup>
// Una esecuzione col suo log, in un dialog sopra la pagina: finche' e' in coda
// o in corso si ricarica da sola ogni due secondi. Ogni riga del log porta nome e
// tipo dello step; quelle con un dettaglio (la query o il comando eseguito coi
// parametri sostituiti, l'output, i file) si aprono col triangolino e si copiano.
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
const aperte = ref({})        // Sequenza -> true per le righe col dettaglio aperto
const soloProblemi = ref(false)
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
  aperte.value = {}
  soloProblemi.value = false
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
const problema = r => r.Livello === 'ERRORE' || r.Livello === 'ERROR' || r.Livello === 'WARN'
const righeLog = () => {
  const tutte = esec.value?.Log ?? []
  return soloProblemi.value ? tutte.filter(problema) : tutte
}
const nProblemi = () => (esec.value?.Log ?? []).filter(problema).length

function apriChiudi(r) {
  const o = { ...aperte.value }
  if (o[r.Sequenza]) delete o[r.Sequenza]; else o[r.Sequenza] = true
  aperte.value = o
}
function apriTutte(apri) {
  const o = {}
  if (apri) for (const r of esec.value?.Log ?? []) if (r.Dettaglio) o[r.Sequenza] = true
  aperte.value = o
}
async function copia(testo) {
  try {
    await navigator.clipboard.writeText(testo)
    toast.add({ severity: 'success', summary: 'Copiato negli appunti', life: 1500 })
  } catch {
    toast.add({ severity: 'warn', summary: 'Copia non riuscita: seleziona il testo e copia a mano', life: 3000 })
  }
}
const durataMs = ms => ms == null ? '' : ms < 1000 ? `${ms} ms` : `${(ms / 1000).toLocaleString('it-IT', { maximumFractionDigits: 1 })} s`
</script>

<template>
  <Dialog :visible="visible" @update:visible="v => emit('update:visible', v)" modal
    :header="esec ? `Esecuzione #${esec.IdEsecuzione} — ${esec.NomeWorkflow}` : 'Esecuzione'" :style="{ width: '78rem' }">
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

      <div class="testa-log">
        <h4>Log <small v-if="esec.Log?.length">({{ esec.Log.length }} righe<template v-if="nProblemi()">, {{ nProblemi() }} con problemi</template>)</small></h4>
        <span class="spazio" />
        <Button v-if="nProblemi()" :label="soloProblemi ? 'Tutte le righe' : 'Solo errori e avvisi'" :icon="soloProblemi ? 'pi pi-list' : 'pi pi-exclamation-triangle'"
          text size="small" @click="soloProblemi = !soloProblemi" />
        <Button label="Apri dettagli" icon="pi pi-angle-double-down" text size="small" @click="apriTutte(true)" />
        <Button label="Chiudi dettagli" icon="pi pi-angle-double-up" text size="small" @click="apriTutte(false)" />
      </div>
      <DataTable v-if="esec.Log?.length" :value="righeLog()" dataKey="Sequenza" v-model:expandedRows="aperte"
        size="small" stripedRows scrollable scrollHeight="30rem" :rowClass="classeLivello" class="log">
        <Column style="width: 2.4rem" bodyClass="col-apri">
          <template #body="{ data }">
            <Button v-if="data.Dettaglio" :icon="aperte[data.Sequenza] ? 'pi pi-chevron-down' : 'pi pi-chevron-right'"
              text rounded size="small" class="apri" :title="aperte[data.Sequenza] ? 'Chiudi il dettaglio' : 'Mostra il dettaglio'" @click="apriChiudi(data)" />
          </template>
        </Column>
        <Column field="Sequenza" header="#" style="width: 3.2rem" />
        <Column field="Livello" header="Livello" style="width: 5.2rem" />
        <Column header="Step" style="width: 11rem">
          <template #body="{ data }">
            <span v-if="data.NomeStep" class="step">{{ data.NomeStep }}</span>
            <span v-else class="nota">—</span>
          </template>
        </Column>
        <Column field="TipoStep" header="Tipo" style="width: 8.5rem" />
        <Column field="Messaggio" header="Messaggio" bodyClass="msg" />
        <Column field="NumRecord" header="Rec" style="width: 4.5rem" bodyClass="num" />
        <Column header="Durata" style="width: 5.5rem" bodyClass="num"><template #body="{ data }">{{ durataMs(data.DurataMs) }}</template></Column>
        <Column header="Ora" style="width: 6.2rem"><template #body="{ data }">{{ oraSec(data.TimestampUtc) }}</template></Column>
        <template #expansion="{ data }">
          <div class="dettaglio">
            <div class="dettaglio-testa">
              <b>Dettaglio</b> <span class="nota">{{ data.NomeStep }} {{ data.TipoStep ? `[${data.TipoStep}]` : '' }}</span>
              <span class="spazio" />
              <Button label="Copia" icon="pi pi-copy" text size="small" @click="copia(data.Dettaglio)" />
            </div>
            <pre>{{ data.Dettaglio }}</pre>
          </div>
        </template>
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
.testa-log { display: flex; align-items: center; gap: .25rem; margin-top: .75rem; }
.testa-log h4 { margin: 0 .5rem 0 0; }
.spazio { flex: 1; }
h4 small { color: var(--p-text-muted-color); font-weight: normal; }
.step { font-weight: 600; }
:deep(.liv-err) { color: var(--p-red-600); }
:deep(.liv-warn) { color: var(--p-orange-600); }
:deep(.msg) { white-space: pre-wrap; word-break: break-word; }
:deep(.num) { text-align: right; }
:deep(.col-apri) { padding-top: 0; padding-bottom: 0; }
.apri { width: 1.8rem; height: 1.8rem; }
.dettaglio { padding: .25rem .5rem .5rem 2.4rem; }
.dettaglio-testa { display: flex; align-items: center; gap: .5rem; }
.dettaglio-testa .nota { margin: 0; }
.dettaglio pre { margin: .25rem 0 0; font-size: .8rem; line-height: 1.35; background: var(--p-content-hover-background);
  padding: .5rem .7rem; border-radius: 6px; max-height: 24rem; overflow: auto; white-space: pre-wrap; word-break: break-word; }
</style>
