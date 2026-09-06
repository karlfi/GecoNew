<script setup>
// SIM aziendali: l'elenco con i filtri, la scheda (anagrafica, variazioni di
// piano/stato, rilevazioni di consumo dal portale Wind) e l'import degli Excel
// dell'operatore, che aggiorna i profili e registra ogni variazione.
import { ref, computed, onMounted, watch } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'
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
const errore = e => toast.add({ severity: 'error', summary: 'Errore', detail: messaggioErrore(e), life: 6000 })

// --- elenco e filtri ---
const sim = ref([])
const lookup = ref({ stati: [], statiPresenti: [], piani: [], prodotti: [], filiali: [], totale: 0, ultimaRilevazione: null })
const filtri = ref({ testo: '', stato: null, idFiliale: null, piano: null })
const caricamento = ref(false)
let timer = null
async function caricaLookup() {
  try { lookup.value = (await api.get('/sim/lookup')).data } catch (e) { errore(e) }
}
async function carica() {
  caricamento.value = true
  try {
    const { data } = await api.get('/sim', { params: { testo: filtri.value.testo || null, stato: filtri.value.stato, idFiliale: filtri.value.idFiliale, piano: filtri.value.piano } })
    sim.value = data
  } catch (e) { errore(e) } finally { caricamento.value = false }
}
watch(() => filtri.value.testo, () => { clearTimeout(timer); timer = setTimeout(carica, 350) })
watch(() => [filtri.value.stato, filtri.value.idFiliale, filtri.value.piano], carica)
onMounted(async () => { await caricaLookup(); await carica() })

const dataIt = v => v ? new Date(v).toLocaleDateString('it-IT') : ''
const dataOra = v => v ? new Date(v).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' }) : ''
const euro = v => v == null ? '' : Number(v).toLocaleString('it-IT', { style: 'currency', currency: 'EUR' })
const gb = v => v == null ? '' : Number(v).toLocaleString('it-IT', { maximumFractionDigits: 2 })
const severitaStato = s => ({ Attiva: 'success', Sospesa: 'warn', Cessata: 'danger' }[s] ?? 'secondary')
const severitaPerc = p => p == null ? 'secondary' : p <= 10 ? 'danger' : p <= 25 ? 'warn' : 'success'
const riepilogo = computed(() => {
  const perStato = {}
  for (const s of sim.value) perStato[s.Stato] = (perStato[s.Stato] ?? 0) + 1
  return perStato
})

