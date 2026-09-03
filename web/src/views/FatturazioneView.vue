<script setup>
// Fatturazione a consuntivo per tipo di vendita (ANCI, ALIA): erano step
// dello schedulatore, ora si lanciano da qui. Il profilo arriva dalla voce di
// menu; quali report e quali allegati li decide l'API per profilo, la pagina
// li legge dallo stato. La data fattura e' il primo del mese corrente e la
// fattura copre quello che sta prima. La pagina mostra chi e' da fatturare e
// le fatture gia' fatte per quella data, poi esegue: FATT_TIPO_Genera per le
// fatture, e per ognuna gli Excel e la mail di prefattura con gli allegati.
//
// Le prove non arrivano ai clienti: con "manda tutto a" le mail vanno solo a
// quell'indirizzo, coi destinatari veri scritti nel testo.
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { useAuthStore } from '../stores/auth'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Checkbox from 'primevue/checkbox'
import InputText from 'primevue/inputtext'
import DatePicker from 'primevue/datepicker'
import Dialog from 'primevue/dialog'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import ProgressSpinner from 'primevue/progressspinner'

const props = defineProps({ profilo: { type: String, default: 'anci' } })
const base = () => `/fatturazione/${props.profilo}`

const toast = useToast()
const auth = useAuthStore()

const oggi = new Date()
const dataFattura = ref(new Date(oggi.getFullYear(), oggi.getMonth(), 1))
const stato = ref(null)           // risposta di /stato
const caricamento = ref(false)
const esecuzione = ref(false)
const esito = ref(null)           // risposta di /esegui
const errore = ref('')

const genera = ref(true)
const inviaMail = ref(false)
const destinatarioProva = ref('')
const selezionate = ref([])       // fatture gia' esistenti da rifare/rimandare
const conferma = ref(false)

const iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`
const dataIt = s => s ? new Date(s).toLocaleDateString('it-IT') : ''
const euro = n => Number(n ?? 0).toLocaleString('it-IT', { style: 'currency', currency: 'EUR' })

async function aggiorna() {
  caricamento.value = true
  errore.value = ''
  esito.value = null
  try {
    const { data } = await api.get(`${base()}/stato`, { params: { dataFattura: iso(dataFattura.value) } })
    stato.value = data
    genera.value = data.daFatturare.length > 0
    selezionate.value = []
    previsione.value = null        // vale per la data di prima: si ricalcola
    espanse.value = []
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dello stato'
  } finally {
    caricamento.value = false
  }
}
onMounted(aggiorna)

// cosa fara' davvero l'esecuzione: serve per il riepilogo prima di confermare
const piano = computed(() => {
  if (!stato.value) return null
  const nuove = genera.value ? stato.value.daFatturare.length : 0
  const rifatte = selezionate.value.length
  const prova = destinatarioProva.value.trim()
  return {
    nuove, rifatte,
    mail: inviaMail.value,
    prova,
    reale: inviaMail.value && !prova,
    niente: nuove === 0 && rifatte === 0
  }
})

async function esegui() {
  conferma.value = false
  esecuzione.value = true
  errore.value = ''
  try {
    const { data } = await api.post(`${base()}/esegui`, {
      dataFattura: iso(dataFattura.value),
      genera: genera.value,
      inviaMail: inviaMail.value,
      destinatarioProva: destinatarioProva.value.trim() || null,
      // le fatture scelte fra quelle esistenti, piu' quelle nuove (che l'API
      // aggiunge da sola quando genera)
      idFatture: selezionate.value.length && !genera.value
        ? selezionate.value.map(f => f.idFattura) : null
    })
    esito.value = data
    for (const a of data.avvisi ?? []) toast.add({ severity: 'warn', summary: 'Attenzione', detail: a, life: 8000 })
    // ricarica lo stato senza perdere l'esito
    const s = await api.get(`${base()}/stato`, { params: { dataFattura: iso(dataFattura.value) } })
    stato.value = s.data
    selezionate.value = []
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nell\'esecuzione'
  } finally {
    esecuzione.value = false
  }
}

// Previsione: quanto verrebbe fatturato oggi, senza fatturare. L'API esegue
// davvero FATT_Genera e annulla, quindi pezzi, importo e voci sono quelli veri.
const previsione = ref(null)
const calcolando = ref(false)
const espanse = ref([])
async function calcolaPrevisione() {
  calcolando.value = true
  try {
    const { data } = await api.get(`${base()}/previsione`, { params: { dataFattura: iso(dataFattura.value) } })
    previsione.value = data
    espanse.value = data.clienti.filter(c => c.voci.length)
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Previsione', detail: e.response?.data?.errore ?? 'Errore nel calcolo', life: 5000 })
  } finally {
    calcolando.value = false
  }
}
const stimaDi = idCliente => previsione.value?.clienti.find(c => c.idCliente === idCliente)

// una fattura gia' fatta: rifare i file, o rifarli e rimandare la mail
async function rilancia(fattura, conMail) {
  esecuzione.value = true
  try {
    const { data } = await api.post(`${base()}/esegui`, {
      dataFattura: iso(dataFattura.value), genera: false, inviaMail: conMail,
      destinatarioProva: destinatarioProva.value.trim() || null,
      idFatture: [fattura.idFattura]
    })
    esito.value = data
    const x = data.esiti[0]
    toast.add({
      severity: x?.erroreFile || x?.mail?.errore ? 'warn' : 'success',
      summary: `Fattura n.${fattura.numero}`,
      detail: x?.erroreFile ? x.erroreFile : conMail ? (x?.mail?.inviata ? `mail inviata a ${x.mail.a}` : (x?.mail?.errore ?? 'mail non inviata')) : `${x?.file?.length ?? 0} file rifatti`,
      life: 6000
    })
    const s = await api.get(`${base()}/stato`, { params: { dataFattura: iso(dataFattura.value) } })
    stato.value = s.data
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Fattura', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    esecuzione.value = false
  }
}

// i file si scaricano passando dall'API (un link diretto non porterebbe il token)
async function scarica(nome) {
  try {
    const { data } = await api.get(`${base()}/file`, { params: { nome }, responseType: 'blob' })
    const a = document.createElement('a')
    a.href = URL.createObjectURL(data)
    a.download = nome
    a.click()
    URL.revokeObjectURL(a.href)
  } catch {
    toast.add({ severity: 'error', summary: 'File', detail: `${nome} non disponibile`, life: 4000 })
  }
}

function mettiMiaMail() { destinatarioProva.value = auth.utente?.email ?? auth.utente?.Email ?? '' }
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">{{ stato?.titolo ?? 'Fatturazione' }}</h2>
    <p class="sotto">
      Fattura a consuntivo: la fattura del <b>{{ dataFattura.toLocaleDateString('it-IT') }}</b>
      copre le attività fino al giorno prima.
      <template v-if="stato">
        Per ogni fattura: dettaglio{{ stato.riepilogo ? ', voci' : '' }} e ripartizione CDC in Excel,
        e la mail di prefattura con {{ stato.allegati.join(' e ').replace('VociFattura', 'voci').replace('RipartizioneCDC', 'ripartizione CDC').replace('Dettaglio', 'dettaglio') }} in allegato.
      </template>
    </p>

    <div class="barra">
      <label>Data fattura
        <DatePicker v-model="dataFattura" dateFormat="dd/mm/yy" view="month" showIcon />
      </label>
      <Button label="Aggiorna" icon="pi pi-refresh" text :loading="caricamento" @click="aggiorna" />
      <span v-if="stato" class="cartella">file in <code>{{ stato.cartella }}</code></span>
    </div>

    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>
    <!-- es. la cartella configurata non e' scrivibile: i file finiscono altrove -->
    <Message v-for="(a, i) in stato?.avvisi ?? []" :key="i" severity="warn" :closable="false">{{ a }}</Message>
    <div v-if="caricamento" class="centro"><ProgressSpinner /></div>

    <template v-if="stato && !caricamento">
      <!-- chi e' ancora da fatturare, con la previsione di quanto verrebbe fatturato -->
      <section>
        <h3>
          Da fatturare <Tag :value="String(stato.daFatturare.length)" :severity="stato.daFatturare.length ? 'warn' : 'success'" />
          <Button v-if="stato.daFatturare.length" label="Calcola previsione" icon="pi pi-calculator" size="small" outlined
            :loading="calcolando" @click="calcolaPrevisione" />
          <span v-if="previsione" class="nota">
            {{ previsione.totalePezzi }} pezzi, {{ euro(previsione.totaleImporto) }} in tutto
          </span>
        </h3>
        <DataTable v-if="stato.daFatturare.length" :value="stato.daFatturare" size="small" stripedRows
          v-model:expandedRows="espanse" dataKey="IdCliente">
          <Column v-if="previsione" expander style="width: 3rem" />
          <Column field="IdCliente" header="Cliente" style="width: 6rem" />
          <Column field="RagioneSociale" header="Ragione sociale" />
          <Column v-if="previsione" header="Pezzi previsti" style="width: 8rem">
            <template #body="{ data }">{{ stimaDi(data.IdCliente)?.pezzi ?? '—' }}</template>
          </Column>
          <Column v-if="previsione" header="Importo previsto" style="width: 9rem">
            <template #body="{ data }">
              <span v-if="stimaDi(data.IdCliente)?.errore" class="errore">{{ stimaDi(data.IdCliente).errore }}</span>
              <b v-else>{{ euro(stimaDi(data.IdCliente)?.importo) }}</b>
            </template>
          </Column>
          <Column field="EmailPrefattura" header="Prefattura a" />
          <template #expansion="{ data }">
            <!-- le voci della fattura che uscirebbe, come nel report VociFattura -->
            <DataTable :value="stimaDi(data.IdCliente)?.voci ?? []" size="small" class="voci">
              <Column field="descrizione" header="Voce" />
              <Column field="numPezzi" header="Pezzi" style="width: 6rem" />
              <Column header="Prezzo" style="width: 7rem"><template #body="{ data: v }">{{ euro(v.prezzoUnitario) }}</template></Column>
              <Column header="Totale" style="width: 8rem"><template #body="{ data: v }">{{ euro(v.totale) }}</template></Column>
            </DataTable>
          </template>
        </DataTable>
        <p v-else class="vuoto">Nessun cliente da fatturare per questa data.</p>
        <small v-if="previsione && previsione.totalePezzi === 0" class="nota">
          Zero pezzi per tutti: questi clienti si fatturano sugli esiti di rendicontazione non ancora fatturati,
          e oggi non ce ne sono. Di solito vuol dire che i rendiconti del mese non sono ancora stati caricati.
        </small>
      </section>

      <!-- le fatture gia' fatte -->
      <section>
        <h3>Fatture del {{ dataIt(stato.dataFattura) }} <Tag :value="String(stato.fatture.length)" severity="info" /></h3>
        <DataTable v-if="stato.fatture.length" :value="stato.fatture" v-model:selection="selezionate"
          dataKey="idFattura" size="small" stripedRows>
          <Column selectionMode="multiple" style="width: 3rem" />
          <Column field="numero" header="N." style="width: 5rem" />
          <Column field="ragioneSociale" header="Cliente" />
          <Column field="pezzi" header="Pezzi" style="width: 6rem" />
          <Column header="Importo" style="width: 8rem">
            <template #body="{ data }">{{ euro(data.importo) }}</template>
          </Column>
          <Column header="File">
            <template #body="{ data }">
              <Button v-for="n in data.file" :key="n" :label="n.replace(data.file[0].split('_').slice(0, 4).join('_') + '_', '')"
                icon="pi pi-file-excel" text size="small" @click="scarica(n)" />
              <span v-if="!data.file.length" class="vuoto">nessun file</span>
            </template>
          </Column>
          <Column header="" style="width: 15rem">
            <template #body="{ data }">
              <!-- per una fattura gia' fatta: rifare i file, o rifarli e rimandare la mail -->
              <Button label="Rifai i file" icon="pi pi-refresh" text size="small" :disabled="esecuzione" @click="rilancia(data, false)" />
              <Button label="Reinvia mail" icon="pi pi-send" text size="small" :disabled="esecuzione" @click="rilancia(data, true)" />
            </template>
          </Column>
        </DataTable>
        <p v-else class="vuoto">Nessuna fattura per questa data.</p>
        <small v-if="stato.fatture.length" class="nota">
          I file si scaricano cliccandoli. "Reinvia mail" rispetta la casella "manda tutto a": vuota = ai destinatari veri.
        </small>
      </section>

      <!-- cosa fare -->
      <section class="opzioni">
        <label><Checkbox v-model="genera" binary /> Genera le fatture mancanti ({{ stato.daFatturare.length }})</label>
        <label><Checkbox v-model="inviaMail" binary /> Invia le mail di prefattura</label>
        <label class="prova">
          manda tutto a (prova)
          <InputText v-model="destinatarioProva" placeholder="vuoto = ai destinatari veri" size="small" />
          <Button label="la mia" text size="small" @click="mettiMiaMail" />
        </label>
        <Button label="Esegui" icon="pi pi-play" severity="success"
          :disabled="!piano || piano.niente" :loading="esecuzione" @click="conferma = true" />
      </section>

      <!-- esito -->
      <section v-if="esito">
        <h3>Esito</h3>
        <Message v-if="!esito.esiti.length" severity="info" :closable="false">Nessuna fattura da lavorare.</Message>
        <DataTable v-else :value="esito.esiti" size="small" stripedRows>
          <Column field="numero" header="N." style="width: 5rem" />
          <Column field="ragioneSociale" header="Cliente" />
          <Column field="pezzi" header="Pezzi" style="width: 6rem" />
          <Column header="Importo" style="width: 8rem">
            <template #body="{ data }">{{ euro(data.importo) }}</template>
          </Column>
          <Column header="Fattura" style="width: 7rem">
            <template #body="{ data }">
              <Tag :value="data.generataOra ? 'nuova' : 'esistente'" :severity="data.generataOra ? 'success' : 'secondary'" />
            </template>
          </Column>
          <Column header="File">
            <template #body="{ data }">
              <span v-if="data.erroreFile" class="errore">{{ data.erroreFile }}</span>
              <Button v-for="n in data.file" :key="n" :label="n.split('_').slice(4).join('_')"
                icon="pi pi-file-excel" text size="small" @click="scarica(n)" />
            </template>
          </Column>
          <Column header="Mail">
            <template #body="{ data }">
              <span v-if="data.mail.inviata"><i class="pi pi-check ok"></i> a {{ data.mail.a }}</span>
              <span v-else-if="data.mail.errore" class="errore">{{ data.mail.errore }}</span>
              <span v-else class="vuoto">non inviata</span>
            </template>
          </Column>
        </DataTable>
      </section>
    </template>

    <!-- riepilogo prima di partire: qui si vede se le mail andranno ai clienti -->
    <Dialog v-model:visible="conferma" modal header="Conferma esecuzione" :style="{ width: '32rem' }">
      <ul v-if="piano" class="riepilogo">
        <li>Data fattura <b>{{ dataFattura.toLocaleDateString('it-IT') }}</b></li>
        <li v-if="piano.nuove">Genera <b>{{ piano.nuove }}</b> fatture nuove</li>
        <li v-if="piano.rifatte">Rifà i file di <b>{{ piano.rifatte }}</b> fatture esistenti</li>
        <li v-if="!piano.mail">Nessuna mail</li>
        <li v-else-if="piano.prova">Mail <b>solo a {{ piano.prova }}</b> (prova)</li>
        <li v-else class="errore"><b>Mail ai clienti</b>, agli indirizzi di prefattura</li>
      </ul>
      <template #footer>
        <Button label="Annulla" text @click="conferma = false" />
        <Button :label="piano?.reale ? 'Esegui e invia ai clienti' : 'Esegui'" :severity="piano?.reale ? 'danger' : 'success'"
          icon="pi pi-play" @click="esegui" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 1rem; }
.titolo { margin: 0; }
.sotto { margin: 0; color: var(--p-text-muted-color); }
.barra { display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
.barra label { display: flex; align-items: center; gap: .5rem; }
.cartella { color: var(--p-text-muted-color); font-size: .85rem; }
section h3 { margin: 0 0 .5rem; display: flex; align-items: center; gap: .5rem; }
.opzioni { display: flex; align-items: center; gap: 1.5rem; flex-wrap: wrap; padding: .75rem 1rem;
  border: 1px solid var(--p-content-border-color); border-radius: 8px; }
.opzioni label { display: flex; align-items: center; gap: .5rem; }
.prova { color: var(--p-text-muted-color); }
.vuoto { color: var(--p-text-muted-color); }
.nota { color: var(--p-text-muted-color); }
.errore { color: var(--p-red-600); }
.ok { color: var(--p-green-600); margin-right: .3rem; }
.centro { display: flex; justify-content: center; padding: 2rem; }
.riepilogo { margin: 0; padding-left: 1.2rem; line-height: 1.8; }
</style>
