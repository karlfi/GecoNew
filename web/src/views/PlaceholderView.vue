<script setup>
import Message from 'primevue/message'

defineProps({
  videata: { type: String, default: '' },
  parametri: { type: String, default: '' }
})
</script>

<template>
  <h2>{{ videata }}</h2>
  <Message severity="info" :closable="false">
    Questa maschera non è ancora stata migrata dall'applicazione legacy.
  </Message>
  <p v-if="parametri">
    <b>Parametri:</b> <code>{{ parametri }}</code>
  </p>
</template>
