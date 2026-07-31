<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { useNavStore } from '../stores/nav'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Checkbox from 'primevue/checkbox'
import DatePicker from 'primevue/datepicker'
import Dialog from 'primevue/dialog'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Scontrini di Fine Gita: replica della videata legacy. Elenco delle gite dei
// driver (conteggi per servizio, gita aperta/chiusa), scontrino a video per le
// gite chiuse, stampa dei cedolini FastReport e drill sulle interrogazioni
// legate (spari da palmare, giro vettore).

const toast = useToast()
const nav = useNavStore()
const errore = ref('')
const caricamento = ref(false)
const righe = ref([])
const tutteFiliali = ref(false)
const dal = ref(new Date(Date.now() - 7 * 864e5))
const al = ref(new Date())

const gita = ref(null)            // riga aperta nel dettaglio
const scontrino = ref([])
const dettaglio = ref([])
const dettaglioVisibile = ref(false)
const caricamentoScontrino = ref(false)

// visore PDF dei cedolini (il report server parla solo col backend)
const pdf = ref({ visibile: false, titolo: '', url: null, caricamento: false })

function ymd(d) {
  return d ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` : null
}

async function carica() {
  caricamento.value = true
  errore.value = ''
  try {
    const { data } = await api.get('/finegita/elenco', {
      params: { dal: ymd(dal.value), al: ymd(al.value), tutte: tutteFiliali.value || undefined }
    })
    righe.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle gite'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)

async function apriGita(r) {
  gita.value = r
  scontrino.value = []
  dettaglio.value = []
  dettaglioVisibile.value = false
  if (!r.idFineGita) return   // gita aperta: niente scontrino, restano i drill
  caricamentoScontrino.value = true
  try {
    const { data } = await api.get(`/finegita/${r.idFineGita}/scontrino`)
    scontrino.value = data
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Scontrino', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  } finally {
    caricamentoScontrino.value = false
  }
}
function tornaAllElenco() {
  gita.value = null
  scontrino.value = []
  dettaglio.value = []
}

async function mostraDettaglio() {
  dettaglioVisibile.value = !dettaglioVisibile.value
  if (!dettaglioVisibile.value || dettaglio.value.length) return
  try {
    const { data } = await api.get(`/finegita/${gita.value.idFineGita}/dettaglio`)
    dettaglio.value = data
  } catch (e) {
    dettaglioVisibile.value = false
    toast.add({ severity: 'error', summary: 'Dettaglio', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  }
}

// cedolini: PDF via proxy /api/report (stessi report della videata legacy)
async function stampa(template, titolo) {
  pdf.value = { visibile: true, titolo, url: null, caricamento: true }
  try {
    const { data } = await api.get('/report', {
      params: { src: `${template}|IdFineGita=${gita.value.idFineGita}` },
      responseType: 'blob'
    })
    if (pdf.value.url) URL.revokeObjectURL(pdf.value.url)
    pdf.value.url = URL.createObjectURL(data)
  } catch (e) {
    pdf.value.visibile = false
    let msg = 'Errore nella generazione del cedolino'
    try { msg = JSON.parse(await e.response.data.text()).errore ?? msg } catch { /* risposta non JSON */ }
    toast.add({ severity: 'error', summary: titolo, detail: msg, life: 5000 })
  } finally {
    pdf.value.caricamento = false
  }
}
function chiudiPdf() {
  if (pdf.value.url) URL.revokeObjectURL(pdf.value.url)
  pdf.value = { visibile: false, titolo: '', url: null, caricamento: false }
}

// drill sulle stesse interrogazioni della videata legacy (colonne QUERY# della 1026)
function apriSpari() {
  nav.drill({
    tipo: 'interrogazioni', idQuery: 1130,
    sWhere: ` and r.driver='${gita.value.driver}' and CONVERT(date,r.datacreazione)='${gita.value.data}'`
  })
}
function apriGiro() {
  nav.drill({
    tipo: 'interrogazioni', idQuery: 1133,
    sWhere: ` and DriverAssegnato='${gita.value.driver}' and CONVERT(date,DataEffettiva)=convert(date,'${gita.value.data}')`
  })
}

const totali = computed(() => {
  const t = { cert: 0, parc: 0, racc: 0, raccAr: 0, ag: 0, notifiche: 0, totale: 0 }
  for (const r of righe.value) for (const k of Object.keys(t)) t[k] += r[k] ?? 0
  return t
})

function dataIt(iso) {
  if (!iso) return ''
  const [a, m, g] = iso.split('-')
  return `${g}/${m}/${a}`
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Scontrini di Fine Gita</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <!-- elenco gite -->
    <section v-if="!gita" class="card">
      <div class="card-titolo">Gite dei driver
        <span class="chk-testata"><Checkbox v-model="tutteFiliali" binary @change="carica" /> tutte le filiali</span>
      </div>
      <div class="corpo">
        <div class="barra">
          <label class="campo-data">Dal
            <DatePicker v-model="dal" dateFormat="dd/mm/yy" showIcon />
          </label>
          <label class="campo-data">Al
            <DatePicker v-model="al" dateFormat="dd/mm/yy" showIcon />
          </label>
          <Button label="Aggiorna" icon="pi pi-refresh" :loading="caricamento" @click="carica" />
          <span class="spazio"></span>
          <span v-if="righe.length" class="conta">{{ righe.length }} gite — {{ totali.totale }} atti</span>
        </div>

        <DataTable :value="righe" size="small" stripedRows :loading="caricamento" rowHover
          paginator :rows="25" @row-click="e => apriGita(e.data)" class="tab-gite">
          <Column field="data" header="Data" style="width: 6.2rem">
            <template #body="{ data }">{{ dataIt(data.data) }}</template>
          </Column>
          <Column field="nome" header="Driver" />
          <Column v-if="tutteFiliali" field="filiale" header="Filiale" />
          <Column field="login" header="Login" style="width: 4.2rem" />
          <Column field="logout" header="Logout" style="width: 4.2rem" />
          <Column field="cert" header="CERT" style="width: 4rem" />
          <Column field="parc" header="PARC" style="width: 4rem" />
          <Column field="racc" header="RACC" style="width: 4rem" />
          <Column field="raccAr" header="RACC AR" style="width: 5rem" />
          <Column field="ag" header="AG" style="width: 3.6rem" />
          <Column field="notifiche" header="NOT" style="width: 3.8rem" />
          <Column field="totale" header="Totale" style="width: 4.5rem" />
          <Column header="Gita" style="width: 6.5rem">
            <template #body="{ data }">
              <Tag :severity="data.idFineGita ? 'success' : 'warn'"
                :value="data.idFineGita ? 'Chiusa' : 'Aperta'" />
            </template>
          </Column>
          <template #empty>Nessuna gita nel periodo selezionato.</template>
        </DataTable>
      </div>
    </section>

    <!-- dettaglio gita / scontrino -->
    <template v-else>
      <section class="card">
        <div class="card-titolo">
          Scontrino — {{ gita.nome }} — {{ dataIt(gita.data) }}
          <Tag :severity="gita.idFineGita ? 'success' : 'warn'" :value="gita.idFineGita ? 'Chiusa' : 'Aperta'" />
        </div>
        <div class="corpo">
          <div class="barra">
            <Button label="Torna all'elenco" icon="pi pi-arrow-left" text @click="tornaAllElenco" />
            <span class="spazio"></span>
            <Button label="Spari da palmare" icon="pi pi-mobile" outlined size="small" @click="apriSpari" />
            <Button label="Giro vettore" icon="pi pi-map" outlined size="small" @click="apriGiro" />
            <template v-if="gita.idFineGita">
              <Button label="Stampa cedolino" icon="pi pi-print" size="small"
                @click="stampa('DELIVERY_FINEGITA.fr3', 'Cedolino Fine Gita')" />
              <Button label="Stampa dettaglio" icon="pi pi-print" outlined size="small"
                @click="stampa('DELIVERY_FINEGITADettaglio.fr3', 'Cedolino Dettaglio Fine Gita')" />
            </template>
          </div>

          <Message v-if="!gita.idFineGita" severity="warn" :closable="false">
            Gita ancora aperta: lo scontrino sarà disponibile alla chiusura dal palmare.
          </Message>

          <template v-else>
            <DataTable :value="scontrino" size="small" stripedRows :loading="caricamentoScontrino"
              class="tab-scontrino">
              <Column field="barcodedistintareso" header="Distinta reso" />
              <Column field="servizio" header="Servizio" />
              <Column field="evento" header="Evento" />
              <Column field="num" header="Atti" style="width: 4.5rem" />
              <template #empty>Nessuna riga sullo scontrino.</template>
            </DataTable>

            <div>
              <Button :label="dettaglioVisibile ? 'Nascondi dettaglio atti' : 'Dettaglio atti'"
                :icon="dettaglioVisibile ? 'pi pi-chevron-up' : 'pi pi-chevron-down'" text size="small"
                @click="mostraDettaglio" />
            </div>
            <DataTable v-if="dettaglioVisibile" :value="dettaglio" size="small" stripedRows
              paginator :rows="25">
              <Column field="barcode" header="Barcode" />
              <Column field="BarcodeDistintaReso" header="Distinta reso" />
              <Column field="Servizio" header="Servizio" />
              <Column field="Evento" header="Evento" />
              <Column field="Destinatario" header="Destinatario" />
              <template #empty>Nessun atto nel dettaglio.</template>
            </DataTable>
          </template>
        </div>
      </section>
    </template>

    <!-- cedolino: PDF servito dal backend, mostrato in un frame interno -->
    <Dialog :visible="pdf.visibile" @update:visible="v => { if (!v) chiudiPdf() }"
      modal maximizable :header="pdf.titolo" :style="{ width: '62rem' }">
      <div v-if="pdf.caricamento" class="pdf-attesa">Generazione in corso…</div>
      <iframe v-else-if="pdf.url" :src="pdf.url" class="pdf-frame" :title="pdf.titolo"></iframe>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1300px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center; gap: .8rem;
}
.chk-testata { display: flex; align-items: center; gap: .4rem; font-size: .82rem; font-weight: 400; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.barra { display: flex; align-items: center; gap: .8rem; flex-wrap: wrap; }
.barra .spazio { flex: 1; }
.campo-data { display: flex; align-items: center; gap: .5rem; font-size: .85rem; color: #555; }
.conta { color: #666; font-size: .85rem; }
.tab-gite :deep(.p-datatable-tbody > tr) { cursor: pointer; }
.tab-scontrino { max-width: 60rem; }
.pdf-frame { width: 100%; height: 75vh; border: 0; }
.pdf-attesa { padding: 3rem; text-align: center; color: #666; }
</style>
