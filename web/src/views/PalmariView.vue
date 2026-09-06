<script setup>
// Palmari aziendali (Knox): l'elenco con i filtri, la scheda (dispositivo, SIM
// montata, chi lo usa giorno per giorno, variazioni, codici) e l'import del
// "Device List" di Knox Manage. L'uso quotidiano arriva dall'app, che si firma
// con l'Android ID: non sta nel file Knox e si abbina dalla scheda scegliendo
// tra gli id visti dall'app e non ancora abbinati.
import { ref, computed, onMounted, watch } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { useNavStore } from '../stores/nav'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Select from 'primevue/select'
import Textarea from 'primevue/textarea'
import Dialog from 'primevue/dialog'
import Tag from 'primevue/tag'
import Tabs from 'primevue/tabs'
import TabList from 'primevue/tablist'
import Tab from 'primevue/tab'
import TabPanels from 'primevue/tabpanels'
import TabPanel from 'primevue/tabpanel'
import AutoComplete from 'primevue/autocomplete'
import { fileBase64, messaggioErrore } from '../lib/schedulatore'

const toast = useToast()
const nav = useNavStore()
const errore = e => toast.add({ severity: 'error', summary: 'Errore', detail: messaggioErrore(e), life: 6000 })

// --- elenco e filtri ---
const palmari = ref([])
const lookup = ref({ stati: [], tags: [], modelli: [], filiali: [], totale: 0, ultimoImport: null, androidNonAbbinati: [] })
const filtri = ref({ testo: '', tag: null, idFiliale: null, modello: null, stato: null, conSim: null, abbinato: null })
const siNo = [{ label: 'con SIM', value: true }, { label: 'senza SIM', value: false }]
const abb = [{ label: 'abbinati all\'app', value: true }, { label: 'da abbinare', value: false }]
const caricamento = ref(false)
let timer = null
async function caricaLookup() { try { lookup.value = (await api.get('/palmari/lookup')).data } catch (e) { errore(e) } }
async function carica() {
  caricamento.value = true
  try {
    const f = filtri.value
    palmari.value = (await api.get('/palmari', { params: { testo: f.testo || null, tag: f.tag, idFiliale: f.idFiliale, modello: f.modello, stato: f.stato, conSim: f.conSim, abbinato: f.abbinato } })).data
  } catch (e) { errore(e) } finally { caricamento.value = false }
}
watch(() => filtri.value.testo, () => { clearTimeout(timer); timer = setTimeout(carica, 350) })
watch(() => [filtri.value.tag, filtri.value.idFiliale, filtri.value.modello, filtri.value.stato, filtri.value.conSim, filtri.value.abbinato], carica)
onMounted(async () => { await caricaLookup(); await carica() })

const dataIt = v => v ? new Date(v).toLocaleDateString('it-IT') : ''
const dataOra = v => v ? new Date(v).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' }) : ''
const severitaStato = s => ({ 'In uso': 'success', Scorta: 'info', Guasto: 'danger', Dismesso: 'secondary' }[s] ?? 'secondary')
const severitaPerc = p => p == null ? 'secondary' : p <= 10 ? 'danger' : p <= 25 ? 'warn' : 'success'
const riepilogo = computed(() => ({
  senzaSim: palmari.value.filter(p => !p.IdSim).length,
  daAbbinare: palmari.value.filter(p => !p.AndroidId).length,
  senzaFiliale: palmari.value.filter(p => !p.IdFiliale).length,
  conProblemi: palmari.value.filter(p => p.Problema).length
}))

