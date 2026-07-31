<script setup>
import { ref, onMounted } from 'vue'
import api from '../api'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Checkbox from 'primevue/checkbox'
import InputText from 'primevue/inputtext'
import IconField from 'primevue/iconfield'
import InputIcon from 'primevue/inputicon'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import { FilterMatchMode } from '@primevue/core/api'

// Dipendenti di Filiale: replica della videata legacy "Dipendenti". Vista HR in
// sola lettura dei dipendenti (codice fiscale reale) della filiale corrente;
// le modifiche passano dalla gestione utenti o dal caricamento UNILAV.

const errore = ref('')
const righe = ref([])
const caricamento = ref(false)
const ancheCessati = ref(false)
const filters = ref({ global: { value: null, matchMode: FilterMatchMode.CONTAINS } })

async function carica() {
  caricamento.value = true
  errore.value = ''
  try {
    const { data } = await api.get('/dipendenti-filiale', {
      params: { ancheCessati: ancheCessati.value || undefined }
    })
    righe.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei dipendenti'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Dipendenti di Filiale</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Dipendenti
        <span class="chk-testata">
          <Checkbox v-model="ancheCessati" binary @change="carica" /> anche cessati
        </span>
      </div>
      <div class="corpo">
        <div class="barra">
          <span class="conta">{{ righe.length }} dipendenti</span>
          <IconField>
            <InputIcon class="pi pi-search" />
            <InputText v-model="filters.global.value" placeholder="Filtra..." size="small" />
          </IconField>
        </div>
        <DataTable :value="righe" v-model:filters="filters" size="small" stripedRows
          :loading="caricamento" paginator :rows="25" sortMode="single" removableSort
          :globalFilterFields="['matricola', 'nome', 'codiceFiscale', 'mansione', 'tipoContratto']">
          <Column field="matricola" header="Matr." sortable style="width: 5rem" />
          <Column field="nome" header="Nominativo" sortable />
          <Column field="codiceFiscale" header="Codice fiscale" style="width: 11rem" />
          <Column field="mansione" header="Mansione" sortable />
          <Column field="livello" header="Liv." sortable style="width: 4rem" />
          <Column field="tipoContratto" header="Contratto" sortable />
          <Column field="assunto" header="Assunto" sortable style="width: 6.5rem" />
          <Column field="fineContratto" header="Fine contr." sortable style="width: 6.5rem" />
          <Column header="Orario" style="width: 6.5rem">
            <template #body="{ data }">
              {{ data.partime ? `PT ${data.partime}%` : 'Full time' }}
            </template>
          </Column>
          <Column field="telefono" header="Telefono" style="width: 7.5rem" />
          <Column v-if="ancheCessati" header="Stato" style="width: 6.5rem">
            <template #body="{ data }">
              <Tag :severity="data.cessato ? 'danger' : 'success'"
                :value="data.cessato ? `cessato ${data.cessato}` : 'attivo'" />
            </template>
          </Column>
          <template #empty>Nessun dipendente per la filiale.</template>
        </DataTable>
      </div>
    </section>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1250px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center;
}
.chk-testata { display: flex; align-items: center; gap: .4rem; font-size: .82rem; font-weight: 400; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.barra { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
.conta { color: #666; font-size: .85rem; }
</style>
