<script setup>
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import InputText from 'primevue/inputtext'
import Password from 'primevue/password'
import Button from 'primevue/button'
import Message from 'primevue/message'

const auth = useAuthStore()
const router = useRouter()
const utente = ref('')
const password = ref('')
const errore = ref('')
const inCorso = ref(false)

async function accedi() {
  errore.value = ''
  inCorso.value = true
  try {
    await auth.login(utente.value, password.value)
    router.push('/')
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore di connessione al server'
  } finally {
    inCorso.value = false
  }
}
</script>

<template>
  <div class="login-page">
    <form class="login-card" @submit.prevent="accedi">
      <h1>Ge.C.O. <span>Web</span></h1>
      <label for="utente">Username</label>
      <InputText id="utente" v-model="utente" autocomplete="username" autofocus />
      <label for="password">Password</label>
      <Password id="password" v-model="password" :feedback="false" toggle-mask />
      <Button type="submit" label="ACCEDI" :loading="inCorso" />
      <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>
      <p class="hint">Inserisci username e password per accedere al sistema</p>
    </form>
  </div>
</template>

<style scoped>
.login-page {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: linear-gradient(160deg, #00628f, #00afde);
}
.login-card {
  width: 360px;
  background: #fff;
  border-radius: 10px;
  padding: 2rem;
  display: flex;
  flex-direction: column;
  gap: .75rem;
  box-shadow: 0 10px 40px rgba(0, 0, 0, .25);
}
.login-card h1 {
  margin: 0 0 1rem;
  text-align: center;
  color: #00628f;
}
.login-card h1 span { color: #00afde; }
label {
  font-weight: 600;
  font-size: .85rem;
  color: #333;
}
.hint {
  text-align: center;
  color: #777;
  font-size: .8rem;
  margin: .5rem 0 0;
}
:deep(.p-password),
:deep(.p-password-input),
:deep(.p-inputtext) { width: 100%; }
</style>
