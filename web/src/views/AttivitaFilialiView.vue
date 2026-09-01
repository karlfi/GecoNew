<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import { useAuthStore } from '../stores/auth'
import api from '../api'
import { frecceCampi } from '../lib/frecceGriglia'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import InputNumber from 'primevue/inputnumber'
import DatePicker from 'primevue/datepicker'
import Message from 'primevue/message'

// Attivita Filiali: contatori giornalieri per corriere della filiale corrente
// (FILIALI_ATTIVITA, mappa colonne da V_ElencoFilialiAttivita03).
// Salvataggio via SP AI_AttivitaFiliali_Save; la filiale arriva dal token.

const auth = useAuthStore()
const toast = useToast()
const errore = ref('')
const righe = ref([])
const caricamento = ref(false)

// ordine dei 18 contatori nell'array inviato all'API = ParamI01..ParamI18
const CORRIERI = ['Nexive', 'Hermes', 'InPost', 'iMile', 'Folletto', 'Gofo']
// gruppo -> indici ParamI (1-based) nell'ordine dei corrieri
const GRUPPI = [
  { nome: 'Arrivi', indici: [1, 2, 3, 4, 5, 16] },
  { nome: 'Distribuzione', indici: [6, 7, 8, 9, 10, 17] },
  { nome: 'Inventario', indici: [11, 12, 13, 14, 15, 18] }
]
const campo = i => `ParamI${String(i).padStart(2, '0')}`

const sel = ref(null)          // riga selezionata (o null)
const nuova = ref(false)
const form = ref(null)         // { IdAttivita, Data(Date), valori: {ParamI01: n, ...} }
const salvataggio = ref(false)

const totali = r => GRUPPI.map(g => g.indici.reduce((s, i) => s + (Number(r[campo(i)]) || 0), 0))

async function carica() {
  caricamento.value = true
  errore.value = ''
  try {
    const { data } = await api.get('/attivita-filiali')
    righe.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle attività'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)

function apri(riga) {
  nuova.value = !riga
  sel.value = riga ?? null
  const valori = {}
  for (let i = 1; i <= 18; i++) valori[campo(i)] = riga ? Number(riga[campo(i)]) || 0 : 0
  form.value = {
    IdAttivita: riga?.idAttivita ?? null,
    Data: riga ? new Date(riga.data) : new Date(),
    valori
  }
}

async function salva() {
  if (!form.value.Data) {
    toast.add({ severity: 'warn', summary: 'Data', detail: 'La data è obbligatoria', life: 3000 })
    return
  }
  salvataggio.value = true
  try {
    const d = form.value.Data
    const iso = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
    const contatori = []
    for (let i = 1; i <= 18; i++) contatori.push(form.value.valori[campo(i)] ?? 0)
    const { data } = await api.post('/attivita-filiali', {
      idAttivita: form.value.IdAttivita,
      data: iso,
      contatori
    })
    toast.add({ severity: 'success', summary: 'Attività salvata', detail: iso, life: 2500 })
    form.value.IdAttivita = data.id
    nuova.value = false
    await carica()
    sel.value = righe.value.find(r => r.idAttivita === data.id) ?? null
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Salvataggio', detail: e.response?.data?.errore ?? 'Errore imprevisto', life: 5000 })
  } finally {
    salvataggio.value = false
  }
}

const filiale = computed(() => auth.utente?.filiale?.nome ?? '')
function fmtData(v) {
  const d = new Date(v)
  return isNaN(d) ? v : d.toLocaleDateString('it-IT')
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Attività Filiali</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="layout">
      <!-- sinistra: giorni della filiale -->
      <div class="pannello elenco">
        <div class="pannello-titolo">
          {{ filiale }}
          <Button icon="pi pi-plus" label="Nuovo giorno" size="small" outlined @click="apri(null)" />
        </div>
        <DataTable
          :value="righe"
          v-model:selection="sel"
          selectionMode="single"
          dataKey="idAttivita"
          @rowSelect="e => apri(e.data)"
          :loading="caricamento"
          paginator :rows="15"
          size="small" stripedRows
        >
          <Column header="Data" style="width: 6.5rem">
            <template #body="{ data }">{{ fmtData(data.data) }}</template>
          </Column>
          <Column header="Arrivi" style="text-align: right">
            <template #body="{ data }">{{ totali(data)[0] }}</template>
          </Column>
          <Column header="Distrib." style="text-align: right">
            <template #body="{ data }">{{ totali(data)[1] }}</template>
          </Column>
          <Column header="Invent." style="text-align: right">
            <template #body="{ data }">{{ totali(data)[2] }}</template>
          </Column>
        </DataTable>
      </div>

      <!-- destra: form del giorno selezionato -->
      <div class="pannello dettaglio">
        <div class="pannello-titolo">
          {{ form ? (nuova ? 'Nuovo giorno' : `Attività del ${form.Data?.toLocaleDateString('it-IT') ?? ''}`) : 'Dettaglio' }}
        </div>
        <p v-if="!form" class="suggerimento">
          Seleziona un giorno dall'elenco oppure premi "Nuovo giorno".
        </p>
        <div v-else class="form">
          <label class="campo data">
            <span>Data</span>
            <DatePicker v-model="form.Data" dateFormat="dd/mm/yy" showIcon :disabled="!nuova" fluid />
          </label>

          <table class="griglia" @keydown="frecceCampi">
            <thead>
              <tr>
                <th></th>
                <th v-for="g in GRUPPI" :key="g.nome">{{ g.nome }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="(corriere, r) in CORRIERI" :key="corriere">
                <th>{{ corriere }}</th>
                <td v-for="g in GRUPPI" :key="g.nome">
                  <InputNumber
                    v-model="form.valori[campo(g.indici[r])]"
                    :useGrouping="false" :min="0"
                    inputClass="cella-num" fluid
                  />
                </td>
              </tr>
            </tbody>
          </table>

          <div class="azioni">
            <Button label="Salva" icon="pi pi-check" :loading="salvataggio" @click="salva" />
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.titolo { margin: 0 0 .75rem; }
.layout { display: flex; gap: 1rem; align-items: flex-start; }
.pannello { border: 1px solid var(--p-surface-200); border-radius: 6px; overflow: hidden; }
.elenco { flex: 0 0 420px; }
.dettaglio { flex: 1; min-width: 0; }
.pannello-titolo {
  background: var(--p-surface-50);
  padding: .35rem .75rem;
  font-weight: 600;
  font-size: .9rem;
  border-bottom: 1px solid var(--p-surface-200);
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 2.4rem;
}
.suggerimento { color: #888; font-size: .85rem; padding: .75rem; margin: 0; }
.form { padding: 1rem; display: flex; flex-direction: column; gap: 1rem; }
.campo { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; }
.campo > span { color: #555; }
.data { max-width: 220px; }

.griglia { border-collapse: collapse; }
.griglia th { font-size: .85rem; color: #444; text-align: left; padding: .3rem .6rem; }
.griglia thead th { text-align: center; }
.griglia td { padding: .2rem .6rem; }
.griglia :deep(.cella-num) { width: 7rem; text-align: right; }
.azioni { display: flex; justify-content: flex-end; }
</style>
