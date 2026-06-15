<script setup>
import { ref, reactive, watch, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import Password from 'primevue/password'
import DatePicker from 'primevue/datepicker'
import Select from 'primevue/select'
import Tag from 'primevue/tag'
import IconField from 'primevue/iconfield'
import InputIcon from 'primevue/inputicon'
import Message from 'primevue/message'
import Tabs from 'primevue/tabs'
import TabList from 'primevue/tablist'
import Tab from 'primevue/tab'
import TabPanels from 'primevue/tabpanels'
import TabPanel from 'primevue/tabpanel'

const toast = useToast()

// definizione campi per sezione (t: text|number|date|select|password; ro: readonly)
const SEZIONI = [
  { nome: 'Account', campi: [
    { k: 'Utente', l: 'Username', t: 'text' },
    { k: 'IdRuolo', l: 'Ruolo', t: 'select', opt: 'ruoli', ov: 'idRuolo', ol: 'ruolo' },
    { k: 'IdCliente', l: 'Cliente collegato', t: 'select', opt: 'clienti', ov: 'idCliente', ol: 'ragioneSociale' },
    { k: 'IdUtentePadre', l: 'Utente padre', t: 'select', opt: 'padri', ov: 'idUtente', ol: 'label' },
    { k: 'Email', l: 'Email', t: 'text' },
    { k: 'codAppLogin', l: 'Cod App Login (palmare)', t: 'text' },
    { k: 'DataInizio', l: 'Data inizio', t: 'date' },
    { k: 'DataFine', l: 'Data fine (disattiva utente)', t: 'date' }
  ] },
  { nome: 'Anagrafica', campi: [
    { k: 'Nome', l: 'Cognome e nome', t: 'text' },
    { k: 'CodiceFiscale', l: 'Codice fiscale', t: 'text' },
    { k: 'DataNascita', l: 'Data di nascita', t: 'date' },
    { k: 'Telefono', l: 'Telefono', t: 'text' },
    { k: 'IndirizzoRes', l: 'Indirizzo residenza', t: 'text' },
    { k: 'CapRes', l: 'CAP', t: 'text' },
    { k: 'ComuneRes', l: 'Comune', t: 'text' },
    { k: 'ProvRes', l: 'Provincia', t: 'text' }
  ] },
  { nome: 'Lavoro', campi: [
    { k: 'IdFiliale', l: 'Filiale', t: 'select', opt: 'filiali', ov: 'idFiliale', ol: 'filiale' },
    { k: 'idAziendaFatt', l: 'Azienda fatturazione', t: 'select', opt: 'aziende', ov: 'idAzienda', ol: 'azienda' },
    { k: 'Matricola', l: 'Matricola', t: 'text' },
    { k: 'Livello', l: 'Livello', t: 'text' },
    { k: 'Mansione', l: 'Mansione', t: 'text' },
    { k: 'Partime', l: 'Percentuale part-time', t: 'number', dec: true },
    { k: 'GiorniLavorativi', l: 'Giorni lavorativi', t: 'text' },
    { k: 'OrarioLavoro', l: 'Orario di lavoro', t: 'text' },
    { k: 'Iban', l: 'IBAN', t: 'text' },
    { k: 'NumeroScarpe', l: 'Numero scarpe', t: 'text' },
    { k: 'TagliaAbbigliamento', l: 'Taglia abbigliamento', t: 'text' },
    { k: 'Stato', l: 'Stato', t: 'text' },
    { k: 'Colore', l: 'Colore', t: 'text' },
    { k: 'CodPoste', l: 'Cod Poste', t: 'text' },
    { k: 'CodADER4', l: 'Cod ADER4', t: 'text' },
    { k: 'CodADER', l: 'Cod ADER', t: 'text' },
    { k: 'Cod_iMile', l: 'Cod iMile', t: 'text' },
    { k: 'IdMezzo_Default', l: 'Mezzo predefinito (Id)', t: 'number' },
    { k: 'Note', l: 'Note', t: 'text' }
  ] },
  { nome: 'Certificato firma', campi: [
    { k: 'CERT_Alias', l: 'Alias certificato', t: 'text' },
    { k: 'CERT_SerialNumber', l: 'Serial number', t: 'text' },
    { k: 'CERT_StatoNascita', l: 'Stato nascita', t: 'text' },
    { k: 'CERT_uniqueidentifier', l: 'Unique identifier', t: 'text' },
    { k: 'CERT_IdUtenteCertificatore', l: 'Id certificatore', t: 'number' },
    { k: 'CERT_Tentativi', l: 'Tentativi PIN', t: 'number' },
    { k: 'CERT_ProfiloCertificatore', l: 'Profilo certificatore', t: 'date' },
    { k: 'CERT_CertificatoValido', l: 'Valido dal', t: 'date' },
    { k: 'CERT_DataScadenza', l: 'Scadenza', t: 'date' },
    { k: 'CERT_DataRevoca', l: 'Data revoca', t: 'date' },
    { k: 'CERT_DataSospensione', l: 'Data sospensione', t: 'date' },
    { k: 'CERT_TempSospeso', l: 'Sospeso temporaneo', t: 'date' },
    { k: 'flagFirma', l: 'Flag firma', t: 'number' },
    { k: 'FotoTessera', l: 'Foto tessera (path)', t: 'text' },
    { k: 'FirmaEstesa', l: 'Firma estesa (path)', t: 'text' },
    { k: 'FirmaSigla', l: 'Firma sigla (path)', t: 'text' }
  ] },
  { nome: 'Sistema', campi: [
    { k: 'IdUtente', l: 'Id utente', t: 'number', ro: true },
    { k: 'LoginErrors', l: 'Tentativi login falliti', t: 'number', ro: true },
    { k: 'DataUltimoAccesso', l: 'Ultimo accesso', t: 'date', ro: true },
    { k: 'RECHASH', l: 'RECHASH', t: 'text', ro: true },
    { k: 'RECDATA', l: 'RECDATA', t: 'date', ro: true },
    { k: 'tokenAutoLogin', l: 'Token auto-login', t: 'text', ro: true },
    { k: 'tokenRegistrazione', l: 'Token registrazione', t: 'text', ro: true }
  ] }
]
const CAMPI_DATA = SEZIONI.flatMap(s => s.campi).filter(c => c.t === 'date').map(c => c.k)

const lookups = reactive({ ruoli: [], filiali: [], clienti: [], aziende: [], padri: [] })

// --- lista ---
const rows = ref([])
const total = ref(0)
const caricamento = ref(false)
const errore = ref('')
const lazy = ref({ page: 0, size: 50, sort: 'Utente', dir: 'asc', q: '' })

async function caricaLista() {
  caricamento.value = true
  errore.value = ''
  try {
    const { page, size, sort, dir, q } = lazy.value
    const { data } = await api.get('/utenti', { params: { page, size, sort, dir, q: q || undefined } })
    rows.value = data.rows
    total.value = data.total
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento'
  } finally {
    caricamento.value = false
  }
}
onMounted(async () => {
  try { const { data } = await api.get('/utenti/lookups'); Object.assign(lookups, data) } catch {}
  caricaLista()
})
function onPage(e) { lazy.value.page = e.page; lazy.value.size = e.rows; caricaLista() }
function onSort(e) { lazy.value.sort = e.sortField; lazy.value.dir = e.sortOrder === -1 ? 'desc' : 'asc'; lazy.value.page = 0; caricaLista() }
let tmr
watch(() => lazy.value.q, () => { clearTimeout(tmr); tmr = setTimeout(() => { lazy.value.page = 0; caricaLista() }, 350) })

// --- edit ---
const dialog = ref(false)
const edit = ref({})
const nuovaPassword = ref('')
const nuovo = ref(false)
const salvataggio = ref(false)

function toDate(v) { if (!v) return null; const d = new Date(v); return isNaN(d) ? null : d }
function toIso(d) {
  if (!(d instanceof Date) || isNaN(d)) return null
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

async function apriNuovo() {
  nuovo.value = true
  nuovaPassword.value = ''
  const r = {}
  for (const s of SEZIONI) for (const c of s.campi) r[c.k] = null
  r.IdUtente = null
  edit.value = r
  dialog.value = true
}
async function apriModifica(riga) {
  nuovo.value = false
  nuovaPassword.value = ''
  try {
    const { data } = await api.get(`/utenti/${riga.IdUtente}`)
    for (const k of CAMPI_DATA) if (data[k]) data[k] = toDate(data[k])
    edit.value = data
    dialog.value = true
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Errore', detail: 'Impossibile aprire l\'utente', life: 4000 })
  }
}

