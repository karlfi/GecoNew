<script setup>
import { ref, computed, watch, onMounted, nextTick } from 'vue'
import { VueFlow, useVueFlow, MarkerType } from '@vue-flow/core'
import { Background } from '@vue-flow/background'
import { Controls } from '@vue-flow/controls'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { layoutStati } from '../lib/layout'
import Select from 'primevue/select'
import MultiSelect from 'primevue/multiselect'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputNumber from 'primevue/inputnumber'
import Message from 'primevue/message'
import ProgressSpinner from 'primevue/progressspinner'

const toast = useToast()
const { onConnect, fitView } = useVueFlow()

const processi = ref([])
const idProcesso = ref(null)
const caricamento = ref(false)
const errore = ref('')
const nodiRaw = ref([])
const archiRaw = ref([])
const azioni = ref([])
const tuttiStati = ref([])

const filtroAzioni = ref([])     // IdAzione selezionati; vuoto = tutte
const statoFocus = ref(null)     // evidenzia il vicinato di uno stato

// opzioni stato con etichetta precalcolata (PrimeVue Select vuole optionLabel come campo)
const statiOpzioni = computed(() =>
  tuttiStati.value.map(s => ({ stato: s.stato, label: `${s.stato} — ${s.descrizione ?? ''}` })))

const COLORI_GRUPPO = {}
const PALETTE = ['#00afde', '#7e57c2', '#26a69a', '#ef5350', '#ffa726', '#66bb6a',
  '#42a5f5', '#ec407a', '#8d6e63', '#5c6bc0', '#26c6da', '#9ccc65']
function coloreGruppo(g) {
  if (!g) return '#90a4ae'
  if (!(g in COLORI_GRUPPO)) {
    COLORI_GRUPPO[g] = PALETTE[Object.keys(COLORI_GRUPPO).length % PALETTE.length]
  }
  return COLORI_GRUPPO[g]
}

onMounted(async () => {
  try {
    const [{ data: proc }, { data: stati }] = await Promise.all([
      api.get('/workflow/processi'),
      api.get('/workflow/stati')
    ])
    processi.value = proc
    tuttiStati.value = stati
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento iniziale'
  }
})

async function caricaProcesso() {
  if (!idProcesso.value) return
  caricamento.value = true
  errore.value = ''
  filtroAzioni.value = []
  statoFocus.value = null
  try {
    const { data } = await api.get(`/workflow/${idProcesso.value}`)
    nodiRaw.value = data.nodi
    archiRaw.value = data.archi
    azioni.value = data.azioni
    await nextTick()
    setTimeout(() => fitView({ padding: 0.2 }), 80)
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento del processo'
  } finally {
    caricamento.value = false
  }
}
watch(idProcesso, caricaProcesso)

// archi visibili in base al filtro azioni
const archiVisibili = computed(() => {
  if (!filtroAzioni.value.length) return archiRaw.value
  const set = new Set(filtroAzioni.value)
  return archiRaw.value.filter(a => set.has(a.idAzione))
})

// stati toccati dagli archi visibili (per evidenziare il vicinato del focus)
const viciniDiFocus = computed(() => {
  if (!statoFocus.value) return null
  const set = new Set([statoFocus.value])
  for (const a of archiVisibili.value) {
    if (a.statoInizio === statoFocus.value) set.add(a.statoFine)
    if (a.statoFine === statoFocus.value) set.add(a.statoInizio)
  }
  return set
})

// --- costruzione nodi/archi per Vue Flow ---
const elements = computed(() => {
  const pos = layoutStati(nodiRaw.value, archiVisibili.value)
  const nodi = nodiRaw.value.map(n => {
    const attivo = !viciniDiFocus.value || viciniDiFocus.value.has(n.stato)
    return {
      id: n.stato,
      type: 'default',
      position: pos[n.stato] ?? { x: 0, y: 0 },
      data: { label: `${n.stato} — ${n.descrizione ?? ''}`, gruppo: n.gruppo },
      style: {
        width: '170px',
        fontSize: '11px',
        borderRadius: '8px',
        border: `2px solid ${coloreGruppo(n.gruppo)}`,
        background: '#fff',
        opacity: attivo ? 1 : 0.25,
        padding: '4px 6px'
      }
    }
  })
  // più archi tra gli stessi stati: li distinguo con un indice di curvatura
  const conteggio = {}
  const archi = archiVisibili.value.map(a => {
    const k = `${a.statoInizio}->${a.statoFine}`
    const i = (conteggio[k] = (conteggio[k] ?? 0) + 1)
    const attivo = !viciniDiFocus.value
      || (viciniDiFocus.value.has(a.statoInizio) && viciniDiFocus.value.has(a.statoFine))
    return {
      id: `e${a.idWorkflow}`,
      source: a.statoInizio,
      target: a.statoFine,
      label: a.azione + (a.giorniSLA ? ` (${a.giorniSLA}g)` : ''),
      type: 'smoothstep',
      animated: false,
      data: a,
      labelStyle: { fontSize: '10px' },
      labelBgStyle: { fill: '#fff', fillOpacity: 0.8 },
      style: { stroke: '#90a4ae', strokeWidth: 1.5, opacity: attivo ? 1 : 0.12 },
      markerEnd: MarkerType.ArrowClosed,
      // offset visuale per archi paralleli
      pathOptions: { offset: (i - 1) * 16 }
    }
  })
  return [...nodi, ...archi]
})

