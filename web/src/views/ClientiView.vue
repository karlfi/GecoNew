<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import Textarea from 'primevue/textarea'
import Checkbox from 'primevue/checkbox'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
import Dialog from 'primevue/dialog'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Tabs from 'primevue/tabs'
import TabList from 'primevue/tablist'
import Tab from 'primevue/tab'
import TabPanels from 'primevue/tabpanels'
import TabPanel from 'primevue/tabpanel'

// Gestione clienti dell'azienda collegata: anagrafica con cancellazione logica
// (DataFine) e tabelle collegate CLIENTI_CONDIZIONI e FATT_LISTINI del cliente.
// Scritture via SP AI_CLIENTI_Save / AI_CLIENTI_CONDIZIONI_* / AI_FATT_LISTINI_*.

const toast = useToast()
const errore = ref('')
const clienti = ref([])
const lookup = ref({ famiglie: [], prodotti: [], tracciati: [], filiali: [], tipiVendita: [] })
const filtro = ref('')
const mostraCessati = ref(false)
const caricamento = ref(false)

const dettaglioVisibile = ref(false)
const scheda = ref(null)          // { anagrafica, condizioni, listini }
const form = ref({})              // copia editabile dell'anagrafica
const salvando = ref(false)
const tab = ref('anagrafica')
const inConferma = ref(null)      // chiave dell'elemento in attesa di conferma cancellazione

const condVisibile = ref(false)
const cond = ref({})
const listinoVisibile = ref(false)
const listino = ref({})

onMounted(async () => {
  try {
    const [{ data: lk }] = await Promise.all([api.get('/clienti/lookup'), carica()])
    lookup.value = lk
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento'
  }
})

async function carica() {
  caricamento.value = true
  try {
    const { data } = await api.get('/clienti', { params: { anchecessati: mostraCessati.value } })
    clienti.value = data
  } finally {
    caricamento.value = false
  }
}

const clientiFiltrati = computed(() => {
  const q = filtro.value.trim().toLowerCase()
  if (!q) return clienti.value
  return clienti.value.filter(c =>
    (c.RagioneSociale ?? '').toLowerCase().includes(q)
    || (c.PartitaIva ?? '').toLowerCase().includes(q)
    || (c.CodiceCliente ?? '').toLowerCase().includes(q)
    || (c.Comune ?? '').toLowerCase().includes(q))
})

