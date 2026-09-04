<script setup>
// Agenda e storico dello schedulatore: cosa scattera' (le prossime occorrenze
// calcolate dalle pianificazioni, piu' quello che e' gia' in coda) e cosa e'
// successo (le ultime esecuzioni). Si aggiorna da sola ogni dieci secondi.
import { ref, onMounted, onUnmounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { useNavStore } from '../stores/nav'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Checkbox from 'primevue/checkbox'
import Select from 'primevue/select'
import Tag from 'primevue/tag'
import SchedulatoreEsecuzione from '../components/SchedulatoreEsecuzione.vue'
import { severitaStato, dataOra, durata, messaggioErrore, STATI } from '../lib/schedulatore'

const toast = useToast()
const nav = useNavStore()

const workflow = ref([])
const prossime = ref([])
const giorni = ref(7)
const esecuzioni = ref([])
const filtroStato = ref(null)
const filtroWorkflow = ref(null)
const autoAggiorna = ref(true)
const caricamento = ref(false)
let timer = null

async function carica() {
  caricamento.value = true
  try {
    const [p, e] = await Promise.all([
      api.get('/schedulatore/prossime', { params: { giorni: giorni.value } }),
      api.get('/schedulatore/esecuzioni', { params: { idWorkflow: filtroWorkflow.value, stato: filtroStato.value, top: 300 } })
    ])
    prossime.value = p.data
    esecuzioni.value = e.data
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Errore', detail: messaggioErrore(e), life: 6000 })
  } finally {
    caricamento.value = false
  }
}
onMounted(async () => {
  try { workflow.value = (await api.get('/schedulatore/workflow')).data } catch { /* il filtro resta vuoto */ }
  await carica()
  timer = setInterval(() => { if (autoAggiorna.value) carica() }, 10000)
})
onUnmounted(() => clearInterval(timer))

const dialogEsec = ref(false)
const idEsec = ref(null)
const apriEsec = id => { idEsec.value = id; dialogEsec.value = true }
const apriWorkflow = id => nav.drill({ tipo: 'schedulatore', idWorkflow: id })
const severitaFonte = f => ({ CRON: 'info', ONESHOT: 'contrast', CODA: 'warn' }[f] ?? 'secondary')
const giorniOpzioni = [1, 3, 7, 14, 30]
</script>

<template>
  <div class="pagina">
    <div class="testata">
      <div>
        <h2 class="titolo">Schedulatore — agenda e storico</h2>
        <p class="sotto">Quello che scatterà nei prossimi giorni e le ultime esecuzioni. In coda = esecuzioni già create, in attesa del motore.</p>
      </div>
      <div class="barra">
        <label><Checkbox v-model="autoAggiorna" binary /> aggiorna ogni 10 s</label>
        <Button icon="pi pi-refresh" label="Aggiorna" text :loading="caricamento" @click="carica" />
      </div>
    </div>

    <section>
      <h3>
        Prossime esecuzioni <Tag :value="String(prossime.length)" severity="info" />
        <label class="filtro">nei prossimi <Select v-model="giorni" :options="giorniOpzioni" size="small" @change="carica" /> giorni</label>
      </h3>
      <DataTable :value="prossime" size="small" stripedRows scrollable scrollHeight="20rem">
        <Column header="Quando" style="width: 10rem"><template #body="{ data }">{{ dataOra(data.quando) }}</template></Column>
        <Column header="Workflow">
          <template #body="{ data }"><Button :label="data.nomeWorkflow" link size="small" class="link" @click="apriWorkflow(data.idWorkflow)" /></template>
        </Column>
        <Column header="Pianificazione"><template #body="{ data }">{{ data.descrizione || '—' }}</template></Column>
        <Column header="Fonte" style="width: 12rem">
          <template #body="{ data }">
            <Tag :value="data.fonte" :severity="severitaFonte(data.fonte)" />
            <code v-if="data.cronExpr" class="cron">{{ data.cronExpr }}</code>
            <Tag v-if="data.sospesa" value="sospesa" severity="warn" />
          </template>
        </Column>
        <Column header="Gruppo" style="width: 8rem"><template #body="{ data }">{{ data.gruppoConcorrenza || '' }}</template></Column>
        <Column header="" style="width: 7rem">
          <template #body="{ data }"><Button v-if="data.idEsecuzione" :label="'#' + data.idEsecuzione" link size="small" @click="apriEsec(data.idEsecuzione)" /></template>
        </Column>
        <template #empty><span class="nota">Niente in programma: nessuna pianificazione attiva e coda vuota.</span></template>
      </DataTable>
    </section>

    <section>
      <h3>
        Esecuzioni <Tag :value="String(esecuzioni.length)" severity="secondary" />
        <Select v-model="filtroWorkflow" :options="workflow" optionLabel="Nome" optionValue="IdWorkflow" placeholder="tutti i workflow" showClear size="small" class="filtro" @change="carica" />
        <Select v-model="filtroStato" :options="STATI" optionLabel="Nome" optionValue="Codice" placeholder="tutti gli stati" showClear size="small" class="filtro" @change="carica" />
      </h3>
      <DataTable :value="esecuzioni" size="small" stripedRows selectionMode="single" @row-click="e => apriEsec(e.data.IdEsecuzione)" class="esec"
        paginator :rows="25">
        <Column field="IdEsecuzione" header="#" style="width: 5rem" />
        <Column field="NomeWorkflow" header="Workflow" />
        <Column header="Stato" style="width: 9rem"><template #body="{ data }"><Tag :value="data.StatoNome" :severity="severitaStato(data.Stato)" /></template></Column>
        <Column header="Origine" style="width: 10rem"><template #body="{ data }">{{ data.Origine }}<small v-if="data.NomeUtente" class="nota"> {{ data.NomeUtente }}</small></template></Column>
        <Column header="Prevista" style="width: 9rem"><template #body="{ data }">{{ dataOra(data.DataOraPrevista) }}</template></Column>
        <Column header="Inizio" style="width: 9rem"><template #body="{ data }">{{ dataOra(data.InizioUtc) }}</template></Column>
        <Column header="Durata" style="width: 5rem"><template #body="{ data }">{{ data.InizioUtc ? durata(data.InizioUtc, data.FineUtc) : '—' }}</template></Column>
        <Column field="Avanzamento" header="%" style="width: 3.5rem" />
        <Column field="Esito" header="Esito" />
        <template #empty><span class="nota">Nessuna esecuzione.</span></template>
      </DataTable>
    </section>

    <SchedulatoreEsecuzione v-model:visible="dialogEsec" :id-esecuzione="idEsec" @cambiata="carica" />
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 1rem; }
.titolo { margin: 0; }
.sotto { margin: 0; color: var(--p-text-muted-color); }
.testata { display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem; flex-wrap: wrap; }
.barra { display: flex; align-items: center; gap: .5rem; }
.barra label { display: flex; align-items: center; gap: .4rem; color: var(--p-text-muted-color); }
section h3 { margin: 0 0 .5rem; display: flex; align-items: center; gap: .6rem; flex-wrap: wrap; }
.filtro { font-weight: normal; font-size: .9rem; display: inline-flex; align-items: center; gap: .3rem; color: var(--p-text-muted-color); }
.link { padding: 0; }
.cron { font-size: .8rem; margin-left: .4rem; }
.esec :deep(tr) { cursor: pointer; }
.nota { color: var(--p-text-muted-color); }
</style>
