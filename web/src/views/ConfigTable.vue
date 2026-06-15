<script setup>
import { ref, computed, watch, onMounted } from 'vue'
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
import DatePicker from 'primevue/datepicker'
import IconField from 'primevue/iconfield'
import InputIcon from 'primevue/inputicon'
import Message from 'primevue/message'
import ProgressSpinner from 'primevue/progressspinner'

const props = defineProps({
  configKey: { type: String, required: true },
  titolo: { type: String, default: '' }
})

const toast = useToast()
const errore = ref('')
const caricamento = ref(false)
const schema = ref(null)            // { key, tabella, pk, colonne[] }
const rows = ref([])
const total = ref(0)
const lazy = ref({ page: 0, size: 50, sort: null, dir: 'asc', q: '' })

const colonneVisibili = computed(() => schema.value?.colonne.filter(c => !c.binario) ?? [])

async function caricaSchema() {
  const { data } = await api.get(`/config/${props.configKey}/schema`)
  schema.value = data
  lazy.value.sort = data.pk
}

async function caricaDati() {
  caricamento.value = true
  errore.value = ''
  try {
    const { page, size, sort, dir, q } = lazy.value
    const { data } = await api.get(`/config/${props.configKey}`, {
      params: { page, size, sort, dir, q: q || undefined }
    })
    rows.value = data.rows
    total.value = data.total
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei dati'
  } finally {
    caricamento.value = false
  }
}

onMounted(async () => {
  try {
    await caricaSchema()
    await caricaDati()
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dello schema'
  }
})

function onPage(e) {
  lazy.value.page = e.page
  lazy.value.size = e.rows
  caricaDati()
}
function onSort(e) {
  lazy.value.sort = e.sortField
  lazy.value.dir = e.sortOrder === -1 ? 'desc' : 'asc'
  lazy.value.page = 0
  caricaDati()
}
let tmr
watch(() => lazy.value.q, () => {
  clearTimeout(tmr)
  tmr = setTimeout(() => { lazy.value.page = 0; caricaDati() }, 350)
})

// --- formattazione celle ---
function formatta(v) {
  if (v == null) return ''
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v)) {
    const d = new Date(v)
    if (!isNaN(d)) {
      const data = d.toLocaleDateString('it-IT')
      const ore = d.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })
      return ore === '00:00' ? data : `${data} ${ore}`
    }
  }
  return v
}

// --- dialog di modifica/inserimento ---
const dialogVisibile = ref(false)
const editRow = ref({})
const nuovo = ref(false)
const salvataggio = ref(false)

function apriNuovo() {
  nuovo.value = true
  const r = {}
  for (const c of schema.value.colonne) r[c.nome] = c.data ? null : (c.numero ? null : null)
  editRow.value = r
  dialogVisibile.value = true
}
function apriModifica(riga) {
  nuovo.value = false
  const r = { ...riga }
  // le date arrivano come stringa ISO -> Date per il DatePicker
  for (const c of schema.value.colonne) {
    if (c.data && r[c.nome]) {
      const d = new Date(r[c.nome])
      r[c.nome] = isNaN(d) ? null : d
    }
  }
  editRow.value = r
  dialogVisibile.value = true
}