async function salva() {
  salvataggio.value = true
  try {
    const payload = { ...edit.value }
    for (const k of CAMPI_DATA) if (payload[k] instanceof Date) payload[k] = toIso(payload[k])
    if (nuovaPassword.value) payload.NuovaPassword = nuovaPassword.value
    await api.post('/utenti', payload)
    dialog.value = false
    toast.add({ severity: 'success', summary: 'Utente salvato', life: 1800 })
    await caricaLista()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Errore salvataggio', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    salvataggio.value = false
  }
}

function fmtData(v) {
  if (!v) return ''
  const d = new Date(v)
  return isNaN(d) ? v : d.toLocaleDateString('it-IT')
}
</script>

<template>
  <div class="utenti">
    <div class="testata">
      <h2>Utenti</h2>
      <div class="azioni">
        <span v-if="total" class="conta">{{ total }} utenti</span>
        <IconField>
          <InputIcon class="pi pi-search" />
          <InputText v-model="lazy.q" placeholder="Cerca per nome, username, email, CF..." size="small" />
        </IconField>
        <Button label="Nuovo utente" icon="pi pi-user-plus" size="small" @click="apriNuovo" />
      </div>
    </div>

    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <DataTable
      :value="rows" lazy paginator :rows="lazy.size" :totalRecords="total"
      :rowsPerPageOptions="[20, 50, 100, 200]" :loading="caricamento"
      @page="onPage" @sort="onSort" scrollable scrollHeight="flex" size="small"
      stripedRows showGridlines class="griglia"
    >
      <Column header="" style="width:3rem">
        <template #body="{ data }">
          <Button icon="pi pi-pencil" text rounded size="small" @click="apriModifica(data)" />
        </template>
      </Column>
      <Column field="Utente" header="Username" sortable />
      <Column field="Nome" header="Nominativo" sortable />
      <Column field="Email" header="Email" sortable />
      <Column field="Ruolo" header="Ruolo" />
      <Column field="Filiale" header="Filiale" />
      <Column field="Cliente" header="Cliente" />
      <Column field="DataUltimoAccesso" header="Ultimo accesso" sortable>
        <template #body="{ data }">{{ fmtData(data.DataUltimoAccesso) }}</template>
      </Column>
      <Column field="Attivo" header="Attivo">
        <template #body="{ data }">
          <Tag :value="data.Attivo ? 'sì' : 'no'" :severity="data.Attivo ? 'success' : 'danger'" />
        </template>
      </Column>
      <template #empty><div v-if="!caricamento" class="vuoto">Nessun utente</div></template>
    </DataTable>

    <Dialog
      v-model:visible="dialog" modal maximizable :style="{ width: '860px' }"
      :header="(nuovo ? 'Nuovo utente' : `Utente: ${edit.Utente ?? ''}`)"
    >
      <Tabs value="0">
        <TabList>
          <Tab v-for="(s, i) in SEZIONI" :key="s.nome" :value="String(i)">{{ s.nome }}</Tab>
          <Tab value="pwd">Password</Tab>
        </TabList>
        <TabPanels>
          <TabPanel v-for="(s, i) in SEZIONI" :key="s.nome" :value="String(i)">
            <div class="form">
              <div v-for="c in s.campi" :key="c.k" class="campo">
                <label>{{ c.l }}</label>
                <Select
                  v-if="c.t === 'select'"
                  v-model="edit[c.k]" :options="lookups[c.opt]" :optionValue="c.ov" :optionLabel="c.ol"
                  filter showClear
                />
                <DatePicker v-else-if="c.t === 'date'" v-model="edit[c.k]" dateFormat="dd/mm/yy" showButtonBar showIcon :disabled="c.ro" />
                <InputNumber v-else-if="c.t === 'number'" v-model="edit[c.k]" :useGrouping="false" :maxFractionDigits="c.dec ? 2 : 0" :disabled="c.ro" />
                <InputText v-else v-model="edit[c.k]" :disabled="c.ro" />
              </div>
            </div>
          </TabPanel>
          <TabPanel value="pwd">
            <div class="pwd-box">
              <p>
                {{ nuovo ? 'Imposta la password di accesso web (lascia vuoto per utente solo-palmare).'
                         : 'Compila solo per reimpostare la password. Vuoto = password invariata.' }}
              </p>
              <label>Nuova password</label>
              <Password v-model="nuovaPassword" toggleMask :feedback="false" />
            </div>
          </TabPanel>
        </TabPanels>
      </Tabs>

      <template #footer>
        <Button label="Annulla" text severity="secondary" @click="dialog = false" />
        <Button label="Salva" icon="pi pi-check" :loading="salvataggio" :disabled="!edit.Utente" @click="salva" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.utenti { display: flex; flex-direction: column; height: 100%; gap: .5rem; }
.testata { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
.testata h2 { margin: 0; }
.azioni { display: flex; align-items: center; gap: .75rem; }
.conta { color: #666; font-size: .85rem; white-space: nowrap; }
.griglia { flex: 1; min-height: 0; }
.griglia :deep(.p-datatable-tbody > tr > td), .griglia :deep(.p-datatable-thead > tr > th) {
  padding: .35rem .6rem; font-size: .85rem;
}
.vuoto { text-align: center; color: #888; padding: 1rem; }
.form { display: grid; grid-template-columns: 1fr 1fr; gap: .8rem 1.25rem; }
.campo { display: flex; flex-direction: column; gap: .25rem; }
.campo label { font-size: .8rem; font-weight: 600; }
.campo :deep(.p-inputtext), .campo :deep(.p-inputnumber), .campo :deep(.p-select), .campo :deep(.p-datepicker) { width: 100%; }
.pwd-box { max-width: 360px; display: flex; flex-direction: column; gap: .4rem; }
.pwd-box p { color: #666; font-size: .85rem; }
.pwd-box :deep(.p-password), .pwd-box :deep(.p-password-input) { width: 100%; }
</style>
