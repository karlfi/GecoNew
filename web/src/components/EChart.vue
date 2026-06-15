<script setup>
import { ref, shallowRef, onMounted, onBeforeUnmount, watch } from 'vue'

// Wrapper riutilizzabile su ECharts con import dinamico (la libreria ~1MB
// si carica solo quando un grafico viene effettivamente montato).
const props = defineProps({
  option: { type: Object, required: true }
})

const el = ref(null)
const chart = shallowRef(null)
let echarts = null
let ro = null

async function init() {
  if (!el.value) return
  echarts = await import('echarts')
  chart.value = echarts.init(el.value)
  chart.value.setOption(props.option)
  ro = new ResizeObserver(() => chart.value?.resize())
  ro.observe(el.value)
}

onMounted(init)

watch(() => props.option, opt => {
  // notMerge: true così cambiando filiale il grafico non sovrappone serie vecchie
  chart.value?.setOption(opt, true)
}, { deep: true })

onBeforeUnmount(() => {
  ro?.disconnect()
  chart.value?.dispose()
})
</script>

<template>
  <div ref="el" class="echart"></div>
</template>

<style scoped>
.echart {
  width: 100%;
  height: 100%;
  min-height: 300px;
}
</style>
