<script setup>
import { ref, computed, onMounted } from 'vue'
import api from '../api'
import { useAuthStore } from '../stores/auth'
import EChart from '../components/EChart.vue'
import Card from 'primevue/card'
import Message from 'primevue/message'
import ProgressSpinner from 'primevue/progressspinner'

const auth = useAuthStore()
const caricamento = ref(false)
const errore = ref('')
const mese = ref([])
const giorno = ref([])

const COLORI = { punteggio: '#00afde', media: '#f59e0b', giornate: '#00628f' }

async function carica() {
  errore.value = ''
  caricamento.value = true
  try {
    const { data } = await api.get('/dashboard/punteggi')
    mese.value = data.mese
    giorno.value = data.giorno
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei dati'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)

// formato numeri italiano, senza decimali per le sintesi
const nf = new Intl.NumberFormat('it-IT', { maximumFractionDigits: 0 })

// --- card di sintesi (mese corrente = ultima riga di "mese") ---
const meseCorrente = computed(() => mese.value.at(-1) ?? null)

// --- grafico mensile: barre Punteggio + linea Media (asse secondario) ---
const optMese = computed(() => ({
  tooltip: { trigger: 'axis', axisPointer: { type: 'cross' } },
  legend: { data: ['Punteggio', 'Media'] },
  grid: { left: 60, right: 60, top: 40, bottom: 40 },
  xAxis: { type: 'category', data: mese.value.map(r => r.mese) },
  yAxis: [
    { type: 'value', name: 'Punteggio', axisLabel: { formatter: v => nf.format(v) } },
    { type: 'value', name: 'Media', splitLine: { show: false } }
  ],
  series: [
    {
      name: 'Punteggio', type: 'bar', itemStyle: { color: COLORI.punteggio },
      data: mese.value.map(r => Math.round(r.punteggio))
    },
    {
      name: 'Media', type: 'line', yAxisIndex: 1, smooth: true, symbol: 'circle',
      symbolSize: 7, lineStyle: { width: 3 }, itemStyle: { color: COLORI.media },
      data: mese.value.map(r => r.media)
    }
  ]
}))

// --- grafico giornaliero (ultimi 15 gg): area Punteggio + linea Media ---
const optGiorno = computed(() => ({
  tooltip: { trigger: 'axis', axisPointer: { type: 'cross' } },
  legend: { data: ['Punteggio', 'Media'] },
  grid: { left: 60, right: 60, top: 40, bottom: 40 },
  xAxis: {
    type: 'category',
    data: giorno.value.map(r => {
      const [, m, d] = r.data.split('-')
      return `${d}/${m}`
    })
  },
  yAxis: [
    { type: 'value', name: 'Punteggio', axisLabel: { formatter: v => nf.format(v) } },
    { type: 'value', name: 'Media', splitLine: { show: false } }
  ],
  series: [
    {
      name: 'Punteggio', type: 'line', smooth: true, areaStyle: { opacity: 0.25 },
      symbol: 'circle', symbolSize: 6, lineStyle: { width: 3 },
      itemStyle: { color: COLORI.punteggio },
      data: giorno.value.map(r => Math.round(r.punteggio))
    },
    {
      name: 'Media', type: 'line', yAxisIndex: 1, smooth: true,
      symbol: 'circle', symbolSize: 6, lineStyle: { width: 2, type: 'dashed' },
      itemStyle: { color: COLORI.media },
      data: giorno.value.map(r => r.media)
    }
  ]
}))

const haDati = computed(() => mese.value.length || giorno.value.length)
</script>

<template>
  <div class="dash">
    <div class="dash-head">
      <h2>Dashboard</h2>
      <span v-if="auth.utente?.filiale?.nome" class="filiale">{{ auth.utente.filiale.nome }}</span>
    </div>

    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div v-if="caricamento" class="centro"><ProgressSpinner /></div>

    <template v-else-if="haDati">
      <div class="kpi" v-if="meseCorrente">
        <Card class="kpi-card">
          <template #title>Punteggio mese ({{ meseCorrente.mese }})</template>
          <template #content><span class="kpi-val">{{ nf.format(meseCorrente.punteggio) }}</span></template>
        </Card>
        <Card class="kpi-card">
          <template #title>Media giornaliera</template>
          <template #content><span class="kpi-val">{{ nf.format(meseCorrente.media) }}</span></template>
        </Card>
        <Card class="kpi-card">
          <template #title>Giornate lavorate</template>
          <template #content><span class="kpi-val">{{ nf.format(meseCorrente.giornate) }}</span></template>
        </Card>
      </div>

      <Card class="grafico">
        <template #title>Punteggio mensile (ultimi 10 mesi)</template>
        <template #content><EChart :option="optMese" /></template>
      </Card>

      <Card class="grafico">
        <template #title>Andamento giornaliero (ultimi 15 giorni)</template>
        <template #content><EChart :option="optGiorno" /></template>
      </Card>
    </template>

    <Message v-else severity="info" :closable="false">
      Nessun dato di punteggio disponibile per questa filiale.
    </Message>
  </div>
</template>

<style scoped>
.dash {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.dash-head {
  display: flex;
  align-items: baseline;
  gap: .75rem;
}
.dash-head h2 { margin: 0; }
.filiale {
  color: #666;
  font-size: .95rem;
}
.centro {
  display: flex;
  justify-content: center;
  padding: 3rem;
}
.kpi {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
  gap: 1rem;
}
.kpi-card :deep(.p-card-title) {
  font-size: .9rem;
  color: #666;
  font-weight: 500;
}
.kpi-val {
  font-size: 2rem;
  font-weight: 700;
  color: #00628f;
}
.grafico :deep(.p-card-content) {
  height: 340px;
}
</style>
