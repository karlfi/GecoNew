<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Listbox from 'primevue/listbox'
import InputText from 'primevue/inputtext'
import Textarea from 'primevue/textarea'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import ProgressSpinner from 'primevue/progressspinner'

const toast = useToast()
const lista = ref([])
const caricamento = ref(false)
const errore = ref('')
const selezionata = ref(null)
const edit = ref(null)
const salvataggio = ref(false)

// campi SQL componibili (nell'ordine in cui vengono concatenati)
const CAMPI_SQL = [
  ['SqlSelect', 'SELECT'],
  ['SqlFrom', 'FROM'],
  ['SqlWhere', 'WHERE'],
  ['SqlGroup', 'GROUP BY'],
  ['SqlOrder', 'ORDER BY']
]

async function caricaLista() {
  caricamento.value = true
  errore.value = ''
  try {
    const { data } = await api.get('/config/interrogazioni', { params: { size: 500, sort: 'IdQuery' } })
    lista.value = data.rows.map(r => ({ ...r, _label: `${r.IdQuery} — ${r.Titolo ?? '(senza titolo)'}` }))
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento'
  } finally {
    caricamento.value = false
  }
}
onMounted(caricaLista)

function seleziona(r) {
  if (!r) return
  edit.value = { ...r }
  prova.value = null
}
function nuova() {
  selezionata.value = null
  edit.value = {
    IdQuery: null, Titolo: '', Descrizione: '', SqlSelect: '', SqlFrom: '',
    SqlWhere: '', SqlGroup: '', SqlOrder: '', Query: '', Alias: '',
    Parametri: '', Visibilita: null, CanSee: ''
  }
  prova.value = null
}

const anteprimaSql = computed(() => {
  if (!edit.value) return ''
  return CAMPI_SQL.map(([k]) => edit.value[k]).filter(v => v && v.trim()).join('\n')
})

async function salva() {
  salvataggio.value = true
  try {
    const { data } = await api.post('/config/interrogazioni', edit.value)
    toast.add({ severity: 'success', summary: 'Interrogazione salvata', life: 1800 })
    await caricaLista()
    const id = data.id ?? edit.value.IdQuery
    const r = lista.value.find(x => x.IdQuery === id)
    if (r) { selezionata.value = r; seleziona(r) }
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Errore', detail: e.response?.data?.errore ?? 'Salvataggio fallito', life: 5000 })
  } finally {
    salvataggio.value = false
  }
}

// prova di esecuzione (versione SALVATA sul DB)
const prova = ref(null)
const provaInCorso = ref(false)
async function provaEsecuzione() {
  if (!edit.value?.IdQuery) return
  provaInCorso.value = true
  prova.value = null
  try {
    const { data } = await api.post('/interrogazioni/esegui', { idQuery: edit.value.IdQuery, sWhere: '' })
    prova.value = { ok: true, righe: data.righe.length, colonne: data.colonne }
  } catch (e) {
    prova.value = { ok: false, msg: e.response?.data?.errore ?? 'Errore' }
  } finally {
    provaInCorso.value = false
  }
}
</script>

