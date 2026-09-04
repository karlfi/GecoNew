<script setup>
import { ref, watch, onMounted } from 'vue'
import api from '../api'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import SchedaUtente from '../components/SchedaUtente.vue'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Tag from 'primevue/tag'
import IconField from 'primevue/iconfield'
import InputIcon from 'primevue/inputicon'
import Message from 'primevue/message'

// --- lista ---
const rows = ref([])
const total = ref(0)
const caricamento = ref(false)
const errore = ref('')
const lazy = ref({ page: 0, size: 50, sort: 'Utente', dir: 'asc', q: '' })

async function caricaLista() {
  caricamento.value = true
  errore.value = ''
  try {
    const { page, size, sort, dir, q } = lazy.value
    const { data } = await api.get('/utenti', { params: { page, size, sort, dir, q: q || undefined } })
    rows.value = data.rows
    total.value = data.total
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento'
  } finally {
    caricamento.value = false
  }
}
// Si puo' arrivare qui chiedendo un utente preciso (una interrogazione con
// l'azione "Listautenti#IdUtente=..."): in quel caso la sua scheda si apre
// subito sopra l'elenco.
const props = defineProps({ idUtente: { type: Number, default: null } })

// --- scheda utente (il componente si carica i dati da se') ---
const dialog = ref(false)
const idSelezionato = ref(null)
const nuovo = ref(false)
function apriNuovo() { idSelezionato.value = null; nuovo.value = true; dialog.value = true }
function apriModifica(riga) { idSelezionato.value = riga.IdUtente; nuovo.value = false; dialog.value = true }

onMounted(() => {
  if (props.idUtente) apriModifica({ IdUtente: props.idUtente })
  caricaLista()
})
function onPage(e) { lazy.value.page = e.page; lazy.value.size = e.rows; caricaLista() }
function onSort(e) { lazy.value.sort = e.sortField; lazy.value.dir = e.sortOrder === -1 ? 'desc' : 'asc'; lazy.value.page = 0; caricaLista() }
let tmr
watch(() => lazy.value.q, () => { clearTimeout(tmr); tmr = setTimeout(() => { lazy.value.page = 0; caricaLista() }, 350) })

function fmtData(v) {
  if (!v) return ''
  const d = new Date(v)
  return isNaN(d) ? v : d.toLocaleDateString('it-IT')
}
</script>

<template>
  <div class="utenti">
    <div class="testata">
      <h2>Utenti</h2>
      <div class="azioni">
        <span v-if="total" class="conta">{{ total }} utenti</span>
        <IconField>
          <InputIcon class="pi pi-search" />
          <InputText v-model="lazy.q" placeholder="Cerca per nome, username, email, CF..." size="small" />
        </IconField>
        <Button label="Nuovo utente" icon="pi pi-user-plus" size="small" @click="apriNuovo" />
      </div>
    </div>

    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <DataTable
      :value="rows" lazy paginator :rows="lazy.size" :totalRecords="total"
      :rowsPerPageOptions="[20, 50, 100, 200]" :loading="caricamento"
      @page="onPage" @sort="onSort" scrollable scrollHeight="flex" size="small"
      stripedRows showGridlines class="griglia"
    >
      <Column header="" style="width:3rem">
        <template #body="{ data }">
          <Button icon="pi pi-pencil" text rounded size="small" @click="apriModifica(data)" />
        </template>
      </Column>
      <Column field="Utente" header="Username" sortable />
      <Column field="Nome" header="Nominativo" sortable />
      <Column field="Email" header="Email" sortable />
      <Column field="Ruolo" header="Ruolo" />
      <Column field="Filiale" header="Filiale" />
      <Column field="Cliente" header="Cliente" />
      <Column field="DataUltimoAccesso" header="Ultimo accesso" sortable>
        <template #body="{ data }">{{ fmtData(data.DataUltimoAccesso) }}</template>
      </Column>
      <Column field="Attivo" header="Attivo">
        <template #body="{ data }">
          <Tag :value="data.Attivo ? 'sì' : 'no'" :severity="data.Attivo ? 'success' : 'danger'" />
        </template>
      </Column>
      <template #empty><div v-if="!caricamento" class="vuoto">Nessun utente</div></template>
    </DataTable>

    <SchedaUtente
      v-model:visible="dialog" :id-utente="idSelezionato" :nuovo="nuovo"
      @salvato="caricaLista"
    />
  </div>
</template>

<style scoped>
.utenti { display: flex; flex-direction: column; height: 100%; gap: .5rem; }
.testata { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
.testata h2 { margin: 0; }
.azioni { display: flex; align-items: center; gap: .75rem; }
.conta { color: #666; font-size: .85rem; white-space: nowrap; }
.griglia { flex: 1; min-height: 0; }
.griglia :deep(.p-datatable-tbody > tr > td), .griglia :deep(.p-datatable-thead > tr > th) {
  padding: .35rem .6rem; font-size: .85rem;
}
.vuoto { text-align: center; color: #888; padding: 1rem; }
.form { display: grid; grid-template-columns: 1fr 1fr; gap: .8rem 1.25rem; }
.campo { display: flex; flex-direction: column; gap: .25rem; }
.campo label { font-size: .8rem; font-weight: 600; }
.campo :deep(.p-inputtext), .campo :deep(.p-inputnumber), .campo :deep(.p-select), .campo :deep(.p-datepicker) { width: 100%; }
.pwd-box { max-width: 360px; display: flex; flex-direction: column; gap: .4rem; }
.pwd-box p { color: #666; font-size: .85rem; }
.pwd-box :deep(.p-password), .pwd-box :deep(.p-password-input) { width: 100%; }
.rel-hint { color: #888; font-style: italic; padding: .5rem 0; }
.rel-add { display: flex; gap: .5rem; margin-bottom: .75rem; }
.rel-add :deep(.p-select) { flex: 1; }
.rel-add-proc { flex-wrap: wrap; }
.rel-add-proc :deep(.p-select) { min-width: 200px; }
.rel-lista { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: .25rem; }
.rel-lista li { display: flex; align-items: center; justify-content: space-between; padding: .3rem .6rem; background: var(--p-surface-50); border-radius: 6px; font-size: .9rem; }
.rel-lista .rel-vuoto { justify-content: center; color: #999; background: none; font-style: italic; }
</style>
