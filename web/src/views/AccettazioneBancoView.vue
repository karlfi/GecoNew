<script setup>
import { ref, computed, watch, onMounted, nextTick } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Select from 'primevue/select'
import AutoComplete from 'primevue/autocomplete'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Dialog from 'primevue/dialog'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Accettazione da banco: replica della videata legacy "AccettazioneDaBanco[Famiglia]".
// L'operatore sceglie cliente/prodotto (ed eventuale ufficio mittente), scansiona i
// barcode delle etichette prestampate e compila i destinatari; il salvataggio crea
// lotto + spedizioni + distinta di accettazione (AI_SPED_AccettazioneBanco) e da li'
// si stampa la ricevuta da consegnare al cliente.

const props = defineProps({ parametri: { type: String, default: '' } })
// regex sulla stringa grezza: il legacy alterna maiuscole/minuscole e virgolette
// (IdCliente=5318, idCliente=5389, CodFamiglia="P"); CodProdotto e' l'alias
// legacy di IdProdotto usato dalle voci Mittenti
const codFamigliaParam = (/CodFamiglia\s*=\s*["']*([A-Za-z0-9]+)/i.exec(props.parametri)?.[1] ?? '').trim()
const idClienteParam = parseInt(/IdCliente\s*=\s*["']*(\d+)/i.exec(props.parametri)?.[1], 10) || null
const idProdottoParam = parseInt(/(?:Id|Cod)Prodotto\s*=\s*["']*(\d+)/i.exec(props.parametri)?.[1], 10) || null

const toast = useToast()
const errore = ref('')
const clienti = ref([])
const cliente = ref(null)
const famiglie = ref([])
const famiglia = ref(null)
const prodotti = ref([])
const prodotto = ref(null)
const mittenti = ref([])
const mittente = ref(null)

// popup di ricerca fine
const ricercaVisibile = ref(false)
const ricercaTesto = ref('')
const ricercaRighe = ref([])
const ricercaInCorso = ref(false)

// griglia degli atti
const nuovaRiga = () => ({
  barcode: '', barcodeAr: '', destinatario: '', indirizzo: '', civico: '',
  localita: '', cap: '', prov: '', esito: null, idSpedizione: null
})
const righe = ref([nuovaRiga()])
const salvando = ref(false)
const riepilogo = ref(null)       // risposta del POST: lotto/distinta creati
const sugComuni = ref([])

// visore PDF della ricevuta (il report server parla solo col backend)
const pdfUrl = ref(null)
const pdfVisibile = ref(false)
const stampando = ref(false)

onMounted(async () => {
  try {
    const { data } = await api.get('/accettazione/init', {
      params: { codFamiglia: codFamigliaParam || undefined }
    })
    clienti.value = data.clienti
    if (idClienteParam) {
      const c = data.clienti.find(x => x.IdCliente === idClienteParam)
      if (c) cliente.value = c
    }
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento iniziale'
  }
})

watch(cliente, async c => {
  famiglie.value = []; famiglia.value = null
  prodotti.value = []; prodotto.value = null
  mittenti.value = []; mittente.value = null
  if (!c) return
  try {
    const [{ data: fam }, { data: mit }] = await Promise.all([
      api.get('/accettazione/famiglie', { params: { idCliente: c.IdCliente } }),
      api.get('/accettazione/mittenti', { params: { idCliente: c.IdCliente } })
    ])
    famiglie.value = fam
    famiglia.value =
      fam.find(f => f.Valore === codFamigliaParam) ?? (fam.length === 1 ? fam[0] : null)
    mittenti.value = mit
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Cliente', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  }
})

watch(famiglia, async f => {
  prodotti.value = []; prodotto.value = null
  if (!f || !cliente.value) return
  try {
    const { data } = await api.get('/accettazione/prodotti', {
      params: { idCliente: cliente.value.IdCliente, codFamiglia: f.Valore }
    })
    prodotti.value = data
    prodotto.value =
      data.find(p => p.idProdotto === idProdottoParam) ?? (data.length === 1 ? data[0] : null)
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Prodotti', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  }
})

// --- ricerca fine (popup), identica all'accettazione da file ---
let timerRicerca = null
watch(ricercaTesto, q => {
  clearTimeout(timerRicerca)
  timerRicerca = setTimeout(async () => {
    if (!q || q.trim().length < 2) { ricercaRighe.value = []; return }
    ricercaInCorso.value = true
    try {
      const { data } = await api.get('/accettazione/clienti-ricerca', {
        params: { q, codFamiglia: codFamigliaParam || undefined }
      })
      ricercaRighe.value = data
    } catch { ricercaRighe.value = [] }
    finally { ricercaInCorso.value = false }
  }, 350)
})
function scegliDaRicerca(r) {
  ricercaVisibile.value = false
  ricercaTesto.value = ''
  ricercaRighe.value = []
  let c = clienti.value.find(x => x.IdCliente === r.idCliente)
  if (!c) {
    c = { IdCliente: r.idCliente, RagioneSociale: r.ragioneSociale }
    clienti.value = [...clienti.value, c].sort((a, b) => a.RagioneSociale.localeCompare(b.RagioneSociale))
  }
  cliente.value = c
}

// --- comuni esistenti (GEO_COMUNE): la scelta imposta anche CAP e provincia ---
let rigaComuni = null
async function cercaComuni(riga, ev) {
  rigaComuni = riga
  try {
    const { data } = await api.get('/sped/comuni', {
      params: { q: ev.query, prov: riga.prov || undefined }
    })
    sugComuni.value = data
  } catch { sugComuni.value = [] }
}
function applicaComune(riga, v) {
  riga.localita = v.comune
  riga.cap = v.cap
  riga.prov = v.provincia
}

// --- righe della griglia ---
const rigaVuota = r => !r.barcode && !r.destinatario && !r.indirizzo && !r.localita
const rigaCompleta = r => r.barcode && r.destinatario && r.indirizzo && r.localita && r.cap && r.prov?.length === 2
const attiValidi = computed(() => righe.value.filter(r => !rigaVuota(r)))
const puoSalvare = computed(() =>
  cliente.value && famiglia.value && prodotto.value && !riepilogo.value
  && attiValidi.value.length > 0 && attiValidi.value.every(rigaCompleta))

const barcodeInput = ref([])
function aggiungiRiga() {
  righe.value.push(nuovaRiga())
  nextTick(() => barcodeInput.value[righe.value.length - 1]?.$el?.focus?.())
}
function rimuoviRiga(i) {
  righe.value.splice(i, 1)
  if (!righe.value.length) righe.value.push(nuovaRiga())
}
function invioSuRiga(i) {
  if (i === righe.value.length - 1 && !rigaVuota(righe.value[i])) aggiungiRiga()
}

async function salva() {
  salvando.value = true
  try {
    const { data } = await api.post('/accettazione/banco', {
      idCliente: cliente.value.IdCliente,
      codFamiglia: famiglia.value.Valore,
      idProdotto: prodotto.value.idProdotto,
      idMittente: mittente.value?.idMittente ?? null,
      righe: righe.value.map(r => ({
        barcode: r.barcode, barcodeAr: r.barcodeAr, destinatario: r.destinatario,
        indirizzo: r.indirizzo, civico: r.civico, localita: r.localita,
        cap: r.cap, prov: r.prov
      }))
    })
    riepilogo.value = data
    for (const e of data.righe) {
      const r = righe.value[e.riga]
      if (r) { r.esito = e.esito; r.idSpedizione = e.idSpedizione }
    }
    if (data.scartati > 0)
      toast.add({ severity: 'warn', summary: 'Accettazione', detail: `${data.scartati} atto/i non inseriti, controlla gli esiti`, life: 6000 })
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Accettazione', detail: e.response?.data?.errore ?? 'Errore imprevisto', life: 6000 })
  } finally {
    salvando.value = false
  }
}

// il PDF arriva dal backend (proxy del report server) e si mostra in un iframe:
// l'URL della pagina non cambia e il report server resta invisibile
async function stampaRicevuta() {
  stampando.value = true
  try {
    const { data } = await api.get(`/accettazione/ricevuta/${riepilogo.value.idDistinta}`, { responseType: 'blob' })
    if (pdfUrl.value) URL.revokeObjectURL(pdfUrl.value)
    pdfUrl.value = URL.createObjectURL(data)
    pdfVisibile.value = true
  } catch (e) {
    let msg = 'Errore nella stampa'
    try { msg = JSON.parse(await e.response.data.text()).errore ?? msg } catch { /* risposta non JSON */ }
    toast.add({ severity: 'error', summary: 'Ricevuta', detail: msg, life: 6000 })
  } finally {
    stampando.value = false
  }
}
function chiudiPdf() {
  if (pdfUrl.value) URL.revokeObjectURL(pdfUrl.value)
  pdfUrl.value = null
}

function nuovaAccettazione() {
  riepilogo.value = null
  righe.value = [nuovaRiga()]
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Accettazione da banco{{ codFamigliaParam ? ` — famiglia ${codFamigliaParam}` : '' }}</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Cliente e prodotto</div>
      <div class="griglia">
        <label class="span2">Cliente *
          <div class="riga-cliente">
            <Select v-model="cliente" :options="clienti" optionLabel="RagioneSociale" filter fluid
              :disabled="!!riepilogo" placeholder="— scegli il cliente —" :loading="!clienti.length && !errore" />
            <Button label="Ricerca" icon="pi pi-search" outlined :disabled="!!riepilogo" @click="ricercaVisibile = true" />
          </div>
        </label>
        <label>Famiglia *
          <Select v-model="famiglia" :options="famiglie" optionLabel="Nome" fluid
            :disabled="!cliente || !!riepilogo" :placeholder="cliente ? '— scegli —' : 'prima il cliente'" />
        </label>
        <label>Prodotto *
          <Select v-model="prodotto" :options="prodotti" optionLabel="prodotto" fluid
            :disabled="!famiglia || !!riepilogo" :placeholder="famiglia ? (prodotti.length ? '— scegli —' : 'nessun prodotto abilitato') : 'prima la famiglia'" />
        </label>
        <label class="span2" v-if="mittenti.length">Ufficio mittente
          <Select v-model="mittente" :options="mittenti" optionLabel="ragioneSociale" filter showClear fluid
            :disabled="!!riepilogo" placeholder="anagrafica del cliente">
            <template #option="{ option }">
              <div class="opt-mittente"><b>{{ option.ragioneSociale }}</b>
                <small>{{ option.indirizzo }}, {{ option.cap }} {{ option.localita }} {{ option.provincia }}</small>
              </div>
            </template>
          </Select>
        </label>
      </div>
    </section>

    <section class="card">
      <div class="card-titolo">Atti da accettare
        <span class="conteggio">{{ attiValidi.length }} atto/i</span>
      </div>
      <div class="corpo">
        <div class="tabella-atti">
          <div class="testata">
            <span>#</span><span>Barcode *</span><span>Barcode AR</span><span>Destinatario *</span>
            <span>Indirizzo *</span><span>Civico</span><span>Comune *</span><span>CAP *</span>
            <span>Prov *</span><span></span>
          </div>
          <div v-for="(r, i) in righe" :key="i" class="riga"
            :class="{ incompleta: !rigaVuota(r) && !rigaCompleta(r) && !riepilogo }">
            <span class="num">{{ i + 1 }}</span>
            <InputText :ref="el => barcodeInput[i] = el" v-model.trim="r.barcode" :disabled="!!riepilogo"
              placeholder="scansiona l'etichetta" @keyup.enter="invioSuRiga(i)" />
            <InputText v-model.trim="r.barcodeAr" :disabled="!!riepilogo"
              placeholder="cartolina AR" @keyup.enter="invioSuRiga(i)" />
            <InputText v-model="r.destinatario" :disabled="!!riepilogo" @keyup.enter="invioSuRiga(i)" />
            <InputText v-model="r.indirizzo" :disabled="!!riepilogo" @keyup.enter="invioSuRiga(i)" />
            <InputText v-model.trim="r.civico" :disabled="!!riepilogo" @keyup.enter="invioSuRiga(i)" />
            <AutoComplete :modelValue="r.localita"
              @update:modelValue="v => r.localita = typeof v === 'string' ? v : v?.comune ?? ''"
              :suggestions="sugComuni" optionLabel="comune" :disabled="!!riepilogo"
              @complete="ev => cercaComuni(r, ev)" @option-select="ev => applicaComune(r, ev.value)">
              <template #option="{ option }">{{ option.comune }} — {{ option.cap }} ({{ option.provincia }})</template>
            </AutoComplete>
            <InputText v-model.trim="r.cap" maxlength="5" :disabled="!!riepilogo" @keyup.enter="invioSuRiga(i)" />
            <InputText :modelValue="r.prov" maxlength="2" :disabled="!!riepilogo"
              @update:modelValue="v => r.prov = (v ?? '').toUpperCase()" @keyup.enter="invioSuRiga(i)" />
            <span class="azioni-riga">
              <Tag v-if="r.esito" :severity="r.esito === 'OK' ? 'success' : 'danger'"
                :value="r.esito === 'OK' ? String(r.idSpedizione) : r.esito"
                v-tooltip.left="r.esito === 'OK' ? 'IdSpedizione ' + r.idSpedizione : r.esito" />
              <Button v-else icon="pi pi-times" text severity="danger" :disabled="!!riepilogo"
                @click="rimuoviRiga(i)" tabindex="-1" />
            </span>
          </div>
        </div>
        <div class="sotto-griglia">
          <Button label="Aggiungi atto" icon="pi pi-plus" outlined :disabled="!!riepilogo" @click="aggiungiRiga" />
          <Button label="Salva accettazione" icon="pi pi-check" :disabled="!puoSalvare"
            :loading="salvando" @click="salva" />
        </div>
      </div>
    </section>

    <div v-if="riepilogo" class="cardone ok">
      <i class="pi pi-check-circle" style="font-size: 2rem; color: var(--p-green-600)"></i>
      <div class="ok-testo">
        <div class="ok-lotto">Lotto <b>{{ riepilogo.lotto }}</b> ({{ riepilogo.idLotto }})</div>
        <div>{{ riepilogo.inseriti }} atto/i accettati — distinta {{ riepilogo.barcodeDistinta }}</div>
        <Message v-if="riepilogo.scartati > 0" severity="warn" :closable="false">
          {{ riepilogo.scartati }} atto/i scartati: vedi gli esiti sulle righe
        </Message>
      </div>
      <div class="ok-azioni">
        <Button label="Stampa ricevuta" icon="pi pi-print" :loading="stampando"
          :disabled="!riepilogo.idDistinta" @click="stampaRicevuta" />
        <Button label="Nuova accettazione" icon="pi pi-plus" outlined @click="nuovaAccettazione" />
      </div>
    </div>

    <Dialog v-model:visible="ricercaVisibile" header="Ricerca cliente" modal :style="{ width: '46rem' }">
      <div class="ricerca-corpo">
        <InputText v-model="ricercaTesto" fluid autofocus
          placeholder="ragione sociale, partita IVA, codice cliente o comune (min 2 caratteri)" />
        <DataTable :value="ricercaRighe" size="small" stripedRows scrollable scrollHeight="320px"
          :loading="ricercaInCorso" @row-click="e => scegliDaRicerca(e.data)" :rowHover="true">
          <Column field="ragioneSociale" header="Ragione sociale" />
          <Column field="partitaIva" header="P.IVA" style="width: 8.5rem" />
          <Column field="codiceCliente" header="Codice" style="width: 6.5rem" />
          <Column header="Sede">
            <template #body="{ data }">{{ data.comune }} {{ data.prov ? `(${data.prov})` : '' }}</template>
          </Column>
        </DataTable>
        <small v-if="ricercaTesto.length >= 2 && !ricercaRighe.length && !ricercaInCorso" class="vuoto">
          Nessun cliente trovato.
        </small>
      </div>
    </Dialog>

    <!-- ricevuta di accettazione: PDF servito dal backend, mostrato in un frame interno -->
    <Dialog v-model:visible="pdfVisibile" modal maximizable header="Ricevuta di accettazione"
      :style="{ width: '62rem' }" @hide="chiudiPdf">
      <iframe v-if="pdfUrl" :src="pdfUrl" class="pdf-frame" title="Ricevuta di accettazione"></iframe>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1400px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center;
}
.conteggio { font-size: .8rem; font-weight: 400; opacity: .9; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.griglia { display: grid; grid-template-columns: repeat(4, 1fr); gap: .6rem .8rem; padding: .8rem; align-items: end; }
.griglia label { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.span2 { grid-column: span 2; }
.riga-cliente { display: flex; gap: .5rem; }
.riga-cliente > :first-child { flex: 1; }
.opt-mittente { display: flex; flex-direction: column; }
.opt-mittente small { color: var(--p-text-muted-color); }

.tabella-atti { display: flex; flex-direction: column; gap: .3rem; overflow-x: auto; }
.testata, .riga {
  display: grid; align-items: center; gap: .35rem; min-width: 1100px;
  grid-template-columns: 1.6rem 11rem 10rem minmax(10rem, 1.3fr) minmax(9rem, 1.2fr) 4.5rem 10.5rem 4.6rem 3.2rem 6.5rem;
}
.testata { font-size: .78rem; color: #555; font-weight: 600; padding: 0 .1rem; }
.riga.incompleta :deep(.p-inputtext) { border-color: var(--p-orange-400); }
.riga .num { font-size: .8rem; color: var(--p-text-muted-color); text-align: right; }
.riga :deep(.p-inputtext) { padding: .35rem .5rem; font-size: .85rem; width: 100%; }
.riga :deep(.p-autocomplete) { width: 100%; }
.azioni-riga { display: flex; justify-content: center; }
.sotto-griglia { display: flex; justify-content: space-between; }

.cardone {
  display: flex; align-items: center; gap: 1rem; padding: 1rem 1.2rem;
  border: 1px solid var(--p-green-200); background: var(--p-green-50); border-radius: 8px;
}
.ok-testo { flex: 1; display: flex; flex-direction: column; gap: .25rem; }
.ok-lotto { font-size: 1.05rem; }
.ok-azioni { display: flex; flex-direction: column; gap: .5rem; }
.pdf-frame { width: 100%; height: 75vh; border: 0; }
.ricerca-corpo { display: flex; flex-direction: column; gap: .75rem; }
.ricerca-corpo :deep(.p-datatable-tbody > tr) { cursor: pointer; }
.vuoto { color: var(--p-text-muted-color); }
</style>
