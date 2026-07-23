<script setup>
import { ref, computed, onMounted } from 'vue'
import api from '../api'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Select from 'primevue/select'
import InputText from 'primevue/inputtext'
import Message from 'primevue/message'
import Tag from 'primevue/tag'

// Export CSV per HR: tracciato TeamSystem IMPDIP_0004_ANAGRAFICA con i
// dipendenti Speedy assunti nel mese scelto (anche se gia' cessati).
// L'API restituisce i 53 campi gia' pronti; qui solo anteprima e download.

const oggi = new Date()
const MESI = ['Gennaio', 'Febbraio', 'Marzo', 'Aprile', 'Maggio', 'Giugno',
  'Luglio', 'Agosto', 'Settembre', 'Ottobre', 'Novembre', 'Dicembre']
const mesi = MESI.map((nome, i) => ({ nome, valore: i + 1 }))
const anni = []
for (let a = oggi.getFullYear(); a >= oggi.getFullYear() - 5; a--) anni.push({ nome: String(a), valore: a })

const mese = ref(oggi.getMonth() + 1)
const anno = ref(oggi.getFullYear())
const azienda = ref('574')

const errore = ref('')
const caricamento = ref(false)
const dati = ref(null) // { intestazione, righe }

async function carica() {
  caricamento.value = true
  errore.value = ''
  dati.value = null
  try {
    const { data } = await api.get('/hr/anagrafica', {
      params: { anno: anno.value, mese: mese.value, azienda: azienda.value }
    })
    dati.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)

const righe = computed(() => dati.value?.righe ?? [])
const nConSegnalazioni = computed(() => righe.value.filter(r => r.segnalazioni.length).length)

function scaricaCsv() {
  const testo = [dati.value.intestazione, ...righe.value.map(r => r.campi.join(';'))].join('\r\n') + '\r\n'
  // il tracciato HR e' ANSI: byte Latin-1, non UTF-8 (gli accenti dei comuni)
  const bytes = new Uint8Array(testo.length)
  for (let i = 0; i < testo.length; i++) {
    const c = testo.charCodeAt(i)
    bytes[i] = c <= 255 ? c : 63 // '?' per caratteri fuori Latin-1
  }
  const blob = new Blob([bytes], { type: 'text/csv;charset=windows-1252' })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = `IMPDIP_0004_ANAGRAFICA_${anno.value}${String(mese.value).padStart(2, '0')}.csv`
  a.click()
  URL.revokeObjectURL(a.href)
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Export CSV per HR — nuovi assunti</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="filtri">
      <label>Mese
        <Select v-model="mese" :options="mesi" optionLabel="nome" optionValue="valore" />
      </label>
      <label>Anno
        <Select v-model="anno" :options="anni" optionLabel="nome" optionValue="valore" />
      </label>
      <label>Codice azienda
        <InputText v-model="azienda" style="width: 6rem" />
      </label>
      <Button label="Aggiorna" icon="pi pi-refresh" :loading="caricamento" @click="carica" />
      <Button label="Scarica CSV" icon="pi pi-download" severity="success"
        :disabled="!righe.length" @click="scaricaCsv" />
    </div>

    <Message v-if="dati && !righe.length" severity="info" :closable="false">
      Nessun dipendente Speedy assunto in {{ MESI[mese - 1] }} {{ anno }}.
    </Message>
    <Message v-if="nConSegnalazioni" severity="warn" :closable="false">
      {{ nConSegnalazioni }} {{ nConSegnalazioni === 1 ? 'riga ha segnalazioni' : 'righe hanno segnalazioni' }}:
      il CSV si genera comunque, ma controlla i campi mancanti prima dell'invio a HR.
    </Message>

    <DataTable v-if="righe.length" :value="righe" dataKey="idUtente"
      :loading="caricamento" size="small" stripedRows scrollable scrollHeight="flex" class="griglia">
      <Column field="matricola" header="Matr." style="width: 5rem">
        <template #body="{ data }">
          <span :class="{ manca: !data.matricola }">{{ data.matricola || '—' }}</span>
        </template>
      </Column>
      <Column field="cognome" header="Cognome" />
      <Column field="nome" header="Nome" />
      <Column field="cf" header="Codice fiscale" style="width: 11.5rem" />
      <Column field="dataInizio" header="Assunto" style="width: 6.5rem" />
      <Column field="dataFine" header="Cessato" style="width: 6.5rem">
        <template #body="{ data }">
          <Tag v-if="data.dataFine" severity="danger" :value="data.dataFine" />
        </template>
      </Column>
      <Column field="filiale" header="Filiale">
        <template #body="{ data }">
          {{ data.filiale }} <Tag v-if="data.codFiliale" :value="'HR ' + data.codFiliale" severity="secondary" />
        </template>
      </Column>
      <Column field="residenza" header="Residenza" />
      <Column header="Segnalazioni">
        <template #body="{ data }">
          <div v-if="data.segnalazioni.length" class="segnalazioni">
            <Tag v-for="(s, i) in data.segnalazioni" :key="i" severity="warn" :value="s" />
          </div>
          <Tag v-else severity="success" value="ok" />
        </template>
      </Column>
    </DataTable>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.75rem; height: 100%; }
.titolo { margin: 0; }
.filtri { display: flex; align-items: end; gap: 0.75rem; flex-wrap: wrap; }
.filtri label { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.85rem; color: var(--p-text-muted-color); }
.griglia { flex: 1; min-height: 0; }
.segnalazioni { display: flex; flex-wrap: wrap; gap: 0.25rem; }
.manca { color: var(--p-red-500); font-weight: 600; }
</style>
