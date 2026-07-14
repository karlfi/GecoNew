<script setup>
import { ref, computed, onMounted } from 'vue'
import api from '../api'
import { useAuthStore } from '../stores/auth'
import EChart from '../components/EChart.vue'
import Card from 'primevue/card'
import Message from 'primevue/message'
import ProgressSpinner from 'primevue/progressspinner'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

const auth = useAuthStore()
const caricamento = ref(false)
const errore = ref('')
const mese = ref([])
const giorno = ref([])
const meseAzienda = ref([])
const giornoAzienda = ref([])
const confrontoFiliali = ref([])
const aziendaNome = ref('')
const meseLabel = ref('')
const idFiliale = ref(null)

const COLORI = { punteggio: '#00afde', media: '#f59e0b', corrente: '#00628f' }
const nf = new Intl.NumberFormat('it-IT', { maximumFractionDigits: 0 })

async function carica() {
  errore.value = ''
  caricamento.value = true
  try {
    const { data } = await api.get('/dashboard/punteggi')
    mese.value = data.mese
    giorno.value = data.giorno
    meseAzienda.value = data.meseAzienda ?? []
    giornoAzienda.value = data.giornoAzienda ?? []
    confrontoFiliali.value = data.confrontoFiliali ?? []
    aziendaNome.value = data.aziendaNome ?? ''
    meseLabel.value = data.meseLabel ?? ''
    idFiliale.value = data.idFiliale
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei dati'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)

const meseCorrente = computed(() => mese.value.at(-1) ?? null)

// --- builder grafici riutilizzabili (filiale e azienda usano gli stessi) ---
function buildMese(dati) {
  return {
    tooltip: { trigger: 'axis', axisPointer: { type: 'cross' } },
    legend: { data: ['Punteggio', 'Media'] },
    grid: { left: 60, right: 60, top: 40, bottom: 40 },
    xAxis: { type: 'category', data: dati.map(r => r.mese) },
    yAxis: [
      { type: 'value', name: 'Punteggio', axisLabel: { formatter: v => nf.format(v) } },
      { type: 'value', name: 'Media', splitLine: { show: false } }
    ],
    series: [
      { name: 'Punteggio', type: 'bar', itemStyle: { color: COLORI.punteggio }, data: dati.map(r => Math.round(r.punteggio)) },
      { name: 'Media', type: 'line', yAxisIndex: 1, smooth: true, symbol: 'circle', symbolSize: 7, lineStyle: { width: 3 }, itemStyle: { color: COLORI.media }, data: dati.map(r => r.media) }
    ]
  }
}
function buildGiorno(dati) {
  return {
    tooltip: { trigger: 'axis', axisPointer: { type: 'cross' } },
    legend: { data: ['Punteggio', 'Media'] },
    grid: { left: 60, right: 60, top: 40, bottom: 40 },
    xAxis: { type: 'category', data: dati.map(r => { const [, m, d] = r.data.split('-'); return `${d}/${m}` }) },
    yAxis: [
      { type: 'value', name: 'Punteggio', axisLabel: { formatter: v => nf.format(v) } },
      { type: 'value', name: 'Media', splitLine: { show: false } }
    ],
    series: [
      { name: 'Punteggio', type: 'line', smooth: true, areaStyle: { opacity: 0.25 }, symbol: 'circle', symbolSize: 6, lineStyle: { width: 3 }, itemStyle: { color: COLORI.punteggio }, data: dati.map(r => Math.round(r.punteggio)) },
      { name: 'Media', type: 'line', yAxisIndex: 1, smooth: true, symbol: 'circle', symbolSize: 6, lineStyle: { width: 2, type: 'dashed' }, itemStyle: { color: COLORI.media }, data: dati.map(r => r.media) }
    ]
  }
}

const optMeseFil = computed(() => buildMese(mese.value))
const optGiornoFil = computed(() => buildGiorno(giorno.value))
const optMeseAz = computed(() => buildMese(meseAzienda.value))
const optGiornoAz = computed(() => buildGiorno(giornoAzienda.value))

// --- confronto filiali: metrica omogenea = Media (punteggio/giornata) ---
const filialiPerMedia = computed(() =>
  [...confrontoFiliali.value].sort((a, b) => b.media - a.media))

const aziendaTotali = computed(() => {
  const p = confrontoFiliali.value.reduce((s, r) => s + (r.punteggio ?? 0), 0)
  const g = confrontoFiliali.value.reduce((s, r) => s + (r.giornate ?? 0), 0)
  return { punteggio: p, giornate: g, media: g > 0 ? Math.round(p / g) : 0 }
})

const optConfronto = computed(() => {
  const filiali = filialiPerMedia.value
  return {
    tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' }, formatter: p => `${p[0].name}<br/>Media: <b>${nf.format(p[0].value)}</b>` },
    grid: { left: 150, right: 30, top: 10, bottom: 30 },
    xAxis: { type: 'value', name: 'Media' },
    yAxis: { type: 'category', inverse: true, data: filiali.map(f => f.filiale), axisLabel: { fontSize: 10 } },
    series: [{
      type: 'bar',
      data: filiali.map(f => ({
        value: f.media,
        itemStyle: { color: f.idFiliale === idFiliale.value ? COLORI.corrente : COLORI.punteggio }
      })),
      label: { show: true, position: 'right', formatter: p => nf.format(p.value), fontSize: 10 },
      markLine: {
        symbol: 'none',
        data: [{ xAxis: aziendaTotali.value.media }],
        lineStyle: { color: COLORI.media, type: 'dashed', width: 2 },
        label: { formatter: `Media azienda ${nf.format(aziendaTotali.value.media)}`, position: 'insideEndTop' }
      }
    }]
  }
})
const altezzaConfronto = computed(() => Math.max(260, filialiPerMedia.value.length * 24 + 60) + 'px')

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
      <!-- ===== FILIALE ===== -->
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
        <template #content><EChart :option="optMeseFil" /></template>
      </Card>
      <Card class="grafico">
        <template #title>Andamento giornaliero (ultimi 15 giorni)</template>
        <template #content><EChart :option="optGiornoFil" /></template>
      </Card>

      <!-- ===== AZIENDA ===== -->
      <template v-if="meseAzienda.length">
        <div class="sezione">
          <h3>Azienda<span v-if="aziendaNome"> — {{ aziendaNome }}</span></h3>
          <span class="nota">aggregato di tutte le filiali attive (media = punteggio totale / giornate totali)</span>
        </div>
        <Card class="grafico">
          <template #title>Punteggio mensile azienda</template>
          <template #content><EChart :option="optMeseAz" /></template>
        </Card>
        <Card class="grafico">
          <template #title>Andamento giornaliero azienda</template>
          <template #content><EChart :option="optGiornoAz" /></template>
        </Card>
      </template>

      <!-- ===== CONFRONTO FILIALI ===== -->
      <template v-if="confrontoFiliali.length">
        <div class="sezione">
          <h3>Confronto filiali attive<span v-if="meseLabel"> — {{ meseLabel }}</span></h3>
          <span class="nota">ordinate per Media (punteggio per giornata): metrica confrontabile tra filiali di dimensioni diverse</span>
        </div>

        <Card class="grafico" :style="{ '--h': altezzaConfronto }">
          <template #title>Media per filiale</template>
          <template #content><EChart :option="optConfronto" class="confronto-chart" /></template>
        </Card>

        <Card>
          <template #title>Dettaglio per filiale</template>
          <template #content>
            <DataTable :value="confrontoFiliali" size="small" stripedRows showGridlines
                       sortField="punteggio" :sortOrder="-1"
                       :rowClass="r => r.idFiliale === idFiliale ? 'riga-corrente' : ''">
              <Column field="filiale" header="Filiale" sortable />
              <Column field="punteggio" header="Punteggio" sortable>
                <template #body="{ data }">{{ nf.format(data.punteggio) }}</template>
              </Column>
              <Column field="media" header="Media" sortable>
                <template #body="{ data }">{{ nf.format(data.media) }}</template>
              </Column>
              <Column field="giornate" header="Giornate" sortable>
                <template #body="{ data }">{{ nf.format(data.giornate) }}</template>
              </Column>
              <template #footer>
                <div class="totale">
                  <span>Totale azienda ({{ confrontoFiliali.length }} filiali)</span>
                  <span>Punteggio: <b>{{ nf.format(aziendaTotali.punteggio) }}</b></span>
                  <span>Media: <b>{{ nf.format(aziendaTotali.media) }}</b></span>
                  <span>Giornate: <b>{{ nf.format(aziendaTotali.giornate) }}</b></span>
                </div>
              </template>
            </DataTable>
          </template>
        </Card>
      </template>
    </template>

    <Message v-else severity="info" :closable="false">
      Nessun dato di punteggio disponibile per questa filiale.
    </Message>
  </div>
</template>

<style scoped>
.dash { display: flex; flex-direction: column; gap: 1rem; }
.dash-head { display: flex; align-items: baseline; gap: .75rem; }
.dash-head h2 { margin: 0; }
.filiale { color: #666; font-size: .95rem; }
.centro { display: flex; justify-content: center; padding: 3rem; }
.kpi { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1rem; }
.kpi-card :deep(.p-card-title) { font-size: .9rem; color: #666; font-weight: 500; }
.kpi-val { font-size: 2rem; font-weight: 700; color: #00628f; }
.grafico :deep(.p-card-content) { height: 340px; }
.sezione {
  display: flex; align-items: baseline; gap: .75rem; flex-wrap: wrap;
  border-top: 2px solid var(--p-surface-200); padding-top: 1rem; margin-top: .5rem;
}
.sezione h3 { margin: 0; color: #00628f; }
.nota { color: #888; font-size: .82rem; }
/* il grafico confronto ha altezza dinamica in base al numero di filiali */
.grafico:has(.confronto-chart) :deep(.p-card-content) { height: var(--h, 340px); }
.confronto-chart { height: 100%; }
:deep(.riga-corrente) { background: rgba(0, 98, 143, .08) !important; font-weight: 600; }
.totale { display: flex; gap: 1.5rem; flex-wrap: wrap; font-size: .88rem; color: #444; }
</style>