<template>
  <div class="editor">
    <div class="lista">
      <div class="lista-head">
        <h2>Interrogazioni</h2>
        <Button icon="pi pi-plus" label="Nuova" size="small" @click="nuova" />
      </div>
      <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>
      <ProgressSpinner v-if="caricamento" style="width:40px" />
      <Listbox
        v-else
        v-model="selezionata"
        :options="lista"
        optionLabel="_label"
        filter
        filterPlaceholder="Cerca..."
        class="lb"
        @change="seleziona($event.value)"
      />
    </div>

    <div class="form" v-if="edit">
      <div class="form-head">
        <h3>
          {{ edit.IdQuery ? `Query #${edit.IdQuery}` : 'Nuova interrogazione' }}
        </h3>
        <div class="azioni">
          <Button label="Prova" icon="pi pi-play" size="small" severity="secondary"
                  :loading="provaInCorso" :disabled="!edit.IdQuery"
                  v-tooltip.bottom="'Esegue la versione salvata'" @click="provaEsecuzione" />
          <Button label="Salva" icon="pi pi-check" size="small" :loading="salvataggio" @click="salva" />
        </div>
      </div>

      <Message v-if="prova && prova.ok" severity="success" :closable="false">
        OK — {{ prova.righe }} righe, {{ prova.colonne.length }} colonne
      </Message>
      <Message v-if="prova && !prova.ok" severity="error" :closable="false">{{ prova.msg }}</Message>

      <div class="riga2">
        <div class="campo">
          <label>Titolo</label>
          <InputText v-model="edit.Titolo" />
        </div>
        <div class="campo">
          <label>Descrizione (sottotitolo)</label>
          <InputText v-model="edit.Descrizione" />
        </div>
      </div>

      <div class="campo" v-for="[k, etic] in CAMPI_SQL" :key="k">
        <label>{{ etic }} <code class="ck">{{ k }}</code></label>
        <Textarea v-model="edit[k]" rows="2" autoResize spellcheck="false" class="sql" />
      </div>

      <div class="riga2">
        <div class="campo">
          <label>Alias (etichette colonne)</label>
          <Textarea v-model="edit.Alias" rows="2" autoResize />
        </div>
        <div class="campo">
          <label>Parametri</label>
          <Textarea v-model="edit.Parametri" rows="2" autoResize />
        </div>
      </div>

      <div class="riga2">
        <div class="campo">
          <label>Visibilità</label>
          <InputText v-model="edit.Visibilita" />
        </div>
        <div class="campo">
          <label>CanSee</label>
          <InputText v-model="edit.CanSee" />
        </div>
      </div>

      <details class="avanzato">
        <summary>Campo Query legacy (combinato)</summary>
        <Textarea v-model="edit.Query" rows="3" autoResize class="sql" />
      </details>

      <div class="anteprima" v-if="anteprimaSql">
        <label>Anteprima SQL composto</label>
        <pre>{{ anteprimaSql }}</pre>
      </div>
    </div>

    <div class="form vuoto" v-else>
      <Tag value="Seleziona un'interrogazione a sinistra o creane una nuova" severity="secondary" />
    </div>
  </div>
</template>

<style scoped>
.editor {
  display: grid;
  grid-template-columns: 320px 1fr;
  gap: 1rem;
  height: 100%;
  min-height: 0;
}
.lista {
  display: flex;
  flex-direction: column;
  gap: .5rem;
  min-height: 0;
}
.lista-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.lista-head h2 { margin: 0; }
.lb { flex: 1; min-height: 0; }
.lb :deep(.p-listbox-list-container) { max-height: calc(100vh - 200px); }
.form {
  overflow-y: auto;
  padding-right: .5rem;
  display: flex;
  flex-direction: column;
  gap: .75rem;
}
.form.vuoto { align-items: center; justify-content: center; }
.form-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.form-head h3 { margin: 0; color: #00628f; }
.azioni { display: flex; gap: .5rem; }
.riga2 {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1rem;
}
.campo { display: flex; flex-direction: column; gap: .25rem; }
.campo label { font-size: .8rem; font-weight: 600; }
.ck { color: #999; font-weight: 400; font-size: .72rem; }
.sql :deep(textarea) {
  font-family: 'Cascadia Code', Consolas, monospace;
  font-size: .82rem;
}
:deep(.p-inputtext), :deep(.p-textarea) { width: 100%; }
.avanzato summary { cursor: pointer; font-size: .85rem; color: #666; }
.anteprima pre {
  background: #1e2530;
  color: #d6e2f0;
  padding: .75rem;
  border-radius: 6px;
  overflow-x: auto;
  font-size: .8rem;
}
.anteprima label { font-size: .8rem; font-weight: 600; }
</style>