// --- scheda ---
const dialog = ref(false)
const scheda = ref(null)      // la SIM letta dall'API (con variazioni e rilevazioni)
const edit = ref({})
const linguetta = ref('anag')
const salvataggio = ref(false)
const dipendenteScelto = ref(null)
const suggerimenti = ref([])
function vuota() {
  return { IdSim: null, Numero: '', ICCID: '', Operatore: 'WINDTRE', Prodotto: '', Stato: 'Attiva', DataAttivazione: null, DataCessazione: null,
           PianoTariffario: '', IdFiliale: null, IdUtente: null, AssegnataA: '', Palmare: '', SerialePalmare: '', Note: '', NotaVariazione: '' }
}
async function apri(riga) {
  linguetta.value = 'anag'
  if (!riga) {
    scheda.value = null; edit.value = vuota(); dipendenteScelto.value = null; dialog.value = true; return
  }
  try {
    const { data } = await api.get(`/sim/${riga.IdSim}`)
    scheda.value = data
    edit.value = { ...vuota(), ...Object.fromEntries(Object.keys(vuota()).map(k => [k, data[k] ?? (k === 'IdSim' ? null : vuota()[k])])),
                   DataAttivazione: data.DataAttivazione ? new Date(data.DataAttivazione) : null,
                   DataCessazione: data.DataCessazione ? new Date(data.DataCessazione) : null, NotaVariazione: '' }
    dipendenteScelto.value = data.IdUtente ? { IdUtente: data.IdUtente, Nome: data.Dipendente, Matricola: data.Matricola } : null
    dialog.value = true
  } catch (e) { errore(e) }
}
async function cercaDipendenti(ev) {
  try { suggerimenti.value = (await api.get('/sim/dipendenti', { params: { testo: ev.query } })).data } catch { suggerimenti.value = [] }
}
const iso = d => d instanceof Date ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` : (d || null)
async function salva() {
  if (!edit.value.Numero?.trim()) { toast.add({ severity: 'warn', summary: 'Il numero è obbligatorio', life: 3000 }); return }
  salvataggio.value = true
  try {
    const corpo = { ...edit.value, IdUtente: dipendenteScelto.value?.IdUtente ?? null,
                    DataAttivazione: iso(edit.value.DataAttivazione), DataCessazione: iso(edit.value.DataCessazione) }
    const { data } = await api.post('/sim', corpo)
    toast.add({ severity: 'success', summary: edit.value.IdSim ? 'SIM salvata' : 'SIM creata', life: 2500 })
    await carica(); await caricaLookup()
    await apri({ IdSim: data.idSim })
  } catch (e) { errore(e) } finally { salvataggio.value = false }
}
const conferma = ref({ visibile: false, testo: '', azione: null })
const chiedi = (testo, azione) => { conferma.value = { visibile: true, testo, azione } }
async function confermato() { const a = conferma.value.azione; conferma.value.visibile = false; if (a) await a() }
const elimina = () => chiedi(`Eliminare la SIM ${edit.value.Numero} con le sue variazioni e rilevazioni? Se è solo dismessa, meglio metterla "Cessata".`, async () => {
  try {
    await api.delete(`/sim/${edit.value.IdSim}`)
    toast.add({ severity: 'info', summary: 'SIM eliminata', life: 2500 })
    dialog.value = false; await carica(); await caricaLookup()
  } catch (e) { errore(e) }
})

// --- import Excel ---
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
    for (const f of files) {
      const { data } = await api.post('/sim/import', { nome: f.name, base64: await fileBase64(f) })
      esiti.push(data)
    }
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
        <h2 class="titolo">SIM aziendali</h2>
        <p class="sotto">
          {{ lookup.totale }} SIM in anagrafica<template v-if="lookup.ultimaRilevazione">, ultima rilevazione Wind del {{ dataIt(lookup.ultimaRilevazione) }}</template>.
          L'import degli Excel dell'operatore aggiorna piani e stati e registra ogni variazione.
        </p>
      </div>
      <div class="barra">
        <Button label="Nuova SIM" icon="pi pi-plus" @click="apri(null)" />
        <Button label="Importa Excel Wind" icon="pi pi-upload" outlined :loading="importazione" @click="inputFile.click()" />
        <input ref="inputFile" type="file" multiple accept=".xlsx" hidden @change="importa" />
        <Button icon="pi pi-refresh" text :loading="caricamento" title="Aggiorna" @click="carica" />
      </div>
    </div>

    <div class="filtri">
      <InputText v-model="filtri.testo" placeholder="numero, ICCID, dipendente, palmare, note…" class="cerca" />
      <Select v-model="filtri.stato" :options="lookup.statiPresenti" placeholder="tutti gli stati" showClear />
      <Select v-model="filtri.idFiliale" :options="lookup.filiali" optionLabel="Filiale" optionValue="IdFiliale" placeholder="tutte le filiali" showClear filter />
      <Select v-model="filtri.piano" :options="lookup.piani" placeholder="tutti i piani" showClear />
      <span class="nota">{{ sim.length }} SIM<template v-for="(n, s) in riepilogo" :key="s"> · {{ s }} {{ n }}</template></span>
    </div>

    <DataTable :value="sim" size="small" stripedRows paginator :rows="25" :rowsPerPageOptions="[25, 50, 100, 500]"
      selectionMode="single" dataKey="IdSim" @row-click="e => apri(e.data)" class="elenco" :loading="caricamento"
      sortField="Numero" :sortOrder="1" removableSort>
      <Column field="Numero" header="Numero" sortable style="width: 8rem"><template #body="{ data }"><b>{{ data.Numero }}</b></template></Column>
      <Column field="Stato" header="Stato" sortable style="width: 6rem"><template #body="{ data }"><Tag :value="data.Stato" :severity="severitaStato(data.Stato)" /></template></Column>
      <Column field="PianoTariffario" header="Piano" sortable />
      <Column field="Prodotto" header="Prodotto" sortable style="width: 10rem" />
      <Column field="DataAttivazione" header="Attivata" sortable style="width: 6.5rem"><template #body="{ data }">{{ dataIt(data.DataAttivazione) }}</template></Column>
      <Column field="Filiale" header="Filiale" sortable />
      <Column header="Assegnata a" sortable sortField="Dipendente"><template #body="{ data }">{{ data.Dipendente || data.AssegnataA || '' }}</template></Column>
      <Column field="Palmare" header="Palmare" sortable style="width: 8rem" />
      <Column header="GB residui" sortable sortField="PercResidua" style="width: 8rem">
        <template #body="{ data }">
          <template v-if="data.UltimaRilevazione">
            <Tag :value="(data.PercResidua ?? 0) + '%'" :severity="severitaPerc(data.PercResidua)" />
            <small class="nota"> {{ gb(data.GbResidui) }}/{{ gb(data.GbSoglia) }}</small>
          </template>
        </template>
      </Column>
      <Column header="Credito" sortable sortField="CreditoResiduo" style="width: 6rem"><template #body="{ data }">{{ euro(data.CreditoResiduo) }}</template></Column>
      <Column header="Rilevata" sortable sortField="UltimaRilevazione" style="width: 6.5rem"><template #body="{ data }">{{ dataIt(data.UltimaRilevazione) }}</template></Column>
      <template #empty><span class="nota">Nessuna SIM: importa l'Excel di Wind o creane una.</span></template>
    </DataTable>

    <!-- scheda -->
    <Dialog v-model:visible="dialog" modal :header="edit.IdSim ? `SIM ${edit.Numero}` : 'Nuova SIM'" :style="{ width: '56rem' }">
      <Tabs v-model:value="linguetta">
        <TabList>
          <Tab value="anag">Anagrafica</Tab>
          <Tab value="var" :disabled="!scheda">Variazioni ({{ scheda?.Variazioni?.length ?? 0 }})</Tab>
          <Tab value="ril" :disabled="!scheda">Rilevazioni ({{ scheda?.Rilevazioni?.length ?? 0 }})</Tab>
        </TabList>
        <TabPanels>
          <TabPanel value="anag">
            <div class="griglia">
              <label>Numero <InputText v-model="edit.Numero" :disabled="!!edit.IdSim && false" /></label>
              <label>ICCID <InputText v-model="edit.ICCID" /></label>
              <label>Operatore <InputText v-model="edit.Operatore" /></label>
              <label>Prodotto <Select v-model="edit.Prodotto" :options="lookup.prodotti" editable placeholder="Mobile / Mobile Ricaricabile" /></label>
              <label>Stato <Select v-model="edit.Stato" :options="lookup.stati" /></label>
              <label>Piano tariffario <Select v-model="edit.PianoTariffario" :options="lookup.piani" editable placeholder="piano" /></label>
              <label>Data attivazione <DatePicker v-model="edit.DataAttivazione" dateFormat="dd/mm/yy" showIcon /></label>
              <label>Data cessazione <DatePicker v-model="edit.DataCessazione" dateFormat="dd/mm/yy" showIcon /></label>
              <label>Filiale <Select v-model="edit.IdFiliale" :options="lookup.filiali" optionLabel="Filiale" optionValue="IdFiliale" showClear filter placeholder="nessuna" /></label>
              <label>Dipendente
                <AutoComplete v-model="dipendenteScelto" :suggestions="suggerimenti" optionLabel="Nome" @complete="cercaDipendenti" dropdown forceSelection placeholder="cerca per nome o matricola">
                  <template #option="{ option }">{{ option.Nome }} <small class="nota">{{ option.Matricola }}</small></template>
                </AutoComplete>
              </label>
              <label>Assegnata a (testo) <InputText v-model="edit.AssegnataA" placeholder="modem, sede, magazzino…" /></label>
              <label>Palmare <InputText v-model="edit.Palmare" /></label>
              <label>Seriale palmare <InputText v-model="edit.SerialePalmare" /></label>
              <label class="larga">Note <Textarea v-model="edit.Note" rows="2" autoResize /></label>
              <label v-if="edit.IdSim" class="larga">Nota per la variazione (se cambi piano o stato) <InputText v-model="edit.NotaVariazione" /></label>
            </div>
            <p v-if="scheda" class="nota piccola">
              Creata il {{ dataOra(scheda.DataCreazione) }}<template v-if="scheda.DataModifica">, modificata il {{ dataOra(scheda.DataModifica) }} da {{ scheda.UtenteModifica }}</template>.
            </p>
          </TabPanel>
          <TabPanel value="var">
            <DataTable :value="scheda?.Variazioni ?? []" size="small" stripedRows>
              <Column header="Data" style="width: 6.5rem"><template #body="{ data }">{{ dataIt(data.Data) }}</template></Column>
              <Column field="PianoTariffario" header="Piano" />
              <Column field="Stato" header="Stato" style="width: 6rem" />
              <Column header="Prima"><template #body="{ data }">{{ [data.PianoPrecedente, data.StatoPrecedente].filter(Boolean).join(' · ') }}</template></Column>
              <Column field="Origine" header="Origine" style="width: 6rem" />
              <Column field="Note" header="Note" />
              <Column field="Utente" header="Chi" style="width: 6rem" />
              <template #empty><span class="nota">Nessuna variazione.</span></template>
            </DataTable>
          </TabPanel>
          <TabPanel value="ril">
            <DataTable :value="scheda?.Rilevazioni ?? []" size="small" stripedRows>
              <Column header="Rilevata" style="width: 6.5rem"><template #body="{ data }">{{ dataIt(data.DataRilevazione) }}</template></Column>
              <Column field="PianoTariffario" header="Piano" />
              <Column field="Stato" header="Stato" style="width: 5rem" />
              <Column header="Credito" style="width: 6rem"><template #body="{ data }">{{ euro(data.CreditoResiduo) }}</template></Column>
              <Column header="GB soglia" style="width: 6rem"><template #body="{ data }">{{ gb(data.GbSoglia) }}</template></Column>
              <Column header="Consumati" style="width: 6rem"><template #body="{ data }">{{ gb(data.GbConsumati) }}</template></Column>
              <Column header="Residui" style="width: 6rem"><template #body="{ data }">{{ gb(data.GbResidui) }}</template></Column>
              <Column header="%" style="width: 5rem"><template #body="{ data }"><Tag :value="(data.PercResidua ?? 0) + '%'" :severity="severitaPerc(data.PercResidua)" /></template></Column>
              <Column field="PeriodoSoglia" header="Periodo" style="width: 7rem" />
              <template #empty><span class="nota">Nessuna rilevazione.</span></template>
            </DataTable>
          </TabPanel>
        </TabPanels>
      </Tabs>
      <template #footer>
        <Button v-if="edit.IdSim" label="Elimina" icon="pi pi-trash" severity="danger" text @click="elimina" />
        <Button label="Chiudi" text @click="dialog = false" />
        <Button :label="edit.IdSim ? 'Salva' : 'Crea'" icon="pi pi-check" :loading="salvataggio" @click="salva" />
      </template>
    </Dialog>

    <!-- esito dell'import -->
    <Dialog v-model:visible="dialogImport" modal header="Import Excel" :style="{ width: '40rem' }">
      <div v-for="(e, i) in esitoImport ?? []" :key="i" class="esito">
        <b>{{ e.file }}</b> — {{ e.righe }} righe
        <span class="nota">({{ e.anagrafica ? 'anagrafica' : '' }}{{ e.anagrafica && e.rilevazione ? ' + ' : '' }}{{ e.rilevazione ? 'rilevazione' : '' }})</span>
        <ul>
          <li>SIM nuove: <b>{{ e.nuove }}</b>, aggiornate (piano/stato/anagrafica): <b>{{ e.aggiornate }}</b>, invariate: {{ e.invariate }}</li>
          <li v-if="e.rilevazione">rilevazioni registrate: <b>{{ e.rilevazioni }}</b></li>
          <li v-if="e.errori.length" class="errore">errori: {{ e.errori.length }}<ul><li v-for="(x, j) in e.errori.slice(0, 10)" :key="j">{{ x }}</li></ul></li>
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
.nota { color: var(--p-text-muted-color); }
.piccola { font-size: .8rem; margin: .75rem 0 0; }
.errore { color: var(--p-red-600); }
.esito { margin-bottom: .75rem; }
.esito ul { margin: .3rem 0 0; padding-left: 1.2rem; }
</style>
