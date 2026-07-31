<script setup>
import { ref, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Password from 'primevue/password'

// Il mio profilo: dati dell'utente collegato e cambio password (la verifica
// della vecchia password e l'hash restano server-side in AI_UTENTI_CambiaPassword).

const toast = useToast()
const errore = ref('')
const profilo = ref(null)
const vecchia = ref('')
const nuova = ref('')
const conferma = ref('')
const salvando = ref(false)

onMounted(async () => {
  try {
    const { data } = await api.get('/profilo')
    profilo.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento del profilo'
  }
})

async function cambiaPassword() {
  if (nuova.value !== conferma.value) {
    toast.add({ severity: 'warn', summary: 'Password', detail: 'La conferma non coincide con la nuova password', life: 4000 })
    return
  }
  salvando.value = true
  try {
    await api.post('/profilo/password', { vecchiaPwd: vecchia.value, nuovaPwd: nuova.value })
    toast.add({ severity: 'success', summary: 'Password', detail: 'Password aggiornata', life: 4000 })
    vecchia.value = ''; nuova.value = ''; conferma.value = ''
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Password', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    salvando.value = false
  }
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Il mio profilo</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section v-if="profilo" class="card">
      <div class="card-titolo">{{ profilo.nome || profilo.utente }}</div>
      <dl class="dati">
        <div><dt>Utente</dt><dd>{{ profilo.utente }}</dd></div>
        <div><dt>Ruolo</dt><dd>{{ profilo.ruolo ?? '—' }}</dd></div>
        <div><dt>Filiale</dt><dd>{{ profilo.filiale ?? '—' }}</dd></div>
        <div v-if="profilo.cliente"><dt>Cliente</dt><dd>{{ profilo.cliente }}</dd></div>
        <div><dt>Email</dt><dd>{{ profilo.email ?? '—' }}</dd></div>
        <div><dt>Telefono</dt><dd>{{ profilo.telefono ?? '—' }}</dd></div>
        <div v-if="profilo.matricola"><dt>Matricola</dt><dd>{{ profilo.matricola }}</dd></div>
        <div v-if="profilo.codAppLogin"><dt>Login palmare</dt><dd>{{ profilo.codAppLogin }}</dd></div>
        <div><dt>Attivo dal</dt><dd>{{ profilo.attivoDal ?? '—' }}</dd></div>
        <div><dt>Ultimo accesso</dt><dd>{{ profilo.ultimoAccesso ?? '—' }}</dd></div>
      </dl>
    </section>

    <section class="card">
      <div class="card-titolo">Cambio password</div>
      <div class="form-pwd">
        <label>Password attuale
          <Password v-model="vecchia" :feedback="false" toggleMask fluid />
        </label>
        <label>Nuova password (min 6 caratteri)
          <Password v-model="nuova" toggleMask fluid promptLabel="Scegli la nuova password"
            weakLabel="Debole" mediumLabel="Media" strongLabel="Robusta" />
        </label>
        <label>Conferma nuova password
          <Password v-model="conferma" :feedback="false" toggleMask fluid />
        </label>
        <div class="azione">
          <Button label="Cambia password" icon="pi pi-key"
            :disabled="!vecchia || nuova.length < 6 || !conferma" :loading="salvando"
            @click="cambiaPassword" />
        </div>
      </div>
    </section>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 46rem; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0;
}
.dati { display: grid; grid-template-columns: 1fr 1fr; gap: .1rem 1.5rem; margin: 0; padding: .8rem; }
.dati div { display: flex; gap: .6rem; padding: .25rem 0; border-bottom: 1px dashed var(--p-surface-200); }
.dati dt { width: 8.5rem; color: #777; font-size: .85rem; flex-shrink: 0; }
.dati dd { margin: 0; font-size: .9rem; }
.form-pwd { padding: .8rem; display: flex; flex-direction: column; gap: .7rem; max-width: 24rem; }
.form-pwd label { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.azione { display: flex; justify-content: flex-end; }
</style>
