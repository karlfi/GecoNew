<script setup>
// Schedulatore: i workflow (i "file step" dello schedulatore legacy) con i loro
// step, le pianificazioni e le esecuzioni. Le scritture passano dalle stored
// WF_usp_*; chi esegue e' il motore, che pesca dalla coda: "esegui ora" mette
// in coda e l'esecuzione si segue nel dialog.
import { ref, computed, watch, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Checkbox from 'primevue/checkbox'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
import Dialog from 'primevue/dialog'
import Tag from 'primevue/tag'
import Tree from 'primevue/tree'
import Tabs from 'primevue/tabs'
import TabList from 'primevue/tablist'
import Tab from 'primevue/tab'
import TabPanels from 'primevue/tabpanels'
import TabPanel from 'primevue/tabpanel'
import SchedulatoreStep from '../components/SchedulatoreStep.vue'
import SchedulatoreEsecuzione from '../components/SchedulatoreEsecuzione.vue'
import { severitaStato, dataOra, durata, messaggioErrore, fileBase64 } from '../lib/schedulatore'

const props = defineProps({ idWorkflow: { type: Number, default: null } })
const toast = useToast()
const errore = e => toast.add({ severity: 'error', summary: 'Errore', detail: messaggioErrore(e), life: 6000 })

// --- conferme: un dialog solo, con il testo e cosa fare ---
const conferma = ref({ visibile: false, testo: '', azione: null })
const chiedi = (testo, azione) => { conferma.value = { visibile: true, testo, azione } }
async function confermato() {
  const a = conferma.value.azione
  conferma.value.visibile = false
  if (a) await a()
}

// --- elenco ---
const workflow = ref([])
const caricamento = ref(false)
const selezione = ref(null)
const tipi = ref([])
async function caricaElenco(idDaSelezionare = selezione.value?.IdWorkflow) {
  caricamento.value = true
  try {
    const { data } = await api.get('/schedulatore/workflow')
    workflow.value = data
    selezione.value = data.find(w => w.IdWorkflow === idDaSelezionare) ?? null
  } catch (e) { errore(e) } finally { caricamento.value = false }
}
onMounted(async () => {
  try { tipi.value = (await api.get('/schedulatore/tipi')).data } catch { /* la combo dei tipi resta col solo tipo corrente */ }
  await caricaElenco(props.idWorkflow)
})

// --- dettaglio del workflow scelto ---
const dettaglio = ref(null)
const scheda = ref('step')
const stepScelto = ref(null)
const chiaviSel = ref({})
const chiaviAperte = ref({})
watch(selezione, w => {
  dettaglio.value = null; stepScelto.value = null; chiaviSel.value = {}
  if (w) caricaDettaglio(w.IdWorkflow, null)
})
watch(scheda, s => { if (s === 'pian') caricaPianificazioni(); if (s === 'esec') caricaEsecuzioni() })

async function caricaDettaglio(id, idStepDaScegliere = stepScelto.value?.IdStep) {
  try {
    const { data } = await api.get(`/schedulatore/workflow/${id}`)
    dettaglio.value = data
    const tutti = appiattisci(data.Steps)
    chiaviAperte.value = Object.fromEntries(tutti.map(s => [String(s.IdStep), true]))
    stepScelto.value = tutti.find(s => s.IdStep === idStepDaScegliere) ?? null
    chiaviSel.value = stepScelto.value ? { [String(stepScelto.value.IdStep)]: true } : {}
    if (scheda.value === 'pian') caricaPianificazioni()
    if (scheda.value === 'esec') caricaEsecuzioni()
  } catch (e) { errore(e) }
}
const appiattisci = nodi => (nodi ?? []).flatMap(n => [n, ...appiattisci(n.Sottopassi)])
// l'albero di PrimeVue vuole key/label/children: il nodo vero viaggia in data
const nodoAlbero = s => ({ key: String(s.IdStep), label: s.NomeSezione, data: s, children: (s.Sottopassi ?? []).map(nodoAlbero) })
const albero = computed(() => (dettaglio.value?.Steps ?? []).map(nodoAlbero))
const numStep = computed(() => appiattisci(dettaglio.value?.Steps).length)

// --- step ---
async function aggiungiStep(idPadre) {
  try {
    const nome = idPadre
      ? `${stepScelto.value.NomeSezione}_Sottopasso${(stepScelto.value.Sottopassi?.length ?? 0) + 1}`
      : `Step${(dettaglio.value.Steps?.length ?? 0) + 1}`
    const { data } = await api.post(`/schedulatore/workflow/${dettaglio.value.IdWorkflow}/step`, { idStepPadre: idPadre, tipo: 'ESEGUIQUERY', nomeSezione: nome })
    await caricaDettaglio(dettaglio.value.IdWorkflow, data.idStep)
  } catch (e) { errore(e) }
}
async function spostaStep(direzione) {
  if (!stepScelto.value) return
  try {
    await api.post(`/schedulatore/step/${stepScelto.value.IdStep}/sposta`, { direzione })
    await caricaDettaglio(dettaglio.value.IdWorkflow)
  } catch (e) { errore(e) }
}
function eliminaStep() {
  if (!stepScelto.value) return
  chiedi(`Eliminare lo step "${stepScelto.value.NomeSezione}" e i suoi sottopassi?`, async () => {
    try {
      await api.delete(`/schedulatore/step/${stepScelto.value.IdStep}`)
      await caricaDettaglio(dettaglio.value.IdWorkflow, null)
    } catch (e) { errore(e) }
  })
}

// --- esegui ora / elimina workflow ---
const dialogEsec = ref(false)
const idEsec = ref(null)
const apriEsec = id => { idEsec.value = id; dialogEsec.value = true }
const eseguiOra = () => chiedi(`Mettere in coda "${dettaglio.value.Nome}" adesso? Parte appena il motore la pesca.`, async () => {
  try {
    const { data } = await api.post(`/schedulatore/workflow/${dettaglio.value.IdWorkflow}/esegui`, {})
    toast.add({ severity: 'success', summary: `In coda: esecuzione #${data.idEsecuzione}`, life: 3000 })
    apriEsec(data.idEsecuzione)
    if (scheda.value === 'esec') caricaEsecuzioni()
  } catch (e) { errore(e) }
})
const eliminaWorkflow = () => chiedi(`Eliminare il workflow "${dettaglio.value.Nome}" con tutti i suoi step? Se ha pianificazioni o esecuzioni il database lo rifiuta.`, async () => {
  try {
    await api.delete(`/schedulatore/workflow/${dettaglio.value.IdWorkflow}`)
    toast.add({ severity: 'info', summary: 'Workflow eliminato', life: 2500 })
    await caricaElenco(null)
  } catch (e) { errore(e) }
})

// --- testata: nuovo workflow o modifica di quello scelto (stesso dialog) ---
const dialogTestata = ref(false)
const testata = ref({})
function apriTestata(w) {
  testata.value = w
    ? { idWorkflow: w.IdWorkflow, nome: w.Nome, descrizione: w.Descrizione ?? '', directoryOutput: w.DirectoryOutput ?? '',
        pausaTraStepMS: w.PausaTraStepMS ?? 0, variabili: Array.isArray(w.VariabiliGlobali) ? w.VariabiliGlobali.join(', ') : '',
        loggaInizioOperazione: w.LoggaInizioOperazione !== false, attivo: w.Attivo !== false }
    : { idWorkflow: null, nome: '', descrizione: '', directoryOutput: '', pausaTraStepMS: 0, variabili: '', loggaInizioOperazione: true, attivo: true }
  dialogTestata.value = true
}
async function salvaTestata() {
  const t = testata.value
  if (!t.nome.trim()) { toast.add({ severity: 'warn', summary: 'Il nome è obbligatorio', life: 3000 }); return }
  const corpo = {
    nome: t.nome.trim(), descrizione: t.descrizione || null, directoryOutput: t.directoryOutput || null,
    pausaTraStepMS: t.pausaTraStepMS ?? 0, loggaInizioOperazione: t.loggaInizioOperazione, attivo: t.attivo,
    variabiliGlobali: t.variabili.split(',').map(v => v.trim()).filter(Boolean)
  }
  try {
    let id = t.idWorkflow
    if (id) await api.put(`/schedulatore/workflow/${id}`, corpo)
    else id = (await api.post('/schedulatore/workflow', corpo)).data.idWorkflow
    dialogTestata.value = false
    toast.add({ severity: 'success', summary: t.idWorkflow ? 'Workflow aggiornato' : 'Workflow creato: ora aggiungi gli step', life: 3000 })
    await caricaElenco(id)
    if (!t.idWorkflow) scheda.value = 'step'
    else if (dettaglio.value) await caricaDettaglio(id)
  } catch (e) { errore(e) }
}

// --- import dei file .stp ---
const inputFile = ref(null)
const sovrascrivi = ref(true)
const importazione = ref(false)
const esitiImport = ref(null)
const dialogImport = computed({ get: () => !!esitiImport.value, set: v => { if (!v) esitiImport.value = null } })
async function importa(ev) {
  const files = Array.from(ev.target.files ?? [])
  ev.target.value = ''
  if (!files.length) return
  importazione.value = true
  try {
    const file = await Promise.all(files.map(async f => ({ nome: f.name, base64: await fileBase64(f) })))
    const { data } = await api.post('/schedulatore/import', { file, sovrascrivi: sovrascrivi.value })
    esitiImport.value = data.esiti
    const primo = data.esiti.find(x => x.ok)
    await caricaElenco(primo?.idWorkflow ?? selezione.value?.IdWorkflow)
  } catch (e) { errore(e) } finally { importazione.value = false }
}

// --- pianificazioni ---
const pianificazioni = ref([])
const nuovaPian = ref({ descrizione: '', gruppoConcorrenza: '', orizzonteGiorni: 30 })
const nuoveRic = ref({})      // per pianificazione: il form della nuova ricorrenza
const provaCron = ref({})     // per pianificazione: l'esito della prova del cron
const vuotaRic = () => ({ tipoRicorrenza: 'CRON', cronExpr: '', dataOraSingola: null, priorita: 0 })
async function caricaPianificazioni() {
  if (!dettaglio.value) return
  try {
    const { data } = await api.get(`/schedulatore/workflow/${dettaglio.value.IdWorkflow}/pianificazioni`)
    pianificazioni.value = data
    for (const p of data) if (!nuoveRic.value[p.IdPianificazione]) nuoveRic.value[p.IdPianificazione] = vuotaRic()
  } catch (e) { errore(e) }
}
const azionePian = async fn => {
  try { await fn(); await caricaPianificazioni(); await caricaElenco() } catch (e) { errore(e) }
}
const creaPian = () => azionePian(async () => {
  await api.post(`/schedulatore/workflow/${dettaglio.value.IdWorkflow}/pianificazioni`, {
    descrizione: nuovaPian.value.descrizione || null, gruppoConcorrenza: nuovaPian.value.gruppoConcorrenza || null,
    orizzonteGiorni: nuovaPian.value.orizzonteGiorni ?? 30
  })
  nuovaPian.value = { descrizione: '', gruppoConcorrenza: '', orizzonteGiorni: 30 }
})
// la stored riscrive tutti i campi: si rimanda la riga com'e', con le modifiche sopra
const salvaPian = (p, modifiche) => azionePian(() => api.put(`/schedulatore/pianificazione/${p.IdPianificazione}`, {
  idWorkflow: p.IdWorkflow, descrizione: p.Descrizione, gruppoConcorrenza: p.GruppoConcorrenza, note: p.Note,
  orizzonteGiorni: p.OrizzonteGiorni, dataOraFinale: p.DataOraFinale, sospesa: p.Sospesa, attiva: p.Attiva,
  parametri: p.Parametri && typeof p.Parametri === 'object' ? p.Parametri : undefined, ...modifiche
}))
const eliminaPian = p => chiedi(`Eliminare la pianificazione "${p.Descrizione || '(senza nome)'}" con le sue ricorrenze?`,
  () => azionePian(() => api.delete(`/schedulatore/pianificazione/${p.IdPianificazione}`)))
const aggiungiRic = p => azionePian(async () => {
  const f = nuoveRic.value[p.IdPianificazione]
  await api.post(`/schedulatore/pianificazione/${p.IdPianificazione}/dettagli`, {
    tipoRicorrenza: f.tipoRicorrenza, cronExpr: f.tipoRicorrenza === 'CRON' ? f.cronExpr : null,
    dataOraSingola: f.tipoRicorrenza === 'ONESHOT' && f.dataOraSingola ? f.dataOraSingola.toISOString() : null,
    priorita: f.priorita ?? 0
  })
  nuoveRic.value[p.IdPianificazione] = vuotaRic()
  provaCron.value[p.IdPianificazione] = null
})
const toggleRic = d => azionePian(() => api.put(`/schedulatore/dettaglio/${d.IdDettaglio}`, {
  tipoRicorrenza: d.TipoRicorrenza, cronExpr: d.CronExpr, dataOraSingola: d.DataOraSingola, priorita: d.Priorita, attiva: !d.Attiva
}))
const eliminaRic = d => azionePian(() => api.delete(`/schedulatore/dettaglio/${d.IdDettaglio}`))
// la prova del cron mentre si scrive: si vede subito quando scatterebbe
let timerCron = null
function provaIlCron(idPian) {
  clearTimeout(timerCron)
  const expr = nuoveRic.value[idPian]?.cronExpr?.trim()
  if (!expr) { provaCron.value[idPian] = null; return }
  timerCron = setTimeout(async () => {
    try { provaCron.value[idPian] = (await api.get('/schedulatore/cron', { params: { expr, n: 3 } })).data } catch { /* niente anteprima */ }
  }, 400)
}

// --- esecuzioni del workflow ---
const esecuzioni = ref([])
async function caricaEsecuzioni() {
  if (!dettaglio.value) return
  try {
    esecuzioni.value = (await api.get('/schedulatore/esecuzioni', { params: { idWorkflow: dettaglio.value.IdWorkflow, top: 100 } })).data
  } catch (e) { errore(e) }
}
const nomeFile = p => (p ?? '').split(/[\\/]/).pop()
</script>

<template>
  <div class="pagina">
    <div class="testata">
      <div>
        <h2 class="titolo">Schedulatore</h2>
        <p class="sotto">I workflow dei file step: step, pianificazioni ed esecuzioni. Le esecuzioni in coda le fa partire il motore.</p>
      </div>
      <div class="barra">
        <Button label="Nuovo workflow" icon="pi pi-plus" @click="apriTestata(null)" />
        <label><Checkbox v-model="sovrascrivi" binary /> sovrascrivi se esiste</label>
        <Button label="Importa file .stp" icon="pi pi-upload" outlined :loading="importazione" @click="inputFile.click()" />
        <input ref="inputFile" type="file" multiple accept=".stp,.txt,.ini" hidden @change="importa" />
        <Button icon="pi pi-refresh" text :loading="caricamento" title="Aggiorna" @click="caricaElenco()" />
      </div>
    </div>

    <div class="colonne">
      <!-- elenco -->
      <DataTable :value="workflow" v-model:selection="selezione" selectionMode="single" dataKey="IdWorkflow"
        size="small" stripedRows class="elenco" :loading="caricamento">
        <Column header="Workflow">
          <template #body="{ data }">
            <b>{{ data.Nome }}</b><br>
            <small class="nota">{{ nomeFile(data.FileOrigine) }}</small>
          </template>
        </Column>
        <Column field="NumStep" header="Step" style="width: 4rem" />
        <Column header="Pianif." style="width: 4.5rem"><template #body="{ data }">{{ data.NumPianificazioni || '—' }}</template></Column>
        <Column header="Ultima esecuzione" style="width: 10rem">
          <template #body="{ data }">
            <template v-if="data.UltimoStato != null">
              <Tag :value="data.UltimoStatoNome" :severity="severitaStato(data.UltimoStato)" /><br>
              <small class="nota">{{ dataOra(data.UltimoInizioUtc) }}</small>
            </template>
            <span v-else class="nota">mai</span>
          </template>
        </Column>
        <template #empty><span class="nota">Nessun workflow: importa un file .stp.</span></template>
      </DataTable>

      <!-- dettaglio -->
      <div v-if="dettaglio" class="dettaglio">
        <div class="testata">
          <div>
            <h3 class="titolo">
              {{ dettaglio.Nome }}
              <Tag v-if="dettaglio.Attivo === false" value="disattivo" severity="secondary" />
              <Button icon="pi pi-pencil" text size="small" title="Modifica la testata" @click="apriTestata(dettaglio)" />
            </h3>
            <p v-if="dettaglio.Descrizione" class="sotto">{{ dettaglio.Descrizione }}</p>
            <div class="meta">
              <span v-if="dettaglio.DirectoryOutput"><b>Output</b> <code>{{ dettaglio.DirectoryOutput }}</code></span>
              <span v-if="Array.isArray(dettaglio.VariabiliGlobali) && dettaglio.VariabiliGlobali.length"><b>Variabili</b> {{ dettaglio.VariabiliGlobali.join(', ') }}</span>
              <span v-if="dettaglio.NStepDichiarati != null"><b>NStep dichiarati</b> {{ dettaglio.NStepDichiarati }}</span>
              <span><b>Importato</b> {{ dataOra(dettaglio.DataCreazione) }}<template v-if="dettaglio.FileOrigine"> da {{ nomeFile(dettaglio.FileOrigine) }}</template></span>
            </div>
          </div>
          <div class="barra">
            <Button label="Esegui ora" icon="pi pi-play" severity="success" @click="eseguiOra" />
            <Button label="Elimina" icon="pi pi-trash" severity="danger" text @click="eliminaWorkflow" />
          </div>
        </div>

        <Tabs v-model:value="scheda">
          <TabList>
            <Tab value="step">Step ({{ numStep }})</Tab>
            <Tab value="pian">Pianificazioni</Tab>
            <Tab value="esec">Esecuzioni</Tab>
          </TabList>
          <TabPanels>
            <!-- albero + editor -->
            <TabPanel value="step">
              <div class="split">
                <div class="albero">
                  <Button label="Step radice" icon="pi pi-plus" text size="small" @click="aggiungiStep(null)" />
                  <Tree :value="albero" selectionMode="single" v-model:selectionKeys="chiaviSel" v-model:expandedKeys="chiaviAperte"
                    @node-select="n => stepScelto = n.data" class="tree">
                    <template #default="{ node }">
                      <span class="nodo" :class="{ off: !node.data.Attivo }">
                        <span class="ord">#{{ node.data.Ordine }}</span>
                        <span class="tipo">{{ node.data.Tipo }}</span>
                        <span class="sez">{{ node.data.NomeSezione }}</span>
                        <Tag v-if="!node.data.Attivo" value="disabilitato" severity="secondary" />
                        <Tag v-else-if="!node.data.EseguiPasso" value="non eseguito" severity="warn" />
                      </span>
                    </template>
                  </Tree>
                  <p v-if="!albero.length" class="nota">Nessuno step.</p>
                </div>
                <div class="editor">
                  <SchedulatoreStep :step="stepScelto" :tipi="tipi"
                    @salvato="caricaDettaglio(dettaglio.IdWorkflow)"
                    @elimina="eliminaStep" @sposta="spostaStep" @aggiungi-sotto="aggiungiStep(stepScelto.IdStep)" />
                </div>
              </div>
            </TabPanel>

            <!-- pianificazioni -->
            <TabPanel value="pian">
              <div class="nuova">
                <InputText v-model="nuovaPian.descrizione" placeholder="Descrizione" size="small" style="width: 18rem" />
                <InputText v-model="nuovaPian.gruppoConcorrenza" placeholder="Gruppo concorrenza" size="small" style="width: 12rem" />
                <label>orizzonte gg <InputNumber v-model="nuovaPian.orizzonteGiorni" size="small" :min="1" :max="365" inputStyle="width: 5rem" /></label>
                <Button label="Pianificazione" icon="pi pi-plus" size="small" @click="creaPian" />
              </div>
              <div v-for="p in pianificazioni" :key="p.IdPianificazione" class="pian" :class="{ ferma: p.Sospesa || !p.Attiva }">
                <div class="testata">
                  <h4>
                    {{ p.Descrizione || '(senza nome)' }}
                    <Tag v-if="p.GruppoConcorrenza" :value="'gruppo ' + p.GruppoConcorrenza" severity="info" />
                    <Tag v-if="p.Sospesa" value="sospesa" severity="warn" />
                    <Tag v-if="!p.Attiva" value="disattiva" severity="secondary" />
                    <small class="nota">orizzonte {{ p.OrizzonteGiorni }} gg<template v-if="p.DataOraFinale"> · fino al {{ dataOra(p.DataOraFinale) }}</template></small>
                  </h4>
                  <div class="barra">
                    <Button :label="p.Sospesa ? 'Riattiva' : 'Sospendi'" :icon="p.Sospesa ? 'pi pi-play' : 'pi pi-pause'" text size="small" @click="salvaPian(p, { sospesa: !p.Sospesa })" />
                    <Button label="Elimina" icon="pi pi-trash" text size="small" severity="danger" @click="eliminaPian(p)" />
                  </div>
                </div>
                <DataTable :value="p.Dettagli" size="small" class="ricorrenze">
                  <Column header="Tipo" style="width: 6rem"><template #body="{ data }">{{ data.TipoRicorrenza }}</template></Column>
                  <Column header="Cron / data" style="width: 12rem">
                    <template #body="{ data }">
                      <code v-if="data.TipoRicorrenza === 'CRON'">{{ data.CronExpr }}</code>
                      <template v-else>{{ dataOra(data.DataOraSingola) }}</template>
                    </template>
                  </Column>
                  <Column header="Prossime">
                    <template #body="{ data }">
                      <span v-if="data.Prossime?.length">{{ data.Prossime.map(dataOra).join(' · ') }}</span>
                      <span v-else class="nota">nessuna</span>
                    </template>
                  </Column>
                  <Column field="Priorita" header="Prio" style="width: 4rem" />
                  <Column header="" style="width: 6rem">
                    <template #body="{ data }">
                      <Button :icon="data.Attiva ? 'pi pi-check-circle' : 'pi pi-circle'" :title="data.Attiva ? 'attiva: clicca per disattivare' : 'disattiva: clicca per attivare'"
                        text size="small" :severity="data.Attiva ? 'success' : 'secondary'" @click="toggleRic(data)" />
                      <Button icon="pi pi-times" text size="small" severity="danger" title="Elimina ricorrenza" @click="eliminaRic(data)" />
                    </template>
                  </Column>
                  <template #empty><span class="nota">Nessuna ricorrenza: aggiungine una qui sotto.</span></template>
                </DataTable>
                <div v-if="nuoveRic[p.IdPianificazione]" class="nuova">
                  <Select v-model="nuoveRic[p.IdPianificazione].tipoRicorrenza" :options="['CRON', 'ONESHOT']" size="small" style="width: 8rem" />
                  <template v-if="nuoveRic[p.IdPianificazione].tipoRicorrenza === 'CRON'">
                    <InputText v-model="nuoveRic[p.IdPianificazione].cronExpr" placeholder="min ora giorno mese sett — es. 0 6 * * 1-5"
                      size="small" class="cron" @input="provaIlCron(p.IdPianificazione)" />
                    <span v-if="provaCron[p.IdPianificazione]" class="anteprima" :class="{ errore: !provaCron[p.IdPianificazione].valida }">
                      {{ provaCron[p.IdPianificazione].valida
                        ? 'prossime: ' + provaCron[p.IdPianificazione].prossime.map(dataOra).join(' · ')
                        : provaCron[p.IdPianificazione].errore }}
                    </span>
                  </template>
                  <DatePicker v-else v-model="nuoveRic[p.IdPianificazione].dataOraSingola" showTime hourFormat="24" dateFormat="dd/mm/yy" size="small" placeholder="data e ora" />
                  <label>prio <InputNumber v-model="nuoveRic[p.IdPianificazione].priorita" size="small" inputStyle="width: 4rem" /></label>
                  <Button label="Ricorrenza" icon="pi pi-plus" text size="small" @click="aggiungiRic(p)" />
                </div>
              </div>
              <p v-if="!pianificazioni.length" class="nota">Nessuna pianificazione per questo workflow.</p>
            </TabPanel>

            <!-- esecuzioni -->
            <TabPanel value="esec">
              <div class="barra"><Button icon="pi pi-refresh" label="Aggiorna" text size="small" @click="caricaEsecuzioni" /></div>
              <DataTable :value="esecuzioni" size="small" stripedRows selectionMode="single" @row-click="e => apriEsec(e.data.IdEsecuzione)" class="esec">
                <Column field="IdEsecuzione" header="#" style="width: 5rem" />
                <Column header="Stato" style="width: 9rem"><template #body="{ data }"><Tag :value="data.StatoNome" :severity="severitaStato(data.Stato)" /></template></Column>
                <Column header="Origine" style="width: 10rem"><template #body="{ data }">{{ data.Origine }}<small v-if="data.NomeUtente" class="nota"> {{ data.NomeUtente }}</small></template></Column>
                <Column header="Prevista" style="width: 9rem"><template #body="{ data }">{{ dataOra(data.DataOraPrevista) }}</template></Column>
                <Column header="Inizio" style="width: 9rem"><template #body="{ data }">{{ dataOra(data.InizioUtc) }}</template></Column>
                <Column header="Durata" style="width: 5rem"><template #body="{ data }">{{ data.InizioUtc ? durata(data.InizioUtc, data.FineUtc) : '—' }}</template></Column>
                <Column field="Avanzamento" header="%" style="width: 3.5rem" />
                <Column field="Esito" header="Esito" />
                <template #empty><span class="nota">Nessuna esecuzione.</span></template>
              </DataTable>
            </TabPanel>
          </TabPanels>
        </Tabs>
      </div>
      <div v-else class="dettaglio vuoto"><span class="nota">Scegli un workflow a sinistra.</span></div>
    </div>

    <!-- esito dell'import -->
    <Dialog v-model:visible="dialogImport" modal header="Import file step" :style="{ width: '44rem' }">
      <p v-if="esitiImport">Importati {{ esitiImport.filter(x => x.ok).length }} / {{ esitiImport.length }}.</p>
      <DataTable :value="esitiImport ?? []" size="small">
        <Column field="file" header="File" />
        <Column header="Esito" style="width: 6rem"><template #body="{ data }"><Tag :value="data.ok ? 'OK' : 'Errore'" :severity="data.ok ? 'success' : 'danger'" /></template></Column>
        <Column header="Workflow"><template #body="{ data }"><span v-if="data.ok">{{ data.nome }}</span><span v-else class="errore">{{ data.errore }}</span></template></Column>
        <Column header="Step" style="width: 5rem"><template #body="{ data }">{{ data.ok ? data.numStep : '—' }}</template></Column>
      </DataTable>
      <template #footer><Button label="Chiudi" @click="dialogImport = false" /></template>
    </Dialog>

    <!-- testata: nuovo workflow o modifica -->
    <Dialog v-model:visible="dialogTestata" modal :header="testata.idWorkflow ? 'Modifica workflow' : 'Nuovo workflow'" :style="{ width: '36rem' }">
      <div class="modulo">
        <label>Nome <InputText v-model="testata.nome" autofocus placeholder="es. ANCI-05_RENDICONTI" /></label>
        <label>Descrizione <InputText v-model="testata.descrizione" /></label>
        <label>Cartella di output <InputText v-model="testata.directoryOutput" placeholder="\\server\share\cartella" /></label>
        <label>Variabili globali <InputText v-model="testata.variabili" placeholder="nomi separati da virgola" /></label>
        <label>Pausa tra gli step (ms) <InputNumber v-model="testata.pausaTraStepMS" :min="0" :max="600000" inputStyle="width: 8rem" /></label>
        <label class="riga"><Checkbox v-model="testata.loggaInizioOperazione" binary /> Logga l'inizio di ogni operazione</label>
        <label class="riga"><Checkbox v-model="testata.attivo" binary /> Attivo</label>
        <small v-if="!testata.idWorkflow" class="nota">Dopo il salvataggio si aggiungono gli step nella linguetta "Step" e le ricorrenze in "Pianificazioni".</small>
      </div>
      <template #footer>
        <Button label="Annulla" text @click="dialogTestata = false" />
        <Button :label="testata.idWorkflow ? 'Salva' : 'Crea'" icon="pi pi-check" @click="salvaTestata" />
      </template>
    </Dialog>

    <!-- conferma -->
    <Dialog v-model:visible="conferma.visibile" modal header="Conferma" :style="{ width: '30rem' }">
      <p>{{ conferma.testo }}</p>
      <template #footer>
        <Button label="Annulla" text @click="conferma.visibile = false" />
        <Button label="Conferma" @click="confermato" />
      </template>
    </Dialog>

    <SchedulatoreEsecuzione v-model:visible="dialogEsec" :id-esecuzione="idEsec" @cambiata="caricaEsecuzioni(); caricaElenco()" />
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 1rem; }
.titolo { margin: 0; }
.sotto { margin: 0; color: var(--p-text-muted-color); }
.testata { display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem; flex-wrap: wrap; }
.barra { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.barra label { display: flex; align-items: center; gap: .4rem; color: var(--p-text-muted-color); }
.colonne { display: grid; grid-template-columns: minmax(24rem, 30rem) 1fr; gap: 1rem; align-items: start; }
.elenco :deep(tr) { cursor: pointer; }
.dettaglio { border: 1px solid var(--p-content-border-color); border-radius: 8px; padding: .75rem 1rem; min-height: 20rem; }
.dettaglio.vuoto { display: flex; align-items: center; justify-content: center; }
.meta { display: flex; flex-wrap: wrap; gap: .3rem 1.2rem; color: var(--p-text-muted-color); font-size: .9rem; }
.split { display: grid; grid-template-columns: minmax(20rem, 26rem) 1fr; gap: 1rem; align-items: start; }
.albero { border-right: 1px solid var(--p-content-border-color); padding-right: .5rem; }
.tree { padding: 0; }
.tree :deep(.p-tree-node-content) { padding: .15rem .3rem; }
.nodo { display: inline-flex; align-items: center; gap: .4rem; font-size: .88rem; }
.nodo.off { opacity: .55; }
.ord { color: var(--p-text-muted-color); font-size: .8rem; }
.tipo { font-family: monospace; font-size: .8rem; color: var(--p-primary-color); }
.nuova { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; margin: .5rem 0; }
.nuova label { display: flex; align-items: center; gap: .3rem; color: var(--p-text-muted-color); }
.cron { width: 18rem; font-family: monospace; }
.anteprima { font-size: .85rem; color: var(--p-green-600); }
.anteprima.errore { color: var(--p-red-600); }
.pian { border: 1px solid var(--p-content-border-color); border-radius: 8px; padding: .5rem .75rem; margin-bottom: .75rem; }
.pian.ferma { opacity: .7; }
.pian h4 { margin: 0; display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.esec :deep(tr) { cursor: pointer; }
.nota { color: var(--p-text-muted-color); }
.errore { color: var(--p-red-600); }
.modulo { display: flex; flex-direction: column; gap: .7rem; }
.modulo label { display: flex; flex-direction: column; gap: .25rem; font-size: .9rem; color: var(--p-text-muted-color); }
.modulo label.riga { flex-direction: row; align-items: center; gap: .5rem; }
/* schermi stretti: elenco sopra il dettaglio, albero sopra l'editor */
@media (max-width: 1100px) {
  .colonne, .split { grid-template-columns: 1fr; }
  .albero { border-right: 0; border-bottom: 1px solid var(--p-content-border-color); padding: 0 0 .5rem; }
}
</style>
