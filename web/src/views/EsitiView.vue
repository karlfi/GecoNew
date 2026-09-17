<script setup>
import { ref, computed, onMounted, nextTick } from 'vue'
import { useToast } from 'primevue/usetoast'
import { parseParametriComando } from '../lib/parametri'
import api from '../api'
import Select from 'primevue/select'
import InputText from 'primevue/inputtext'
import DatePicker from 'primevue/datepicker'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import Message from 'primevue/message'
import ProgressSpinner from 'primevue/progressspinner'

// Videata legacy "Esiti": la pagina operativa cardine (114 voci di menu).
// Processo -> Azione -> campi dinamici (Comune/Operatore) in base ai flag
// dell'azione -> scansione barcode con verifica asincrona (VerificaBarcode)
// -> Conferma (InserimentoEsiti) + stampa distinta. I parametri in ingresso
// (IdProcesso, IdAzione, CodFamiglia, CodFamigliaAzione, Lista) bloccano/
// precompilano le scelte in alto.

const props = defineProps({ parametri: { type: String, default: '' } })
const toast = useToast()

function sq(v) { // strip quotes dai valori dei parametri menu
  let t = `${v ?? ''}`.trim()
  if (t.startsWith('"')) t = t.slice(1)
  if (t.endsWith('"')) t = t.slice(0, -1)
  return t
}
const p = parseParametriComando(props.parametri)
const codFamiglia = sq(p.CodFamiglia)
const codFamigliaAzione = sq(p.CodFamiglia && p.CodFamigliaAzione ? p.CodFamigliaAzione : p.CodFamigliaAzione)
const idProcessoParam = Number(sq(p.IdProcesso)) || null
const idAzioneParam = Number(sq(p.IdAzione)) || null

const errore = ref('')
const processi = ref([])
const processoSel = ref(null)
const processoBloccato = ref(false)

const azioni = ref([])
const azioneSel = ref(null)
const azioneBloccata = ref(false)

const cfg = ref(null)          // config azione: flags, campoComune, campoOperatore, maxAtti
const data = ref(new Date())
const comuneVal = ref(null)
const operatoreVal = ref(null)

const barcodeInput = ref('')
const righe = ref([])
const barcodeRef = ref(null)

// header bloccato quando ci sono barcode in lista (come il legacy)
const headerBloccato = computed(() => righe.value.length > 0)

const numeroDocumenti = computed(() => righe.value.length)
const confermaAbilitata = computed(() =>
  righe.value.length > 0 &&
  righe.value.every(r => r.result === '1' || r.result === '0'))

onMounted(async () => {
  try {
    const { data: proc } = await api.get('/esiti/processi', { params: { codFamiglia: codFamiglia || undefined } })
    processi.value = proc
    if (idProcessoParam) {
      processoSel.value = idProcessoParam
      processoBloccato.value = true
      await caricaAzioni()
      if (idAzioneParam) {
        azioneSel.value = idAzioneParam
        azioneBloccata.value = true
        await caricaConfig()
      }
    }
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento della pagina'
  }
})

async function caricaAzioni() {
  azioni.value = []
  azioneSel.value = null
  cfg.value = null
  try {
    const { data: a } = await api.get('/esiti/azioni', {
      params: { idProcesso: processoSel.value, codFamigliaAzione: codFamigliaAzione || undefined }
    })
    azioni.value = a
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle azioni'
  }
}

async function caricaConfig() {
  cfg.value = null
  comuneVal.value = null
  operatoreVal.value = null
  if (!azioneSel.value) return
  try {
    const { data: c } = await api.get(`/esiti/azione/${azioneSel.value}`, {
      params: { idProcesso: processoSel.value }
    })
    cfg.value = c
    // una combo con una voce sola (Portiere, Vicino) parte gia' scelta
    const unica = campo => campo?.tipo === 'combo' && campo.options?.length === 1 ? campo.options[0][campo.valueKey] : null
    comuneVal.value = unica(c.campoComune)
    operatoreVal.value = unica(c.campoOperatore)
  } catch (e) {
    errore.value = e.response?.data?.errore ?? "Errore nel caricamento della configurazione dell'azione"
  }
}

