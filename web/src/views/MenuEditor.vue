<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Tree from 'primevue/tree'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import Select from 'primevue/select'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import ProgressSpinner from 'primevue/progressspinner'

const toast = useToast()
const righe = ref([])
const caricamento = ref(false)
const errore = ref('')
const edit = ref(null)
const selezione = ref({})
const salvataggio = ref(false)

async function carica() {
  caricamento.value = true
  errore.value = ''
  try {
    const { data } = await api.get('/menu/all')
    righe.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento del menu'
  } finally {
    caricamento.value = false
  }
}
onMounted(carica)

// albero PrimeVue da ParentID
const albero = computed(() => {
  const byId = new Map()
  for (const r of righe.value) {
    byId.set(r.IdMenuElemento, {
      key: String(r.IdMenuElemento),
      label: r.Text || `#${r.IdMenuElemento}`,
      data: r,
      icon: r.Link ? 'pi pi-circle-fill migrata' : undefined,
      children: []
    })
  }
  const radici = []
  for (const n of byId.values()) {
    const p = byId.get(n.data.ParentID)
    if (p) p.children.push(n)
    else radici.push(n)
  }
  return radici
})

// opzioni per la Select del padre
const opzioniPadre = computed(() => [
  { id: 0, label: '(nessuno — voce di primo livello)' },
  ...righe.value.map(r => ({ id: r.IdMenuElemento, label: `${r.Text || '#' + r.IdMenuElemento} (#${r.IdMenuElemento})` }))
])

function onSelect(node) {
  edit.value = { ...node.data }
}
function nuovo(parentId = 0) {
  selezione.value = {}
  edit.value = {
    IdMenuElemento: null, ParentID: parentId, Text: '', Descrizione: '',
    Videata: '', Link: '', Parametri: '', NavigateUrl: '', Sorting: null,
    ToolTip: '', Disabled: 0, Icon: '', Popup: 0, CodFamiglia: ''
  }
}

async function salva() {
  salvataggio.value = true
  try {
    await api.post('/config/menu', edit.value)
    toast.add({ severity: 'success', summary: 'Voce salvata', life: 1800 })
    await carica()
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Errore', detail: e.response?.data?.errore ?? 'Salvataggio fallito', life: 5000 })
  } finally {
    salvataggio.value = false
  }
}

const migrate = computed(() => righe.value.filter(r => r.Link && r.ParentID).length)
const foglie = computed(() => righe.value.filter(r => r.ParentID).length)
</script>

<template>
  <div class="menued">
    <div class="albero">
      <div class="albero-head">
        <h2>Menu</h2>
        <Button icon="pi pi-plus" label="Nuova radice" size="small" text @click="nuovo(0)" />
      </div>
      <div class="legenda">
        <span class="dot"></span> migrata
        <span class="conta">{{ migrate }}/{{ foglie }} foglie collegate</span>
      </div>
      <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>
      <ProgressSpinner v-if="caricamento" style="width:40px" />
      <Tree
        v-else
        :value="albero"
        v-model:selectionKeys="selezione"
        selectionMode="single"
        :filter="true"
        filterMode="lenient"
        filterPlaceholder="Cerca voce..."
        class="tree"
        @node-select="onSelect"
      />
    </div>

    <div class="form" v-if="edit">
      <div class="form-head">
        <h3>{{ edit.IdMenuElemento ? `Voce #${edit.IdMenuElemento}` : 'Nuova voce' }}</h3>
        <div class="azioni">
          <Button v-if="edit.IdMenuElemento" icon="pi pi-plus" label="Figlio" size="small" severity="secondary"
                  @click="nuovo(edit.IdMenuElemento)" />
          <Button label="Salva" icon="pi pi-check" size="small" :loading="salvataggio" @click="salva" />
        </div>
      </div>

      <div class="riga2">
        <div class="campo">
          <label>Testo</label>
          <InputText v-model="edit.Text" />
        </div>
        <div class="campo">
          <label>Padre</label>
          <Select v-model="edit.ParentID" :options="opzioniPadre" optionLabel="label" optionValue="id" filter />
        </div>
      </div>

      <div class="campo link">
        <label>
          Link <span class="hint">— rotta della pagina nuova (vuoto = ancora da migrare)</span>
          <Tag v-if="edit.Link" value="migrata" severity="success" />
          <Tag v-else value="da migrare" severity="warn" />
        </label>
        <InputText v-model="edit.Link" placeholder="es. /config/prodotti, /interrogazioni, /workflow" />
      </div>

      <div class="riga2">
        <div class="campo">
          <label>Videata (legacy)</label>
          <InputText v-model="edit.Videata" />
        </div>
        <div class="campo">
          <label>NavigateUrl (link esterno)</label>
          <InputText v-model="edit.NavigateUrl" />
        </div>
      </div>

      <div class="campo">
        <label>Parametri</label>
        <InputText v-model="edit.Parametri" />
      </div>

      <div class="campo">
        <label>Descrizione</label>
        <InputText v-model="edit.Descrizione" />
      </div>

      <div class="riga3">
        <div class="campo">
          <label>Ordine (Sorting)</label>
          <InputNumber v-model="edit.Sorting" :useGrouping="false" />
        </div>
        <div class="campo">
          <label>Disabled (0/1)</label>
          <InputNumber v-model="edit.Disabled" :useGrouping="false" />
        </div>
        <div class="campo">
          <label>Popup (0/1)</label>
          <InputNumber v-model="edit.Popup" :useGrouping="false" />
        </div>
      </div>

      <div class="riga2">
        <div class="campo">
          <label>Icona</label>
          <InputText v-model="edit.Icon" />
        </div>
        <div class="campo">
          <label>CodFamiglia</label>
          <InputText v-model="edit.CodFamiglia" maxlength="1" />
        </div>
      </div>

      <div class="campo">
        <label>ToolTip</label>
        <InputText v-model="edit.ToolTip" />
      </div>
    </div>

    <div class="form vuoto" v-else>
      <Tag value="Seleziona una voce nell'albero o crea una nuova radice" severity="secondary" />
    </div>
  </div>
</template>

<style scoped>
.menued {
  display: grid;
  grid-template-columns: 360px 1fr;
  gap: 1rem;
  height: 100%;
  min-height: 0;
}
.albero {
  display: flex;
  flex-direction: column;
  gap: .5rem;
  min-height: 0;
}
.albero-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.albero-head h2 { margin: 0; }
.legenda {
  display: flex;
  align-items: center;
  gap: .4rem;
  font-size: .78rem;
  color: #666;
}
.legenda .dot {
  width: 8px; height: 8px; border-radius: 50%;
  background: #29b96e; display: inline-block;
}
.legenda .conta { margin-left: auto; }
.tree { flex: 1; min-height: 0; overflow: auto; }
.tree :deep(.migrata) { color: #29b96e; font-size: .55rem; }
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
.riga2 { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
.riga3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 1rem; }
.campo { display: flex; flex-direction: column; gap: .25rem; }
.campo label { font-size: .8rem; font-weight: 600; display: flex; align-items: center; gap: .5rem; }
.campo.link :deep(.p-inputtext) { border-color: #29b96e; }
.hint { color: #999; font-weight: 400; }
:deep(.p-inputtext), :deep(.p-inputnumber), :deep(.p-select) { width: 100%; }
</style>
