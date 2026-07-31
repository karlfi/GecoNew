<script setup>
import { ref, computed, onMounted } from 'vue'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Textarea from 'primevue/textarea'
import RisultatoInterrogazioni from './RisultatoInterrogazioni.vue'

// Ricerca Multipla: replica della videata legacy. Si incolla un elenco di
// barcode (uno per riga, o separati da spazi/virgole) e l'interrogazione della
// voce di menu viene eseguita con "and <colonna barcode> in ('...','...')",
// esattamente come faceva il legacy (visto nella plan cache del server).

const props = defineProps({
  idQuery: { type: Number, default: null },
  sWhere: { type: String, default: '' }
})

const errore = ref('')
const titolo = ref('')
const colonnaBarcode = ref('Barcode')
const testo = ref('')
const eseguita = ref(0)           // incrementata a ogni Cerca: rimonta la griglia
const sWhereRicerca = ref('')

onMounted(async () => {
  if (!props.idQuery) { errore.value = 'Parametri non validi: IdQuery mancante'; return }
  try {
    const { data } = await api.get(`/interrogazioni/${props.idQuery}/ricerca-info`)
    titolo.value = data.titolo
    colonnaBarcode.value = data.colonnaBarcode
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento della ricerca'
  }
})

// solo caratteri da barcode: niente apici o altro che rompa l'SQL
const barcodes = computed(() =>
  [...new Set(testo.value.split(/[\s,;]+/)
    .map(b => b.replace(/[^A-Za-z0-9_\-./]/g, '').trim())
    .filter(b => b.length >= 3))])

function cerca() {
  if (!barcodes.value.length) return
  const elenco = barcodes.value.slice(0, 2000).map(b => `'${b}'`).join(',')
  sWhereRicerca.value = ` and ${colonnaBarcode.value} in (${elenco})${props.sWhere ?? ''}`
  eseguita.value++
}
</script>

<template>
  <div class="pagina-ricerca">
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Ricerca Multipla{{ titolo ? ` — ${titolo}` : '' }}</div>
      <div class="corpo">
        <label class="campo">Elenco barcode (uno per riga, o separati da spazi/virgole)
          <Textarea v-model="testo" rows="4" autoResize fluid
            placeholder="incolla qui l'elenco dei barcode da cercare..." />
        </label>
        <div class="barra">
          <span class="conta">{{ barcodes.length }} barcode</span>
          <Button label="Cerca" icon="pi pi-search" :disabled="!barcodes.length" @click="cerca" />
        </div>
      </div>
    </section>

    <RisultatoInterrogazioni v-if="eseguita" :key="eseguita"
      :id-query="idQuery" :s-where="sWhereRicerca" class="griglia-risultato" />
  </div>
</template>

<style scoped>
.pagina-ricerca { display: flex; flex-direction: column; gap: .9rem; height: 100%; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; flex-shrink: 0; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0;
}
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .6rem; }
.campo { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.barra { display: flex; align-items: center; justify-content: flex-end; gap: 1rem; }
.conta { color: #666; font-size: .85rem; }
.griglia-risultato { flex: 1; min-height: 0; }
</style>
