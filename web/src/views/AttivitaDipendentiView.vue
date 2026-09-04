<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import { useAuthStore } from '../stores/auth'
import api from '../api'
import { frecceCellEdit } from '../lib/frecceGriglia'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import ColumnGroup from 'primevue/columngroup'
import Row from 'primevue/row'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import DatePicker from 'primevue/datepicker'
import Select from 'primevue/select'
import Message from 'primevue/message'

// Attivita Dipendenti: griglia excel-like dei driver della filiale corrente
// per il giorno scelto (UTENTI_ATTIVITA). SOLO update, via SP
// AI_AttivitaDipendenti_Save (che rifiuta le modifiche oltre 15 giorni).
// Login/Logout, targa, km e palmare arrivano dal palmare: non modificabili.

const auth = useAuthStore()
const toast = useToast()
const errore = ref('')
const giorno = ref(new Date())
const righe = ref([])
const presenze = ref([])
const modificabile = ref(false)
const caricamento = ref(false)

// mappa contatori (da V_UtentiAttivita2024): gruppo legacy -> colonna reale.
// cls = colore tenue del gruppo (stessi toni della videata legacy)
const CONTATORI = [
  { gruppo: 'Parcel POSTE', label: 'Consegnato', campo: 'ParamI07', cls: 'g-poste' },
  { gruppo: 'Racc 140', label: 'Cons.', campo: 'ParamI09', cls: 'g-racc' },
  { gruppo: 'Racc 140', label: 'Avvisati', campo: 'ParamI18', cls: 'g-racc' },
  { gruppo: 'Notifiche MOD1', label: 'Consegnato', campo: 'ParamI10', cls: 'g-mod1' },
  { gruppo: 'Notifiche MOD1', label: 'Assente', campo: 'ParamI11', cls: 'g-mod1' },
  { gruppo: 'Notifiche MOD1', label: 'Scon.', campo: 'ParamI12', cls: 'g-mod1' },
  { gruppo: 'Notifiche MOD2', label: 'Consegnato', campo: 'ParamI13', cls: 'g-mod2' },
  { gruppo: 'Notifiche MOD2', label: 'Assente', campo: 'ParamI14', cls: 'g-mod2' },
  { gruppo: 'Notifiche MOD2', label: 'Scon.', campo: 'ParamI15', cls: 'g-mod2' },
  { gruppo: 'AG', label: 'Tutte', campo: 'ParamI16', cls: 'g-ag' },
  { gruppo: 'Parcel EXTRA', label: 'Hermes', campo: 'ParamI05', cls: 'g-extra' },
  { gruppo: 'Parcel EXTRA', label: 'InPost', campo: 'ParamI06', cls: 'g-extra' },
  { gruppo: 'Parcel EXTRA', label: 'iMile', campo: 'ParamI08', cls: 'g-extra' },
  { gruppo: 'Parcel EXTRA', label: 'Folletto', campo: 'ParamI17', cls: 'g-extra' },
  { gruppo: 'Parcel EXTRA', label: 'Gofo', campo: 'ParamI20', cls: 'g-extra' },
  { gruppo: 'Parcel EXTRA', label: 'Altri', campo: 'ParamI04', cls: 'g-extra' },
  { gruppo: 'Parcel SPEEDY', label: 'Consegnato', campo: 'ParamI03', cls: 'g-speedy' },
  { gruppo: 'BackOffice', label: 'M1 Reso', campo: 'ParamB03', cls: 'g-bko' },
  { gruppo: 'BackOffice', label: 'M2 Reso', campo: 'ParamB04', cls: 'g-bko' },
  { gruppo: 'BackOffice', label: 'M2 Lis. 143', campo: 'ParamB10', cls: 'g-bko' },
  { gruppo: 'BackOffice', label: '140 Inv. UP', campo: 'ParamB11', cls: 'g-bko' },
  { gruppo: 'SDA', label: 'Bancario', campo: 'ParamI19', cls: 'g-sda' }
]
// gruppi per la prima riga di intestazione (nome + quante colonne occupa + colore)
const GRUPPI = CONTATORI.reduce((acc, c) => {
  const g = acc[acc.length - 1]
  if (g?.nome === c.gruppo) g.span++
  else acc.push({ nome: c.gruppo, span: 1, cls: c.cls })
  return acc
}, [])

// filiale selezionata nel filtro: parte da quella corrente dell'utente;
// l'elenco (auth.filiali) viene dalla SP ElencoFiliali = diritti dell'utente
const filialeSel = ref(auth.utente?.idFiliale ?? null)

