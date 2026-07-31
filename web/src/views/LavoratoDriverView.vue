<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Select from 'primevue/select'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import ColumnGroup from 'primevue/columngroup'
import Row from 'primevue/row'

// Lavorato Driver: replica della videata legacy. La stored getLavoratoByIdUtente
// restituisce, per il driver scelto e il mese, i conteggi giornalieri del lavorato
// per categoria (certificate, raccomandate, moduli ADER, R139/R140, atti giudiziari).
// NB: un driver alla volta, come nel legacy (la stored non regge il CSV di id).

const toast = useToast()
const errore = ref('')
const driver = ref([])
const scelto = ref(null)
const MESI = ['Gennaio', 'Febbraio', 'Marzo', 'Aprile', 'Maggio', 'Giugno',
  'Luglio', 'Agosto', 'Settembre', 'Ottobre', 'Novembre', 'Dicembre']
const oggi = new Date()
const mese = ref(oggi.getMonth() + 1)
const anno = ref(oggi.getFullYear())
const opzioniMese = MESI.map((m, i) => ({ label: m, value: i + 1 }))
const opzioniAnno = Array.from({ length: 4 }, (_, i) => oggi.getFullYear() - i)
const righe = ref([])
const caricamento = ref(false)
const eseguito = ref(false)

onMounted(async () => {
  try {
    const { data } = await api.get('/lavorato/driver')
    driver.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei driver'
  }
})

async function carica() {
  caricamento.value = true
  eseguito.value = true
  try {
    const { data } = await api.get('/lavorato', {
      params: { idUtenti: String(scelto.value), mese: mese.value, anno: anno.value }
    })
    righe.value = data
  } catch (e) {
    righe.value = []
    toast.add({ severity: 'error', summary: 'Lavorato', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    caricamento.value = false
  }
}

const COLONNE = [
  ['fc', 'Cons.'], ['fc_TrSc', 'Tr/Sc'], ['fc_Ass', 'Ass.'],
  ['Racc', 'Cons.'], ['Racc_TrSc', 'Tr/Sc'], ['Racc_Avv', 'Avv.'],
  ['M1_Consegnate', 'Cons.'], ['M1_TrSc', 'Tr/Sc'], ['M1_Avv', 'Avv.'],
  ['M2_Consegnate', 'Cons.'], ['M2_Art139', '139'], ['M2_Art140', '140'], ['M2_Art60', '60'],
  ['R139', 'Cons.'], ['R139_TrSc', 'Tr/Sc'], ['R139_Avv', 'Avv.'],
  ['R140', 'Cons.'], ['R140_TrSc', 'Tr/Sc'], ['R140_Avv', 'Avv.'],
  ['AG_Dirette', 'Dir.'], ['AG_139', '139'], ['AG_140', '140'], ['AG_Rifiuti', 'Rif.'], ['AG_Resi', 'Resi']
]
const totali = computed(() => {
  const t = {}
  for (const [c] of COLONNE) t[c] = righe.value.reduce((s, r) => s + (r[c] ?? 0), 0)
  return t
})
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Lavorato Driver</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Driver e periodo</div>
      <div class="barra">
        <label class="campo">Driver *
          <Select v-model="scelto" :options="driver" optionLabel="nome" optionValue="idUtente"
            filter placeholder="— scegli il driver —" class="sel-driver" />
        </label>
        <label class="campo">Mese
          <Select v-model="mese" :options="opzioniMese" optionLabel="label" optionValue="value" />
        </label>
        <label class="campo">Anno
          <Select v-model="anno" :options="opzioniAnno" />
        </label>
        <Button label="Carica" icon="pi pi-search" :disabled="!scelto"
          :loading="caricamento" @click="carica" />
      </div>
    </section>

    <section v-if="eseguito" class="card">
      <div class="card-titolo">{{ MESI[mese - 1] }} {{ anno }}</div>
      <DataTable :value="righe" size="small" stripedRows showGridlines :loading="caricamento"
        scrollable class="tab-lavorato">
        <ColumnGroup type="header">
          <Row>
            <Column header="Driver" :rowspan="2" frozen />
            <Column header="Data" :rowspan="2" />
            <Column header="Certificate" :colspan="3" />
            <Column header="Raccomandate" :colspan="3" />
            <Column header="Modulo 1" :colspan="3" />
            <Column header="Modulo 2" :colspan="4" />
            <Column header="Racc. 139" :colspan="3" />
            <Column header="Racc. 140" :colspan="3" />
            <Column header="Atti Giudiziari" :colspan="5" />
          </Row>
          <Row>
            <Column v-for="[c, h] in COLONNE" :key="c" :header="h" />
          </Row>
        </ColumnGroup>
        <Column field="postino" header="Driver" frozen />
        <Column field="Data" header="Data" style="width: 6.2rem" />
        <Column v-for="[c] in COLONNE" :key="c" :field="c" style="width: 3.6rem">
          <template #body="{ data }">{{ data[c] || '' }}</template>
        </Column>
        <ColumnGroup type="footer">
          <Row>
            <Column footer="Totale" :colspan="2" />
            <Column v-for="[c] in COLONNE" :key="c" :footer="totali[c] ? String(totali[c]) : ''" />
          </Row>
        </ColumnGroup>
        <template #empty>Nessun lavorato nel mese per i driver scelti.</template>
      </DataTable>
    </section>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0;
}
.barra { display: flex; align-items: flex-end; gap: .8rem; padding: .8rem; flex-wrap: wrap; }
.campo { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.sel-driver { min-width: 22rem; max-width: 34rem; }
.tab-lavorato :deep(.p-datatable-tbody > tr > td) { font-size: .82rem; padding: .3rem .45rem; }
.tab-lavorato :deep(.p-datatable-thead > tr > th) { font-size: .8rem; padding: .35rem .45rem; }
</style>