// --- scheda ---
const dialog = ref(false)
const scheda = ref(null)
const edit = ref({})
const linguetta = ref('disp')
const salvataggio = ref(false)
const simScelta = ref(null)
const simSuggerite = ref([])
const androidScelto = ref(null)
function vuoto() {
  return { IdPalmare: null, Seriale: '', Imei: '', Imei2: '', Mac: '', AndroidId: '', NomeDevice: '', Alias: '', Modello: '', Produttore: 'samsung',
           Tag: '', NumeroMobile: '', ICCID: '', IdSim: null, IdFiliale: null, Stato: 'In uso', Note: '' }
}
async function apri(riga) {
  linguetta.value = 'disp'
  if (!riga) { scheda.value = null; edit.value = vuoto(); simScelta.value = null; androidScelto.value = null; dialog.value = true; return }
  try {
    const { data } = await api.get(`/palmari/${riga.IdPalmare}`)
    scheda.value = data
    edit.value = Object.fromEntries(Object.keys(vuoto()).map(k => [k, data[k] ?? vuoto()[k]]))
    simScelta.value = data.IdSim ? { IdSim: data.IdSim, Numero: data.SimNumero, PianoTariffario: data.SimPiano } : null
    androidScelto.value = data.AndroidId ? { AndroidId: data.AndroidId } : null
    dialog.value = true
  } catch (e) { errore(e) }
}
async function cercaSim(ev) { try { simSuggerite.value = (await api.get('/palmari/sim', { params: { testo: ev.query } })).data } catch { simSuggerite.value = [] } }
// gli Android ID non abbinati, filtrati mentre si scrive; si puo' anche scriverne uno a mano
const androidSuggeriti = ref([])
function cercaAndroid(ev) {
  const q = (ev.query || '').toLowerCase()
  androidSuggeriti.value = lookup.value.androidNonAbbinati.filter(a => !q || a.AndroidId.includes(q) || (a.UltimoDriver || '').toLowerCase().includes(q) || (a.Filiale || '').toLowerCase().includes(q))
}
const etichettaAndroid = a => typeof a === 'string' ? a : a?.AndroidId ?? ''
async function salva() {
  if (!edit.value.Seriale?.trim()) { toast.add({ severity: 'warn', summary: 'Il seriale è obbligatorio', life: 3000 }); return }
  salvataggio.value = true
  try {
    const corpo = { ...edit.value, IdSim: simScelta.value?.IdSim ?? null,
                    AndroidId: typeof androidScelto.value === 'string' ? androidScelto.value : (androidScelto.value?.AndroidId ?? null) }
    const { data } = await api.post('/palmari', corpo)
    toast.add({ severity: 'success', summary: edit.value.IdPalmare ? 'Palmare salvato' : 'Palmare creato', life: 2500 })
    await carica(); await caricaLookup()
    await apri({ IdPalmare: data.idPalmare })
  } catch (e) { errore(e) } finally { salvataggio.value = false }
}
const conferma = ref({ visibile: false, testo: '', azione: null })
const chiedi = (testo, azione) => { conferma.value = { visibile: true, testo, azione } }
async function confermato() { const a = conferma.value.azione; conferma.value.visibile = false; if (a) await a() }
const elimina = () => chiedi(`Eliminare il palmare ${edit.value.Seriale}? Se è solo fuori uso, meglio "Dismesso".`, async () => {
  try { await api.delete(`/palmari/${edit.value.IdPalmare}`); toast.add({ severity: 'info', summary: 'Palmare eliminato', life: 2500 }); dialog.value = false; await carica(); await caricaLookup() }
  catch (e) { errore(e) }
})
const apriSim = () => { if (scheda.value?.IdSim) nav.drill({ tipo: 'sim', idSim: scheda.value.IdSim }) }

// --- import Knox ---
const inputFile = ref(null)
const importazione = ref(false)
const esitoImport = ref(null)
async function importa(ev) {
  const files = Array.from(ev.target.files ?? [])
  ev.target.value = ''
  if (!files.length) return
  importazione.value = true
  try {
    const esiti = []
    for (const f of files) esiti.push((await api.post('/palmari/import', { nome: f.name, base64: await fileBase64(f) })).data)
    esitoImport.value = esiti
    await carica(); await caricaLookup()
  } catch (e) { errore(e) } finally { importazione.value = false }
}
const dialogImport = computed({ get: () => !!esitoImport.value, set: v => { if (!v) esitoImport.value = null } })
</script>

