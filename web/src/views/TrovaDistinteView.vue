<script setup>
import { ref, computed } from 'vue'
import Button from 'primevue/button'
import Message from 'primevue/message'
import InputText from 'primevue/inputtext'
import DatePicker from 'primevue/datepicker'
import RisultatoInterrogazioni from './RisultatoInterrogazioni.vue'

// Trova Distinte: replica della videata legacy "Trova Distinte" ("Cerca
// Distinte"). Ricerca sull'interrogazione 1012 (gia' filtrata sulla filiale
// corrente, con stampa distinta e drill sul dettaglio dal tasto destro):
// qui si aggiungono barcode/numero distinta e intervallo di date.

const props = defineProps({
  idQuery: { type: Number, default: 1012 },
  sWhere: { type: String, default: '' }
})

const errore = ref('')
const barcode = ref('')
const dal = ref(null)
const al = ref(null)
const eseguita = ref(0)
const sWhereRicerca = ref('')

function ymd(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

const puoCercare = computed(() => barcode.value.trim().length >= 3 || dal.value || al.value)

function cerca() {
  const cond = []
  const b = barcode.value.replace(/[^A-Za-z0-9_\-./]/g, '').trim()
  if (b) cond.push(/^\d{1,9}$/.test(b)
    ? ` and (sd.Barcode like '%${b}%' or sd.IdDistinta = ${b})`
    : ` and sd.Barcode like '%${b}%'`)
  if (dal.value) cond.push(` and sd.Data >= '${ymd(dal.value)}'`)
  if (al.value) cond.push(` and sd.Data < dateadd(day, 1, convert(date, '${ymd(al.value)}'))`)
  sWhereRicerca.value = cond.join('') + (props.sWhere ?? '')
  eseguita.value++
}
</script>

<template>
  <div class="pagina-ricerca">
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Cerca Distinte</div>
      <div class="corpo">
        <div class="griglia-campi">
          <label class="campo">Barcode o numero distinta
            <InputText v-model="barcode" fluid placeholder="es. 501601303954 o 1303954"
              @keyup.enter="puoCercare && cerca()" />
          </label>
          <label class="campo">Dal
            <DatePicker v-model="dal" dateFormat="dd/mm/yy" showIcon showButtonBar fluid />
          </label>
          <label class="campo">Al
            <DatePicker v-model="al" dateFormat="dd/mm/yy" showIcon showButtonBar fluid />
          </label>
          <div class="azione">
            <Button label="Cerca" icon="pi pi-search" :disabled="!puoCercare" @click="cerca" />
          </div>
        </div>
        <small class="nota">La ricerca è limitata alla filiale corrente (come nel legacy);
          col tasto destro sulla riga si stampa la distinta o si apre il dettaglio.</small>
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
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .5rem; }
.griglia-campi {
  display: grid; grid-template-columns: minmax(16rem, 24rem) 11rem 11rem auto;
  gap: .8rem; align-items: end;
}
.campo { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.azione { display: flex; align-items: flex-end; }
.nota { color: #888; }
.griglia-risultato { flex: 1; min-height: 0; }
</style>
