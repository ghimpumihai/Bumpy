import path from 'node:path'
import babel from '@rolldown/plugin-babel'
import tailwindcss from '@tailwindcss/vite'
import { tanstackRouter } from '@tanstack/router-plugin/vite'
import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// The router plugin must run before the React plugin (it generates routeTree.gen.ts).
export default defineConfig({
  plugins: [
    tanstackRouter({ target: 'react', autoCodeSplitting: true }),
    react(),
    babel({ presets: [reactCompilerPreset()] }),
    tailwindcss(),
  ],
  // MapLibre loads its worker via `new URL("./maplibre-gl-worker.mjs", import.meta.url)`;
  // pre-bundling moves the module and breaks that path.
  optimizeDeps: { exclude: ["maplibre-gl"] },
  // The MapLibre worker is an ES module (see src/lib/maplibre.ts).
  worker: { format: "es" },
  resolve: {
    alias: { '@': path.resolve(import.meta.dirname, './src') },
  },
})
