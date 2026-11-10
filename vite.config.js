import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
export default defineConfig({
 plugins: [react()],
 server: { host: '0.0.0.0' },
 build: { rollupOptions: { output: { manualChunks(id) {
  if (!id.includes('node_modules')) return
  if (id.includes('recharts') || id.includes('d3-')) return 'charts'
  if (id.includes('@supabase')) return 'supabase'
  if (id.includes('lucide-react')) return 'icons'
  if (id.includes('react-dom') || id.includes('/react/')) return 'react'
 } } } }
})