<template>
  <div class="pagina">
    <div class="testata">
      <div>
        <h2 class="titolo">Palmari</h2>
        <p class="sotto">
          {{ lookup.totale }} dispositivi<template v-if="lookup.ultimoImport">, ultimo import Knox del {{ dataIt(lookup.ultimoImport) }}</template>.
          L'uso quotidiano (chi lo prende) arriva dall'app: vale per i palmari abbinati al loro Android ID.
        </p>
      </div>
      <div class="barra">
        <Button label="Nuovo palmare" icon="pi pi-plus" @click="apri(null)" />
        <Button label="Importa Device List Knox" icon="pi pi-upload" outlined :loading="importazione" @click="inputFile.click()" />
        <input ref="inputFile" type="file" multiple accept=".xlsx" hidden @change="importa" />
        <Button icon="pi pi-refresh" text :loading="caricamento" title="Aggiorna" @click="carica" />
      </div>
    </div>

    <div class="filtri">
      <InputText v-model="filtri.testo" placeholder="seriale, IMEI, nome, numero, ICCID, driver…" class="cerca" />
      <Select v-model="filtri.tag" :options="lookup.tags" placeholder="tutti i tag" showClear />
      <Select v-model="filtri.idFiliale" :options="lookup.filiali" optionLabel="Filiale" optionValue="IdFiliale" placeholder="tutte le filiali" showClear filter />
      <Select v-model="filtri.modello" :options="lookup.modelli" placeholder="tutti i modelli" showClear />
      <Select v-model="filtri.stato" :options="lookup.stati" placeholder="tutti gli stati" showClear />
      <Select v-model="filtri.conSim" :options="siNo" optionLabel="label" optionValue="value" placeholder="SIM: tutti" showClear />
      <Select v-model="filtri.abbinato" :options="abb" optionLabel="label" optionValue="value" placeholder="app: tutti" showClear />
      <span class="nota">{{ palmari.length }} palmari · senza SIM {{ riepilogo.senzaSim }} · da abbinare all'app {{ riepilogo.daAbbinare }} · senza filiale {{ riepilogo.senzaFiliale }}<template v-if="riepilogo.conProblemi"> · con segnalazioni Knox {{ riepilogo.conProblemi }}</template></span>
    </div>

    <DataTable :value="palmari" size="small" stripedRows paginator :rows="25" :rowsPerPageOptions="[25, 50, 100, 500]"
      selectionMode="single" dataKey="IdPalmare" @row-click="e => apri(e.data)" class="elenco" :loading="caricamento" removableSort>
      <Column field="NomeDevice" header="Device" sortable><template #body="{ data }"><b>{{ data.NomeDevice }}</b><br><small class="nota">{{ data.Seriale }}</small></template></Column>
      <Column field="Tag" header="Tag Knox" sortable style="width: 7rem" />
      <Column field="Filiale" header="Filiale" sortable />
      <Column field="Modello" header="Modello" sortable style="width: 11rem"><template #body="{ data }">{{ (data.Modello || '').replace('Galaxy ', '') }}<br><small class="nota">Android {{ data.VersioneOS }}</small></template></Column>
      <Column header="SIM" sortable sortField="SimNumero" style="width: 9rem">
        <template #body="{ data }">
          <template v-if="data.IdSim">{{ data.SimNumero }}<br><small class="nota">{{ data.SimPiano }}</small></template>
          <span v-else-if="data.ICCID" class="attenzione" title="ICCID presente ma nessuna SIM in anagrafica con quell'ICCID">ICCID sconosciuto</span>
          <span v-else class="nota">—</span>
        </template>
      </Column>
      <Column header="Ultimo uso" sortable sortField="UltimoUso" style="width: 11rem">
        <template #body="{ data }">
          <template v-if="data.AndroidId">
            <template v-if="data.UltimoUso">{{ dataIt(data.UltimoUso) }} <b>{{ data.UltimoDriver }}</b><br><small class="nota">{{ data.UltimaFiliale }} · {{ data.GiorniUso30 }} gg/30</small></template>
            <span v-else class="nota">mai visto dall'app</span>
          </template>
          <Tag v-else value="da abbinare" severity="warn" />
        </template>
      </Column>
      <Column field="UtenteMdm" header="Utente Knox" sortable style="width: 7rem" />
      <Column field="Stato" header="Stato" sortable style="width: 6rem"><template #body="{ data }"><Tag :value="data.Stato" :severity="severitaStato(data.Stato)" /></template></Column>
      <Column header="Knox" style="width: 8rem"><template #body="{ data }">{{ data.StatoMdm }} <small class="nota">{{ data.UltimoContatto }}</small><br><small v-if="data.Problema" class="attenzione">{{ data.Problema }}</small></template></Column>
      <template #empty><span class="nota">Nessun palmare: importa il Device List di Knox.</span></template>
    </DataTable>

    <!-- scheda -->
    <Dialog v-model:visible="dialog" modal :header="edit.IdPalmare ? `Palmare ${edit.NomeDevice || edit.Seriale}` : 'Nuovo palmare'" :style="{ width: '60rem' }">
      <Tabs v-model:value="linguetta">
        <TabList>
          <Tab value="disp">Dispositivo</Tab>
          <Tab value="sim" :disabled="!scheda">SIM</Tab>
          <Tab value="uso" :disabled="!scheda">Uso ({{ scheda?.Utilizzo?.length ?? 0 }})</Tab>
          <Tab value="var" :disabled="!scheda">Variazioni ({{ scheda?.Variazioni?.length ?? 0 }})</Tab>
          <Tab value="knox" :disabled="!scheda">Knox</Tab>
        </TabList>
        <TabPanels>
          <TabPanel value="disp">
            <div class="griglia">
              <label>Seriale <InputText v-model="edit.Seriale" /></label>
              <label>Nome device <InputText v-model="edit.NomeDevice" /></label>
              <label>IMEI <InputText v-model="edit.Imei" /></label>
              <label>IMEI 2 <InputText v-model="edit.Imei2" /></label>
              <label>Modello <Select v-model="edit.Modello" :options="lookup.modelli" editable /></label>
              <label>MAC <InputText v-model="edit.Mac" /></label>
              <label>Tag Knox <Select v-model="edit.Tag" :options="lookup.tags" editable showClear /></label>
              <label>Filiale <Select v-model="edit.IdFiliale" :options="lookup.filiali" optionLabel="Filiale" optionValue="IdFiliale" showClear filter placeholder="nessuna" /></label>
              <label>Stato <Select v-model="edit.Stato" :options="lookup.stati" /></label>
              <label>Alias <InputText v-model="edit.Alias" /></label>
              <label class="larga">Android ID (quello che l'app scrive nelle attività)
                <AutoComplete v-model="androidScelto" :suggestions="androidSuggeriti" :optionLabel="etichettaAndroid" @complete="cercaAndroid" dropdown
                  placeholder="scegli tra gli id visti dall'app non ancora abbinati, o scrivilo">
                  <template #option="{ option }">
                    <code>{{ option.AndroidId }}</code> <small class="nota">{{ option.UltimoDriver }} · {{ option.Filiale }} · {{ option.Modello }} · {{ dataIt(option.UltimoUso) }} · {{ option.Eventi }} eventi</small>
                  </template>
                </AutoComplete>
              </label>
              <label class="larga">Note <Textarea v-model="edit.Note" rows="2" autoResize /></label>
            </div>
            <p v-if="scheda" class="nota piccola">Creato il {{ dataOra(scheda.DataCreazione) }}<template v-if="scheda.DataModifica">, modificato il {{ dataOra(scheda.DataModifica) }} da {{ scheda.UtenteModifica }}</template><template v-if="scheda.DataImport">, ultimo import Knox {{ dataOra(scheda.DataImport) }}</template>.</p>
          </TabPanel>
          <TabPanel value="sim">
            <div class="griglia">
              <label class="larga">SIM montata (dall'anagrafica SIM)
                <AutoComplete v-model="simScelta" :suggestions="simSuggerite" optionLabel="Numero" @complete="cercaSim" dropdown forceSelection placeholder="cerca per numero o ICCID">
                  <template #option="{ option }">{{ option.Numero }} <small class="nota">{{ option.ICCID }} · {{ option.PianoTariffario }} · {{ option.Stato }}</small></template>
                </AutoComplete>
              </label>
              <label>Numero (da Knox) <InputText v-model="edit.NumeroMobile" /></label>
              <label>ICCID (da Knox) <InputText v-model="edit.ICCID" /></label>
            </div>
            <div v-if="scheda?.Sim" class="riquadro">
              <b>{{ scheda.Sim.Numero }}</b> · {{ scheda.Sim.PianoTariffario }} · <Tag :value="scheda.Sim.Stato" :severity="scheda.Sim.Stato === 'Attiva' ? 'success' : 'warn'" />
              <template v-if="scheda.Sim.UltimaRilevazione"> · GB residui <Tag :value="(scheda.Sim.PercResidua ?? 0) + '%'" :severity="severitaPerc(scheda.Sim.PercResidua)" /> al {{ dataIt(scheda.Sim.UltimaRilevazione) }}</template>
              <Button label="Apri la SIM" icon="pi pi-external-link" link size="small" @click="apriSim" />
            </div>
            <p v-else-if="edit.ICCID" class="attenzione">L'ICCID di Knox ({{ edit.ICCID }}) non corrisponde a nessuna SIM in anagrafica: importa l'elenco SIM aggiornato o scegli la SIM a mano.</p>
          </TabPanel>
          <TabPanel value="uso">
            <p v-if="!scheda?.AndroidId" class="nota">Senza Android ID abbinato non si sa chi lo usa: scegli l'id nella linguetta Dispositivo.</p>
            <DataTable v-else :value="scheda?.Utilizzo ?? []" size="small" stripedRows paginator :rows="20">
              <Column header="Giorno" style="width: 6.5rem"><template #body="{ data }">{{ dataIt(data.Data) }}</template></Column>
              <Column field="Driver" header="Driver" />
              <Column field="Filiale" header="Filiale" />
              <Column field="Presenza" header="Pres." style="width: 4rem" />
              <Column header="Login" style="width: 5rem"><template #body="{ data }">{{ data.Login ? new Date(data.Login).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' }) : '' }}</template></Column>
              <Column header="Logout" style="width: 5rem"><template #body="{ data }">{{ data.Logout ? new Date(data.Logout).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' }) : '' }}</template></Column>
              <Column field="KmPercorsi" header="Km" style="width: 4rem" />
              <template #empty><span class="nota">Nessun uso registrato negli ultimi 90 giorni.</span></template>
            </DataTable>
          </TabPanel>
          <TabPanel value="var">
            <DataTable :value="scheda?.Variazioni ?? []" size="small" stripedRows>
              <Column header="Quando" style="width: 9rem"><template #body="{ data }">{{ dataOra(data.DataRegistrazione) }}</template></Column>
              <Column field="Campo" header="Campo" style="width: 8rem" />
              <Column field="Prima" header="Prima" />
              <Column field="Dopo" header="Dopo" />
              <Column field="Origine" header="Origine" style="width: 6rem" />
              <Column field="Utente" header="Chi" style="width: 6rem" />
              <template #empty><span class="nota">Nessuna variazione.</span></template>
            </DataTable>
          </TabPanel>
          <TabPanel value="knox">
            <div v-if="scheda" class="knox">
              <div><b>Stato</b> {{ scheda.StatoMdm }} ({{ scheda.UltimoContatto }})</div>
              <div><b>Segnalazione</b> {{ scheda.Problema || '—' }}</div>
              <div><b>Utente Knox</b> {{ scheda.UtenteMdm }}</div>
              <div><b>Organizzazione</b> {{ scheda.Organizzazione }}</div>
              <div><b>Profilo</b> {{ scheda.Profilo }}</div>
              <div><b>Gestione</b> {{ scheda.TipoGestione }} · {{ scheda.TipoEnrollment }}</div>
              <div><b>Android</b> {{ scheda.VersioneOS }} · agent {{ scheda.VersioneAgent }}</div>
              <div><b>Firmware</b> {{ scheda.Firmware }}</div>
              <div><b>EID</b> {{ scheda.EID }}</div>
              <div><b>Roaming</b> {{ scheda.Roaming ? 'sì' : 'no' }} · <b>ultimo comando</b> {{ scheda.UltimoComando }} · <b>aggiornato</b> {{ dataIt(scheda.UltimoAggiornamentoMdm) }}</div>
              <div><b>App Speedy</b> <template v-if="scheda.UltimoEventoApp">versione {{ scheda.VersioneApp }}, ultimo evento {{ dataOra(scheda.UltimoEventoApp) }}</template><span v-else class="nota">nessun evento (Android ID non abbinato o mai usato)</span></div>
              <div class="codici"><b>Codici</b> uscita kiosk <code>{{ scheda.CodiceKiosk }}</code> · sblocco <code>{{ scheda.CodiceSblocco }}</code> · unenroll <code>{{ scheda.CodiceUnenroll }}</code></div>
            </div>
          </TabPanel>
        </TabPanels>
      </Tabs>
      <template #footer>
        <Button v-if="edit.IdPalmare" label="Elimina" icon="pi pi-trash" severity="danger" text @click="elimina" />
        <Button label="Chiudi" text @click="dialog = false" />
        <Button :label="edit.IdPalmare ? 'Salva' : 'Crea'" icon="pi pi-check" :loading="salvataggio" @click="salva" />
      </template>
    </Dialog>

    <Dialog v-model:visible="dialogImport" modal header="Import Device List Knox" :style="{ width: '40rem' }">
      <div v-for="(e, i) in esitoImport ?? []" :key="i" class="esito">
        <b>{{ e.file }}</b> — {{ e.righe }} righe
        <ul>
          <li>palmari nuovi: <b>{{ e.nuovi }}</b>, aggiornati: <b>{{ e.aggiornati }}</b>, invariati: {{ e.invariati }}</li>
          <li v-if="e.iccidSenzaSim">con ICCID che non corrisponde a nessuna SIM in anagrafica: <b>{{ e.iccidSenzaSim }}</b> (importa l'elenco SIM aggiornato)</li>
          <li v-if="e.tagSenzaFiliale.length">tag Knox non riconducibili a una filiale sola (da assegnare a mano): {{ e.tagSenzaFiliale.join(', ') }}</li>
          <li v-if="e.errori.length" class="attenzione">errori: {{ e.errori.length }}<ul><li v-for="(x, j) in e.errori.slice(0, 10)" :key="j">{{ x }}</li></ul></li>
        </ul>
      </div>
      <template #footer><Button label="Chiudi" @click="dialogImport = false" /></template>
    </Dialog>

    <Dialog v-model:visible="conferma.visibile" modal header="Conferma" :style="{ width: '30rem' }">
      <p>{{ conferma.testo }}</p>
      <template #footer>
        <Button label="Annulla" text @click="conferma.visibile = false" />
        <Button label="Conferma" severity="danger" @click="confermato" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 1rem; }
.titolo { margin: 0; }
.sotto { margin: 0; color: var(--p-text-muted-color); }
.testata { display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem; flex-wrap: wrap; }
.barra { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.filtri { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.cerca { width: 22rem; }
.elenco :deep(tr) { cursor: pointer; }
.griglia { display: grid; grid-template-columns: 1fr 1fr; gap: .6rem 1rem; }
.griglia label { display: flex; flex-direction: column; gap: .2rem; font-size: .85rem; color: var(--p-text-muted-color); }
.griglia label.larga { grid-column: 1 / -1; }
.riquadro { margin-top: .75rem; padding: .6rem .8rem; border: 1px solid var(--p-content-border-color); border-radius: 8px; display: flex; align-items: center; gap: .4rem; flex-wrap: wrap; }
.knox { display: flex; flex-direction: column; gap: .4rem; }
.codici code { margin: 0 .3rem; }
.nota { color: var(--p-text-muted-color); }
.piccola { font-size: .8rem; margin: .75rem 0 0; }
.attenzione { color: var(--p-orange-600); }
.esito { margin-bottom: .75rem; }
.esito ul { margin: .3rem 0 0; padding-left: 1.2rem; }
</style>