// --- scheda cliente ---
async function apri(riga) {
  try {
    const { data } = await api.get(`/clienti/${riga.IdCliente}`)
    scheda.value = data
    form.value = { ...data.anagrafica }
    tab.value = 'anagrafica'
    inConferma.value = null
    dettaglioVisibile.value = true
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Cliente', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  }
}

function nuovo() {
  scheda.value = { anagrafica: {}, condizioni: [], listini: [] }
  form.value = { IdCliente: null, Nazione: 'IT' }
  tab.value = 'anagrafica'
  inConferma.value = null
  dettaglioVisibile.value = true
}

async function ricaricaScheda() {
  const { data } = await api.get(`/clienti/${form.value.IdCliente}`)
  scheda.value = data
  form.value = { ...data.anagrafica }
}

async function salvaAnagrafica() {
  if (!form.value.RagioneSociale?.trim()) {
    toast.add({ severity: 'warn', summary: 'Anagrafica', detail: 'La ragione sociale è obbligatoria', life: 3000 })
    return
  }
  salvando.value = true
  try {
    const { data } = await api.post('/clienti', form.value)
    const nuovoCliente = !form.value.IdCliente
    form.value.IdCliente = data.id
    toast.add({ severity: 'success', summary: 'Cliente salvato', detail: form.value.RagioneSociale, life: 2500 })
    await Promise.all([ricaricaScheda(), carica()])
    if (nuovoCliente) tab.value = 'condizioni'
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Salvataggio', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    salvando.value = false
  }
}

// cancellazione logica: DataFine = oggi; riattivazione: DataFine = NULL
async function cambiaStato(cessa) {
  const chiave = cessa ? 'cessa' : 'riattiva'
  if (inConferma.value !== chiave) { inConferma.value = chiave; return }
  inConferma.value = null
  salvando.value = true
  try {
    const oggi = new Date()
    await api.post('/clienti', {
      ...form.value,
      DataFine: cessa
        ? `${oggi.getFullYear()}-${String(oggi.getMonth() + 1).padStart(2, '0')}-${String(oggi.getDate()).padStart(2, '0')}`
        : null
    })
    toast.add({ severity: 'success', summary: cessa ? 'Cliente cessato' : 'Cliente riattivato', life: 2500 })
    await Promise.all([ricaricaScheda(), carica()])
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Stato cliente', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    salvando.value = false
  }
}

// --- condizioni ---
const prodottiFamiglia = computed(() =>
  cond.value.CodFamiglia ? lookup.value.prodotti.filter(p => p.CodFamiglia === cond.value.CodFamiglia) : lookup.value.prodotti)

function apriCondizione(riga) {
  cond.value = riga
    ? { ...riga, DataInizioFatturazione: daData(riga.DataInizioFatturazione), DataFineFatturazione: daData(riga.DataFineFatturazione) }
    : { IdClienteCondizione: null, Scansione: null }
  condVisibile.value = true
}

async function salvaCondizione() {
  salvando.value = true
  try {
    await api.post(`/clienti/${form.value.IdCliente}/condizioni`, {
      ...cond.value,
      DataInizioFatturazione: aData(cond.value.DataInizioFatturazione),
      DataFineFatturazione: aData(cond.value.DataFineFatturazione)
    })
    condVisibile.value = false
    toast.add({ severity: 'success', summary: 'Condizione salvata', life: 2000 })
    await Promise.all([ricaricaScheda(), carica()])
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Condizione', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    salvando.value = false
  }
}

async function eliminaCondizione(riga) {
  const chiave = `cond-${riga.IdClienteCondizione}`
  if (inConferma.value !== chiave) { inConferma.value = chiave; return }
  inConferma.value = null
  try {
    await api.delete(`/clienti/condizioni/${riga.IdClienteCondizione}`)
    toast.add({ severity: 'success', summary: 'Condizione eliminata', life: 2000 })
    await Promise.all([ricaricaScheda(), carica()])
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Condizione', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  }
}

// --- listini ---
const prodottiListino = computed(() => lookup.value.prodotti)

function apriListino(riga) {
  listino.value = riga
    ? { ...riga, ValidoDal: daData(riga.ValidoDal), ValidoAl: daData(riga.ValidoAl) }
    : { IdListino: null }
  listinoVisibile.value = true
}

async function salvaListino() {
  salvando.value = true
  try {
    await api.post(`/clienti/${form.value.IdCliente}/listini`, {
      ...listino.value,
      TariffaOS: listino.value.tariffaOS,
      ValidoDal: aData(listino.value.ValidoDal),
      ValidoAl: aData(listino.value.ValidoAl)
    })
    listinoVisibile.value = false
    toast.add({ severity: 'success', summary: 'Listino salvato', life: 2000 })
    await Promise.all([ricaricaScheda(), carica()])
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Listino', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    salvando.value = false
  }
}

async function eliminaListino(riga) {
  const chiave = `lst-${riga.IdListino}`
  if (inConferma.value !== chiave) { inConferma.value = chiave; return }
  inConferma.value = null
  try {
    await api.delete(`/clienti/listini/${riga.IdListino}`)
    toast.add({ severity: 'success', summary: 'Listino eliminato', life: 2000 })
    await Promise.all([ricaricaScheda(), carica()])
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Listino', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  }
}

// date: dal server come 'yyyy-MM-dd', al DatePicker come Date e ritorno
const daData = s => (s ? new Date(s) : null)
const aData = d => d
  ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  : null

const cessato = computed(() => !!form.value.DataFine)
</script>

<template>
  <div class="pagina">
    <div class="testata">
      <h2>Clienti — {{ clientiFiltrati.length }}</h2>
      <InputText v-model="filtro" placeholder="cerca per nome, P.IVA, codice, comune…" class="cerca" />
      <label class="chk"><Checkbox v-model="mostraCessati" binary @change="carica" /> mostra cessati</label>
      <Button label="Nuovo cliente" icon="pi pi-plus" @click="nuovo" />
    </div>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <DataTable :value="clientiFiltrati" size="small" stripedRows paginator :rows="25"
      :loading="caricamento" @row-click="e => apri(e.data)" :rowHover="true">
      <Column field="RagioneSociale" header="Ragione sociale" sortable />
      <Column field="PartitaIva" header="P.IVA" style="width: 8.5rem" />
      <Column field="CodiceCliente" header="Codice" style="width: 7rem" />
      <Column header="Sede" style="width: 14rem">
        <template #body="{ data }">{{ data.Comune }} {{ data.Prov ? `(${data.Prov})` : '' }}</template>
      </Column>
      <Column field="nCondizioni" header="Condizioni" style="width: 6.5rem" class="num" />
      <Column field="nListini" header="Listini" style="width: 5.5rem" class="num" />
      <Column header="Stato" style="width: 9rem">
        <template #body="{ data }">
          <Tag v-if="data.DataFine" severity="danger" :value="`cessato ${data.DataFine}`" />
          <Tag v-else severity="success" value="attivo" />
        </template>
      </Column>
    </DataTable>

    <!-- scheda cliente -->
    <Dialog v-model:visible="dettaglioVisibile" modal maximizable :style="{ width: '76rem' }"
      :header="form.IdCliente ? `${form.RagioneSociale ?? ''} — cliente ${form.IdCliente}` : 'Nuovo cliente'">
      <div class="stato-riga">
        <Tag v-if="cessato" severity="danger" :value="`cessato il ${form.DataFine}`" />
        <Tag v-else-if="form.IdCliente" severity="success" value="attivo" />
        <span class="spazio" />
        <template v-if="form.IdCliente">
          <Button v-if="!cessato" :label="inConferma === 'cessa' ? 'Confermi la cessazione?' : 'Cessa cliente'"
            icon="pi pi-ban" severity="danger" outlined size="small" :loading="salvando" @click="cambiaStato(true)" />
          <Button v-else :label="inConferma === 'riattiva' ? 'Confermi la riattivazione?' : 'Riattiva cliente'"
            icon="pi pi-undo" severity="warn" outlined size="small" :loading="salvando" @click="cambiaStato(false)" />
        </template>
      </div>

      <Tabs v-model:value="tab">
        <TabList>
          <Tab value="anagrafica">Anagrafica</Tab>
          <Tab value="condizioni" :disabled="!form.IdCliente">Condizioni ({{ scheda?.condizioni?.length ?? 0 }})</Tab>
          <Tab value="listini" :disabled="!form.IdCliente">Listini ({{ scheda?.listini?.length ?? 0 }})</Tab>
        </TabList>
        <TabPanels>
          <TabPanel value="anagrafica">
            <div class="griglia">
              <label class="span2">Ragione sociale * <InputText v-model="form.RagioneSociale" maxlength="250" fluid /></label>
              <label>Partita IVA <InputText v-model="form.PartitaIva" maxlength="50" fluid /></label>
              <label>Codice cliente <InputText v-model="form.CodiceCliente" maxlength="50" fluid /></label>
              <label class="span2">Indirizzo <InputText v-model="form.Indirizzo" maxlength="250" fluid /></label>
              <label>CAP <InputText v-model="form.CAP" maxlength="5" fluid /></label>
              <label class="riga2">Comune / Prov
                <span class="doppio">
                  <InputText v-model="form.Comune" maxlength="250" fluid />
                  <InputText v-model="form.Prov" maxlength="2" class="prov" />
                </span>
              </label>
              <label>Telefono <InputText v-model="form.Telefono" maxlength="50" fluid /></label>
              <label>Email <InputText v-model="form.Email" maxlength="50" fluid /></label>
              <label>PEC <InputText v-model="form.PEC" maxlength="50" fluid /></label>
              <label>Codice SDI <InputText v-model="form.CodSDI" maxlength="50" fluid /></label>
              <label>CIG <InputText v-model="form.CIG" maxlength="50" fluid /></label>
              <label>Nazione <InputText v-model="form.Nazione" maxlength="5" fluid /></label>
              <label>Gestionale <InputText v-model="form.Gestionale" maxlength="50" fluid /></label>
              <label class="chk-col">Opzioni
                <span class="chk-multi">
                  <label class="chk"><Checkbox :modelValue="!!form.InvioEmailEventi" binary
                    @update:modelValue="v => form.InvioEmailEventi = v ? 1 : 0" /> email eventi</label>
                  <label class="chk"><Checkbox :modelValue="!!form.Demo" binary
                    @update:modelValue="v => form.Demo = v ? 1 : 0" /> demo</label>
                </span>
              </label>
              <label class="span2">Email prefattura <InputText v-model="form.EmailPrefattura" maxlength="2000" fluid /></label>
              <label class="span4">Descrizione <Textarea v-model="form.Descrizione" maxlength="500" rows="2" fluid /></label>
            </div>
            <div class="barra-form">
              <Button :label="form.IdCliente ? 'Salva anagrafica' : 'Crea cliente'" icon="pi pi-check"
                :loading="salvando" @click="salvaAnagrafica" />
            </div>
          </TabPanel>

          <TabPanel value="condizioni">
            <div class="barra-tab">
              <Button label="Nuova condizione" icon="pi pi-plus" size="small" @click="apriCondizione(null)" />
            </div>
            <DataTable :value="scheda?.condizioni ?? []" size="small" stripedRows>
              <Column field="FamigliaDiProdotto" header="Famiglia" />
              <Column field="Prodotto" header="Prodotto (specifico)" />
              <Column field="CodTipoVendita" header="Tipo vendita" style="width: 7rem" />
              <Column field="DataInizioFatturazione" header="Fatt. dal" style="width: 7rem" />
              <Column field="DataFineFatturazione" header="Fatt. al" style="width: 7rem" />
              <Column field="Ambito" header="Ambito" style="width: 6rem" />
              <Column field="Tracciato" header="Tracciato" />
              <Column field="Filiale" header="Filiale" />
              <Column style="width: 11rem">
                <template #body="{ data }">
                  <Button icon="pi pi-pencil" text size="small" @click="apriCondizione(data)" />
                  <Button :icon="inConferma === `cond-${data.IdClienteCondizione}` ? undefined : 'pi pi-trash'"
                    :label="inConferma === `cond-${data.IdClienteCondizione}` ? 'confermi?' : undefined"
                    text size="small" severity="danger" @click="eliminaCondizione(data)" />
                </template>
              </Column>
            </DataTable>
          </TabPanel>

          <TabPanel value="listini">
            <div class="barra-tab">
              <Button label="Nuovo listino" icon="pi pi-plus" size="small" @click="apriListino(null)" />
            </div>
            <DataTable :value="scheda?.listini ?? []" size="small" stripedRows scrollable scrollHeight="380px">
              <Column field="Descrizione" header="Descrizione" />
              <Column field="Prodotto" header="Prodotto" />
              <Column field="PrezzoAttivo" header="Prezzo att." style="width: 6rem" class="num" />
              <Column field="PrezzoPassivo" header="Prezzo pass." style="width: 6.5rem" class="num" />
              <Column field="AliquotaIVA" header="IVA" style="width: 4rem" class="num" />
              <Column field="ValidoDal" header="Dal" style="width: 7rem" />
              <Column field="ValidoAl" header="Al" style="width: 7rem" />
              <Column style="width: 11rem">
                <template #body="{ data }">
                  <Button icon="pi pi-pencil" text size="small" @click="apriListino(data)" />
                  <Button :icon="inConferma === `lst-${data.IdListino}` ? undefined : 'pi pi-trash'"
                    :label="inConferma === `lst-${data.IdListino}` ? 'confermi?' : undefined"
                    text size="small" severity="danger" @click="eliminaListino(data)" />
                </template>
              </Column>
            </DataTable>
          </TabPanel>
        </TabPanels>
      </Tabs>
    </Dialog>

    <!-- condizione -->
    <Dialog v-model:visible="condVisibile" modal :style="{ width: '38rem' }"
      :header="cond.IdClienteCondizione ? 'Modifica condizione' : 'Nuova condizione'">
      <div class="griglia g2">
        <label>Famiglia
          <Select v-model="cond.CodFamiglia" :options="lookup.famiglie" optionLabel="FamigliaDiProdotto"
            optionValue="CodFamiglia" showClear fluid placeholder="— scegli —" />
        </label>
        <label>Prodotto specifico (facoltativo)
          <Select v-model="cond.IdProdotto" :options="prodottiFamiglia" optionLabel="Prodotto"
            optionValue="IdProdotto" showClear filter fluid placeholder="— tutta la famiglia —" />
        </label>
        <label>Tipo vendita
          <Select v-model="cond.CodTipoVendita" :options="lookup.tipiVendita" showClear editable fluid />
        </label>
        <label>Ambito <InputText v-model="cond.Ambito" maxlength="50" fluid /></label>
        <label>Fatturazione dal
          <DatePicker v-model="cond.DataInizioFatturazione" dateFormat="dd/mm/yy" showIcon showButtonBar fluid />
        </label>
        <label>Fatturazione al
          <DatePicker v-model="cond.DataFineFatturazione" dateFormat="dd/mm/yy" showIcon showButtonBar fluid />
        </label>
        <label>Tracciato di carico
          <Select v-model="cond.IdTracciato" :options="lookup.tracciati" optionLabel="Tracciato"
            optionValue="IdTracciato" showClear filter fluid placeholder="— nessuno —" />
        </label>
        <label>Filiale
          <Select v-model="cond.IdFiliale" :options="lookup.filiali" optionLabel="Filiale"
            optionValue="IdFiliale" showClear filter fluid placeholder="— nessuna —" />
        </label>
        <label>Scansione <InputNumber v-model="cond.Scansione" fluid /></label>
      </div>
      <template #footer>
        <Button label="Annulla" text @click="condVisibile = false" />
        <Button label="Salva" icon="pi pi-check" :loading="salvando" @click="salvaCondizione" />
      </template>
    </Dialog>

    <!-- listino -->
    <Dialog v-model:visible="listinoVisibile" modal :style="{ width: '42rem' }"
      :header="listino.IdListino ? 'Modifica listino' : 'Nuovo listino'">
      <div class="griglia g2">
        <label>Descrizione <InputText v-model="listino.Descrizione" maxlength="50" fluid /></label>
        <label>Codice <InputText v-model="listino.CodiceListino" maxlength="50" fluid /></label>
        <label class="span2g">Prodotto
          <Select v-model="listino.IdProdotto" :options="prodottiListino" optionLabel="Prodotto"
            optionValue="IdProdotto" showClear filter fluid placeholder="— scegli —" />
        </label>
        <label>Prezzo attivo <InputNumber v-model="listino.PrezzoAttivo" :minFractionDigits="0" :maxFractionDigits="4" fluid /></label>
        <label>Sconto attivo <InputNumber v-model="listino.ScontoAttivo" :minFractionDigits="0" :maxFractionDigits="2" fluid /></label>
        <label>Prezzo passivo <InputNumber v-model="listino.PrezzoPassivo" :minFractionDigits="0" :maxFractionDigits="4" fluid /></label>
        <label>Sconto passivo <InputNumber v-model="listino.ScontoPassivo" :minFractionDigits="0" :maxFractionDigits="2" fluid /></label>
        <label>Aliquota IVA <InputNumber v-model="listino.AliquotaIVA" fluid /></label>
        <label>Tariffa OS <InputNumber v-model="listino.tariffaOS" :minFractionDigits="0" :maxFractionDigits="4" fluid /></label>
        <label>Valido dal <DatePicker v-model="listino.ValidoDal" dateFormat="dd/mm/yy" showIcon showButtonBar fluid /></label>
        <label>Valido al <DatePicker v-model="listino.ValidoAl" dateFormat="dd/mm/yy" showIcon showButtonBar fluid /></label>
        <label>Prodotto/Servizio <InputText v-model="listino.ProdottoServizio" maxlength="5" fluid /></label>
        <label>Tipo area <InputText v-model="listino.TipoArea" maxlength="10" fluid /></label>
        <label>Porto <InputNumber v-model="listino.Porto" fluid /></label>
        <label>Tipo <InputText v-model="listino.Tipo" maxlength="100" fluid /></label>
        <label>Peso min <InputNumber v-model="listino.PesoMin" fluid /></label>
        <label>Peso max <InputNumber v-model="listino.PesoMax" fluid /></label>
      </div>
      <template #footer>
        <Button label="Annulla" text @click="listinoVisibile = false" />
        <Button label="Salva" icon="pi pi-check" :loading="salvando" @click="salvaListino" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.75rem; }
.testata { display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
.testata h2 { margin: 0; flex: 1; }
.cerca { width: 20rem; }
.chk { display: inline-flex; align-items: center; gap: .4rem; cursor: pointer; font-size: .9rem; }
:deep(.p-datatable-tbody > tr) { cursor: pointer; }
.num { text-align: right; }

.stato-riga { display: flex; align-items: center; gap: .75rem; margin-bottom: .5rem; }
.stato-riga .spazio { flex: 1; }

.griglia { display: grid; grid-template-columns: repeat(4, 1fr); gap: .6rem .8rem; }
.griglia.g2 { grid-template-columns: 1fr 1fr; }
.griglia label { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.span2 { grid-column: span 2; }
.span4 { grid-column: span 4; }
.span2g { grid-column: span 2; }
.doppio { display: flex; gap: .4rem; }
.doppio > :first-child { flex: 1; }
.prov { width: 4rem; }
.chk-col .chk-multi { display: flex; gap: 1rem; min-height: 2.4rem; align-items: center; }
.barra-form { margin-top: .9rem; display: flex; justify-content: flex-end; }
.barra-tab { margin-bottom: .5rem; display: flex; justify-content: flex-end; }
</style>