function onProcessoChange() { righe.value = []; caricaAzioni() }
function onAzioneChange() { righe.value = []; caricaConfig() }

function isoData() {
  const d = data.value
  return d instanceof Date ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` : null
}

const COLORI = { '1': '#BCFFBC', '0': '#FFFF00', '-1': '#FF0000', '-2': '#FF0000' }
function stileRiga(r) {
  const c = COLORI[r.result]
  return c ? { background: c } : undefined
}

// --- scansione barcode ---
async function onBarcodeEnter() {
  const bc = barcodeInput.value.trim()
  barcodeInput.value = ''
  if (!bc) return
  if (!processoSel.value) { toast.add({ severity: 'error', summary: 'Esiti', detail: 'Processo non specificato', life: 3000 }); return }
  if (!azioneSel.value) { toast.add({ severity: 'error', summary: 'Esiti', detail: 'Azione non specificata', life: 3000 }); return }
  if (righe.value.some(r => r.barcode === bc)) {
    toast.add({ severity: 'warn', summary: 'Barcode', detail: `Barcode ${bc} già inserito`, life: 2500 })
    return
  }
  if (cfg.value?.maxAtti > 0 && righe.value.length >= cfg.value.maxAtti) {
    toast.add({ severity: 'error', summary: 'Esiti', detail: 'Raggiunto il massimo di documenti inseribili in distinta', life: 3500 })
    return
  }
  const attributo = `${operatoreVal.value ?? ''};${comuneVal.value ?? ''}`
  righe.value.push({ progr: righe.value.length + 1, barcode: bc, info: '', attributo, result: null, message: '', stato: '' })
  // passo l'elemento reattivo dell'array (non l'oggetto raw), altrimenti gli
  // aggiornamenti asincroni della verifica non triggererebbero il re-render
  await verifica(righe.value[righe.value.length - 1])
}

async function verifica(riga) {
  try {
    const { data: v } = await api.post('/esiti/verifica', {
      barcode: riga.barcode,
      idAzione: azioneSel.value,
      idProcesso: processoSel.value,
      comune: comuneVal.value != null ? `${comuneVal.value}` : null,
      operatore: operatoreVal.value != null ? `${operatoreVal.value}` : null,
      attributo: riga.attributo,
      data: isoData()
    })
    // caso distinta: il barcode conteneva una lista -> esplodo
    if (v.listaBarcode) {
      const idx = righe.value.indexOf(riga)
      if (idx >= 0) righe.value.splice(idx, 1)
      for (const b of v.listaBarcode.split(',').map(x => x.trim()).filter(Boolean)) {
        if (righe.value.some(r => r.barcode === b)) continue
        righe.value.push({ progr: righe.value.length + 1, barcode: b, info: '', attributo: riga.attributo, result: null, message: '', stato: '' })
        await verifica(righe.value[righe.value.length - 1])
      }
      return
    }
    riga.result = v.result
    riga.info = v.info ?? ''
    riga.message = v.message ?? ''
    riga.stato = v.stato ?? ''
    if (v.result === '-2') {
      // il barcode va tolto dalla lista, con messaggio
      toast.add({ severity: 'warn', summary: riga.barcode, detail: v.message ?? 'Rimosso', life: 4000 })
      const idx = righe.value.indexOf(riga)
      if (idx >= 0) righe.value.splice(idx, 1)
      rinumera()
    } else if (v.result === '-1') {
      toast.add({ severity: 'error', summary: riga.barcode, detail: v.message ?? 'Errore', life: 4000 })
    } else if (v.result === '0') {
      toast.add({ severity: 'warn', summary: riga.barcode, detail: v.message ?? '', life: 3000 })
    }
  } catch (e) {
    riga.result = '-1'
    riga.message = e.response?.data?.errore ?? 'Errore di verifica'
  }
}

function rinumera() { righe.value.forEach((r, i) => r.progr = i + 1) }

function rimuovi(riga) {
  const idx = righe.value.indexOf(riga)
  if (idx >= 0) righe.value.splice(idx, 1)
  rinumera()
}

// --- visore report ---
const visore = ref({ visibile: false, titolo: '', src: '', caricamento: false })
let blobCorrente = null
function chiudiVisore() {
  visore.value.visibile = false
  if (blobCorrente) { URL.revokeObjectURL(blobCorrente); blobCorrente = null }
}
async function mostraReport(report, parametri, titolo) {
  visore.value = { visibile: true, titolo, src: '', caricamento: true }
  try {
    const src = parametri ? `${report}|${parametri}` : report
    const { data: pdf } = await api.get('/report', { params: { src }, responseType: 'blob' })
    if (blobCorrente) URL.revokeObjectURL(blobCorrente)
    blobCorrente = URL.createObjectURL(pdf)
    visore.value.src = blobCorrente
  } catch (e) {
    chiudiVisore()
    let msg = 'Errore nella generazione del report'
    try { msg = JSON.parse(await e.response?.data?.text())?.errore ?? msg } catch {}
    toast.add({ severity: 'error', summary: titolo, detail: msg, life: 5000 })
  } finally {
    visore.value.caricamento = false
  }
}

const conferma = ref(false)
async function onConferma() {
  conferma.value = true
  try {
    const { data: res } = await api.post('/esiti/conferma', {
      idAzione: azioneSel.value,
      idProcesso: processoSel.value,
      elencoBarcode: righe.value.map(r => r.barcode).join(','),
      elencoParametri1: righe.value.map(r => r.attributo).join('|'),
      comune: comuneVal.value != null ? `${comuneVal.value}` : null,
      operatore: operatoreVal.value != null ? `${operatoreVal.value}` : null,
      data: isoData()
    })
    toast.add({ severity: 'success', summary: 'Esiti', detail: res.messaggio, life: 3000 })
    if (res.report) mostraReport(res.report, res.reportParametri, `Distinta ${azioneSel.value}`)
    reset()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Conferma', detail: e.response?.data?.errore ?? 'Errore imprevisto', life: 6000 })
  } finally {
    conferma.value = false
  }
}

// ReStart del legacy: svuota la lista per la successiva azione
function reset() {
  righe.value = []
  barcodeInput.value = ''
  nextTick(() => barcodeRef.value?.$el?.focus?.())
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Esiti</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="scheda">
      <div class="campo">
        <label>Processo</label>
        <Select
          v-model="processoSel" :options="processi"
          optionValue="idProcesso" optionLabel="processo" filter fluid
          :disabled="processoBloccato || headerBloccato"
          @change="onProcessoChange"
          placeholder="Scegli il processo"
        />
      </div>
      <div class="campo">
        <label>Azione</label>
        <Select
          v-model="azioneSel" :options="azioni"
          optionValue="idAzione" optionLabel="azione" filter fluid
          :disabled="azioneBloccata || headerBloccato || !processoSel"
          @change="onAzioneChange"
          placeholder="Scegli l'azione"
        />
      </div>
      <div class="campo">
        <label>Data</label>
        <DatePicker v-model="data" dateFormat="dd/mm/yy" showIcon :disabled="headerBloccato" />
      </div>

      <!-- campo dinamico Comune (etichetta/tipo/opzioni dipendono dall'azione) -->
      <div v-if="cfg?.campoComune" class="campo">
        <label>{{ cfg.campoComune.label }}</label>
        <Select
          v-if="cfg.campoComune.tipo === 'combo'"
          v-model="comuneVal" :options="cfg.campoComune.options"
          :optionValue="cfg.campoComune.valueKey" :optionLabel="cfg.campoComune.labelKey"
          filter showClear fluid :disabled="headerBloccato"
        />
        <DatePicker
          v-else-if="cfg.campoComune.tipo === 'date'"
          v-model="comuneVal" dateFormat="dd/mm/yy" showIcon :disabled="headerBloccato"
        />
        <InputText v-else v-model="comuneVal" fluid :disabled="headerBloccato" />
      </div>

      <!-- campo dinamico Operatore -->
      <div v-if="cfg?.campoOperatore" class="campo">
        <label>{{ cfg.campoOperatore.label }}</label>
        <Select
          v-model="operatoreVal" :options="cfg.campoOperatore.options"
          :optionValue="cfg.campoOperatore.valueKey" :optionLabel="cfg.campoOperatore.labelKey"
          filter showClear fluid :disabled="headerBloccato"
        />
      </div>

      <div class="campo campo-barcode">
        <label>Barcode</label>
        <InputText
          ref="barcodeRef" v-model="barcodeInput" fluid autofocus
          placeholder="Scansiona o digita e premi Invio"
          :disabled="!azioneSel"
          @keyup.enter="onBarcodeEnter"
        />
      </div>
    </div>

    <!-- griglia atti -->
    <div class="griglia-testata">
      Atti <span class="conteggio">{{ righe.length }} documenti</span>
    </div>
    <DataTable :value="righe" :rowStyle="stileRiga" size="small" scrollable scrollHeight="45vh" class="griglia">
      <Column header="Progr." field="progr" style="width: 5rem" />
      <Column header="Barcode" field="barcode" style="width: 16rem" />
      <Column header="Info" field="info" />
      <Column header="Attributo" field="attributo" style="width: 10rem" />
      <Column header="Esito" style="width: 8rem">
        <template #body="{ data: r }">
          <ProgressSpinner v-if="r.result === null" style="width: 18px; height: 18px" strokeWidth="6" />
          <span v-else-if="r.result === '1'" class="pi pi-check esito-ok" />
          <span v-else :title="r.message">{{ r.message || r.result }}</span>
        </template>
      </Column>
      <Column style="width: 3.5rem">
        <template #body="{ data: r }">
          <Button
            icon="pi pi-trash" rounded size="small"
            class="btn-rimuovi" title="Rimuovi dalla griglia"
            @click="rimuovi(r)"
          />
        </template>
      </Column>
      <template #empty><span class="vuoto">Scansiona i barcode da elaborare.</span></template>
    </DataTable>

    <div class="barra-conferma">
      <span class="num">Numero Documenti <b>{{ numeroDocumenti }}</b></span>
      <Button label="Conferma" icon="pi pi-check" :disabled="!confermaAbilitata" :loading="conferma" @click="onConferma" />
    </div>

    <Dialog
      :visible="visore.visibile" @update:visible="v => { if (!v) chiudiVisore() }"
      modal maximizable :header="visore.titolo"
      :style="{ width: '80vw', height: '85vh' }" contentClass="visore-contenuto"
    >
      <div v-if="visore.caricamento" class="centro"><ProgressSpinner /></div>
      <iframe v-else-if="visore.src" :src="visore.src" class="visore-frame" />
      <template #footer><Button label="Chiudi" @click="chiudiVisore" /></template>
    </Dialog>
  </div>
</template>

<style scoped>
.titolo { margin: 0 0 .75rem; }
.scheda {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: .6rem 1.5rem;
  max-width: 1000px;
  margin-bottom: 1rem;
}
.campo { display: grid; grid-template-columns: 8rem 1fr; align-items: center; gap: .5rem; }
.campo > label { font-size: .9rem; color: #444; }
.campo-barcode { grid-column: 1 / -1; max-width: 60%; }

.griglia-testata {
  background: #00a5cf; color: #fff; padding: .4rem .75rem;
  font-weight: 600; font-size: .9rem; border-radius: 6px 6px 0 0;
}
.conteggio { float: right; font-weight: 400; opacity: .9; }
.griglia { font-size: .85rem; }
.esito-ok { color: #1a7a1a; font-weight: 700; }
/* tasto rimuovi: sfondo bianco + icona scura, leggibile su riga verde/gialla/rossa */
.btn-rimuovi {
  background: #fff;
  border: 1px solid #d32f2f;
  color: #d32f2f;
  width: 2rem;
  height: 2rem;
}
.btn-rimuovi:hover { background: #d32f2f; color: #fff; }
.vuoto { color: #888; }

.barra-conferma {
  display: flex; align-items: center; justify-content: flex-end; gap: 1.5rem;
  margin-top: 1rem;
}
.num { font-size: .95rem; }
.centro { display: flex; justify-content: center; padding: 3rem; }
:global(.visore-contenuto) { height: 100%; display: flex; flex-direction: column; }
.visore-frame { flex: 1; width: 100%; height: 100%; min-height: 60vh; border: 0; }
</style>