function toIsoDate(d) {
  if (!(d instanceof Date) || isNaN(d)) return null
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const g = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${g}`
}

async function salva() {
  salvataggio.value = true
  try {
    const payload = {}
    for (const c of schema.value.colonne) {
      if (c.binario) continue
      let v = editRow.value[c.nome]
      if (c.data && v instanceof Date) v = toIsoDate(v)
      payload[c.nome] = v ?? null
    }
    await api.post(`/config/${props.configKey}`, payload)
    dialogVisibile.value = false
    toast.add({ severity: 'success', summary: 'Salvato', life: 1800 })
    await caricaDati()
  } catch (e) {
    toast.add({
      severity: 'error',
      summary: 'Errore salvataggio',
      detail: e.response?.data?.errore ?? 'Errore imprevisto',
      life: 5000
    })
  } finally {
    salvataggio.value = false
  }
}
</script>

<template>
  <div class="config">
    <div class="testata">
      <h2>{{ titolo || configKey }}</h2>
      <div class="azioni">
        <span v-if="total" class="conta">{{ total }} record</span>
        <IconField>
          <InputIcon class="pi pi-search" />
          <InputText v-model="lazy.q" placeholder="Cerca..." size="small" />
        </IconField>
        <Button label="Nuovo" icon="pi pi-plus" size="small" :disabled="!schema" @click="apriNuovo" />
      </div>
    </div>

    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <DataTable
      :value="rows"
      lazy
      paginator
      :rows="lazy.size"
      :totalRecords="total"
      :rowsPerPageOptions="[20, 50, 100, 500]"
      :loading="caricamento"
      @page="onPage"
      @sort="onSort"
      scrollable
      scrollHeight="flex"
      size="small"
      stripedRows
      showGridlines
      class="griglia"
    >
      <Column header="" :exportable="false" style="width: 3rem">
        <template #body="{ data }">
          <Button icon="pi pi-pencil" text rounded size="small" @click="apriModifica(data)" />
        </template>
      </Column>
      <Column v-for="c in colonneVisibili" :key="c.nome" :field="c.nome" :header="c.nome" sortable>
        <template #body="{ data }">{{ formatta(data[c.nome]) }}</template>
      </Column>
      <template #empty>
        <div v-if="!caricamento" class="vuoto">Nessun record</div>
      </template>
    </DataTable>

    <Dialog
      v-model:visible="dialogVisibile"
      :header="(nuovo ? 'Nuovo' : 'Modifica') + ' — ' + (titolo || configKey)"
      modal
      :style="{ width: '720px' }"
      maximizable
    >
      <div v-if="schema" class="form">
        <div v-for="c in schema.colonne" :key="c.nome" class="campo" :class="{ binario: c.binario }">
          <label :for="c.nome">
            {{ c.nome }}
            <span v-if="c.obbligatorio" class="req">*</span>
            <small v-if="c.pk" class="badge">PK</small>
            <small class="tipo">{{ c.tipo }}{{ c.lunghezza ? `(${c.lunghezza})` : '' }}</small>
          </label>

          <span v-if="c.binario" class="binario-nota">campo binario, non modificabile da qui</span>
          <InputText
            v-else-if="c.readonly_"
            :id="c.nome"
            :modelValue="editRow[c.nome]"
            disabled
            :placeholder="nuovo ? '(assegnato al salvataggio)' : ''"
          />
          <DatePicker
            v-else-if="c.data"
            :id="c.nome"
            v-model="editRow[c.nome]"
            dateFormat="dd/mm/yy"
            showButtonBar
            showIcon
          />
          <InputNumber
            v-else-if="c.numero"
            :id="c.nome"
            v-model="editRow[c.nome]"
            :useGrouping="false"
            :maxFractionDigits="['float','decimal','numeric','money','real'].includes(c.tipo) ? 4 : 0"
          />
          <Textarea
            v-else-if="c.testo && (!c.lunghezza || c.lunghezza > 200)"
            :id="c.nome"
            v-model="editRow[c.nome]"
            rows="3"
            autoResize
          />
          <InputText
            v-else
            :id="c.nome"
            v-model="editRow[c.nome]"
            :maxlength="c.lunghezza || undefined"
          />
        </div>
      </div>

      <template #footer>
        <Button label="Annulla" severity="secondary" text @click="dialogVisibile = false" />
        <Button label="Salva" icon="pi pi-check" :loading="salvataggio" @click="salva" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.config {
  display: flex;
  flex-direction: column;
  height: 100%;
  gap: .5rem;
}
.testata {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
}
.testata h2 { margin: 0; }
.azioni {
  display: flex;
  align-items: center;
  gap: .75rem;
}
.conta {
  color: #666;
  font-size: .85rem;
  white-space: nowrap;
}
.griglia {
  flex: 1;
  min-height: 0;
}
.griglia :deep(.p-datatable-tbody > tr > td),
.griglia :deep(.p-datatable-thead > tr > th) {
  padding: .35rem .6rem;
  font-size: .85rem;
}
.vuoto {
  text-align: center;
  color: #888;
  padding: 1rem;
}
.form {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: .9rem 1.25rem;
}
.campo {
  display: flex;
  flex-direction: column;
  gap: .25rem;
}
.campo.binario { opacity: .6; }
.campo label {
  font-size: .8rem;
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: .4rem;
}
.campo :deep(.p-inputtext),
.campo :deep(.p-inputnumber),
.campo :deep(.p-datepicker),
.campo :deep(.p-textarea) { width: 100%; }
.req { color: #e53935; }
.badge {
  background: #00628f;
  color: #fff;
  border-radius: 4px;
  padding: 0 .3rem;
  font-size: .65rem;
}
.tipo {
  color: #999;
  font-weight: 400;
  font-size: .7rem;
  margin-left: auto;
}
.binario-nota {
  color: #999;
  font-style: italic;
  font-size: .8rem;
}
</style>
