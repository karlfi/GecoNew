<script setup>
// Scheda del dipendente: si apre sopra l'Elenco Dipendenti (tasto destro ->
// Scheda Utente) senza cambiare pagina, cosi' chiudendola si torna esattamente
// da dove si e' partiti.
//
// E' cosa diversa dalla scheda dentro la pagina Utenti: li' si gestisce
// l'utente dell'applicativo, che non e' detto sia un dipendente e seguira'
// logiche sue. Oggi i campi coincidono, ma le due schede si toccano separate.
//
// Chi la usa passa il dipendente da aprire e la visibilita'; il caricamento dei
// dati, delle lookup e delle relazioni lo fa da se'.
import { ref, reactive, watch } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import Password from 'primevue/password'
import DatePicker from 'primevue/datepicker'
import Select from 'primevue/select'
import Tabs from 'primevue/tabs'
import TabList from 'primevue/tablist'
import Tab from 'primevue/tab'
import TabPanels from 'primevue/tabpanels'
import TabPanel from 'primevue/tabpanel'

const props = defineProps({
  visible: { type: Boolean, default: false },
  idUtente: { type: Number, default: null },   // null + nuovo = utente nuovo
  nuovo: { type: Boolean, default: false }
})
const emit = defineEmits(['update:visible', 'salvato'])

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
    { k: 'LuogoNascita', l: 'Luogo di nascita', t: 'text' },
    { k: 'Cittadinanza', l: 'Cittadinanza', t: 'text' },
    { k: 'TitoloStudio', l: 'Titolo di studio', t: 'text' },
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
    { k: 'TipoContratto', l: 'Tipologia contrattuale', t: 'text' },
    { k: 'DataFineContratto', l: 'Fine contratto', t: 'date' },
    { k: 'CCNL', l: 'CCNL', t: 'text' },
    { k: 'OreSettimanali', l: 'Ore settimanali', t: 'number', dec: true },
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
    { k: 'Note', l: 'Note', t: 'text' },
    // le scrive la pagina "Carica UNILAV": dicono da quale comunicazione
    // arrivano i dati del rapporto qui sopra
    { k: 'UnilavCodice', l: 'Cod. ultima comunicazione UNILAV', t: 'text' },
    { k: 'UnilavData', l: 'UNILAV trasmessa il', t: 'date' }
  ] },
  { nome: 'Permesso di soggiorno', campi: [
    { k: 'SoggiornoTipo', l: 'Titolo di soggiorno', t: 'text' },
    { k: 'SoggiornoNumero', l: 'Numero titolo', t: 'text' },
    { k: 'SoggiornoMotivo', l: 'Motivo', t: 'text' },
    { k: 'SoggiornoScadenza', l: 'Scadenza', t: 'date' },
    { k: 'SoggiornoQuestura', l: 'Questura di rilascio', t: 'text' }
  ] },
  { nome: 'Certificato firma', campi: [
    { k: 'CERT_Alias', l: 'Alias certificato', t: 'text' },
    { k: 'CERT_PIN', l: 'PIN', t: 'text' },
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
let lookupsCaricate = false
async function caricaLookups() {
  if (lookupsCaricate) return
  try { const { data } = await api.get('/utenti/lookups'); Object.assign(lookups, data); lookupsCaricate = true } catch {}
}

const edit = ref({})
const nuovaPassword = ref('')
const salvataggio = ref(false)
const caricando = ref(false)

// --- collezioni N:N (Gruppi, Famiglie, Processi, Filiali abilitate) ---
const relazioni = reactive({ gruppi: [], profili: [], processi: [], filiali: [] })
const comuni = ref([])
const comuniCaricati = ref(false)
const addGruppo = ref(null)
const addProfilo = ref(null)
const addFiliale = ref(null)
const addProcesso = reactive({ idProcesso: null, belfiore: null })

function resetRelazioni() {
  relazioni.gruppi = []; relazioni.profili = []; relazioni.processi = []; relazioni.filiali = []
  addGruppo.value = null; addProfilo.value = null; addFiliale.value = null
  addProcesso.idProcesso = null; addProcesso.belfiore = null
}
async function caricaRelazioni(id) {
  try { const { data } = await api.get(`/utenti/${id}/relazioni`); Object.assign(relazioni, data) }
  catch { /* ignore */ }
}
async function caricaComuni() {
  if (comuniCaricati.value) return
  try { const { data } = await api.get('/utenti/comuni'); comuni.value = data; comuniCaricati.value = true } catch {}
}
async function addRel(coll, body, reset) {
  try {
    await api.post(`/utenti/${edit.value.IdUtente}/${coll}`, body)
    await caricaRelazioni(edit.value.IdUtente)
    reset && reset()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Errore', detail: e.response?.data?.errore ?? 'Operazione fallita', life: 4000 })
  }
}
async function delRel(coll, id) {
  try { await api.delete(`/utenti/${coll}/${id}`); await caricaRelazioni(edit.value.IdUtente) }
  catch (e) { toast.add({ severity: 'error', summary: 'Errore', detail: e.response?.data?.errore ?? 'Operazione fallita', life: 4000 }) }
}

function toDate(v) { if (!v) return null; const d = new Date(v); return isNaN(d) ? null : d }
function toIso(d) {
  if (!(d instanceof Date) || isNaN(d)) return null
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

// all'apertura si carica quello che serve: lookup, utente e sue relazioni
watch(() => [props.visible, props.idUtente, props.nuovo], async ([vis]) => {
  if (!vis) return
  nuovaPassword.value = ''
  resetRelazioni()
  await caricaLookups()
  if (props.nuovo || !props.idUtente) {
    const r = {}
    for (const s of SEZIONI) for (const c of s.campi) r[c.k] = null
    r.IdUtente = null
    edit.value = r
    return
  }
  caricando.value = true
  try {
    const { data } = await api.get(`/utenti/${props.idUtente}`)
    for (const k of CAMPI_DATA) if (data[k]) data[k] = toDate(data[k])
    edit.value = data
    await caricaRelazioni(props.idUtente)
  } catch {
    toast.add({ severity: 'error', summary: 'Errore', detail: 'Impossibile aprire l\'utente', life: 4000 })
    emit('update:visible', false)
  } finally {
    caricando.value = false
  }
}, { immediate: true })

async function salva() {
  salvataggio.value = true
  try {
    const payload = { ...edit.value }
    for (const k of CAMPI_DATA) if (payload[k] instanceof Date) payload[k] = toIso(payload[k])
    if (nuovaPassword.value) payload.NuovaPassword = nuovaPassword.value
    const { data } = await api.post('/utenti', payload)
    emit('update:visible', false)
    emit('salvato', data?.id ?? edit.value.IdUtente)
    toast.add({ severity: 'success', summary: 'Utente salvato', life: 1800 })
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Errore salvataggio', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    salvataggio.value = false
  }
}
</script>

<template>
    <Dialog
      :visible="visible" @update:visible="v => emit('update:visible', v)"
      modal maximizable :style="{ width: '860px' }"
      :header="`Dipendente: ${edit.Nome ?? edit.Utente ?? ''}`"
    >
      <Tabs value="0">
        <TabList>
          <Tab v-for="(s, i) in SEZIONI" :key="s.nome" :value="String(i)">{{ s.nome }}</Tab>
          <Tab value="rel-g">Gruppi</Tab>
          <Tab value="rel-f">Famiglie</Tab>
          <Tab value="rel-p">Processi</Tab>
          <Tab value="rel-fi">Filiali abilitate</Tab>
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
          <TabPanel value="rel-g">
            <div v-if="!edit.IdUtente" class="rel-hint">Salva prima l'utente per gestire i gruppi.</div>
            <template v-else>
              <div class="rel-add">
                <Select v-model="addGruppo" :options="lookups.gruppi" optionValue="idGruppo" optionLabel="gruppo" filter placeholder="Aggiungi gruppo..." />
                <Button icon="pi pi-plus" :disabled="!addGruppo" @click="addRel('gruppi', { idGruppo: addGruppo }, () => addGruppo = null)" />
              </div>
              <ul class="rel-lista">
                <li v-for="r in relazioni.gruppi" :key="r.id">
                  <span>{{ r.gruppo }}</span>
                  <Button icon="pi pi-trash" text rounded size="small" severity="danger" @click="delRel('gruppi', r.id)" />
                </li>
                <li v-if="!relazioni.gruppi.length" class="rel-vuoto">Nessun gruppo</li>
              </ul>
            </template>
          </TabPanel>

          <TabPanel value="rel-f">
            <div v-if="!edit.IdUtente" class="rel-hint">Salva prima l'utente per gestire le famiglie.</div>
            <template v-else>
              <div class="rel-add">
                <Select v-model="addProfilo" :options="lookups.famiglie" optionValue="codFamiglia" optionLabel="famiglia" placeholder="Aggiungi famiglia..." />
                <Button icon="pi pi-plus" :disabled="!addProfilo" @click="addRel('profili', { codFamiglia: addProfilo }, () => addProfilo = null)" />
              </div>
              <ul class="rel-lista">
                <li v-for="r in relazioni.profili" :key="r.id">
                  <span>{{ r.famiglia ?? r.codFamiglia }}</span>
                  <Button icon="pi pi-trash" text rounded size="small" severity="danger" @click="delRel('profili', r.id)" />
                </li>
                <li v-if="!relazioni.profili.length" class="rel-vuoto">Nessuna famiglia</li>
              </ul>
            </template>
          </TabPanel>

          <TabPanel value="rel-p">
            <div v-if="!edit.IdUtente" class="rel-hint">Salva prima l'utente per gestire i processi.</div>
            <template v-else>
              <div class="rel-add rel-add-proc">
                <Select v-model="addProcesso.idProcesso" :options="lookups.processi" optionValue="idProcesso" optionLabel="processo" filter placeholder="Processo..." />
                <Select v-model="addProcesso.belfiore" :options="comuni" optionValue="belfiore" optionLabel="label" filter showClear placeholder="Comune (opzionale)" @show="caricaComuni" />
                <Button icon="pi pi-plus" :disabled="!addProcesso.idProcesso"
                        @click="addRel('processi', { idProcesso: addProcesso.idProcesso, belfiore: addProcesso.belfiore }, () => { addProcesso.idProcesso = null; addProcesso.belfiore = null })" />
              </div>
              <ul class="rel-lista">
                <li v-for="r in relazioni.processi" :key="r.id">
                  <span>{{ r.processo }}<template v-if="r.comune"> — {{ r.comune }}</template></span>
                  <Button icon="pi pi-trash" text rounded size="small" severity="danger" @click="delRel('processi', r.id)" />
                </li>
                <li v-if="!relazioni.processi.length" class="rel-vuoto">Nessun processo</li>
              </ul>
            </template>
          </TabPanel>

          <TabPanel value="rel-fi">
            <div v-if="!edit.IdUtente" class="rel-hint">Salva prima l'utente per gestire le filiali abilitate.</div>
            <template v-else>
              <div class="rel-add">
                <Select v-model="addFiliale" :options="lookups.filiali" optionValue="idFiliale" optionLabel="filiale" filter placeholder="Aggiungi filiale..." />
                <Button icon="pi pi-plus" :disabled="!addFiliale" @click="addRel('filiali', { idFiliale: addFiliale }, () => addFiliale = null)" />
              </div>
              <ul class="rel-lista">
                <li v-for="r in relazioni.filiali" :key="r.id">
                  <span>{{ r.filiale }}</span>
                  <Button icon="pi pi-trash" text rounded size="small" severity="danger" @click="delRel('filiali', r.id)" />
                </li>
                <li v-if="!relazioni.filiali.length" class="rel-vuoto">Nessuna filiale aggiuntiva</li>
              </ul>
            </template>
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
        <Button label="Annulla" text severity="secondary" @click="emit('update:visible', false)" />
        <Button label="Salva" icon="pi pi-check" :loading="salvataggio" :disabled="!edit.Utente" @click="salva" />
      </template>
    </Dialog>
</template>

<style scoped>
.form { display: grid; grid-template-columns: 1fr 1fr; gap: .8rem 1.25rem; }
.campo { display: flex; flex-direction: column; gap: .25rem; }
.campo label { font-size: .8rem; font-weight: 600; }
.campo :deep(.p-inputtext), .campo :deep(.p-inputnumber), .campo :deep(.p-select), .campo :deep(.p-datepicker) { width: 100%; }
.pwd-box { max-width: 360px; display: flex; flex-direction: column; gap: .4rem; }
.pwd-box p { color: #666; font-size: .85rem; }
.pwd-box :deep(.p-password), .pwd-box :deep(.p-password-input) { width: 100%; }
.rel-hint { color: #888; font-style: italic; padding: .5rem 0; }
.rel-add { display: flex; gap: .5rem; margin-bottom: .75rem; }
.rel-add :deep(.p-select) { flex: 1; }
.rel-add-proc { flex-wrap: wrap; }
.rel-add-proc :deep(.p-select) { min-width: 200px; }
.rel-lista { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: .25rem; }
.rel-lista li { display: flex; align-items: center; justify-content: space-between; padding: .3rem .6rem; background: var(--p-surface-50); border-radius: 6px; font-size: .9rem; }
.rel-lista .rel-vuoto { justify-content: center; color: #999; background: none; font-style: italic; }
</style>
