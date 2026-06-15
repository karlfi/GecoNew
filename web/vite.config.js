import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// https://vite.dev/config/
export default defineConfig({
  plugins: [vue()],
  server: {
    proxy: {
      // in sviluppo le chiamate /api vengono girate all'API ASP.NET Core
      '/api': { target: 'http://localhost:5180', changeOrigin: true }
    }
  }
})
