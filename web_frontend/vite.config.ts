import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import Components from 'unplugin-vue-components/vite'
import { VantResolver } from '@vant/auto-import-resolver'

const helperTarget = process.env.VENERA_WEB_HELPER_URL || 'http://localhost:8080'

export default defineConfig({
  base: '/',
  resolve: {
    alias: { '@': '/src' }
  },
  build: {
    outDir: '../build/web-vue',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        manualChunks: {
          'vendor-vue': ['vue', 'vue-router', 'pinia'],
          'vendor-vant': ['vant'],
        }
      }
    }
  },
  server: {
    proxy: {
      '/api': helperTarget,
      '/sync': helperTarget,
    }
  },
  plugins: [
    vue(),
    Components({ resolvers: [VantResolver()] }),
  ]
})
