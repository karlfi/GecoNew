<script setup>
import { ref, computed, onMounted } from 'vue'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import InputText from 'primevue/inputtext'
import DatePicker from 'primevue/datepicker'
import Select from 'primevue/select'
import RisultatoInterrogazioni from './RisultatoInterrogazioni.vue'

// Ricerca con parametri: replica della videata legacy "Ricercaparams". La query
// contiene segnaposto &[Nome] (testo), &[D_Nome] (data) e &[Nome{select...}]
// (tendina da lookup): il backend li estrae (/ricerca-info) e qui si compila il
// form; alla ricerca i valori vengono sostituiti nella query lato server.

const props = defineProps({
  idQuery: { type: Number, default: null },
  sWhere: { type: String, default: '' }
})

const errore = ref('')
const titolo = ref('')
const descrizione = ref('')
const parametri = ref([])
const valori = ref({})            // nome segnaposto -> valore digitato
const eseguita = ref(0)
const valoriRicerca = ref(null)

onMounted(async () => {
  if (!props.idQuery) { errore.value = 'Parametri non validi: IdQuery mancante'; return }
  try {
    const { data } = await api.get(`/interrogazioni/${props.idQuery}/ricerca-info`)
    titolo.value = data.titolo
    descrizione.value = data.descrizione
    parametri.value = data.parametri
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento della ricerca'
  }
})

// le date vanno alla query in formato italiano (stile 103 / DATEFORMAT dmy)
function ddmmyyyy(d) {
  return d instanceof Date
    ? `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}/${d.getFullYear()}`
    : (d ?? '')
}

const dateMancanti = computed(() =>
  parametri.value.filter(p => p.tipo === 'data' && !valori.value[p.nome]))

function cerca() {
  const v = {}
  for (const p of parametri.value) {
    const val = valori.value[p.nome]
    v[p.nome] = p.tipo === 'data' ? ddmmyyyy(val) : String(val ?? '')
  }
  valoriRicerca.value = v
  eseguita.value++
}
</script>

<template>
  <div class="pagina-ricerca">
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">{{ titolo || 'Ricerca con parametri' }}
        <small v-if="descrizione" class="sotto">{{ descrizione }}</small>
      </div>
      <div class="corpo">
        <div class="griglia-campi">
          <label v-for="p in parametri" :key="p.nome" class="campo">
            {{ p.etichetta }}{{ p.tipo === 'data' ? ' *' : '' }}
            <DatePicker v-if="p.tipo === 'data'" v-model="valori[p.nome]"
              dateFormat="dd/mm/yy" showIcon fluid />
            <Select v-else-if="p.tipo === 'lookup'" v-model="valori[p.nome]"
              :options="p.opzioni" optionLabel="etichetta" optionValue="valore"
              filter showClear fluid placeholder="— tutti —" />
            <InputText v-else v-model="valori[p.nome]" fluid @keyup.enter="cerca" />
          </label>
        </div>
        <div class="barra">
          <Button label="Cerca" icon="pi pi-search" :disabled="dateMancanti.length > 0" @click="cerca" />
        </div>
      </div>
    </section>

    <RisultatoInterrogazioni v-if="eseguita" :key="eseguita"
      :id-query="idQuery" :s-where="sWhere" :valori="valoriRicerca" class="griglia-risultato" />
  </div>
</template>

<style scoped>
.pagina-ricerca { display: flex; flex-direction: column; gap: .9rem; height: 100%; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; flex-shrink: 0; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; align-items: baseline; gap: .8rem;
}
.sotto { font-weight: 400; opacity: .9; font-size: .8rem; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .6rem; }
.griglia-campi {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(15rem, 22rem));
  gap: .8rem;
}
.campo { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.barra { display: flex; justify-content: flex-end; }
.griglia-risultato { flex: 1; min-height: 0; }
</style>
