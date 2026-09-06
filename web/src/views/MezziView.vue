<script setup>
// Scheda mezzo, come la "Mezzi24" del legacy: si sceglie il mezzo (elenco
// filtrabile, frecce avanti/indietro), si vedono e si modificano testata e
// dati Info, e sotto le linguette: km con foto, posizione e grafico, foto del
// mezzo, costi, altri costi (rifornimenti e Telepass), sinistri, note e
// manutenzioni. Dalle griglie legacy ci si arriva con la targa.
import { ref, computed, watch, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
import Checkbox from 'primevue/checkbox'
import Textarea from 'primevue/textarea'
import Dialog from 'primevue/dialog'
import Tag from 'primevue/tag'
import Tabs from 'primevue/tabs'
import TabList from 'primevue/tablist'
import Tab from 'primevue/tab'
import TabPanels from 'primevue/tabpanels'
import TabPanel from 'primevue/tabpanel'
import AutoComplete from 'primevue/autocomplete'
import ProgressSpinner from 'primevue/progressspinner'
import EChart from '../components/EChart.vue'
import { messaggioErrore } from '../lib/schedulatore'

const props = defineProps({ targa: { type: String, default: null }, idMezzo: { type: Number, default: null }, nuovo: { type: Boolean, default: false } })
const toast = useToast()
const errore = e => toast.add({ severity: 'error', summary: 'Errore', detail: messaggioErrore(e), life: 6000 })

const dataIt = v => v ? new Date(v).toLocaleDateString('it-IT') : ''
const dataOra = v => v ? new Date(v).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' }) : ''
const euro = v => v == null ? '' : Number(v).toLocaleString('it-IT', { style: 'currency', currency: 'EUR' })
const num = (v, d = 0) => v == null ? '' : Number(v).toLocaleString('it-IT', { maximumFractionDigits: d })
const iso = d => d instanceof Date ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` : (d || null)
const mappa = (lat, lng) => `https://www.openstreetmap.org/?mlat=${lat}&mlon=${lng}#map=16/${lat}/${lng}`
// la mappa incorporata di OpenStreetMap: un riquadro di ~1 km attorno al punto, col segnaposto
const mappaEmbed = (lat, lng) => {
  const d = 0.006
  return `https://www.openstreetmap.org/export/embed.html?bbox=${(+lng - d).toFixed(5)},${(+lat - d).toFixed(5)},${(+lng + d).toFixed(5)},${(+lat + d).toFixed(5)}&layer=mapnik&marker=${lat},${lng}`
}

// --- elenco e navigazione tra i mezzi ---
const lookup = ref({ tipi: [], filiali: [], proprieta: [], noleggiatori: [], fornitori: [], aziende: [] })
const mezzi = ref([])
const filtri = ref({ testo: '', idFiliale: null, tipo: null, stato: 'attivi' })
const stati = [{ label: 'attivi', value: 'attivi' }, { label: 'dismessi', value: 'dismessi' }, { label: 'tutti', value: 'tutti' }]
const caricamento = ref(false)
const scelto = ref(null)          // idMezzo corrente
let timer = null
async function caricaElenco(idDaTenere = scelto.value) {
  caricamento.value = true
  try {
    const f = filtri.value
    mezzi.value = (await api.get('/mezzi', { params: { testo: f.testo || null, idFiliale: f.idFiliale, tipo: f.tipo, stato: f.stato } })).data
    if (idDaTenere && mezzi.value.some(m => m.idMezzo === idDaTenere)) scelto.value = idDaTenere
    else if (mezzi.value.length && !nuovoInCorso.value) scelto.value = mezzi.value[0].idMezzo
  } catch (e) { errore(e) } finally { caricamento.value = false }
}
let pronto = false   // i filtri scattano solo dopo l'avvio
watch(() => filtri.value.testo, () => { if (!pronto) return; clearTimeout(timer); timer = setTimeout(() => caricaElenco(), 350) })
watch(() => [filtri.value.idFiliale, filtri.value.tipo, filtri.value.stato], () => { if (pronto) caricaElenco() })
const posizione = computed(() => mezzi.value.findIndex(m => m.idMezzo === scelto.value))
const vai = passo => { const i = posizione.value + passo; if (i >= 0 && i < mezzi.value.length) scelto.value = mezzi.value[i].idMezzo }
const elencoAperto = ref(false)

// --- la scheda ---
const scheda = ref(null)
const edit = ref({})
const nuovoInCorso = ref(false)
const salvataggio = ref(false)
const linguetta = ref('info')
const assegnatario = ref(null)
const suggerimenti = ref([])
const CAMPI_DATA = ['dataImmatricolazione', 'dataAcquisto', 'dataDismissione', 'DataRevisione', 'DataBollo', 'DataScadenzaNoleggio', 'DataContrattoNoleggio', 'DataScadenzaZTL', 'DataFermo']
const CAMPI = ['idMezzo', 'targa', 'codTipoMezzo', 'modello', 'marca', 'telaio', 'idFiliale', 'IdUtente', 'Telepass', 'TesseraCarb', 'Proprieta', 'ImportoRata', 'Noleggiatore',
  'Contratto', 'ImportoRiscatto', 'Rottamato', 'Scorta', 'IdAzienda', 'ComuneZTL', 'DKV_idveicolo', 'DKV_trasponder', ...CAMPI_DATA]
function vuoto() {
  const o = Object.fromEntries(CAMPI.map(k => [k, null]))
  return { ...o, targa: '', Scorta: false, Rottamato: false, IdAzienda: lookup.value.aziende[0]?.IdAzienda ?? null }
}
let inCarico = null   // per non chiedere due volte lo stesso mezzo
async function caricaScheda(id) {
  if (!id || inCarico === id) return
  inCarico = id
  try {
    const { data } = await api.get(`/mezzi/${id}`)
    scheda.value = data
    const e = Object.fromEntries(CAMPI.map(k => [k, data[k] ?? null]))
    for (const k of CAMPI_DATA) e[k] = data[k] ? new Date(data[k]) : null
    e.Scorta = data.Scorta === 1; e.Rottamato = data.Rottamato === 1
    e.codTipoMezzo = (data.codTipoMezzo ?? '').trim() || null
    edit.value = e
    assegnatario.value = data.IdUtente ? { IdUtente: data.IdUtente, Nome: data.Assegnatario, Matricola: data.Matricola } : null
    nuovoInCorso.value = false
    await caricaLinguetta(linguetta.value, true)
  } catch (e) { errore(e) } finally { if (inCarico === id) inCarico = null }
}
watch(scelto, id => { if (id && scheda.value?.idMezzo !== id) caricaScheda(id) })
function nuovoMezzo() {
  nuovoInCorso.value = true
  scheda.value = null
  edit.value = vuoto()
  assegnatario.value = null
  linguetta.value = 'info'
  km.value = []; foto.value = []; costi.value = null; altri.value = null; sinistri.value = []; note.value = []; modifiche.value = []
}
async function cercaDipendenti(ev) { try { suggerimenti.value = (await api.get('/mezzi/dipendenti', { params: { testo: ev.query } })).data } catch { suggerimenti.value = [] } }
async function salva() {
  if (!edit.value.targa?.trim()) { toast.add({ severity: 'warn', summary: 'La targa è obbligatoria', life: 3000 }); return }
  salvataggio.value = true
  try {
    const corpo = { ...edit.value, IdUtente: assegnatario.value?.IdUtente ?? null, Scorta: edit.value.Scorta ? 1 : 0, Rottamato: edit.value.Rottamato ? 1 : 0 }
    for (const k of CAMPI_DATA) corpo[k] = iso(edit.value[k])
    const { data } = await api.post('/mezzi', corpo)
    toast.add({ severity: 'success', summary: nuovoInCorso.value ? 'Mezzo creato' : 'Mezzo salvato', life: 2500 })
    nuovoInCorso.value = false
    await caricaElenco(data.idMezzo)
    if (scelto.value === data.idMezzo) await caricaScheda(data.idMezzo); else scelto.value = data.idMezzo
  } catch (e) { errore(e) } finally { salvataggio.value = false }
}
const titolo = computed(() => nuovoInCorso.value ? 'Nuovo mezzo' : scheda.value ? `${scheda.value.targa} · ${scheda.value.marca ?? ''} ${scheda.value.modello ?? ''}` : 'Scheda mezzo')

// --- linguette: si caricano quando servono ---
const km = ref([]); const anniKm = ref([]); const annoKm = ref(null); const kmScelto = ref(null)
const foto = ref([]); const costi = ref(null); const annoCosti = ref(null); const altri = ref(null); const sinistri = ref([]); const note = ref([])
// log delle modifiche alla scheda: una riga per campo cambiato, come nella scheda utente
const modifiche = ref([])
const ETICHETTE = { targa: 'Targa', codTipoMezzo: 'Tipo mezzo', modello: 'Modello', marca: 'Marca', telaio: 'Telaio', dataImmatricolazione: 'Data immatricolazione',
  dataAcquisto: 'Data acquisto', dataDismissione: 'Data dismissione', DataRevisione: 'Data revisione', idFiliale: 'Filiale (id)', IdUtente: 'Assegnatario (id utente)',
  Telepass: 'Telepass', TesseraCarb: 'Tessera carburante', 'Proprietà': 'Proprietà (0 propria, 1 noleggio, 2 leasing)', ImportoRata: 'Importo rata', Noleggiatore: 'Noleggiatore',
  DataContrattoNoleggio: 'Data contratto noleggio', Contratto: 'Contratto', DataScadenzaNoleggio: 'Scadenza noleggio', ImportoRiscatto: 'Importo riscatto', Rottamato: 'Rottamato',
  Scorta: 'Scorta', DataBollo: 'Data bollo', IdAzienda: 'Azienda (id)', DataScadenzaZTL: 'Data scadenza ZTL', ComuneZTL: 'Comune ZTL', DataFermo: 'Data fermo',
  DKVIdVeicolo: 'DKV id veicolo', DKVTrasponder: 'DKV trasponder' }
const etichetta = c => ETICHETTE[c] ?? c
const righeModifiche = computed(() => modifiche.value.flatMap(m =>
  m.campi.length
    ? m.campi.map(c => ({ data: m.data, operatore: m.operatore, operazione: m.tipoOperazione, ...c, campo: etichetta(c.campo) }))
    : [{ data: m.data, operatore: m.operatore, operazione: m.tipoOperazione, campo: m.prima ? '(nessun campo cambiato)' : '(prima registrazione)', prima: '', dopo: '' }]))
const caricate = ref({})
watch(linguetta, l => caricaLinguetta(l))
async function caricaLinguetta(l, forza = false) {
  const id = scheda.value?.idMezzo
  if (!id) return
  if (forza) { caricate.value = {}; kmScelto.value = null; annoKm.value = null; annoCosti.value = null }
  if (caricate.value[l]) return
  try {
    if (l === 'km') {
      anniKm.value = (await api.get(`/mezzi/${id}/km/anni`)).data
      annoKm.value = anniKm.value[0]?.Anno ?? null
      await caricaKm()
    }
    else if (l === 'foto') foto.value = (await api.get(`/mezzi/${id}/foto`)).data
    else if (l === 'costi') { costi.value = (await api.get(`/mezzi/${id}/costi`, { params: { anno: annoCosti.value } })).data }
    else if (l === 'altri') altri.value = (await api.get(`/mezzi/${id}/altri-costi`)).data
    else if (l === 'sinistri') sinistri.value = (await api.get(`/mezzi/${id}/sinistri`)).data
    else if (l === 'note') note.value = (await api.get(`/mezzi/${id}/note`)).data
    else if (l === 'log') modifiche.value = (await api.get(`/mezzi/${id}/modifiche`)).data
    caricate.value[l] = true
  } catch (e) { errore(e) }
}
async function caricaKm() {
  const id = scheda.value?.idMezzo
  if (!id) return
  try {
    km.value = (await api.get(`/mezzi/${id}/km`, { params: { anno: annoKm.value } })).data
    kmScelto.value = km.value[0] ?? null
  } catch (e) { errore(e) }
}
async function caricaCosti() {
  const id = scheda.value?.idMezzo
  if (!id) return
  try { costi.value = (await api.get(`/mezzi/${id}/costi`, { params: { anno: annoCosti.value } })).data } catch (e) { errore(e) }
}
// il grafico dei km: la serie dell'anno scelto in ordine di data, con le rilevazioni sospette in arancione
const serieKm = computed(() => [...km.value].filter(r => r.Km != null).sort((a, b) => new Date(a.Data) - new Date(b.Data) || a.IdMezziKM - b.IdMezziKM))
const opzioniGrafico = computed(() => {
  const punti = serieKm.value.map(r => [r.Data, Number(r.Km)])
  const sospette = serieKm.value.filter(r => anomalie.value.get(r.IdMezziKM)).map(r => [r.Data, Number(r.Km)])
  return {
    tooltip: { trigger: 'axis', valueFormatter: v => num(v) + ' km' },
    grid: { left: 60, right: 16, top: 24, bottom: 36 },
    xAxis: { type: 'time' },
    yAxis: { type: 'value', name: 'km', scale: true, axisLabel: { formatter: v => num(v) } },
    series: [
      { name: 'km', type: 'line', data: punti, showSymbol: punti.length < 200, smooth: false, lineStyle: { width: 2 } },
      { name: 'sospette', type: 'scatter', data: sospette, symbolSize: 10, itemStyle: { color: '#f97316' }, z: 3 }
    ]
  }
})
// doppio clic sul grafico: la rilevazione piu' vicina nel tempo si seleziona nella griglia e si apre la correzione
const tabKm = ref(null)
function puntoGrafico({ x, dentro }) {
  if (!dentro || !serieKm.value.length || x == null) return
  let vicina = null, distanza = Infinity
  for (const r of serieKm.value) { const d = Math.abs(new Date(r.Data) - x); if (d < distanza) { distanza = d; vicina = r } }
  if (!vicina) return
  kmScelto.value = vicina
  const i = km.value.indexOf(vicina)
  tabKm.value?.$el?.querySelectorAll('tbody tr')[i]?.scrollIntoView({ block: 'center' })
  apriCorrezione(vicina)
}
// km giornalieri: differenza fra rilevazioni consecutive dell'anno
const kmPercorsi = computed(() => {
  const ord = [...km.value].filter(r => r.Km != null).sort((a, b) => new Date(a.Data) - new Date(b.Data))
  return ord.length > 1 ? Number(ord[ord.length - 1].Km) - Number(ord[0].Km) : null
})
// rilevazioni sospette: un picco (sale tanto e poi torna giu'), un buco (scende e poi
// risale), o comunque un valore sotto quello precedente o un salto troppo grande
const SALTO_KM = 1000
const anomalie = computed(() => {
  const ord = [...km.value].filter(r => r.Km != null).sort((a, b) => new Date(a.Data) - new Date(b.Data) || a.IdMezziKM - b.IdMezziKM)
  const m = new Map()
  let prima = null   // l'ultima rilevazione buona: dopo un picco o un buco resta quella
  for (let i = 0; i < ord.length; i++) {
    const v = Number(ord[i].Km), dopo = i < ord.length - 1 ? Number(ord[i + 1].Km) : null
    const su = prima == null ? 0 : v - prima, giu = dopo == null ? 0 : dopo - v
    let motivo = null, buona = true
    if (prima != null && dopo != null && su > SALTO_KM && giu < 0) { motivo = `picco: +${num(su)} km e poi torna a ${num(dopo)}`; buona = false }
    else if (prima != null && dopo != null && su < 0 && giu > SALTO_KM) { motivo = `buco: ${num(su)} km e poi risale a ${num(dopo)}`; buona = false }
    else if (prima != null && su < 0) motivo = `meno della rilevazione precedente (${num(prima)})`
    else if (prima != null && su > SALTO_KM) motivo = `salto di ${num(su)} km dalla rilevazione precedente`
    if (motivo) m.set(ord[i].IdMezziKM, motivo)
    if (buona) prima = v
  }
  return m
})
const classeRigaKm = r => anomalie.value.get(r.IdMezziKM) ? 'riga-anomala' : (r.KmOriginale != null ? 'riga-corretta' : '')

// --- correzione di una rilevazione: il valore di prima resta in traccia ---
const dialogKm = ref(false)
const correzione = ref({ IdMezziKM: null, Km: null, Note: '', riga: null })
const salvandoKm = ref(false)
function apriCorrezione(r) {
  if (!r) return
  correzione.value = { IdMezziKM: r.IdMezziKM, Km: r.Km == null ? null : Math.round(Number(r.Km)), Note: '', riga: r }
  dialogKm.value = true
}
async function salvaCorrezione() {
  const c = correzione.value
  if (c.Km == null || c.Km < 0) { toast.add({ severity: 'warn', summary: 'Scrivi i km giusti', life: 3000 }); return }
  salvandoKm.value = true
  try {
    await api.put(`/mezzi/km/${c.IdMezziKM}`, { km: c.Km, note: c.Note })
    toast.add({ severity: 'success', summary: 'Km corretti', life: 2500 })
    dialogKm.value = false
    const idScelto = c.IdMezziKM
    await caricaKm()
    kmScelto.value = km.value.find(r => r.IdMezziKM === idScelto) ?? kmScelto.value
    // la testata (ultimi km) si riallinea senza ricaricare tutta la scheda
    const { data } = await api.get(`/mezzi/${scheda.value.idMezzo}`)
    scheda.value = { ...scheda.value, UltimiKm: data.UltimiKm, DataUltimiKm: data.DataUltimiKm, DriverAttuale: data.DriverAttuale }
  } catch (e) { errore(e) } finally { salvandoKm.value = false }
}

// --- foto: si chiede con il token e si mostra come blob ---
const urlFoto = ref({})
const fotoMancanti = ref({})
async function caricaFoto(nome) {
  if (!nome || urlFoto.value[nome] || fotoMancanti.value[nome]) return
  try {
    const { data } = await api.get(`/mezzi/foto/${encodeURIComponent(nome)}`, { responseType: 'blob' })
    urlFoto.value = { ...urlFoto.value, [nome]: URL.createObjectURL(data) }
  } catch { fotoMancanti.value = { ...fotoMancanti.value, [nome]: true } }
}
watch(kmScelto, r => { if (r?.Foto) caricaFoto(r.Foto) })
watch(foto, lista => { for (const f of lista.slice(0, 12)) if (f.Foto) caricaFoto(f.Foto) })
const fotoGrande = ref(null)

// --- note e manutenzioni: una nota nuova o modificata con la stored esistente ---
const dialogNota = ref(false)
const nota = ref({})
function apriNota(n) {
  nota.value = n
    ? { IdMezzoNota: n.IdMezzoNota, data: n.data ? new Date(n.data) : new Date(), note: n.note ?? '', IdFornitore: n.IdFornitore, Fornitore: n.Fornitore ?? '',
        ImportoPreventivo: n.ImportoPreventivo, DataFattura: n.DataFattura ? new Date(n.DataFattura) : null, Seriale: n.Seriale,
        DataInizioFermo: n.DataInizioFermo ? new Date(n.DataInizioFermo) : null, DataFineFermo: n.DataFineFermo ? new Date(n.DataFineFermo) : null,
        DataFine: n.DataFine ? new Date(n.DataFine) : null, IdUtente: n.IdUtente, IdDipendenteSpeedy: n.IdDipendenteSpeedy }
    : { IdMezzoNota: null, data: new Date(), note: '', IdFornitore: null, Fornitore: '', ImportoPreventivo: null, DataFattura: null, Seriale: null, DataInizioFermo: null, DataFineFermo: null, DataFine: null }
  dialogNota.value = true
}
async function salvaNota() {
  if (!nota.value.note?.trim()) { toast.add({ severity: 'warn', summary: 'Scrivi la nota', life: 3000 }); return }
  try {
    const n = nota.value
    await api.post(`/mezzi/${scheda.value.idMezzo}/note`, { ...n, data: n.data ? n.data.toISOString() : null, DataFine: n.DataFine ? n.DataFine.toISOString() : null,
      DataFattura: iso(n.DataFattura), DataInizioFermo: iso(n.DataInizioFermo), DataFineFermo: iso(n.DataFineFermo) })
    dialogNota.value = false
    toast.add({ severity: 'success', summary: 'Nota salvata', life: 2500 })
    caricate.value.note = false; await caricaLinguetta('note')
  } catch (e) { errore(e) }
}

onMounted(async () => {
  try { lookup.value = (await api.get('/mezzi/lookup')).data } catch (e) { errore(e) }
  let id = props.idMezzo
  if (!id && props.targa) {
    try { id = (await api.get(`/mezzi/targa/${encodeURIComponent(props.targa)}`)).data.idMezzo }
    catch { toast.add({ severity: 'warn', summary: `Nessun mezzo con targa ${props.targa}`, life: 4000 }) }
  }
  if (props.nuovo) { await caricaElenco(null); nuovoMezzo(); pronto = true; return }
  if (id) filtri.value.stato = 'tutti'
  await caricaElenco(id)
  if (id) scelto.value = id
  if (scelto.value && scheda.value?.idMezzo !== scelto.value) await caricaScheda(scelto.value)
  pronto = true
})
</script>

<template>
  <div class="pagina">
    <!-- scelta del mezzo, come la barra "Riga n di N" del legacy -->
    <div class="barra-mezzo">
      <Button icon="pi pi-list" text :label="mezzi.length ? `${posizione + 1} di ${mezzi.length}` : 'elenco'" @click="elencoAperto = true" title="Apri l'elenco" />
      <Button icon="pi pi-angle-double-left" text :disabled="posizione <= 0" @click="scelto = mezzi[0]?.idMezzo" />
      <Button icon="pi pi-angle-left" text :disabled="posizione <= 0" @click="vai(-1)" />
      <Select v-model="scelto" :options="mezzi" optionLabel="targa" optionValue="idMezzo" filter placeholder="scegli un mezzo" class="tendina"
        :filterFields="['targa', 'modello', 'marca', 'Assegnatario', 'DriverAttuale']">
        <template #option="{ option }"><b>{{ option.targa }}</b> <small class="nota">{{ option.marca }} {{ option.modello }} · {{ option.Filiale }}<template v-if="option.dataDismissione"> · dismesso</template></small></template>
      </Select>
      <Button icon="pi pi-angle-right" text :disabled="posizione < 0 || posizione >= mezzi.length - 1" @click="vai(1)" />
      <Button icon="pi pi-angle-double-right" text :disabled="posizione < 0 || posizione >= mezzi.length - 1" @click="scelto = mezzi[mezzi.length - 1]?.idMezzo" />
      <span class="spazio"></span>
      <InputText v-model="filtri.testo" placeholder="targa, telaio, modello, assegnatario…" class="cerca" />
      <Select v-model="filtri.idFiliale" :options="lookup.filiali" optionLabel="Filiale" optionValue="IdFiliale" placeholder="tutte le filiali" showClear filter />
      <Select v-model="filtri.tipo" :options="lookup.tipi" optionLabel="Descrizione" optionValue="Codice" placeholder="tutti i tipi" showClear />
      <Select v-model="filtri.stato" :options="stati" optionLabel="label" optionValue="value" />
      <Button label="Nuovo" icon="pi pi-plus" outlined @click="nuovoMezzo" />
      <Button icon="pi pi-refresh" text :loading="caricamento" title="Aggiorna" @click="caricaElenco()" />
    </div>

    <div v-if="!scheda && !nuovoInCorso" class="centro"><ProgressSpinner v-if="caricamento" /><span v-else class="nota">Nessun mezzo con questi filtri.</span></div>

    <template v-else>
      <div class="testata">
        <h2 class="titolo">
          {{ titolo }}
          <Tag v-if="scheda?.dataDismissione" value="dismesso" severity="secondary" />
          <Tag v-if="scheda?.DataFermo" :value="'fermo dal ' + dataIt(scheda.DataFermo)" severity="warn" />
        </h2>
        <div class="meta" v-if="scheda">
          <span v-if="scheda.UltimiKm != null"><b>Ultimi km</b> {{ num(scheda.UltimiKm) }} il {{ dataOra(scheda.DataUltimiKm) }}<template v-if="scheda.DriverAttuale"> · {{ scheda.DriverAttuale }}</template></span>
          <span v-if="scheda.Assegnatario"><b>Assegnatario</b> {{ scheda.Assegnatario }}</span>
        </div>
        <Button :label="nuovoInCorso ? 'Crea' : 'Salva'" icon="pi pi-check" :loading="salvataggio" @click="salva" />
      </div>

      <!-- testata: le due colonne del legacy -->
      <div class="griglia">
        <label>Targa <InputText v-model="edit.targa" class="targa" /></label>
        <label>Data dismissione <DatePicker v-model="edit.dataDismissione" dateFormat="dd/mm/yy" showIcon /></label>
        <label>Tipo mezzo <Select v-model="edit.codTipoMezzo" :options="lookup.tipi" optionLabel="Descrizione" optionValue="Codice" showClear /></label>
        <label>Data bollo <DatePicker v-model="edit.DataBollo" dateFormat="dd/mm/yy" showIcon /></label>
        <label>Modello <InputText v-model="edit.modello" /></label>
        <label>Data revisione <DatePicker v-model="edit.DataRevisione" dateFormat="dd/mm/yy" showIcon /></label>
        <label>Marca <InputText v-model="edit.marca" /></label>
        <label>Scadenza noleggio <DatePicker v-model="edit.DataScadenzaNoleggio" dateFormat="dd/mm/yy" showIcon /></label>
        <label>Telaio <InputText v-model="edit.telaio" /></label>
        <label>Filiale <Select v-model="edit.idFiliale" :options="lookup.filiali" optionLabel="Filiale" optionValue="IdFiliale" showClear filter /></label>
        <label>Data acquisto <DatePicker v-model="edit.dataAcquisto" dateFormat="dd/mm/yy" showIcon /></label>
        <label>Proprietà <Select v-model="edit.Proprieta" :options="lookup.proprieta" optionLabel="testo" optionValue="valore" showClear placeholder="altro" /></label>
        <label>Data immatricolazione <DatePicker v-model="edit.dataImmatricolazione" dateFormat="dd/mm/yy" showIcon /></label>
        <label>Noleggiatore <Select v-model="edit.Noleggiatore" :options="lookup.noleggiatori" editable showClear /></label>
        <label>Assegnatario
          <AutoComplete v-model="assegnatario" :suggestions="suggerimenti" optionLabel="Nome" @complete="cercaDipendenti" dropdown forceSelection placeholder="cerca per nome o matricola">
            <template #option="{ option }">{{ option.Nome }} <small class="nota">{{ option.Matricola }}</small></template>
          </AutoComplete>
        </label>
        <label>Importo rata <InputNumber v-model="edit.ImportoRata" mode="currency" currency="EUR" locale="it-IT" /></label>
        <label>Azienda <Select v-model="edit.IdAzienda" :options="lookup.aziende" optionLabel="RagioneSociale" optionValue="IdAzienda" showClear /></label>
        <label>Contratto <InputText v-model="edit.Contratto" /></label>
        <label>Data contratto noleggio <DatePicker v-model="edit.DataContrattoNoleggio" dateFormat="dd/mm/yy" showIcon /></label>
        <label>Importo riscatto <InputNumber v-model="edit.ImportoRiscatto" mode="currency" currency="EUR" locale="it-IT" /></label>
      </div>

      <Tabs v-model:value="linguetta">
        <TabList>
          <Tab value="info">Info</Tab>
          <Tab value="km" :disabled="nuovoInCorso">KM<template v-if="scheda?.NumKm"> ({{ num(scheda.NumKm) }})</template></Tab>
          <Tab value="foto" :disabled="nuovoInCorso">Foto<template v-if="scheda?.NumFoto"> ({{ scheda.NumFoto }})</template></Tab>
          <Tab value="costi" :disabled="nuovoInCorso">Costi<template v-if="scheda?.NumCosti"> ({{ num(scheda.NumCosti) }})</template></Tab>
          <Tab value="altri" :disabled="nuovoInCorso">Altri costi</Tab>
          <Tab value="sinistri" :disabled="nuovoInCorso">Sinistri<template v-if="scheda?.NumSinistri"> ({{ scheda.NumSinistri }})</template></Tab>
          <Tab value="note" :disabled="nuovoInCorso">Manutenzioni e note<template v-if="scheda?.NumNote"> ({{ scheda.NumNote }})</template></Tab>
          <Tab value="log" :disabled="nuovoInCorso">Log</Tab>
        </TabList>
        <TabPanels>
          <TabPanel value="info">
            <div class="griglia">
              <label>Tessera carburante <InputText v-model="edit.TesseraCarb" /></label>
              <label>Telepass <InputText v-model="edit.Telepass" /></label>
              <label class="riga"><Checkbox v-model="edit.Scorta" binary /> Mezzo di scorta</label>
              <label class="riga"><Checkbox v-model="edit.Rottamato" binary /> Rottamato</label>
              <label>Data scadenza ZTL <DatePicker v-model="edit.DataScadenzaZTL" dateFormat="dd/mm/yy" showIcon /></label>
              <label>Comune ZTL <InputText v-model="edit.ComuneZTL" /></label>
              <label>Data fermo <DatePicker v-model="edit.DataFermo" dateFormat="dd/mm/yy" showIcon /></label>
              <label>DKV id veicolo <InputText v-model="edit.DKV_idveicolo" /></label>
              <label>DKV trasponder <InputText v-model="edit.DKV_trasponder" /></label>
            </div>
          </TabPanel>

          <!-- km: griglia a sinistra, a destra foto, posizione e grafico della riga scelta -->
          <TabPanel value="km">
            <div class="barra-km">
              <label>Anno <Select v-model="annoKm" :options="anniKm" optionLabel="Anno" optionValue="Anno" @change="caricaKm">
                <template #option="{ option }">{{ option.Anno }} <small class="nota">· {{ option.Righe }} rilevazioni · {{ num(option.KmMin) }}–{{ num(option.KmMax) }} km</small></template>
              </Select></label>
              <span v-if="kmPercorsi != null" class="nota">{{ num(kmPercorsi) }} km percorsi nel periodo, {{ km.length }} rilevazioni</span>
              <span v-if="anomalie.size" class="attenzione"><i class="pi pi-exclamation-triangle"></i> {{ anomalie.size }} rilevazioni sospette: scegline una e usa "Correggi km"</span>
            </div>
            <div class="split-km">
              <DataTable ref="tabKm" :value="km" v-model:selection="kmScelto" selectionMode="single" dataKey="IdMezziKM" size="small" stripedRows scrollable scrollHeight="30rem" class="tab-km" :rowClass="classeRigaKm">
                <Column header="Data" style="width: 8rem"><template #body="{ data }">{{ dataOra(data.Data) }}</template></Column>
                <Column header="Km" style="width: 7.5rem">
                  <template #body="{ data }">
                    <b>{{ num(data.Km) }}</b>
                    <i v-if="anomalie.get(data.IdMezziKM)" class="pi pi-exclamation-triangle attenzione icona" :title="anomalie.get(data.IdMezziKM)"></i>
                    <i v-else-if="data.KmOriginale != null" class="pi pi-pencil nota icona" :title="`corretto da ${num(data.KmOriginale)} il ${dataOra(data.DataCorrezione)} (${data.CorrettoDa})`"></i>
                  </template>
                </Column>
                <Column field="Driver" header="Driver" />
                <Column field="Filiale" header="Filiale" />
                <Column header="Foto" style="width: 3rem"><template #body="{ data }"><i v-if="data.Foto" class="pi pi-camera nota"></i></template></Column>
                <Column header="Posizione" style="width: 3rem"><template #body="{ data }"><i v-if="data.Latitude" class="pi pi-map-marker nota"></i></template></Column>
                <template #empty><span class="nota">Nessuna rilevazione km.</span></template>
              </DataTable>
              <div class="dettaglio-km">
                <template v-if="kmScelto">
                  <h4 class="titolo-km">
                    <span>{{ dataOra(kmScelto.Data) }} · {{ num(kmScelto.Km) }} km · {{ kmScelto.Driver }}</span>
                    <Button label="Correggi km" icon="pi pi-pencil" size="small" outlined @click="apriCorrezione(kmScelto)" />
                  </h4>
                  <p v-if="anomalie.get(kmScelto.IdMezziKM)" class="attenzione avviso-km"><i class="pi pi-exclamation-triangle"></i> Rilevazione sospetta: {{ anomalie.get(kmScelto.IdMezziKM) }}.</p>
                  <p v-if="kmScelto.KmOriginale != null" class="nota avviso-km">Corretto il {{ dataOra(kmScelto.DataCorrezione) }} da {{ kmScelto.CorrettoDa }}: prima {{ num(kmScelto.KmOriginale) }} km<template v-if="kmScelto.NotaCorrezione"> · {{ kmScelto.NotaCorrezione }}</template>.</p>
                  <div class="foto-posizione">
                    <div class="foto-box">
                      <img v-if="kmScelto.Foto && urlFoto[kmScelto.Foto]" :src="urlFoto[kmScelto.Foto]" class="foto" @click="fotoGrande = urlFoto[kmScelto.Foto]" title="Ingrandisci" />
                      <div v-else-if="kmScelto.Foto && fotoMancanti[kmScelto.Foto]" class="segnaposto">foto <code>{{ kmScelto.Foto }}</code> non trovata sul server</div>
                      <div v-else-if="kmScelto.Foto" class="segnaposto"><ProgressSpinner style="width: 2rem; height: 2rem" /></div>
                      <div v-else class="segnaposto">nessuna foto</div>
                    </div>
                    <div class="mappa-box">
                      <iframe v-if="kmScelto.Latitude" :src="mappaEmbed(kmScelto.Latitude, kmScelto.Longitude)" loading="lazy"></iframe>
                      <div v-else class="segnaposto">nessuna posizione</div>
                      <a v-if="kmScelto.Latitude" :href="mappa(kmScelto.Latitude, kmScelto.Longitude)" target="_blank" rel="noopener" class="link-mappa"><i class="pi pi-external-link"></i> apri in OpenStreetMap</a>
                    </div>
                  </div>
                </template>
                <span v-else class="nota">Scegli una rilevazione nella griglia.</span>
                <div v-if="km.length > 1" class="grafico"><EChart :option="opzioniGrafico" @dblclick="puntoGrafico" /></div>
                <small v-if="km.length > 1" class="nota">Doppio clic su un punto del grafico: si seleziona la rilevazione e si apre la correzione. I punti arancioni sono le rilevazioni sospette.</small>
              </div>
            </div>
          </TabPanel>

          <TabPanel value="foto">
            <div v-if="!foto.length" class="nota">Nessuna foto del mezzo.</div>
            <div class="galleria">
              <div v-for="f in foto" :key="f.IdMezziFOTO" class="scatto">
                <img v-if="urlFoto[f.Foto]" :src="urlFoto[f.Foto]" @click="fotoGrande = urlFoto[f.Foto]" title="Ingrandisci" />
                <div v-else-if="fotoMancanti[f.Foto]" class="segnaposto piccolo">non trovata</div>
                <div v-else class="segnaposto piccolo" @click="caricaFoto(f.Foto)">carica</div>
                <div class="didascalia"><b>{{ f.TipoFoto }}</b> · {{ dataOra(f.Data) }}<br><small class="nota">{{ f.Utente }} · {{ f.Filiale }}</small>
                  <a v-if="f.Latitude" :href="mappa(f.Latitude, f.Longitude)" target="_blank" rel="noopener" title="posizione"><i class="pi pi-map-marker"></i></a></div>
              </div>
            </div>
          </TabPanel>

          <TabPanel value="costi">
            <div class="barra-km" v-if="costi">
              <label>Anno <Select v-model="annoCosti" :options="costi.perAnno" optionLabel="Anno" optionValue="Anno" showClear placeholder="tutti" @change="caricaCosti">
                <template #option="{ option }">{{ option.Anno }} <small class="nota">· {{ option.Righe }} righe · {{ euro(option.Totale) }}</small></template>
              </Select></label>
              <span class="nota">{{ costi.righe.length }} righe · totale {{ euro(costi.righe.reduce((s, r) => s + Number(r.TotaleFinale ?? r.Totale ?? 0), 0)) }}</span>
            </div>
            <DataTable v-if="costi" :value="costi.righe" size="small" stripedRows paginator :rows="25">
              <Column header="Data" style="width: 6.5rem"><template #body="{ data }">{{ dataIt(data.DataDoc) }}</template></Column>
              <Column field="Tipo" header="Voce" />
              <Column header="Q.tà" style="width: 5rem"><template #body="{ data }">{{ num(data.Quantita, 2) }}</template></Column>
              <Column header="Prezzo" style="width: 6rem"><template #body="{ data }">{{ data.PrezzoUnitario == null ? '' : Number(data.PrezzoUnitario).toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 3 }) }}</template></Column>
              <Column header="Totale" style="width: 7rem"><template #body="{ data }"><b>{{ euro(data.TotaleFinale ?? data.Totale) }}</b></template></Column>
              <Column field="Fornitore" header="Fornitore" />
              <Column field="NDoc" header="Documento" style="width: 9rem" />
              <Column field="CDC" header="CDC" style="width: 6rem" />
              <template #empty><span class="nota">Nessun costo.</span></template>
            </DataTable>
          </TabPanel>

          <TabPanel value="altri">
            <template v-if="altri">
              <h4>Rifornimenti (carta carburante) <small class="nota">{{ altri.rifornimenti.length }}</small></h4>
              <DataTable :value="altri.rifornimenti" size="small" stripedRows paginator :rows="15">
                <Column header="Data" style="width: 7rem"><template #body="{ data }">{{ dataIt(data.Datatransazione) }} {{ data.Oratransazione }}</template></Column>
                <Column header="Km" style="width: 5rem"><template #body="{ data }">{{ num(data.Km) }}</template></Column>
                <Column field="Descrizioneprodotto" header="Prodotto" />
                <Column header="Q.tà" style="width: 5rem"><template #body="{ data }">{{ num(data.Quantita, 2) }}</template></Column>
                <Column header="Importo" style="width: 6rem"><template #body="{ data }">{{ euro(data.Importo) }}</template></Column>
                <Column field="Localita" header="Località" />
                <Column field="Matricolaautista" header="Autista" style="width: 6rem" />
                <template #empty><span class="nota">Nessun rifornimento.</span></template>
              </DataTable>
              <h4>Telepass <small class="nota">{{ altri.telepass.length }}</small></h4>
              <DataTable :value="altri.telepass" size="small" stripedRows paginator :rows="15">
                <Column header="Data" style="width: 8rem"><template #body="{ data }">{{ dataOra(data.Data) }}</template></Column>
                <Column field="TipoMov" header="Tipo" style="width: 6rem" />
                <Column field="Passaggio" header="Passaggio" />
                <Column field="Classe" header="Classe" style="width: 4rem" />
                <Column header="Importo" style="width: 6rem"><template #body="{ data }">{{ euro(data.Importo) }}</template></Column>
                <Column field="CDC" header="CDC" style="width: 6rem" />
                <template #empty><span class="nota">Nessun passaggio Telepass.</span></template>
              </DataTable>
            </template>
          </TabPanel>

          <TabPanel value="sinistri">
            <DataTable :value="sinistri" size="small" stripedRows>
              <Column header="Data" style="width: 6.5rem"><template #body="{ data }">{{ dataIt(data.data) }}</template></Column>
              <Column field="sanzione" header="Sanzione" style="width: 6rem" />
              <Column field="note" header="Note" />
              <Column field="Dipendente" header="Dipendente" />
              <Column field="NomeFornitore" header="Fornitore" />
              <Column header="Riparazione" style="width: 7rem"><template #body="{ data }">{{ euro(data.ValoreRiparazione) }}</template></Column>
              <Column header="Rimborso" style="width: 7rem"><template #body="{ data }">{{ euro(data.ValoreRimborso) }}</template></Column>
              <Column header="Franchigia" style="width: 7rem"><template #body="{ data }">{{ euro(data.ValoreFranchigia) }}</template></Column>
              <Column field="Riferimento" header="Riferimento" />
              <template #empty><span class="nota">Nessun sinistro.</span></template>
            </DataTable>
            <small class="nota">I sinistri si inseriscono e si modificano dalla pagina "Sinistri mezzi".</small>
          </TabPanel>

          <TabPanel value="note">
            <div class="barra-km"><Button label="Nuova nota" icon="pi pi-plus" size="small" @click="apriNota(null)" /></div>
            <DataTable :value="note" size="small" stripedRows selectionMode="single" @row-click="e => apriNota(e.data)" class="cliccabile">
              <Column header="Data" style="width: 8rem"><template #body="{ data }">{{ dataOra(data.data || data.datainserimento) }}</template></Column>
              <Column field="note" header="Nota" />
              <Column header="Fornitore"><template #body="{ data }">{{ data.NomeFornitore || data.Fornitore || '' }}</template></Column>
              <Column header="Preventivo" style="width: 7rem"><template #body="{ data }">{{ euro(data.ImportoPreventivo) }}</template></Column>
              <Column header="Fermo" style="width: 11rem"><template #body="{ data }"><template v-if="data.DataInizioFermo">{{ dataIt(data.DataInizioFermo) }} → {{ dataIt(data.DataFineFermo) || '…' }}</template></template></Column>
              <Column header="Fattura" style="width: 6.5rem"><template #body="{ data }">{{ dataIt(data.DataFattura) }}</template></Column>
              <Column header="Chi" style="width: 8rem"><template #body="{ data }">{{ data.NomeUtente || data.utente || '' }}</template></Column>
              <template #empty><span class="nota">Nessuna nota.</span></template>
            </DataTable>
          </TabPanel>
          <!-- log: ogni modifica alla riga di MEZZI, campo per campo -->
          <TabPanel value="log">
            <p class="nota piccola-nota">Ogni salvataggio della scheda (da qui o dal legacy) lascia una fotografia in LOGTabelle; qui il confronto fra una fotografia e la precedente. L'operatore è l'account con cui l'applicazione scrive sul database.</p>
            <DataTable :value="righeModifiche" size="small" stripedRows paginator :rows="20" class="log-modifiche">
              <Column header="Quando" style="width: 9.5rem"><template #body="{ data }">{{ dataOra(data.data) }}</template></Column>
              <Column field="operazione" header="Operazione" style="width: 6.5rem" />
              <Column field="operatore" header="Operatore" style="width: 9rem" />
              <Column field="campo" header="Campo" style="width: 16rem" />
              <Column field="prima" header="Prima" />
              <Column field="dopo" header="Dopo" />
              <template #empty><span class="nota">Nessuna modifica registrata per questo mezzo.</span></template>
            </DataTable>
          </TabPanel>
        </TabPanels>
      </Tabs>
    </template>

    <!-- elenco completo, per scegliere a colpo d'occhio -->
    <Dialog v-model:visible="elencoAperto" modal header="Mezzi" :style="{ width: '70rem' }">
      <DataTable :value="mezzi" size="small" stripedRows paginator :rows="15" selectionMode="single" @row-click="e => { scelto = e.data.idMezzo; elencoAperto = false }" class="cliccabile">
        <Column field="targa" header="Targa" sortable style="width: 6rem" />
        <Column field="Tipo" header="Tipo" sortable />
        <Column field="marca" header="Marca" sortable />
        <Column field="modello" header="Modello" sortable />
        <Column field="Filiale" header="Filiale" sortable />
        <Column field="Assegnatario" header="Assegnatario" sortable />
        <Column field="DriverAttuale" header="Driver attuale" sortable />
        <Column header="Ultimi km" sortable sortField="UltimiKm"><template #body="{ data }">{{ num(data.UltimiKm) }} <small class="nota">{{ dataIt(data.DataUltimiKm) }}</small></template></Column>
        <Column header="Revisione" sortable sortField="DataRevisione"><template #body="{ data }">{{ dataIt(data.DataRevisione) }}</template></Column>
      </DataTable>
    </Dialog>

    <Dialog :visible="fotoGrande !== null" modal :style="{ width: '90vw' }" @update:visible="v => { if (!v) fotoGrande = null }">
      <img v-if="fotoGrande" :src="fotoGrande" class="foto-intera" />
    </Dialog>

    <!-- correzione km -->
    <Dialog v-model:visible="dialogKm" modal header="Correggi i km della rilevazione" :style="{ width: '32rem' }">
      <p v-if="correzione.riga" class="nota">{{ dataOra(correzione.riga.Data) }} · {{ correzione.riga.Driver }} · adesso <b>{{ num(correzione.riga.Km) }}</b> km<template v-if="anomalie.get(correzione.IdMezziKM)"><br><span class="attenzione">{{ anomalie.get(correzione.IdMezziKM) }}</span></template></p>
      <div class="griglia-km">
        <label>Km giusti <InputNumber v-model="correzione.Km" :min="0" :maxFractionDigits="0" locale="it-IT" inputClass="km-input" autofocus /></label>
        <label>Nota <InputText v-model="correzione.Note" placeholder="perché si corregge (facoltativo)" /></label>
      </div>
      <small class="nota">Il valore di prima resta in traccia con chi e quando ha corretto.</small>
      <template #footer>
        <Button label="Annulla" text @click="dialogKm = false" />
        <Button label="Salva" icon="pi pi-check" :loading="salvandoKm" @click="salvaCorrezione" />
      </template>
    </Dialog>

    <Dialog v-model:visible="dialogNota" modal :header="nota.IdMezzoNota ? 'Nota / manutenzione' : 'Nuova nota / manutenzione'" :style="{ width: '40rem' }">
      <div class="griglia">
        <label>Data <DatePicker v-model="nota.data" dateFormat="dd/mm/yy" showTime hourFormat="24" showIcon /></label>
        <label>Fornitore <Select v-model="nota.IdFornitore" :options="lookup.fornitori" optionLabel="Fornitore" optionValue="IdFornitore" showClear filter placeholder="nessuno" /></label>
        <label class="larga">Nota <Textarea v-model="nota.note" rows="3" autoResize /></label>
        <label>Importo preventivo <InputNumber v-model="nota.ImportoPreventivo" mode="currency" currency="EUR" locale="it-IT" /></label>
        <label>Data fattura <DatePicker v-model="nota.DataFattura" dateFormat="dd/mm/yy" showIcon /></label>
        <label>Inizio fermo <DatePicker v-model="nota.DataInizioFermo" dateFormat="dd/mm/yy" showIcon /></label>
        <label>Fine fermo <DatePicker v-model="nota.DataFineFermo" dateFormat="dd/mm/yy" showIcon /></label>
        <label>Data fine <DatePicker v-model="nota.DataFine" dateFormat="dd/mm/yy" showTime hourFormat="24" showIcon /></label>
        <label>Seriale (costo collegato) <InputNumber v-model="nota.Seriale" :useGrouping="false" /></label>
      </div>
      <template #footer>
        <Button label="Annulla" text @click="dialogNota = false" />
        <Button label="Salva" icon="pi pi-check" @click="salvaNota" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: .75rem; }
