import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ mode }) => ({
  plugins: [react()],
  base: mode === 'production' ? '/Veira/' : '/',
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes('/node_modules/@supabase/')) return 'supabase-vendor'
          if (
            id.includes('/node_modules/react/')
            || id.includes('/node_modules/react-dom/')
            || id.includes('/node_modules/scheduler/')
          ) return 'react-vendor'
          return undefined
        },
      },
    },
  },
}))
