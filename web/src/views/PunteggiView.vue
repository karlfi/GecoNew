<script setup>
import { ref, computed, onMounted } from 'vue'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Checkbox from 'primevue/checkbox'
import SelectButton from 'primevue/selectbutton'
import DatePicker from 'primevue/datepicker'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Punteggi driver: replica della videata legacy "Punteggi" (vista
// V_UtentiAttivita2024): punteggio e lavorato per driver/giorno, con riepilogo
// per driver nel periodo scelto.

const errore = ref('')
const righe = ref([])
const caricamento = ref(false)
const tutteFiliali = ref(false)
const dal = ref(new Date(Date.now() - 15 * 864e5))
const al = ref(new Date())
const vista = ref('driver')
const OPZIONI_VISTA = [
  { label: 'Riepilogo per driver', value: 'driver' },
  { label: 'Dettaglio per giorno', value: 'giorno' }
]

function ymd(d) {
  return d ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` : null
}

async function carica() {
  caricamento.value = true
  errore.value = ''
  try {
    const { data } = await api.get('/punteggi', {
      params: { dal: ymd(dal.value), al: ymd(al.value), tutte: tutteFiliali.value || undefined }
    })
    righe.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei punteggi'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)

const NUMERI = ['punteggio', 'km', 'parcelPoste', 'parcelSpeedy', 'parcelAltri',
  'rac140', 'rac140Avv', 'm1', 'm1Altro', 'm2', 'm2Altro', 'ag']

const perDriver = computed(() => {
  const m = new Map()
  for (const r of righe.value) {
    const k = r.driver + '|' + r.filiale
    if (!m.has(k)) {
      m.set(k, { driver: r.driver, filiale: r.filiale, giornate: 0,
        ...Object.fromEntries(NUMERI.map(c => [c, 0])) })
    }
    const t = m.get(k)
    t.giornate++
    for (const c of NUMERI) t[c] += r[c] ?? 0
  }
  return [...m.values()]
    .map(t => ({ ...t, media: t.giornate ? Math.round(t.punteggio / t.giornate) : 0 }))
    .sort((a, b) => b.punteggio - a.punteggio)
})

function dataIt(iso) {
  if (!iso) return ''
  const [a, m, g] = iso.split('-')
  return `${g}/${m}/${a}`
}
function n(v) { return v ? Math.round(v * 10) / 10 : '' }
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Punteggi driver</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Periodo
        <span class="chk-testata"><Checkbox v-model="tutteFiliali" binary @change="carica" /> tutte le filiali</span>
      </div>
      <div class="barra">
        <label class="campo-data">Dal
          <DatePicker v-model="dal" dateFormat="dd/mm/yy" showIcon />
        </label>
        <label class="campo-data">Al
          <DatePicker v-model="al" dateFormat="dd/mm/yy" showIcon />
        </label>
        <Button label="Aggiorna" icon="pi pi-refresh" :loading="caricamento" @click="carica" />
        <span class="spazio"></span>
        <SelectButton v-model="vista" :options="OPZIONI_VISTA" optionLabel="label" optionValue="value"
          :allowEmpty="false" />
      </div>
    </section>

    <section class="card">
      <div class="card-titolo">
        {{ vista === 'driver' ? 'Riepilogo per driver' : 'Dettaglio per giorno' }}
      </div>
      <DataTable v-if="vista === 'driver'" :value="perDriver" size="small" stripedRows showGridlines
        :loading="caricamento" paginator :rows="25" sortMode="single" removableSort>
        <Column field="driver" header="Driver" sortable />
        <Column v-if="tutteFiliali" field="filiale" header="Filiale" sortable />
        <Column field="giornate" header="Giornate" sortable style="width: 5.5rem" />
        <Column field="punteggio" header="Punteggio" sortable style="width: 6.5rem">
          <template #body="{ data }">{{ n(data.punteggio) }}</template>
        </Column>
        <Column field="media" header="Media/g" sortable style="width: 5.5rem" />
        <Column field="km" header="Km" sortable style="width: 5rem">
          <template #body="{ data }">{{ n(data.km) }}</template>
        </Column>
        <Column field="parcelPoste" header="Parcel Poste" sortable style="width: 6rem" />
        <Column field="parcelSpeedy" header="Parcel Speedy" sortable style="width: 6.5rem" />
        <Column field="parcelAltri" header="Parcel altri" sortable style="width: 5.8rem" />
        <Column field="rac140" header="R140" sortable style="width: 4.5rem" />
        <Column field="m1" header="Mod.1" sortable style="width: 4.5rem" />
        <Column field="m2" header="Mod.2" sortable style="width: 4.5rem" />
        <Column field="ag" header="AG" sortable style="width: 4rem" />
        <template #empty>Nessuna attività nel periodo.</template>
      </DataTable>

      <DataTable v-else :value="righe" size="small" stripedRows showGridlines
        :loading="caricamento" paginator :rows="50" sortMode="single" removableSort>
        <Column field="data" header="Data" sortable style="width: 6.2rem">
          <template #body="{ data }">{{ dataIt(data.data) }}</template>
        </Column>
        <Column field="driver" header="Driver" sortable />
        <Column v-if="tutteFiliali" field="filiale" header="Filiale" sortable />
        <Column field="punteggio" header="Punteggio" sortable style="width: 6.5rem">
          <template #body="{ data }">{{ n(data.punteggio) }}</template>
        </Column>
        <Column field="km" header="Km" sortable style="width: 5rem">
          <template #body="{ data }">{{ n(data.km) }}</template>
        </Column>
        <Column field="parcelPoste" header="Parcel Poste" style="width: 6rem" />
        <Column field="parcelSpeedy" header="Parcel Speedy" style="width: 6.5rem" />
        <Column field="parcelAltri" header="Parcel altri" style="width: 5.8rem" />
        <Column field="rac140" header="R140" style="width: 4.5rem" />
        <Column field="m1" header="Mod.1" style="width: 4.5rem" />
        <Column field="m2" header="Mod.2" style="width: 4.5rem" />
        <Column field="ag" header="AG" style="width: 4rem" />
        <template #empty>Nessuna attività nel periodo.</template>
      </DataTable>
    </section>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1300px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center;
}
.chk-testata { display: flex; align-items: center; gap: .4rem; font-size: .82rem; font-weight: 400; }
.barra { display: flex; align-items: center; gap: .8rem; padding: .8rem; flex-wrap: wrap; }
.barra .spazio { flex: 1; }
.campo-data { display: flex; align-items: center; gap: .5rem; font-size: .85rem; color: #555; }
</style>
