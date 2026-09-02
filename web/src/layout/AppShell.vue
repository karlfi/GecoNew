<script setup>
import { onMounted, computed, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { useAuthStore } from '../stores/auth'
import { useNavStore } from '../stores/nav'
import { buildMenuTree } from '../lib/menuTree'
import { navDaVideata, navDaLink } from '../config/tabelle'
import PanelMenu from 'primevue/panelmenu'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import IconField from 'primevue/iconfield'
import InputIcon from 'primevue/inputicon'
import Message from 'primevue/message'
import Select from 'primevue/select'
import DashboardView from '../views/DashboardView.vue'
import PlaceholderView from '../views/PlaceholderView.vue'
import RisultatoInterrogazioni from '../views/RisultatoInterrogazioni.vue'
import ElencoDipendentiView from '../views/ElencoDipendentiView.vue'
import ConfigTable from '../views/ConfigTable.vue'
import WorkflowView from '../views/WorkflowView.vue'
import InterrogazioniEditor from '../views/InterrogazioniEditor.vue'
import MenuEditor from '../views/MenuEditor.vue'
import UtentiView from '../views/UtentiView.vue'
import AzioniView from '../views/AzioniView.vue'
import TrackingView from '../views/TrackingView.vue'
import AttivitaFilialiView from '../views/AttivitaFilialiView.vue'
import AttivitaDipendentiView from '../views/AttivitaDipendentiView.vue'
import DdtView from '../views/DdtView.vue'
import EseguiComandoView from '../views/EseguiComandoView.vue'
import EsitiView from '../views/EsitiView.vue'
import GiriMappaView from '../views/GiriMappaView.vue'
import ExportHrView from '../views/ExportHrView.vue'
import UnilavView from '../views/UnilavView.vue'
import StoriciView from '../views/StoriciView.vue'
import SpedNuovaView from '../views/SpedNuovaView.vue'
import AccettazioneFileView from '../views/AccettazioneFileView.vue'
import AccettazioneBancoView from '../views/AccettazioneBancoView.vue'
import VideoCodificaView from '../views/VideoCodificaView.vue'
import CheckinLottiView from '../views/CheckinLottiView.vue'
import ScontriniGitaView from '../views/ScontriniGitaView.vue'
import SpedizioniInterneView from '../views/SpedizioniInterneView.vue'
import DistintaRiepilogativaView from '../views/DistintaRiepilogativaView.vue'
import RicercaMultiplaView from '../views/RicercaMultiplaView.vue'
import RicercaParamsView from '../views/RicercaParamsView.vue'
import TrovaDistinteView from '../views/TrovaDistinteView.vue'
import LavoratoDriverView from '../views/LavoratoDriverView.vue'
import ProfiloView from '../views/ProfiloView.vue'
import ScatoleView from '../views/ScatoleView.vue'
import CesteView from '../views/CesteView.vue'
import DipendentiFilialeView from '../views/DipendentiFilialeView.vue'
import PunteggiView from '../views/PunteggiView.vue'
import PickupView from '../views/PickupView.vue'
import GruppiView from '../views/GruppiView.vue'
import PresenzeTsView from '../views/PresenzeTsView.vue'
import ClientiView from '../views/ClientiView.vue'

const auth = useAuthStore()
const nav = useNavStore()
const router = useRouter()
const toast = useToast()

const filtro = ref('')
const expandedKeys = ref({})
// Sotto i 900px (telefoni e tablet stretti) il menu da 300px coprirebbe quasi
// tutta la pagina: li' parte chiuso e si apre sopra il contenuto invece che di
// fianco. Il "come si dispone" lo decide il CSS con una media query, cosi' resta
// giusto anche ridimensionando la finestra; qui si tiene solo aperto/chiuso.
const schermoStretto = () => window.matchMedia('(max-width: 900px)').matches
const sidebarAperta = ref(!schermoStretto())

onMounted(() => {
  if (!auth.menu.length) auth.caricaMenu()
  if (!auth.filiali.length) auth.caricaFiliali()
})

// filiale corrente: dal login, con riserva sull'elenco filiali (per sessioni vecchie)
const filialeCorrente = computed(() => {
  const f = auth.utente?.filiale
  if (f?.nome) return f
  const x = auth.filiali.find(x => x.idFiliale === auth.utente?.idFiliale)
  return x ? { nome: x.filiale, indirizzo: '', comune: '' } : null
})

const filialeSelezionata = computed({
  get: () => auth.utente?.idFiliale ?? null,
  set: v => {
    if (v && v !== auth.utente?.idFiliale) cambiaFiliale(v)
  }
})

async function cambiaFiliale(idFiliale) {
  try {
    await auth.cambiaFiliale(idFiliale)
    nav.ricarica()
    toast.add({
      severity: 'success',
      summary: 'Filiale cambiata',
      detail: auth.utente?.filiale?.nome ?? '',
      life: 2000
    })
  } catch (e) {
    toast.add({
      severity: 'error',
      summary: 'Cambio filiale',
      detail: e.response?.data?.errore ?? 'Errore nel cambio filiale',
      life: 3500
    })
  }
}

// Registra l'apertura su LOG_CALL, la stessa tabella che scrive tweb: si tiene
// la Videata legacy come nome, cosi' le due applicazioni restano confrontabili
// (per le pagine nuove, che una Videata non ce l'hanno, si scrive il Link).
// E' un "manda e dimentica": se il log non passa, la pagina si apre lo stesso.
function tracciaApertura(voce) {
  const videata = (voce.Videata || voce.Link || '').trim()
  if (!videata) return
  api.post('/log/videata', { videata, parametri: voce.Parametri ?? null })
    .catch(() => {})
}

function naviga(voce) {
  if (schermoStretto()) sidebarAperta.value = false   // sul telefono libera subito la pagina
  tracciaApertura(voce)
  if (voce.NavigateUrl) {
    window.open(voce.NavigateUrl, '_blank')
    return
  }
  // routing primario: dal campo Link (mappatura esplicita menu -> pagina nuova)
  const dalLink = navDaLink(voce)
  if (dalLink) {
    nav.apriDaMenu(dalLink, voce.ID)
    return
  }
  // fallback per le voci con Link ancora vuoto: risoluzione per Videata
  // (stessa logica delle azioni "paginaN#" delle interrogazioni)
  nav.apriDaMenu(navDaVideata(voce.Videata || String(voce.ID), voce.Parametri ?? ''), voce.ID)
}

const modello = computed(() =>
  buildMenuTree(auth.menu, naviga, filtro.value, nav.idMenuAttivo)
)

// col filtro attivo apro tutte le sezioni che hanno risultati
watch([filtro, modello], ([f]) => {
  if (f.trim()) {
    const aperte = {}
    for (const r of modello.value) aperte[r.key] = true
    expandedKeys.value = aperte
  }
})

function esci() {
  auth.logout()
  router.push('/login')
}

// chiave per rimontare la pagina a ogni navigazione (anche stessa pagina, parametri
// diversi) e a ogni cambio filiale (nav.versione)
const chiavePagina = computed(() =>
  `${nav.versione}#${nav.stack.length}#${JSON.stringify(nav.corrente)}`)
</script>

<template>
  <div class="shell">
    <header class="topbar">
      <Button
        icon="pi pi-bars"
        text rounded severity="contrast"
        :title="sidebarAperta ? 'Nascondi menu' : 'Mostra menu'"
        aria-label="Menu"
        @click="sidebarAperta = !sidebarAperta"
      />
      <span class="brand" @click="nav.vaiHome()">Speedy <b>Web</b></span>
      <span v-if="filialeCorrente" class="filiale-info">
        <span class="filiale-nome">{{ filialeCorrente.nome }}</span>
        <span v-if="filialeCorrente.indirizzo" class="filiale-indirizzo">
          {{ filialeCorrente.indirizzo }}<template v-if="filialeCorrente.comune"> — {{ filialeCorrente.comune }}</template>
        </span>
      </span>
      <span class="spacer" />
      <span class="user">{{ auth.utente?.nome || auth.utente?.utente }}</span>
      <Select
        v-if="auth.filiali.length > 1"
        v-model="filialeSelezionata"
        :options="auth.filiali"
        optionLabel="filiale"
        optionValue="idFiliale"
        size="small"
        filter
        class="filiale-select"
        title="Cambia filiale"
      />
      <Button icon="pi pi-sign-out" text rounded severity="contrast" title="Esci" @click="esci" />
    </header>
    <div class="body">
      <!-- sul telefono il menu copre la pagina: toccando fuori si richiude -->
      <div v-if="sidebarAperta" class="velo" @click="sidebarAperta = false" />
      <aside class="sidebar" :class="{ chiusa: !sidebarAperta }">
        <IconField class="menu-filtro">
          <InputIcon class="pi pi-search" />
          <InputText v-model="filtro" placeholder="Cerca nel menu..." fluid />
        </IconField>
        <Message v-if="auth.menuErrore" severity="warn" :closable="false">
          {{ auth.menuErrore }}
        </Message>
        <PanelMenu
          :model="modello"
          v-model:expandedKeys="expandedKeys"
          multiple
          class="menu-albero"
        />
        <p v-if="!auth.menuErrore && !modello.length" class="menu-vuoto">
          {{ filtro ? 'Nessuna voce trovata' : 'Caricamento menu…' }}
        </p>
      </aside>
      <main class="content">
        <DashboardView v-if="nav.corrente.tipo === 'dashboard'" />
        <RisultatoInterrogazioni
          v-else-if="nav.corrente.tipo === 'interrogazioni'"
          :key="chiavePagina"
          :id-query="nav.corrente.idQuery"
          :s-where="nav.corrente.sWhere"
        />
        <ElencoDipendentiView
          v-else-if="nav.corrente.tipo === 'elenco-dipendenti'"
          :key="chiavePagina"
          :id-query="nav.corrente.idQuery"
          :s-where="nav.corrente.sWhere"
        />
        <ConfigTable
          v-else-if="nav.corrente.tipo === 'config'"
          :key="chiavePagina"
          :config-key="nav.corrente.key"
          :titolo="nav.corrente.titolo"
        />
        <WorkflowView
          v-else-if="nav.corrente.tipo === 'workflow'"
          :key="chiavePagina"
        />
        <InterrogazioniEditor
          v-else-if="nav.corrente.tipo === 'interrogazioni-editor'"
          :key="chiavePagina"
        />
        <MenuEditor
          v-else-if="nav.corrente.tipo === 'menu-editor'"
          :key="chiavePagina"
        />
        <UtentiView
          v-else-if="nav.corrente.tipo === 'utenti'"
          :key="chiavePagina"
        />
        <AzioniView
          v-else-if="nav.corrente.tipo === 'azioni'"
          :key="chiavePagina"
        />
        <TrackingView
          v-else-if="nav.corrente.tipo === 'tracking'"
          :key="chiavePagina"
        />
        <AttivitaFilialiView
          v-else-if="nav.corrente.tipo === 'attivita-filiali'"
          :key="chiavePagina"
        />
        <AttivitaDipendentiView
          v-else-if="nav.corrente.tipo === 'attivita-dipendenti'"
          :key="chiavePagina"
        />
        <DdtView
          v-else-if="nav.corrente.tipo === 'ddt'"
          :key="chiavePagina"
        />
        <EseguiComandoView
          v-else-if="nav.corrente.tipo === 'esegui-comando'"
          :key="chiavePagina"
          :parametri="nav.corrente.parametri"
        />
        <EsitiView
          v-else-if="nav.corrente.tipo === 'esiti'"
          :key="chiavePagina"
          :parametri="nav.corrente.parametri"
        />
        <GiriMappaView
          v-else-if="nav.corrente.tipo === 'giri-mappa'"
          :key="chiavePagina"
        />
        <ExportHrView
          v-else-if="nav.corrente.tipo === 'export-hr'"
          :key="chiavePagina"
        />
        <UnilavView
          v-else-if="nav.corrente.tipo === 'unilav'"
          :key="chiavePagina"
        />
        <StoriciView
          v-else-if="nav.corrente.tipo === 'storici'"
          :key="chiavePagina"
        />
        <SpedNuovaView
          v-else-if="nav.corrente.tipo === 'sped-nuova'"
          :key="chiavePagina"
        />
        <AccettazioneFileView
          v-else-if="nav.corrente.tipo === 'accettazione-file'"
          :key="chiavePagina"
          :parametri="nav.corrente.parametri"
        />
        <AccettazioneBancoView
          v-else-if="nav.corrente.tipo === 'accettazione-banco'"
          :key="chiavePagina"
          :parametri="nav.corrente.parametri"
        />
        <VideoCodificaView
          v-else-if="nav.corrente.tipo === 'videocodifica'"
          :key="chiavePagina"
          :parametri="nav.corrente.parametri"
        />
        <CheckinLottiView
          v-else-if="nav.corrente.tipo === 'checkin'"
          :key="chiavePagina"
          :parametri="nav.corrente.parametri"
        />
        <ScontriniGitaView
          v-else-if="nav.corrente.tipo === 'scontrini-gita'"
          :key="chiavePagina"
        />
        <SpedizioniInterneView
          v-else-if="nav.corrente.tipo === 'sped-interna'"
          :key="chiavePagina"
        />
        <DistintaRiepilogativaView
          v-else-if="nav.corrente.tipo === 'distinta-riepilogativa'"
          :key="chiavePagina"
        />
        <RicercaMultiplaView
          v-else-if="nav.corrente.tipo === 'ricerca-multipla'"
          :key="chiavePagina"
          :id-query="nav.corrente.idQuery"
          :s-where="nav.corrente.sWhere"
        />
        <RicercaParamsView
          v-else-if="nav.corrente.tipo === 'ricerca-params'"
          :key="chiavePagina"
          :id-query="nav.corrente.idQuery"
          :s-where="nav.corrente.sWhere"
        />
        <TrovaDistinteView
          v-else-if="nav.corrente.tipo === 'trova-distinte'"
          :key="chiavePagina"
          :id-query="nav.corrente.idQuery"
          :s-where="nav.corrente.sWhere"
        />
        <LavoratoDriverView
          v-else-if="nav.corrente.tipo === 'lavorato-driver'"
          :key="chiavePagina"
        />
        <ProfiloView
          v-else-if="nav.corrente.tipo === 'profilo'"
          :key="chiavePagina"
        />
        <ScatoleView
          v-else-if="nav.corrente.tipo === 'scatole'"
          :key="chiavePagina"
        />
        <CesteView
          v-else-if="nav.corrente.tipo === 'ceste'"
          :key="chiavePagina"
        />
        <DipendentiFilialeView
          v-else-if="nav.corrente.tipo === 'dipendenti-filiale'"
          :key="chiavePagina"
        />
        <PunteggiView
          v-else-if="nav.corrente.tipo === 'punteggi'"
          :key="chiavePagina"
        />
        <PickupView
          v-else-if="nav.corrente.tipo === 'pickup'"
          :key="chiavePagina"
        />
        <ClientiView
          v-else-if="nav.corrente.tipo === 'clienti'"
          :key="chiavePagina"
        />
        <GruppiView
          v-else-if="nav.corrente.tipo === 'gruppi'"
          :key="chiavePagina"
        />
        <PresenzeTsView
          v-else-if="nav.corrente.tipo === 'presenze-ts'"
          :key="chiavePagina"
        />
        <PlaceholderView
          v-else
          :key="chiavePagina"
          :videata="nav.corrente.videata"
          :parametri="nav.corrente.parametri"
        />
      </main>
    </div>
  </div>
</template>

<style scoped>
.shell {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
}
.topbar {
  display: flex;
  align-items: center;
  gap: 1rem;
  background: #00628f;
  color: #fff;
  padding: .5rem 1rem;
}
.brand {
  font-size: 1.2rem;
  cursor: pointer;
}
.filiale-info {
  display: flex;
  flex-direction: column;
  line-height: 1.2;
  margin-left: .25rem;
  border-left: 1px solid rgba(255, 255, 255, .35);
  padding-left: .75rem;
}
.filiale-nome {
  font-size: .8rem;
  font-weight: 600;
}
.filiale-indirizzo {
  font-size: .7rem;
  opacity: .8;
}
.filiale-select {
  max-width: 260px;
}
.spacer { flex: 1; }
.user {
  font-size: .9rem;
  opacity: .9;
}
.body {
  display: flex;
  flex: 1;
}
.sidebar {
  width: 300px;
  padding: .75rem;
  background: var(--p-surface-50);
  border-right: 1px solid var(--p-surface-200);
  overflow-y: auto;
  height: calc(100vh - 52px);
  display: flex;
  flex-direction: column;
  gap: .75rem;
  transition: width .2s ease, padding .2s ease;
}
/* menu nascosto: collassa a larghezza zero (il contenuto principale si allarga) */
.sidebar.chiusa {
  width: 0;
  min-width: 0;
  padding-left: 0;
  padding-right: 0;
  border-right: none;
  overflow: hidden;
}
.menu-vuoto {
  color: #888;
  font-size: .85rem;
  text-align: center;
}
.content {
  flex: 1;
  padding: 1.25rem;
  overflow-y: auto;
  height: calc(100vh - 52px);
}

/* menu compatto: 35 sezioni devono respirare */
.menu-albero :deep(.p-panelmenu-header-content .p-panelmenu-header-link) {
  padding: .55rem .75rem;
  font-size: .9rem;
}
.menu-albero :deep(.p-panelmenu-item-link) {
  padding: .45rem .75rem;
  font-size: .875rem;
}
.menu-albero :deep(.voce-attiva > .p-panelmenu-item-content) {
  background: var(--p-highlight-background, #e3f2fd);
  border-radius: 6px;
}
.menu-albero :deep(.voce-attiva .p-panelmenu-item-label) {
  color: #00628f;
  font-weight: 600;
}
/* voci non ancora migrate: smorzate, con un pallino davanti */
.menu-albero :deep(.voce-da-migrare .p-panelmenu-item-label) {
  color: #9aa4ad;
}
.menu-albero :deep(.voce-migrata .p-panelmenu-item-link::before) {
  content: '';
  display: inline-block;
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: #29b96e;
  margin-right: .5rem;
  flex: 0 0 auto;
}

/* --- schermi stretti (telefoni, tablet in verticale) ---------------------
   Il menu non sta piu' di fianco: si apre sopra la pagina come un cassetto e
   si richiude scegliendo una voce o toccando fuori. Nella barra in alto
   restano solo le cose indispensabili, altrimenti non ci sta niente. */
/* sul desktop il velo non serve: il menu sta di fianco, non copre niente */
.velo { display: none; }

@media (max-width: 900px) {
  .velo {
    display: block;
    position: fixed;
    inset: 52px 0 0 0;
    background: rgba(0, 0, 0, .35);
    z-index: 20;
  }
  .sidebar {
    position: fixed;
    top: 52px;
    left: 0;
    bottom: 0;
    /* la larghezza resta quella base (300px): l'apertura e' animata da una
       transizione, e con min()/calc() il browser non interpola e il menu
       resterebbe largo zero. Il limite in percentuale lo mette max-width. */
    max-width: 84vw;
    height: auto;
    z-index: 30;
    box-shadow: 4px 0 18px rgba(0, 0, 0, .3);
  }
  .sidebar.chiusa { box-shadow: none; }
  .topbar { gap: .5rem; padding: .5rem; }
  /* indirizzo della filiale e nome utente: sacrificabili, lo spazio serve */
  .filiale-info, .user { display: none; }
  .brand { font-size: 1.05rem; }
  .filiale-select { max-width: 45vw; }
  .content { padding: .75rem; height: calc(100vh - 52px); }
}
</style>