.barra-mezzo { display: flex; align-items: center; gap: .3rem; flex-wrap: wrap; padding: .4rem .6rem; border: 1px solid var(--p-content-border-color); border-radius: 8px; background: var(--p-content-hover-background); }
.tendina { width: 20rem; }
.spazio { flex: 1; }
.cerca { width: 18rem; }
.testata { display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
.titolo { margin: 0; display: flex; align-items: center; gap: .5rem; flex: 1; }
.meta { display: flex; gap: 1.2rem; flex-wrap: wrap; color: var(--p-text-muted-color); font-size: .9rem; }
.griglia { display: grid; grid-template-columns: 1fr 1fr; gap: .45rem 1.5rem; }
.griglia label { display: grid; grid-template-columns: 11rem 1fr; align-items: center; gap: .5rem; font-size: .9rem; color: var(--p-text-muted-color); }
.griglia label.larga { grid-column: 1 / -1; }
.griglia label.riga { grid-template-columns: auto 1fr; }
.targa { font-weight: 700; letter-spacing: .05em; }
.centro { display: flex; justify-content: center; padding: 3rem; }
.barra-km { display: flex; align-items: center; gap: 1rem; margin-bottom: .5rem; flex-wrap: wrap; }
.barra-km label { display: flex; align-items: center; gap: .4rem; }
.split-km { display: grid; grid-template-columns: minmax(28rem, 1fr) minmax(24rem, 1fr); gap: 1rem; align-items: start; }
.tab-km :deep(tr) { cursor: pointer; }
.tab-km :deep(tr.riga-anomala) { background: color-mix(in srgb, var(--p-orange-500) 14%, transparent); }
.tab-km :deep(tr.riga-corretta) { background: color-mix(in srgb, var(--p-primary-color) 8%, transparent); }
.icona { margin-left: .35rem; font-size: .8rem; }
.attenzione { color: var(--p-orange-600); }
.titolo-km { display: flex; align-items: center; justify-content: space-between; gap: .5rem; }
.avviso-km { margin: 0 0 .5rem; font-size: .9rem; }
.griglia-km { display: grid; gap: .6rem; margin: .5rem 0; }
.griglia-km label { display: grid; grid-template-columns: 7rem 1fr; align-items: center; gap: .5rem; font-size: .9rem; color: var(--p-text-muted-color); }
.dettaglio-km h4 { margin: 0 0 .5rem; }
.foto-posizione { display: grid; grid-template-columns: 1fr 1fr; gap: .75rem; }
.foto-box, .mappa-box { min-height: 16rem; border: 1px solid var(--p-content-border-color); border-radius: 8px; overflow: hidden; display: flex; flex-direction: column; align-items: center; justify-content: center; background: var(--p-content-hover-background); }
.foto { max-width: 100%; max-height: 22rem; object-fit: contain; cursor: zoom-in; }
.mappa-box iframe { width: 100%; height: 16rem; border: 0; }
.link-mappa { font-size: .8rem; padding: .3rem; }
.segnaposto { color: var(--p-text-muted-color); padding: 1rem; text-align: center; font-size: .85rem; }
.segnaposto.piccolo { padding: .5rem; cursor: pointer; }
.grafico { height: 16rem; margin-top: .75rem; }
.galleria { display: grid; grid-template-columns: repeat(auto-fill, minmax(14rem, 1fr)); gap: .75rem; }
.scatto { border: 1px solid var(--p-content-border-color); border-radius: 8px; overflow: hidden; }
.scatto img { width: 100%; height: 11rem; object-fit: cover; cursor: zoom-in; display: block; }
.didascalia { padding: .4rem .6rem; font-size: .85rem; }
.foto-intera { width: 100%; max-height: 85vh; object-fit: contain; }
.cliccabile :deep(tr) { cursor: pointer; }
.log-modifiche :deep(td), .log-modifiche :deep(th) { font-size: .82rem; padding: .3rem .5rem; }
.piccola-nota { margin: 0 0 .5rem; font-size: .85rem; }
.nota { color: var(--p-text-muted-color); }
h4 { margin: .75rem 0 .4rem; }
@media (max-width: 1200px) { .split-km, .foto-posizione { grid-template-columns: 1fr; } }
</style>
