<script setup>
import { ref, reactive, computed, watch, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import Select from 'primevue/select'
import AutoComplete from 'primevue/autocomplete'
import DatePicker from 'primevue/datepicker'
import Checkbox from 'primevue/checkbox'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import Textarea from 'primevue/textarea'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Tag from 'primevue/tag'

// Nuova spedizione parcel Speedy: flusso a sezioni come i portali corriere
// (cliente/prodotto -> ritiro -> destinazione -> dettagli -> conferma).
// Salva con la stored SPED_INSERIMENTO (wrapper AI_SPED_NuovaParcel) e stampa
// la lettera di vettura DELIVERY_LDV.fr3 dal ReportServer.

const toast = useToast()
const errore = ref('')
const clienti = ref([])
const cliente = ref(null)
const prodotti = ref([])
const prodotto = ref(null)
const listini = ref([])
const listino = ref(null)
const mittenti = ref([])
const mittente = ref(null)
const caricamentoCliente = ref(false)

const ritiroRichiesto = ref(false)
const dataRitiro = ref(null)

// blocchi indirizzo gemelli (ritiro e destinazione); 'libero' e' il testo intero
// da scomporre con la verifica
const vuotoIndirizzo = () => ({
  ragioneSociale: '', libero: '', indirizzo: '', numeroCivico: '', localita: '', cap: '', provincia: '',
  lat: null, lng: null, verificato: false
})
const ritiro = reactive(vuotoIndirizzo())
const dest = reactive(vuotoIndirizzo())
const contatto = reactive({ nome: '', telefono: '', email: '' })

const importo = ref(null)
const contrassegno = ref(false)
const importoContrassegno = ref(null)
const pesoKg = ref(null)
const nota = ref('')
const barcode = ref('')

const salvataggio = ref(false)
const esito = ref(null)          // risposta del POST quando la spedizione e' salvata
const copertura = ref(null)      // esito GetCoperture sul CAP di destinazione

const sugRubrica = ref([])
const sugComuni = ref([])
const province = ref([])
let guardia = false              // evita che i prefill invalidino la verifica

// popup di scelta tra le alternative trovate dalla verifica geografica
const alternative = ref([])
const alternativeVisibili = ref(false)
let bloccoInVerifica = null

// visore PDF della lettera di vettura (il report server parla solo col backend)
const pdfUrl = ref(null)
const pdfVisibile = ref(false)
const stampando = ref(false)

onMounted(async () => {
  try {
    const [{ data }, { data: prov }] = await Promise.all([
      api.get('/sped/init'), api.get('/sped/province')
    ])
    clienti.value = data
    province.value = prov
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei clienti'
  }
})

watch(cliente, async c => {
  prodotto.value = null; listino.value = null; mittente.value = null
  prodotti.value = []; listini.value = []; mittenti.value = []
  if (!c) return
  caricamentoCliente.value = true
  try {
    const { data } = await api.get(`/sped/cliente/${c.idCliente}`)
    prodotti.value = data.prodotti
    listini.value = data.listini
    mittenti.value = data.mittenti
    if (data.prodotti.length === 1) prodotto.value = data.prodotti[0]
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Cliente', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  } finally {
    caricamentoCliente.value = false
  }
})

// listini validi per il prodotto scelto (se il cliente ne ha di specifici)
const listiniProdotto = computed(() =>
  prodotto.value ? listini.value.filter(l => l.idProdotto === prodotto.value.idProdotto) : [])
watch(listiniProdotto, ls => {
  listino.value = ls.length === 1 ? ls[0] : null
})

// mittente scelto -> precompila il blocco ritiro (resta modificabile)
watch([mittente, ritiroRichiesto], () => {
  if (!ritiroRichiesto.value || !mittente.value) return
  guardia = true
  ritiro.ragioneSociale = mittente.value.ragioneSociale ?? ''
  ritiro.indirizzo = mittente.value.indirizzo ?? ''
  ritiro.numeroCivico = ''
  ritiro.localita = mittente.value.localita ?? ''
  ritiro.cap = mittente.value.cap ?? ''
  ritiro.provincia = mittente.value.provincia ?? ''
  ritiro.lat = null; ritiro.lng = null; ritiro.verificato = false
  nextTick(() => { guardia = false })
})

// ogni modifica manuale dell'indirizzo invalida la verifica geografica
for (const blocco of [ritiro, dest]) {
  watch(() => [blocco.indirizzo, blocco.numeroCivico, blocco.localita, blocco.cap, blocco.provincia], () => {
    if (guardia) return
    blocco.verificato = false
    blocco.lat = null
    blocco.lng = null
  })
}

// --- rubrica: nominativi gia' usati dal cliente ---
async function cercaRubrica(tipo, ev) {
  if (!cliente.value) { sugRubrica.value = []; return }
  try {
    const { data } = await api.get('/sped/rubrica', {
      params: { idCliente: cliente.value.idCliente, tipo, q: ev.query || undefined }
    })
    sugRubrica.value = data
  } catch { sugRubrica.value = [] }
}
function applicaRubrica(blocco, v) {
  guardia = true
  blocco.ragioneSociale = v.ragioneSociale ?? ''
  blocco.libero = ''
  blocco.indirizzo = v.indirizzo ?? ''
  blocco.numeroCivico = v.numeroCivico ?? ''
  blocco.localita = v.localita ?? ''
  blocco.cap = v.cap ?? ''
  blocco.provincia = v.provincia ?? ''
  blocco.lat = v.lat ?? null
  blocco.lng = v.lng ?? null
  blocco.verificato = v.lat != null && v.lng != null
  nextTick(() => { guardia = false; if (blocco === dest) aggiornaMappa() })
}

// --- comuni esistenti (GEO_COMUNE), filtrati per la provincia del blocco ---
let bloccoComuni = null
async function cercaComuni(blocco, ev) {
  bloccoComuni = blocco
  try {
    const { data } = await api.get('/sped/comuni', {
      params: { q: ev.query, prov: blocco.provincia || undefined }
    })
    sugComuni.value = data
  } catch { sugComuni.value = [] }
}
function applicaComune(blocco, v) {
  guardia = true
  blocco.localita = v.comune
  blocco.cap = v.cap
  blocco.provincia = v.provincia
  blocco.verificato = false; blocco.lat = null; blocco.lng = null
  nextTick(() => { guardia = false })
}

// --- verifica geografica (Nominatim): dal testo libero (che viene scomposto)
// o dai campi strutturati; con piu' alternative si sceglie da un popup ---
const verificando = ref(false)
async function verifica(blocco, daLibero) {
  if (daLibero && !blocco.libero.trim()) {
    toast.add({ severity: 'warn', summary: 'Verifica', detail: 'Scrivi l\'indirizzo completo nel campo libero', life: 3000 })
    return
  }
  if (!daLibero && (!blocco.indirizzo || !blocco.localita)) {
    toast.add({ severity: 'warn', summary: 'Verifica', detail: 'Compila almeno comune e indirizzo', life: 3000 })
    return
  }
  verificando.value = true
  try {
    const params = daLibero
      ? { libero: blocco.libero }
      : {
          indirizzo: blocco.indirizzo, civico: blocco.numeroCivico || undefined,
          cap: blocco.cap || undefined, localita: blocco.localita, provincia: blocco.provincia || undefined
        }
    const { data } = await api.get('/sped/geocode', { params })
    if (!data.length) {
      toast.add({ severity: 'warn', summary: 'Verifica indirizzo', detail: 'Nessun risultato: controlla i dati', life: 4000 })
    } else if (data.length === 1) {
      applicaCandidato(blocco, data[0])
    } else {
      bloccoInVerifica = blocco
      alternative.value = data
      alternativeVisibili.value = true
    }
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Verifica indirizzo', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    verificando.value = false
  }
}

// applica l'alternativa scelta CORREGGENDO i campi con quanto trovato
function applicaCandidato(blocco, c) {
  guardia = true
  if (c.indirizzo) blocco.indirizzo = c.indirizzo
  if (c.civico) blocco.numeroCivico = c.civico
  if (c.cap) blocco.cap = c.cap
  if (c.localita) blocco.localita = c.localita
  if (c.provincia) blocco.provincia = c.provincia
  blocco.lat = c.lat
  blocco.lng = c.lng
  blocco.verificato = true
  alternativeVisibili.value = false
  nextTick(() => { guardia = false; if (blocco === dest) aggiornaMappa() })
}
function scegliAlternativa(c) {
  if (bloccoInVerifica) applicaCandidato(bloccoInVerifica, c)
}

// --- mappina della destinazione (marker trascinabile per rifinire il punto) ---
let mappa = null, marker = null
const mapEl = ref(null)
function aggiornaMappa() {
  if (dest.lat == null) return
  nextTick(() => {
    if (!mapEl.value) return
    if (!mappa) {
      mappa = L.map(mapEl.value, { center: [dest.lat, dest.lng], zoom: 16 })
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(mappa)
      marker = L.marker([dest.lat, dest.lng], { draggable: true }).addTo(mappa)
      marker.on('dragend', () => {
        const ll = marker.getLatLng()
        dest.lat = Math.round(ll.lat * 1e6) / 1e6
        dest.lng = Math.round(ll.lng * 1e6) / 1e6
      })
    } else {
      mappa.setView([dest.lat, dest.lng], 16)
      marker.setLatLng([dest.lat, dest.lng])
    }
    setTimeout(() => mappa && mappa.invalidateSize(), 150)
  })
}
onBeforeUnmount(() => { if (mappa) { mappa.remove(); mappa = null } })

// --- copertura del CAP destinazione per il prodotto ---
watch([() => dest.cap, prodotto], async ([cap, p]) => {
  copertura.value = null
  if (!p || !cap || cap.length !== 5) return
  try {
    const { data } = await api.get('/sped/copertura', { params: { idProdotto: p.idProdotto, cap } })
    copertura.value = data
  } catch { /* solo informativa */ }
})

const oraMinimaRitiro = computed(() => new Date())

const puoSalvare = computed(() =>
  cliente.value && prodotto.value
  && dest.ragioneSociale && dest.indirizzo && dest.localita && dest.cap && dest.provincia
  && dest.verificato && pesoKg.value > 0
  && (!contrassegno.value || importoContrassegno.value > 0)
  && (!ritiroRichiesto.value || (dataRitiro.value && dataRitiro.value > new Date()
      && ritiro.ragioneSociale && ritiro.indirizzo && ritiro.localita && ritiro.cap)))

async function salva() {
  salvataggio.value = true
  try {
    const { data } = await api.post('/sped/nuova', {
      idCliente: cliente.value.idCliente,
      idProdotto: prodotto.value.idProdotto,
      idMittente: mittente.value?.idMittente ?? null,
      tariffarioCodice: listino.value ? (listino.value.codiceListino || String(listino.value.idListino)) : null,
      barcode: barcode.value || null,
      ritiroRichiesto: ritiroRichiesto.value,
      dataRitiro: ritiroRichiesto.value && dataRitiro.value ? fmtDataOra(dataRitiro.value) : null,
      ritiroRagioneSociale: ritiro.ragioneSociale || null,
      ritiroIndirizzo: ritiro.indirizzo || null,
      ritiroNumeroCivico: ritiro.numeroCivico || null,
      ritiroLocalita: ritiro.localita || null,
      ritiroCap: ritiro.cap || null,
      ritiroProvincia: ritiro.provincia || null,
      ritiroLat: ritiro.lat, ritiroLng: ritiro.lng,
      mittenteRagioneSociale: mittente.value?.ragioneSociale ?? null,
      mittenteIndirizzo: mittente.value?.indirizzo ?? null,
      mittenteLocalita: mittente.value?.localita ?? null,
      mittenteCap: mittente.value?.cap ?? null,
      mittenteProvincia: mittente.value?.provincia ?? null,
      mittenteEmail: mittente.value?.email ?? null,
      destinazioneRagioneSociale: dest.ragioneSociale,
      destinazioneIndirizzo: dest.indirizzo,
      destinazioneNumeroCivico: dest.numeroCivico || null,
      destinazioneLocalita: dest.localita,
      destinazioneCap: dest.cap,
      destinazioneProvincia: dest.provincia,
      destinazioneLat: dest.lat, destinazioneLng: dest.lng,
      contattoNome: contatto.nome || null,
      contattoTelefono: contatto.telefono || null,
      contattoEmail: contatto.email || null,
      importo: importo.value,
      contrassegno: contrassegno.value,
      importoContrassegno: contrassegno.value ? importoContrassegno.value : null,
      pesoKg: pesoKg.value,
      nota: nota.value || null
    })
    esito.value = data
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Salvataggio', detail: e.response?.data?.errore ?? 'Errore imprevisto', life: 6000 })
  } finally {
    salvataggio.value = false
  }
}

// data locale senza sorprese di fuso (il backend la legge come DateTime)
const fmtDataOra = d =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` +
  `T${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:00`

// il PDF arriva dal backend (proxy del report server) e si mostra in un iframe:
// l'URL della pagina non cambia e il report server resta invisibile
async function stampaLdv() {
  stampando.value = true
  try {
    const { data } = await api.get(`/sped/ldv/${esito.value.idSpedizione}`, { responseType: 'blob' })
    if (pdfUrl.value) URL.revokeObjectURL(pdfUrl.value)
    pdfUrl.value = URL.createObjectURL(data)
    pdfVisibile.value = true
  } catch (e) {
    let msg = 'Errore nella stampa'
    try { msg = JSON.parse(await e.response.data.text()).errore ?? msg } catch { /* risposta non JSON */ }
    toast.add({ severity: 'error', summary: 'Stampa LDV', detail: msg, life: 6000 })
  } finally {
    stampando.value = false
  }
}
function chiudiPdf() {
  if (pdfUrl.value) URL.revokeObjectURL(pdfUrl.value)
  pdfUrl.value = null
}

function nuova() {
  esito.value = null
  Object.assign(ritiro, vuotoIndirizzo())
  Object.assign(dest, vuotoIndirizzo())
  Object.assign(contatto, { nome: '', telefono: '', email: '' })
  ritiroRichiesto.value = false; dataRitiro.value = null
  importo.value = null; contrassegno.value = false; importoContrassegno.value = null
  pesoKg.value = null; nota.value = ''; barcode.value = ''
  copertura.value = null
  if (mappa) { mappa.remove(); mappa = null; marker = null }
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Nuova spedizione parcel Speedy</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <!-- esito: riepilogo e stampa -->
    <div v-if="esito" class="cardone ok">
      <i class="pi pi-check-circle" style="font-size: 2rem; color: var(--p-green-600)"></i>
      <div class="ok-testo">
        <div class="ok-barcode">{{ esito.barcode }}</div>
        <div>Spedizione <b>{{ esito.idSpedizione }}</b> creata — attività palmare {{ esito.idAttivita }}</div>
        <Message v-if="esito.copertura && esito.copertura !== 'OK'" severity="warn" :closable="false">
          Copertura: {{ esito.copertura }}
        </Message>
      </div>
      <div class="ok-azioni">
        <Button label="Stampa lettera di vettura" icon="pi pi-print" :loading="stampando" @click="stampaLdv" />
        <Button label="Nuova spedizione" icon="pi pi-plus" outlined @click="nuova" />
      </div>
    </div>

    <template v-else>
      <!-- 1: cliente, prodotto, listino, mittente -->
      <section class="card">
        <div class="card-titolo"><span class="passo">1</span> Cliente e prodotto</div>
        <div class="griglia4">
          <label>Cliente *
            <Select v-model="cliente" :options="clienti" optionLabel="ragioneSociale" filter
              placeholder="— scegli il cliente —" fluid :loading="!clienti.length && !errore" />
          </label>
          <label>Prodotto *
            <Select v-model="prodotto" :options="prodotti" optionLabel="prodotto" fluid
              :disabled="!cliente" :loading="caricamentoCliente"
              :placeholder="cliente ? (prodotti.length ? '— scegli —' : 'nessun prodotto abilitato') : 'prima il cliente'" />
          </label>
          <label v-if="listiniProdotto.length">Listino
            <Select v-model="listino" :options="listiniProdotto" optionLabel="descrizione" fluid showClear
              placeholder="— nessuno —" />
          </label>
          <label v-if="mittenti.length">Mittente
            <Select v-model="mittente" :options="mittenti" optionLabel="ragioneSociale" fluid showClear
              placeholder="— nessuno —" />
          </label>
        </div>
      </section>

      <!-- 2: ritiro -->
      <section class="card">
        <div class="card-titolo"><span class="passo">2</span> Ritiro
          <label class="chk"><Checkbox v-model="ritiroRichiesto" binary /> richiedi il ritiro</label>
          <DatePicker v-if="ritiroRichiesto" v-model="dataRitiro" showTime hourFormat="24"
            dateFormat="dd/mm/yy" showIcon :minDate="oraMinimaRitiro" placeholder="data e ora ritiro *" />
          <Tag v-if="ritiroRichiesto && dataRitiro && dataRitiro <= new Date()" severity="danger" value="deve essere futura" />
        </div>
        <div v-if="ritiroRichiesto" class="corpo-card">
          <div class="griglia4">
            <label class="span2">Nome / ragione sociale *
              <AutoComplete :modelValue="ritiro.ragioneSociale"
                @update:modelValue="v => ritiro.ragioneSociale = typeof v === 'string' ? v : v?.ragioneSociale ?? ''"
                :suggestions="sugRubrica" optionLabel="ragioneSociale" fluid
                placeholder="digita o scegli tra i ritiri precedenti"
                @complete="ev => cercaRubrica('ritiro', ev)"
                @option-select="ev => applicaRubrica(ritiro, ev.value)">
                <template #option="{ option }">
                  <div class="opt-rubrica"><b>{{ option.ragioneSociale }}</b>
                    <small>{{ option.indirizzo }} {{ option.numeroCivico }}, {{ option.cap }} {{ option.localita }} {{ option.provincia }}</small>
                  </div>
                </template>
              </AutoComplete>
            </label>
            <label class="span2">Indirizzo completo (testo libero)
              <span class="doppio-lib">
                <InputText v-model="ritiro.libero" fluid placeholder="es. via dei cerretani 5, 50123 firenze"
                  @keyup.enter="verifica(ritiro, true)" />
                <Button icon="pi pi-search" label="Verifica" outlined :loading="verificando"
                  @click="verifica(ritiro, true)" />
              </span>
            </label>
          </div>
          <div class="oppure">oppure compila i campi, dalla provincia al civico:</div>
          <div class="griglia6">
            <label>Provincia
              <Select v-model="ritiro.provincia" :options="province" filter showClear editable fluid placeholder="—" />
            </label>
            <label class="g2">Comune *
              <AutoComplete :modelValue="ritiro.localita"
                @update:modelValue="v => ritiro.localita = typeof v === 'string' ? v : v?.comune ?? ''"
                :suggestions="sugComuni" optionLabel="comune" fluid
                @complete="ev => cercaComuni(ritiro, ev)" @option-select="ev => applicaComune(ritiro, ev.value)">
                <template #option="{ option }">{{ option.comune }} — {{ option.cap }} ({{ option.provincia }})</template>
              </AutoComplete>
            </label>
            <label>CAP * <InputText v-model="ritiro.cap" maxlength="5" fluid /></label>
            <label class="g2">Indirizzo *
              <InputText v-model="ritiro.indirizzo" fluid />
            </label>
            <label>Civico <InputText v-model="ritiro.numeroCivico" fluid /></label>
            <div class="verifica g5">
              <Button label="Verifica indirizzo" icon="pi pi-map-marker" size="small" outlined
                :loading="verificando" @click="verifica(ritiro, false)" />
              <Tag v-if="ritiro.verificato" severity="success" icon="pi pi-check"
                :value="`verificato · ${ritiro.lat?.toFixed(5)}, ${ritiro.lng?.toFixed(5)}`" />
            </div>
          </div>
        </div>
      </section>

      <!-- 3: destinazione -->
      <section class="card">
        <div class="card-titolo"><span class="passo">3</span> Destinazione
          <Tag v-if="copertura?.esito" :severity="copertura.esito === 'OK' ? 'success' : 'warn'"
            :value="copertura.esito === 'OK' ? `copertura OK — ${copertura.filiale ?? ''}` : copertura.esito" />
        </div>
        <div class="corpo-card">
          <div class="griglia4">
            <label class="span2">Nome / ragione sociale *
              <AutoComplete :modelValue="dest.ragioneSociale"
                @update:modelValue="v => dest.ragioneSociale = typeof v === 'string' ? v : v?.ragioneSociale ?? ''"
                :suggestions="sugRubrica" optionLabel="ragioneSociale" fluid
                placeholder="digita o scegli tra i destinatari precedenti"
                @complete="ev => cercaRubrica('destinazione', ev)"
                @option-select="ev => applicaRubrica(dest, ev.value)">
                <template #option="{ option }">
                  <div class="opt-rubrica"><b>{{ option.ragioneSociale }}</b>
                    <small>{{ option.indirizzo }} {{ option.numeroCivico }}, {{ option.cap }} {{ option.localita }} {{ option.provincia }}</small>
                  </div>
                </template>
              </AutoComplete>
            </label>
            <label class="span2">Indirizzo completo (testo libero)
              <span class="doppio-lib">
                <InputText v-model="dest.libero" fluid placeholder="es. via dei cerretani 5, 50123 firenze"
                  @keyup.enter="verifica(dest, true)" />
                <Button icon="pi pi-search" label="Verifica" outlined :loading="verificando"
                  @click="verifica(dest, true)" />
              </span>
            </label>
          </div>
          <div class="oppure">oppure compila i campi, dalla provincia al civico:</div>
          <div class="griglia6">
            <label>Provincia *
              <Select v-model="dest.provincia" :options="province" filter showClear editable fluid placeholder="—" />
            </label>
            <label class="g2">Comune *
              <AutoComplete :modelValue="dest.localita"
                @update:modelValue="v => dest.localita = typeof v === 'string' ? v : v?.comune ?? ''"
                :suggestions="sugComuni" optionLabel="comune" fluid
                @complete="ev => cercaComuni(dest, ev)" @option-select="ev => applicaComune(dest, ev.value)">
                <template #option="{ option }">{{ option.comune }} — {{ option.cap }} ({{ option.provincia }})</template>
              </AutoComplete>
            </label>
            <label>CAP * <InputText v-model="dest.cap" maxlength="5" fluid /></label>
            <label class="g2">Indirizzo *
              <InputText v-model="dest.indirizzo" fluid />
            </label>
            <label>Civico <InputText v-model="dest.numeroCivico" fluid /></label>
            <div class="verifica g5">
              <Button label="Verifica indirizzo" icon="pi pi-map-marker" size="small" outlined
                :loading="verificando" @click="verifica(dest, false)" />
              <Tag v-if="dest.verificato" severity="success" icon="pi pi-check"
                :value="`verificato · ${dest.lat?.toFixed(5)}, ${dest.lng?.toFixed(5)}`" />
              <Tag v-else severity="secondary" value="obbligatoria per salvare" />
            </div>
          </div>
          <div v-show="dest.lat != null" class="mappa-wrap">
            <div ref="mapEl" class="mappina"></div>
            <small>trascina il segnaposto per rifinire il punto di consegna</small>
          </div>
          <div class="griglia4">
            <label class="span2">Contatto per la consegna <InputText v-model="contatto.nome" maxlength="40" fluid /></label>
            <label>Telefono <InputText v-model="contatto.telefono" maxlength="15" fluid /></label>
            <label>Email <InputText v-model="contatto.email" maxlength="100" fluid /></label>
          </div>
        </div>
      </section>

      <!-- 4: dettagli -->
      <section class="card">
        <div class="card-titolo"><span class="passo">4</span> Dettagli spedizione</div>
        <div class="corpo-card griglia4">
          <label>Peso (kg) *
            <InputNumber v-model="pesoKg" :minFractionDigits="0" :maxFractionDigits="3" :min="0" fluid />
          </label>
          <label>Importo (€)
            <InputNumber v-model="importo" mode="currency" currency="EUR" locale="it-IT" fluid />
          </label>
          <label class="chk-col">Contrassegno
            <span class="chk"><Checkbox v-model="contrassegno" binary />
              <InputNumber v-if="contrassegno" v-model="importoContrassegno" mode="currency" currency="EUR" locale="it-IT"
                placeholder="importo *" fluid />
            </span>
          </label>
          <label>Barcode (facoltativo)
            <InputText v-model="barcode" maxlength="50" fluid placeholder="vuoto = assegnato automaticamente" />
          </label>
          <label class="span4">Nota ({{ nota.length }}/200)
            <Textarea v-model="nota" maxlength="200" rows="2" fluid />
          </label>
        </div>
      </section>

      <div class="barra-salva">
        <Button label="Crea la spedizione" icon="pi pi-send" size="large"
          :disabled="!puoSalvare" :loading="salvataggio" @click="salva" />
        <small v-if="!puoSalvare" class="hint">
          servono cliente, prodotto, destinazione completa e verificata, peso{{ ritiroRichiesto ? ', dati e data/ora di ritiro futura' : '' }}
        </small>
      </div>
    </template>

    <!-- alternative trovate dalla verifica geografica: si sceglie quella giusta
         e i campi vengono corretti con quanto trovato -->
    <Dialog v-model:visible="alternativeVisibili" modal header="Scegli l'indirizzo corretto" :style="{ width: '44rem' }">
      <div class="alternative">
        <div v-for="(c, i) in alternative" :key="i" class="candidato" @click="scegliAlternativa(c)">
          <div><b>{{ [c.indirizzo, c.civico].filter(Boolean).join(' ') || '(via non riconosciuta)' }}</b>
            — {{ c.cap ?? '' }} {{ c.localita ?? '' }} {{ c.provincia ? `(${c.provincia})` : '' }}</div>
          <small>{{ c.descrizione }}</small>
        </div>
      </div>
      <template #footer>
        <Button label="Nessuno di questi" text @click="alternativeVisibili = false" />
      </template>
    </Dialog>

    <!-- lettera di vettura: PDF servito dal backend, mostrato in un frame interno -->
    <Dialog v-model:visible="pdfVisibile" modal maximizable header="Lettera di vettura"
      :style="{ width: '62rem' }" @hide="chiudiPdf">
      <iframe v-if="pdfUrl" :src="pdfUrl" class="pdf-frame" title="Lettera di vettura"></iframe>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1100px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; overflow: visible; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; align-items: center; gap: 1rem; flex-wrap: wrap;
}
.passo {
  display: inline-flex; align-items: center; justify-content: center;
  width: 1.5rem; height: 1.5rem; border-radius: 50%; background: #fff; color: #00a5cf; font-size: .85rem;
}
.card-titolo .chk { display: inline-flex; align-items: center; gap: .4rem; font-weight: 400; cursor: pointer; }
.corpo-card { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.griglia4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: .6rem .8rem; padding: .8rem; }
.corpo-card .griglia4 { padding: 0; }
.griglia4 label { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.span2 { grid-column: span 2; }
.span4 { grid-column: span 4; }
.chk-col .chk { display: flex; align-items: center; gap: .6rem; min-height: 2.4rem; }
.verifica { display: flex; align-items: center; gap: .75rem; flex-wrap: wrap; }
.doppio-lib { display: flex; gap: .5rem; }
.doppio-lib > :first-child { flex: 1; }
.oppure { font-size: .8rem; color: var(--p-text-muted-color); font-style: italic; }
.griglia6 { display: grid; grid-template-columns: repeat(6, 1fr); gap: .6rem .8rem; }
.griglia6 label { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.g2 { grid-column: span 2; }
.g5 { grid-column: span 5; }
.alternative { display: flex; flex-direction: column; gap: .4rem; }
.candidato {
  padding: .45rem .6rem; border: 1px solid var(--p-surface-300); border-radius: 6px;
  cursor: pointer; font-size: .88rem; display: flex; flex-direction: column; gap: .15rem;
}
.candidato:hover { background: var(--p-highlight-background); border-color: var(--p-primary-color); }
.candidato small { color: var(--p-text-muted-color); }
.pdf-frame { width: 100%; height: 72vh; border: none; }
.mappa-wrap { display: flex; flex-direction: column; gap: .25rem; }
.mappina { height: 260px; border: 1px solid var(--p-surface-300); border-radius: 6px; z-index: 0; }
.mappa-wrap small { color: var(--p-text-muted-color); }
.opt-rubrica { display: flex; flex-direction: column; }
.opt-rubrica small { color: var(--p-text-muted-color); }
.barra-salva { display: flex; align-items: center; gap: 1rem; padding-bottom: 1.5rem; }
.hint { color: var(--p-text-muted-color); }
.cardone.ok {
  border: 1px solid var(--p-green-200); background: var(--p-green-50); border-radius: 8px;
  padding: 1.25rem; display: flex; align-items: center; gap: 1.25rem; flex-wrap: wrap;
}
.ok-testo { flex: 1; display: flex; flex-direction: column; gap: .3rem; }
.ok-barcode { font-family: monospace; font-size: 1.6rem; font-weight: 700; letter-spacing: .1em; }
.ok-azioni { display: flex; flex-direction: column; gap: .5rem; }
</style>
