<script setup>
import { onMounted, computed, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { useToast } from 'primevue/usetoast'
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
import ClientiView from '../views/ClientiView.vue'

const auth = useAuthStore()
const nav = useNavStore()
const router = useRouter()
const toast = useToast()

const filtro = ref('')
const expandedKeys = ref({})
const sidebarAperta = ref(true)

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

function naviga(voce) {
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
        :icon="sidebarAperta ? 'pi pi-angle-double-left' : 'pi pi-bars'"
        text rounded severity="contrast"
        :title="sidebarAperta ? 'Nascondi menu' : 'Mostra menu'"
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
        <ClientiView
          v-else-if="nav.corrente.tipo === 'clienti'"
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
</style>
