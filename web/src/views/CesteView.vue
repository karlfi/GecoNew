<script setup>
import { ref, computed, onMounted } from 'vue'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Ceste blu: replica della videata legacy "Ceste" (monitor delle ceste BOX@).
// La stored legacy fndCesteBlu restituisce l'ultimo evento di ogni cesta; gli
// hub (filiali 1 e 20) vedono tutte le ceste, le altre solo le proprie.

const errore = ref('')
const righe = ref([])
const caricamento = ref(false)

async function carica() {
  caricamento.value = true
  errore.value = ''
  try {
    const { data } = await api.get('/ceste')
    righe.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle ceste'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)

const ferme = computed(() => righe.value.filter(r => (r.Note ?? '').startsWith('Ferma')).length)

function dataIt(v) {
  if (!v) return ''
  const d = new Date(v)
  return isNaN(d) ? v : d.toLocaleDateString('it-IT') + ' ' +
    d.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Ceste blu</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Ultimo evento per cesta
        <span class="conteggio">{{ righe.length }} ceste<template v-if="ferme"> — {{ ferme }} ferme</template></span>
      </div>
      <div class="corpo">
        <div class="barra">
          <Button label="Aggiorna" icon="pi pi-refresh" :loading="caricamento" @click="carica" />
        </div>
        <DataTable :value="righe" size="small" stripedRows :loading="caricamento"
          paginator :rows="25" sortMode="single" removableSort>
          <Column field="barcode" header="Cesta" sortable style="width: 8rem" />
          <Column field="Evento" header="Ultimo evento" sortable />
          <Column field="datainserimento" header="Quando" sortable style="width: 9.5rem">
            <template #body="{ data }">{{ dataIt(data.datainserimento) }}</template>
          </Column>
          <Column field="Utente" header="Operatore" sortable />
          <Column field="Filiale" header="Filiale" sortable />
          <Column field="Destinazione" header="Destinazione" sortable />
          <Column header="Note" style="width: 11rem">
            <template #body="{ data }">
              <Tag v-if="data.Note" :severity="data.Note.startsWith('Ferma') ? 'warn' : 'info'"
                :value="data.Note" />
              <span v-else>—</span>
            </template>
          </Column>
          <template #empty>Nessuna cesta trovata per la filiale.</template>
        </DataTable>
      </div>
    </section>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1200px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center;
}
.conteggio { font-size: .8rem; font-weight: 400; opacity: .9; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.barra { display: flex; justify-content: flex-end; }
</style>
