<script setup>
import { ref, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import Textarea from 'primevue/textarea'
import Checkbox from 'primevue/checkbox'
import Select from 'primevue/select'
import Message from 'primevue/message'
import ProgressSpinner from 'primevue/progressspinner'

// Replica della videata legacy "Azioni": processi a sinistra, azioni del
// processo in alto (tutte le colonne di SPED_AZIONI), e per l'azione
// selezionata il workflow (stati decodificati) e i processi collegati.
// Scritture SOLO via SP AI_Azioni_SaveAzione / SaveWorkflow / SaveProcessoAzione.

const toast = useToast()
const errore = ref('')
const processi = ref([])
const processoSel = ref(null)

const azioni = ref([])
const caricamentoAzioni = ref(false)
const azioneSel = ref(null)

const workflow = ref([])
const processiAzione = ref([])
const caricamentoDettaglio = ref(false)

// lookup: famiglie azione (FK SIST_FAMIGLIAAZIONI), tipi evento palmare, stati
const lookups = ref({ famiglie: [], tipiEventi: [], stati: [] })

// Colonne flag di SPED_AZIONI: convenzione legacy -1 = vero, 0/NULL = falso.
// NB: Chiedi_Scatola e ControlloData NON sono flag (hanno valori 2,3,4 e -9..1).
const FLAGS = [
  'Attivo', 'PortaSuPalmare', 'Forzabile', 'EsitoFinale', 'AggiornaSpedizione',
  'ForzaFiliale', 'MantieniDataPrec', 'AttiChiusi',
  'Chiedi_Operatore', 'Chiedi_Citta', 'Chiedi_Filiale', 'Chiedi_Distinta',
  'Chiedi_FilialeDest', 'Chiedi_FilialeGiac', 'Chiedi_Resi', 'Chiedi_Terzi',
  'Chiedi_Cartolina'
]
const FLAG_SET = new Set(FLAGS)
const CAMPI_TESTO = ['Stato_Inizio', 'Stato_Fine', 'IdProcessi', 'TipoDistinta', 'WebReport', 'Param1_Tipo', 'Param1_Desc']
const CAMPI_NUMERO = ['Ordine', 'Chiedi_Scatola', 'IdProdottoGenerato', 'MaxAtti', 'ControlloData']
const colonne = ref([])   // nomi colonna nell'ordine restituito dall'API

onMounted(async () => {
  try {
    const [proc, lk] = await Promise.all([
      api.get('/workflow/processi'),
      api.get('/azioni/lookups')
    ])
    processi.value = proc.data
    lookups.value = lk.data
    if (proc.data.length) selezionaProcesso(proc.data[0])
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei processi'
  }
})

async function selezionaProcesso(p) {
  processoSel.value = p
  azioneSel.value = null
  workflow.value = []
  processiAzione.value = []
  caricamentoAzioni.value = true
  errore.value = ''
  try {
    const { data } = await api.get(`/azioni/processo/${p.idProcesso}`)
    azioni.value = data
    if (data.length && !colonne.value.length) colonne.value = Object.keys(data[0])
  } catch (e) {
    azioni.value = []
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle azioni'
  } finally {
    caricamentoAzioni.value = false
  }
}

async function caricaDettaglio() {
  if (!azioneSel.value) return
  caricamentoDettaglio.value = true
  try {
    const [wf, pa] = await Promise.all([
      api.get(`/azioni/${azioneSel.value.IdAzione}/workflow`),
      api.get(`/azioni/${azioneSel.value.IdAzione}/processi`)
    ])
    workflow.value = wf.data
    processiAzione.value = pa.data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? "Errore nel caricamento del dettaglio dell'azione"
  } finally {
    caricamentoDettaglio.value = false
  }
}

async function ricaricaAzioni(idDaSelezionare) {
  const { data } = await api.get(`/azioni/processo/${processoSel.value.idProcesso}`)
  azioni.value = data
  if (idDaSelezionare != null) {
    azioneSel.value = data.find(a => a.IdAzione === idDaSelezionare) ?? null
    await caricaDettaglio()
  }
}

function toastErr(e, titolo) {
  toast.add({ severity: 'error', summary: titolo, detail: e.response?.data?.errore ?? 'Errore imprevisto', life: 5000 })
}
function toastOk(titolo, dettaglio) {
  toast.add({ severity: 'success', summary: titolo, detail: dettaglio, life: 2500 })
}

// === Dialog azione (nuova / modifica) =======================================
const dlgAzione = ref(false)
const azNuova = ref(false)
const azForm = ref({})
const azSalva = ref(false)

function vuotoAzione() {
  const f = { IdAzione: null, Azione: '', CodFamigliaAzione: null, Descrizione: '' }
  for (const c of CAMPI_TESTO) f[c] = ''
  for (const c of CAMPI_NUMERO) f[c] = null
  for (const c of FLAGS) f[c] = false
  return f
}
function apriNuovaAzione() {
  azNuova.value = true
  azForm.value = vuotoAzione()
  dlgAzione.value = true
}
function apriModificaAzione(riga) {
  azNuova.value = false
  const f = vuotoAzione()
  f.IdAzione = riga.IdAzione
  f.Azione = riga.Azione ?? ''
  f.CodFamigliaAzione = riga.CodFamigliaAzione ?? null
  f.Descrizione = riga.Descrizione ?? ''
  for (const c of CAMPI_TESTO) f[c] = riga[c] ?? ''
  for (const c of CAMPI_NUMERO) f[c] = riga[c] ?? null
  for (const c of FLAGS) f[c] = Number(riga[c]) === -1
  azForm.value = f
  dlgAzione.value = true
}
async function salvaAzione() {
  if (!azForm.value.Azione?.trim()) {
    toast.add({ severity: 'warn', summary: 'Azione', detail: 'Il nome dell\'azione è obbligatorio', life: 3000 })
    return
  }
  azSalva.value = true
  try {
    const f = azForm.value
    const payload = {
      IdAzione: f.IdAzione,
      Azione: f.Azione,
      CodFamigliaAzione: f.CodFamigliaAzione,
      Descrizione: f.Descrizione
    }
    for (const c of CAMPI_TESTO) payload[c] = f[c] || null
    for (const c of CAMPI_NUMERO) payload[c] = f[c]
    for (const c of FLAGS) payload[c] = f[c] ? -1 : 0
    if (azNuova.value) payload.IdProcesso = processoSel.value?.idProcesso
    const { data } = await api.post('/azioni/azione', payload)
    dlgAzione.value = false
    toastOk('Azione salvata', `${f.Azione} (Id ${data.id})`)
    await ricaricaAzioni(data.id)
  } catch (e) {
    toastErr(e, 'Salvataggio azione')
  } finally {
    azSalva.value = false
  }
}

// === Dialog workflow (nuova transizione / modifica) =========================
const dlgWf = ref(false)
const wfForm = ref({})
const wfSalva = ref(false)

function apriWf(riga) {
  wfForm.value = riga
    ? { IdWorkflow: riga.idWorkflow, Stato_Inizio: riga.statoInizio, Stato_Fine: riga.statoFine, GiorniSLA: riga.giorniSLA }
    : { IdWorkflow: null, Stato_Inizio: null, Stato_Fine: null, GiorniSLA: null }
  dlgWf.value = true
}
async function salvaWf() {
  wfSalva.value = true
  try {
    await api.post('/azioni/workflow', { ...wfForm.value, IdAzione: azioneSel.value.IdAzione })
    dlgWf.value = false
    toastOk('Workflow salvato')
    await caricaDettaglio()
  } catch (e) {
    toastErr(e, 'Salvataggio workflow')
  } finally {
    wfSalva.value = false
  }
}

// === Dialog processo collegato (nuovo / modifica) ===========================
const dlgPa = ref(false)
const paForm = ref({})
const paSalva = ref(false)

function apriPa(riga) {
  paForm.value = riga
    ? { IdProcessoAzione: riga.idProcessoAzione, IdProcesso: riga.idProcesso, TipoEventoCodice: riga.tipoEventoCodice }
    : { IdProcessoAzione: null, IdProcesso: processoSel.value?.idProcesso ?? null, TipoEventoCodice: null }
  dlgPa.value = true
}
async function salvaPa() {
  if (!paForm.value.IdProcesso) {
    toast.add({ severity: 'warn', summary: 'Processo', detail: 'Scegli il processo da collegare', life: 3000 })
    return
  }
  paSalva.value = true
  try {
    await api.post('/azioni/processo-azione', { ...paForm.value, IdAzione: azioneSel.value.IdAzione })
    dlgPa.value = false
    toastOk('Collegamento salvato')
    await caricaDettaglio()
  } catch (e) {
    toastErr(e, 'Salvataggio collegamento')
  } finally {
    paSalva.value = false
  }
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Azioni <span class="old">(OLD)</span></h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="layout">
      <!-- sinistra: scelta processo -->
      <aside class="processi">
        <div class="pannello-titolo">Scelta Processo</div>
        <ul>
          <li
            v-for="p in processi"
            :key="p.idProcesso"
            :class="{ attivo: processoSel?.idProcesso === p.idProcesso }"
            @click="selezionaProcesso(p)"
          >
            {{ p.processo }}
          </li>
        </ul>
      </aside>

      <section class="destra">
        <!-- alto: azioni del processo, tutte le colonne -->
        <div class="pannello">
          <div class="pannello-titolo">
            Azioni{{ processoSel ? ` — ${processoSel.processo}` : '' }}
            <span class="strumenti">
              <span v-if="azioni.length" class="conteggio">{{ azioni.length }} azioni</span>
              <Button
                icon="pi pi-plus" label="Nuova azione" size="small" outlined
                :disabled="!processoSel" @click="apriNuovaAzione"
              />
            </span>
          </div>
          <ProgressSpinner v-if="caricamentoAzioni" class="spinner" />
          <DataTable
            v-else
            :value="azioni"
            v-model:selection="azioneSel"
            selectionMode="single"
            dataKey="IdAzione"
            @rowSelect="caricaDettaglio"
            scrollable
            scrollHeight="360px"
            size="small"
            stripedRows
            class="tabella-azioni"
          >
            <Column frozen class="col-edit">
              <template #body="{ data }">
                <Button
                  icon="pi pi-pencil" text rounded size="small" title="Modifica azione"
                  @click.stop="apriModificaAzione(data)"
                />
              </template>
            </Column>
            <Column
              v-for="c in colonne"
              :key="c"
              :field="c"
              :header="c"
              :frozen="c === 'IdAzione' || c === 'Azione'"
            >
              <template #body="{ data }">
                <i v-if="FLAG_SET.has(c) && Number(data[c]) === -1" class="pi pi-check spunta" />
                <template v-else-if="FLAG_SET.has(c)"></template>
                <template v-else>{{ data[c] }}</template>
              </template>
            </Column>
          </DataTable>
        </div>

        <div class="basso">
          <!-- basso sinistra: workflow dell'azione -->
          <div class="pannello">
            <div class="pannello-titolo">
              Workflow{{ azioneSel ? ` — ${azioneSel.Azione}` : '' }}
              <span class="strumenti">
                <span v-if="workflow.length" class="conteggio">{{ workflow.length }} transizioni</span>
                <Button
                  icon="pi pi-plus" label="Aggiungi" size="small" outlined
                  :disabled="!azioneSel" @click="apriWf(null)"
                />
              </span>
            </div>
            <p v-if="!azioneSel" class="suggerimento">Seleziona un'azione per vedere le transizioni di stato.</p>
            <DataTable v-else :value="workflow" size="small" stripedRows scrollable scrollHeight="300px" :loading="caricamentoDettaglio">
              <Column class="col-edit">
                <template #body="{ data }">
                  <Button icon="pi pi-pencil" text rounded size="small" title="Modifica" @click="apriWf(data)" />
                </template>
              </Column>
              <Column field="statoInizio" header="Stato Inizio" />
              <Column field="descInizio" header="Descrizione" />
              <Column field="statoFine" header="Stato Fine" />
              <Column field="descFine" header="Descrizione" />
              <Column field="giorniSLA" header="Giorni SLA" />
            </DataTable>
          </div>

          <!-- basso destra: processi collegati all'azione -->
          <div class="pannello">
            <div class="pannello-titolo">
              Processi associati
              <span class="strumenti">
                <span v-if="processiAzione.length" class="conteggio">{{ processiAzione.length }}</span>
                <Button
                  icon="pi pi-plus" label="Aggiungi" size="small" outlined
                  :disabled="!azioneSel" @click="apriPa(null)"
                />
              </span>
            </div>
            <p v-if="!azioneSel" class="suggerimento">Seleziona un'azione per vedere i processi collegati.</p>
            <DataTable v-else :value="processiAzione" size="small" stripedRows scrollable scrollHeight="300px" :loading="caricamentoDettaglio">
              <Column class="col-edit">
                <template #body="{ data }">
                  <Button icon="pi pi-pencil" text rounded size="small" title="Modifica" @click="apriPa(data)" />
                </template>
              </Column>
              <Column field="processo" header="Processo" />
              <Column field="tipoEventoCodice" header="Tipo Evento Codice" />
              <Column field="evento" header="Evento" />
            </DataTable>
          </div>
        </div>
      </section>
    </div>

    <!-- ==================== dialog azione ==================== -->
    <Dialog
      v-model:visible="dlgAzione" modal
      :header="azNuova ? `Nuova azione — ${processoSel?.processo ?? ''}` : `Modifica azione ${azForm.IdAzione} — ${azForm.Azione}`"
      :style="{ width: '860px', maxWidth: '95vw' }"
    >
      <div class="form-griglia">
        <label class="campo campo-largo">
          <span>Azione *</span>
          <InputText v-model="azForm.Azione" maxlength="50" fluid />
        </label>
        <label class="campo">
          <span>Famiglia azione</span>
          <Select
            v-model="azForm.CodFamigliaAzione" :options="lookups.famiglie"
            optionValue="codFamigliaAzione"
            :optionLabel="o => `${o.codFamigliaAzione} — ${o.famigliaAzione}`"
            showClear filter fluid
          />
        </label>
        <label class="campo">
          <span>Ordine</span>
          <InputNumber v-model="azForm.Ordine" :useGrouping="false" fluid />
        </label>

        <label v-for="c in CAMPI_TESTO" :key="c" class="campo">
          <span>{{ c }}</span>
          <InputText v-model="azForm[c]" maxlength="50" fluid />
        </label>
        <label v-for="c in CAMPI_NUMERO.filter(x => x !== 'Ordine')" :key="c" class="campo">
          <span>{{ c }}</span>
          <InputNumber v-model="azForm[c]" :useGrouping="false" fluid />
        </label>

        <label class="campo campo-tutto">
          <span>Descrizione</span>
          <Textarea v-model="azForm.Descrizione" rows="2" maxlength="1000" fluid />
        </label>

        <div class="campo campo-tutto flags">
          <label v-for="c in FLAGS" :key="c" class="flag">
            <Checkbox v-model="azForm[c]" binary />
            <span>{{ c }}</span>
          </label>
        </div>
      </div>
      <template #footer>
        <Button label="Annulla" text @click="dlgAzione = false" />
        <Button label="Salva" icon="pi pi-check" :loading="azSalva" @click="salvaAzione" />
      </template>
    </Dialog>

    <!-- ==================== dialog workflow ==================== -->
    <Dialog
      v-model:visible="dlgWf" modal
      :header="wfForm.IdWorkflow ? `Modifica transizione ${wfForm.IdWorkflow}` : `Nuova transizione — ${azioneSel?.Azione ?? ''}`"
      :style="{ width: '480px', maxWidth: '95vw' }"
    >
      <div class="form-colonna">
        <label class="campo">
          <span>Stato inizio</span>
          <Select
            v-model="wfForm.Stato_Inizio" :options="lookups.stati"
            optionValue="stato" :optionLabel="o => `${o.stato} — ${o.descrizione ?? ''}`"
            showClear filter fluid
          />
        </label>
        <label class="campo">
          <span>Stato fine</span>
          <Select
            v-model="wfForm.Stato_Fine" :options="lookups.stati"
            optionValue="stato" :optionLabel="o => `${o.stato} — ${o.descrizione ?? ''}`"
            showClear filter fluid
          />
        </label>
        <label class="campo">
          <span>Giorni SLA</span>
          <InputNumber v-model="wfForm.GiorniSLA" :useGrouping="false" fluid />
        </label>
      </div>
      <template #footer>
        <Button label="Annulla" text @click="dlgWf = false" />
        <Button label="Salva" icon="pi pi-check" :loading="wfSalva" @click="salvaWf" />
      </template>
    </Dialog>

    <!-- ==================== dialog processo collegato ==================== -->
    <Dialog
      v-model:visible="dlgPa" modal
      :header="paForm.IdProcessoAzione ? 'Modifica collegamento' : `Collega processo — ${azioneSel?.Azione ?? ''}`"
      :style="{ width: '480px', maxWidth: '95vw' }"
    >
      <div class="form-colonna">
        <label class="campo">
          <span>Processo *</span>
          <Select
            v-model="paForm.IdProcesso" :options="processi"
            optionValue="idProcesso" optionLabel="processo"
            filter fluid
          />
        </label>
        <label class="campo">
          <span>Tipo evento (palmare)</span>
          <Select
            v-model="paForm.TipoEventoCodice" :options="lookups.tipiEventi"
            optionValue="tipoEventoCodice" :optionLabel="o => `${o.tipoEventoCodice} — ${o.evento ?? ''}`"
            showClear filter fluid
          />
        </label>
      </div>
      <template #footer>
        <Button label="Annulla" text @click="dlgPa = false" />
        <Button label="Salva" icon="pi pi-check" :loading="paSalva" @click="salvaPa" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.titolo { margin: 0 0 .75rem; }
.old { color: #9aa4ad; font-weight: 400; font-size: .8em; }
.layout { display: flex; gap: 1rem; align-items: flex-start; }

.processi {
  flex: 0 0 230px;
  border: 1px solid var(--p-surface-200);
  border-radius: 6px;
  overflow: hidden;
}
.processi ul { list-style: none; margin: 0; padding: 0; max-height: 75vh; overflow-y: auto; }
.processi li {
  padding: .45rem .75rem;
  font-size: .875rem;
  cursor: pointer;
  border-top: 1px solid var(--p-surface-100);
}
.processi li:hover { background: var(--p-surface-100); }
.processi li.attivo { background: #e3f2fd; color: #00628f; font-weight: 600; }

.destra { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1rem; }
.pannello { border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; }
.pannello-titolo {
  background: var(--p-surface-50);
  padding: .35rem .75rem;
  font-weight: 600;
  font-size: .9rem;
  border-bottom: 1px solid var(--p-surface-200);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: .75rem;
  min-height: 2.4rem;
}
.strumenti { display: flex; align-items: center; gap: .75rem; font-weight: 400; }
.conteggio { color: #888; font-size: .8rem; }
.basso { display: grid; grid-template-columns: 3fr 2fr; gap: 1rem; }
.suggerimento { color: #888; font-size: .85rem; padding: .75rem; margin: 0; }
.spinner { display: block; margin: 2rem auto; width: 40px; height: 40px; }
.tabella-azioni { font-size: .8rem; }
.spunta { color: #29b96e; }
.col-edit { width: 2.5rem; padding: 0 .25rem; }

/* form del dialog azione */
.form-griglia {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: .75rem 1rem;
}
.campo { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; }
.campo > span { color: #555; }
.campo-largo { grid-column: span 2; }
.campo-tutto { grid-column: 1 / -1; }
.flags {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: .4rem 1rem;
  border: 1px solid var(--p-surface-200);
  border-radius: 6px;
  padding: .75rem;
}
.flag { display: flex; align-items: center; gap: .5rem; font-size: .85rem; cursor: pointer; }
.form-colonna { display: flex; flex-direction: column; gap: .75rem; }
</style>
