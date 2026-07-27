<script setup>
import { ref, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Select from 'primevue/select'
import AutoComplete from 'primevue/autocomplete'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Dialog from 'primevue/dialog'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Gruppi: replica della videata legacy InDe. A sinistra l'elenco dei gruppi,
// a destra — per il gruppo selezionato — le RADICI di menu collegate
// (MENU_ELEMENTIGRUPPI: decidono cosa vedono gli utenti del gruppo) e gli
// UTENTI relazionati (UTENTI_GRUPPI), entrambe modificabili.

const toast = useToast()
const errore = ref('')
const gruppi = ref([])
const caricamento = ref(false)

const gruppo = ref(null)          // testata del gruppo aperto
const nomeGruppo = ref('')
const menuCollegati = ref([])
const utentiCollegati = ref([])
const radiciDisponibili = ref([])
const radiceDaAggiungere = ref(null)
const utenteDaAggiungere = ref(null)
const sugUtenti = ref([])
const salvandoNome = ref(false)

const nuovoVisibile = ref(false)
const nuovoNome = ref('')

async function caricaGruppi() {
  caricamento.value = true
  try {
    const { data } = await api.get('/gruppi')
    gruppi.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei gruppi'
  } finally {
    caricamento.value = false
  }
}
onMounted(caricaGruppi)

async function apri(g) {
  try {
    const { data } = await api.get(`/gruppi/${g.IdGruppo}`)
    gruppo.value = data.gruppo
    nomeGruppo.value = data.gruppo.Gruppo
    menuCollegati.value = data.menu
    utentiCollegati.value = data.utenti
    radiciDisponibili.value = data.radiciDisponibili
    radiceDaAggiungere.value = null
    utenteDaAggiungere.value = null
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Gruppo', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  }
}
async function ricarica() {
  await apri({ IdGruppo: gruppo.value.IdGruppo })
  await caricaGruppi()
}

async function salvaNome() {
  if (!nomeGruppo.value.trim()) return
  salvandoNome.value = true
  try {
    await api.post('/config/gruppi', { IdGruppo: gruppo.value.IdGruppo, Gruppo: nomeGruppo.value.trim() })
    toast.add({ severity: 'success', summary: 'Gruppo rinominato', life: 2000 })
    await ricarica()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Gruppo', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    salvandoNome.value = false
  }
}

async function creaGruppo() {
  if (!nuovoNome.value.trim()) return
  try {
    const { data } = await api.post('/config/gruppi', { Gruppo: nuovoNome.value.trim() })
    nuovoVisibile.value = false
    nuovoNome.value = ''
    await caricaGruppi()
    if (data.id) await apri({ IdGruppo: data.id })
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Nuovo gruppo', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  }
}

// --- radici di menu collegate ---
async function aggiungiRadice() {
  if (!radiceDaAggiungere.value) return
  try {
    await api.post(`/gruppi/${gruppo.value.IdGruppo}/menu`, { idMenu: radiceDaAggiungere.value.idMenu })
    await ricarica()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Menu', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  }
}
async function rimuoviRadice(riga) {
  try {
    await api.delete(`/gruppi/menu/${riga.id}`)
    await ricarica()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Menu', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  }
}

// --- utenti relazionati ---
async function cercaUtenti(ev) {
  try {
    const { data } = await api.get('/utenti', { params: { q: ev.query, size: 15 } })
    const collegati = new Set(utentiCollegati.value.map(u => u.idUtente))
    sugUtenti.value = data.rows.filter(u => !collegati.has(u.IdUtente))
  } catch { sugUtenti.value = [] }
}
async function aggiungiUtente(u) {
  utenteDaAggiungere.value = null
  try {
    await api.post(`/gruppi/${gruppo.value.IdGruppo}/utenti`, { idUtente: u.IdUtente })
    await ricarica()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Utenti', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  }
}
async function rimuoviUtente(riga) {
  try {
    await api.delete(`/gruppi/utenti/${riga.id}`)
    await ricarica()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Utenti', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  }
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Gruppi</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="colonne">
      <!-- elenco gruppi -->
      <section class="card">
        <div class="card-titolo">Gruppi
          <Button icon="pi pi-plus" label="Nuovo" size="small" text class="btn-testata"
            @click="nuovoVisibile = true" />
        </div>
        <DataTable :value="gruppi" size="small" stripedRows :loading="caricamento" :rowHover="true"
          scrollable scrollHeight="calc(100vh - 220px)" @row-click="e => apri(e.data)" class="tab-gruppi"
          :rowClass="r => r.IdGruppo === gruppo?.IdGruppo ? 'riga-attiva' : ''">
          <Column field="Gruppo" header="Gruppo" />
          <Column field="nMenu" header="Menu" style="width: 4.5rem" />
          <Column field="nUtenti" header="Utenti" style="width: 4.5rem" />
        </DataTable>
      </section>

      <!-- dettaglio del gruppo -->
      <div class="dettaglio" v-if="gruppo">
        <section class="card">
          <div class="card-titolo">Gruppo #{{ gruppo.IdGruppo }}</div>
          <div class="corpo riga-nome">
            <InputText v-model="nomeGruppo" fluid maxlength="50" @keyup.enter="salvaNome" />
            <Button label="Rinomina" icon="pi pi-check" outlined :loading="salvandoNome"
              :disabled="!nomeGruppo.trim() || nomeGruppo.trim() === gruppo.Gruppo" @click="salvaNome" />
          </div>
        </section>

        <section class="card">
          <div class="card-titolo">Radici di menu collegate
            <span class="conteggio">{{ menuCollegati.length }}</span>
          </div>
          <div class="corpo">
            <div class="riga-aggiungi">
              <Select v-model="radiceDaAggiungere" :options="radiciDisponibili" optionLabel="testo"
                filter showClear fluid placeholder="— aggiungi una radice di menu —" />
              <Button label="Aggiungi" icon="pi pi-plus" :disabled="!radiceDaAggiungere" @click="aggiungiRadice" />
            </div>
            <ul class="lista">
              <li v-for="m in menuCollegati" :key="m.id">
                <span>{{ m.testo ?? `#${m.idMenu}` }}</span>
                <Button icon="pi pi-trash" text severity="danger" size="small" @click="rimuoviRadice(m)" />
              </li>
              <li v-if="!menuCollegati.length" class="vuota">Nessuna radice collegata.</li>
            </ul>
          </div>
        </section>

        <section class="card">
          <div class="card-titolo">Utenti relazionati
            <span class="conteggio">{{ utentiCollegati.length }}</span>
          </div>
          <div class="corpo">
            <AutoComplete v-model="utenteDaAggiungere" :suggestions="sugUtenti" optionLabel="Utente" fluid
              placeholder="cerca un utente da aggiungere (nome, login, email)"
              @complete="cercaUtenti" @option-select="ev => aggiungiUtente(ev.value)">
              <template #option="{ option }">
                <div class="opt-utente"><b>{{ option.Utente }}</b>
                  <small>{{ option.Nome }} {{ option.Attivo ? '' : '· cessato' }}</small>
                </div>
              </template>
            </AutoComplete>
            <ul class="lista">
              <li v-for="u in utentiCollegati" :key="u.id">
                <span>
                  <b>{{ u.utente ?? `#${u.idUtente}` }}</b>
                  <small class="muto"> {{ u.nome }}</small>
                  <Tag v-if="u.attivo === false" severity="warn" value="cessato" class="tag-cessato" />
                </span>
                <Button icon="pi pi-trash" text severity="danger" size="small" @click="rimuoviUtente(u)" />
              </li>
              <li v-if="!utentiCollegati.length" class="vuota">Nessun utente relazionato.</li>
            </ul>
          </div>
        </section>
      </div>

      <div class="dettaglio vuoto" v-else>
        <Tag value="Seleziona un gruppo dall'elenco" severity="secondary" />
      </div>
    </div>

    <Dialog v-model:visible="nuovoVisibile" header="Nuovo gruppo" modal :style="{ width: '26rem' }">
      <InputText v-model="nuovoNome" fluid maxlength="50" autofocus placeholder="nome del gruppo"
        @keyup.enter="creaGruppo" />
      <template #footer>
        <Button label="Annulla" text @click="nuovoVisibile = false" />
        <Button label="Crea" icon="pi pi-check" :disabled="!nuovoNome.trim()" @click="creaGruppo" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1200px; }
.titolo { margin: 0; }
.colonne { display: grid; grid-template-columns: minmax(20rem, 26rem) 1fr; gap: 1rem; align-items: start; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center;
}
.btn-testata { color: #fff; }
.conteggio { font-size: .8rem; font-weight: 400; opacity: .9; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .7rem; }
.riga-nome { flex-direction: row; }
.riga-nome > :first-child { flex: 1; }
.riga-aggiungi { display: flex; gap: .5rem; }
.riga-aggiungi > :first-child { flex: 1; }
.dettaglio { display: flex; flex-direction: column; gap: .9rem; }
.dettaglio.vuoto { align-items: center; padding-top: 3rem; }
.tab-gruppi :deep(.p-datatable-tbody > tr) { cursor: pointer; }
.tab-gruppi :deep(.riga-attiva) { background: var(--p-highlight-background) !important; }
.lista { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; }
.lista li {
  display: flex; justify-content: space-between; align-items: center;
  padding: .15rem .3rem; border-bottom: 1px solid var(--p-surface-100);
}
.lista li:last-child { border-bottom: 0; }
.lista .vuota { color: var(--p-text-muted-color); font-size: .85rem; }
.muto { color: var(--p-text-muted-color); }
.tag-cessato { margin-left: .4rem; }
.opt-utente { display: flex; flex-direction: column; }
.opt-utente small { color: var(--p-text-muted-color); }
</style>