// --- editing transizione ---
const dlgArco = ref(false)
const arcoEdit = ref(null)
const salvataggio = ref(false)

function apriArco(_, edge) {
  arcoEdit.value = { ...edge.data }
  dlgArco.value = true
}
function nuovaTransizione(statoInizio = null, statoFine = null) {
  arcoEdit.value = {
    idWorkflow: null, idAzione: azioni.value[0]?.idAzione ?? null,
    statoInizio, statoFine, giorniSLA: null
  }
  dlgArco.value = true
}
onConnect(params => nuovaTransizione(params.source, params.target))

async function salvaArco() {
  salvataggio.value = true
  try {
    await api.post('/workflow/transizione', {
      IdWorkflow: arcoEdit.value.idWorkflow,
      IdAzione: arcoEdit.value.idAzione,
      Stato_Inizio: arcoEdit.value.statoInizio,
      Stato_Fine: arcoEdit.value.statoFine,
      GiorniSLA: arcoEdit.value.giorniSLA
    })
    dlgArco.value = false
    toast.add({ severity: 'success', summary: 'Transizione salvata', life: 1800 })
    await caricaProcesso()
  } catch (e) {
    toast.add({
      severity: 'error', summary: 'Errore',
      detail: e.response?.data?.errore ?? 'Salvataggio fallito', life: 5000
    })
  } finally {
    salvataggio.value = false
  }
}

function onNodeClick(_, node) {
  statoFocus.value = statoFocus.value === node.id ? null : node.id
}
</script>

<template>
  <div class="wf">
    <div class="wf-bar">
      <h2>Azioni / Workflow</h2>
      <Select
        v-model="idProcesso"
        :options="processi"
        optionLabel="processo"
        optionValue="idProcesso"
        placeholder="Seleziona un processo"
        filter
        class="sel-proc"
      />
      <template v-if="nodiRaw.length">
        <MultiSelect
          v-model="filtroAzioni"
          :options="azioni"
          optionLabel="azione"
          optionValue="idAzione"
          placeholder="Filtra per azione"
          display="chip"
          filter
          class="sel-az"
          :maxSelectedLabels="2"
        />
        <span class="conta">{{ nodiRaw.length }} stati · {{ archiVisibili.length }} transizioni</span>
        <Button label="Nuova transizione" icon="pi pi-plus" size="small" text @click="nuovaTransizione()" />
        <Button v-if="statoFocus" :label="`Focus: ${statoFocus}`" icon="pi pi-times" size="small"
                severity="secondary" @click="statoFocus = null" />
      </template>
    </div>

    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div v-if="caricamento" class="centro"><ProgressSpinner /></div>

    <div v-else-if="!idProcesso" class="centro vuoto">
      Seleziona un processo per visualizzarne la macchina a stati.
    </div>

    <div v-else class="canvas">
      <VueFlow
        :nodes="elements.filter(e => !e.source)"
        :edges="elements.filter(e => e.source)"
        :min-zoom="0.1"
        :max-zoom="2"
        fit-view-on-init
        @edge-click="apriArco"
        @node-click="onNodeClick"
      >
        <Background pattern-color="#ddd" :gap="18" />
        <Controls />
      </VueFlow>
    </div>

    <Dialog v-model:visible="dlgArco" :header="arcoEdit?.idWorkflow ? 'Modifica transizione' : 'Nuova transizione'"
            modal :style="{ width: '480px' }">
      <div v-if="arcoEdit" class="form">
        <label>Azione</label>
        <Select v-model="arcoEdit.idAzione" :options="azioni" optionLabel="azione" optionValue="idAzione" filter />
        <label>Stato inizio</label>
        <Select v-model="arcoEdit.statoInizio" :options="statiOpzioni" optionValue="stato" optionLabel="label" filter />
        <label>Stato fine</label>
        <Select v-model="arcoEdit.statoFine" :options="statiOpzioni" optionValue="stato" optionLabel="label" filter />
        <label>Giorni SLA</label>
        <InputNumber v-model="arcoEdit.giorniSLA" :useGrouping="false" />
      </div>
      <template #footer>
        <Button label="Annulla" text severity="secondary" @click="dlgArco = false" />
        <Button label="Salva" icon="pi pi-check" :loading="salvataggio"
                :disabled="!arcoEdit?.idAzione || !arcoEdit?.statoInizio || !arcoEdit?.statoFine"
                @click="salvaArco" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.wf {
  display: flex;
  flex-direction: column;
  height: 100%;
  gap: .5rem;
}
.wf-bar {
  display: flex;
  align-items: center;
  gap: .75rem;
  flex-wrap: wrap;
}
.wf-bar h2 { margin: 0; }
.sel-proc { min-width: 240px; }
.sel-az { min-width: 240px; }
.conta { color: #666; font-size: .85rem; white-space: nowrap; }
.centro {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: 1;
}
.vuoto { color: #888; }
.canvas {
  flex: 1;
  min-height: 0;
  border: 1px solid var(--p-surface-200);
  border-radius: 8px;
  overflow: hidden;
}
.form {
  display: flex;
  flex-direction: column;
  gap: .35rem;
}
.form label { font-size: .8rem; font-weight: 600; margin-top: .4rem; }
</style>