function isoGiorno() {
  const d = giorno.value
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

async function carica() {
  caricamento.value = true
  errore.value = ''
  try {
    if (!auth.filiali.length) await auth.caricaFiliali()
    const { data } = await api.get('/attivita-dipendenti', {
      params: { data: isoGiorno(), idFiliale: filialeSel.value ?? undefined }
    })
    righe.value = data.righe
    presenze.value = data.presenze
    modificabile.value = data.modificabile
  } catch (e) {
    righe.value = []
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle attività'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)

const etichettaPresenza = cod =>
  presenze.value.find(p => p.codPresenza?.trim() === `${cod ?? ''}`.trim())?.presenza ?? cod ?? ''
const etichettaFiliale = id =>
  auth.filiali.find(f => f.idFiliale === id)?.filiale ?? id

// salvataggio immediato al termine della modifica di una cella
async function onCellEditComplete(e) {
  const { data, field, newValue } = e
  if (`${data[field] ?? ''}` === `${newValue ?? ''}`) { data[field] = newValue; return }
  const precedente = data[field]
  data[field] = newValue
  try {
    const payload = {
      IdAttivita: data.idAttivita,
      IdFiliale: data.idFiliale,
      CodPresenza: data.codPresenza ? `${data.codPresenza}`.trim() : null,
      Note: data.Note
    }
    for (const c of CONTATORI) payload[c.campo] = data[c.campo] ?? 0
    await api.post('/attivita-dipendenti', payload)
  } catch (err) {
    data[field] = precedente
    toast.add({
      severity: 'error', summary: 'Salvataggio rifiutato',
      detail: err.response?.data?.errore ?? 'Errore imprevisto', life: 5000
    })
  }
}

</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Attività Dipendenti</h2>

    <div class="filtro">
      <label>Filiale</label>
      <Select
        v-model="filialeSel" :options="auth.filiali"
        optionValue="idFiliale" optionLabel="filiale"
        filter class="filtro-filiale"
        @update:modelValue="carica"
      />
      <label>Giorno</label>
      <DatePicker v-model="giorno" dateFormat="dd/mm/yy" showIcon @update:modelValue="carica" />
      <Button label="Aggiorna" icon="pi pi-refresh" outlined size="small" @click="carica" />
      <Message v-if="!modificabile && righe.length" severity="warn" :closable="false" class="avviso">
        Giorno più vecchio di 15 giorni: sola lettura
      </Message>
    </div>

    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>
    <p v-if="!caricamento && !righe.length && !errore" class="suggerimento">
      Nessuna attività per la filiale nel giorno selezionato.
    </p>

    <DataTable
      v-if="righe.length"
      :value="righe"
      dataKey="idAttivita"
      :editMode="modificabile ? 'cell' : undefined"
      @cell-edit-complete="onCellEditComplete"
      @keydown.capture="frecceCellEdit"
      scrollable scrollHeight="calc(100vh - 220px)"
      size="small" stripedRows
      class="griglia"
      :loading="caricamento"
    >
      <ColumnGroup type="header">
        <Row>
          <Column header="UTENTI" :rowspan="2" frozen class="col-nome" />
          <Column header="Cod Presenza" :rowspan="2" />
          <Column header="Targa" :rowspan="2" />
          <Column header="Login" :rowspan="2" />
          <Column header="Logout" :rowspan="2" />
          <Column v-for="g in GRUPPI" :key="g.nome" :header="g.nome" :colspan="g.span" :class="['testata-gruppo', g.cls]" />
          <Column header="Note" :rowspan="2" />
          <Column header="Perc. Partime" :rowspan="2" />
          <Column header="Palmare" :rowspan="2" />
          <Column header="FILIALE" :rowspan="2" />
        </Row>
        <Row>
          <Column v-for="c in CONTATORI" :key="c.campo" :header="c.label" :class="c.cls" />
        </Row>
      </ColumnGroup>

      <Column field="nome" frozen class="col-nome" />

      <Column field="codPresenza" class="col-presenza">
        <template #body="{ data }">{{ etichettaPresenza(data.codPresenza) }}</template>
        <template #editor="{ data, field }">
          <Select
            v-model="data[field]" :options="presenze"
            optionValue="codPresenza" optionLabel="presenza"
            size="small" fluid autofocus
          />
        </template>
      </Column>

      <!-- dal palmare: sola lettura -->
      <Column field="targa" class="col-ro" />
      <Column field="login" class="col-ro num" />
      <Column field="logout" class="col-ro num" />

      <!-- contatori: editabili, verdi quando <> 0 -->
      <Column
        v-for="c in CONTATORI" :key="c.campo" :field="c.campo"
        :class="['num', c.cls]"
      >
        <template #body="{ data }">
          <span :class="['cella-num', { verde: Number(data[c.campo]) !== 0 }]">{{ data[c.campo] ?? 0 }}</span>
        </template>
        <template #editor="{ data, field }">
          <InputNumber v-model="data[field]" :useGrouping="false" inputClass="editor-num" autofocus fluid />
        </template>
      </Column>

      <Column field="Note" class="col-note">
        <template #editor="{ data, field }">
          <InputText v-model="data[field]" maxlength="50" size="small" fluid autofocus />
        </template>
      </Column>

      <Column field="Partime" class="col-ro num" />

      <Column field="Palmare" class="col-ro col-palmare" />

      <Column field="idFiliale" class="col-filiale">
        <template #body="{ data }">{{ etichettaFiliale(data.idFiliale) }}</template>
        <template #editor="{ data, field }">
          <Select
            v-model="data[field]" :options="auth.filiali"
            optionValue="idFiliale" optionLabel="filiale"
            filter size="small" fluid autofocus
          />
        </template>
      </Column>
    </DataTable>
  </div>
</template>

<style scoped>
.titolo { margin: 0 0 .75rem; }
.filtro { display: flex; align-items: center; gap: .75rem; margin-bottom: .75rem; flex-wrap: wrap; }
.filtro label { font-size: .9rem; color: #555; }
.filtro-filiale { min-width: 260px; }
.avviso { margin: 0; }
.suggerimento { color: #888; font-size: .9rem; }

.griglia { font-size: .8rem; }
.griglia :deep(th) { white-space: nowrap; }
.griglia.p-datatable :deep(.p-datatable-tbody > tr > td) { padding: 10px 6px; line-height: 1.15; white-space: nowrap; }
.griglia.p-datatable :deep(.p-datatable-thead > tr > th) { padding: 4px 6px; }
.col-nome { font-weight: 600; }
.griglia :deep(th.col-nome), .griglia :deep(td.col-nome) { min-width: 18rem; white-space: nowrap; }
.col-presenza { min-width: 8.5rem; }
.col-note { min-width: 10rem; }
.col-palmare { min-width: 9rem; font-size: .7rem; color: #888; }
.col-filiale { min-width: 11rem; }
.num { text-align: right; }
.col-ro :deep(&), .col-ro { background: var(--p-surface-50); color: #666; }
.cella-num { display: block; padding: 0 .3rem; border-radius: 4px; text-align: right; }
.cella-num.verde { background: #4be34b; font-weight: 600; }

/* colori tenui dei gruppi di colonne (stessi toni della videata legacy);
   valgono sia per le celle sia per le intestazioni (anche di gruppo) */
.griglia :deep(td.g-poste), .griglia :deep(th.g-poste) { background: #fdf6d5; }
.griglia :deep(td.g-racc), .griglia :deep(th.g-racc) { background: #fbe3da; }
.griglia :deep(td.g-mod1), .griglia :deep(th.g-mod1) { background: #cff0e4; }
.griglia :deep(td.g-mod2), .griglia :deep(th.g-mod2) { background: #fce8cf; }
.griglia :deep(td.g-ag), .griglia :deep(th.g-ag) { background: #def4da; }
.griglia :deep(td.g-extra), .griglia :deep(th.g-extra) { background: #d9f2f8; }
.griglia :deep(td.g-speedy), .griglia :deep(th.g-speedy) { background: #e6f0fa; }
.griglia :deep(td.g-bko), .griglia :deep(th.g-bko) { background: #c9d5f6; }
.griglia :deep(td.g-sda), .griglia :deep(th.g-sda) { background: #ece7f6; }
/* La cella non deve cambiare misura quando si apre la modifica: l'editor sta
   dentro lo spazio che c'e' gia', con meno bordi e senza larghezze proprie.
   Le colonne dei contatori tengono una larghezza minima stabile, cosi' la
   griglia non si riassesta a ogni cella aperta. */
.griglia.p-datatable :deep(td.num), .griglia.p-datatable :deep(th.num) { min-width: 3.6rem; }
.griglia.p-datatable :deep(td[data-p-cell-editing="true"]) { padding: 2px 4px; }
.griglia.p-datatable :deep(td[data-p-cell-editing="true"] .p-inputtext),
.griglia.p-datatable :deep(td[data-p-cell-editing="true"] .p-select) {
  width: 100%; min-width: 0; box-sizing: border-box;
  padding: 2px 4px; border-radius: 3px; font-size: inherit;
}
:deep(.editor-num) { width: 100%; min-width: 0; box-sizing: border-box; text-align: right; }
</style>
