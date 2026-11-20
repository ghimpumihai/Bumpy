import { readFileSync } from 'node:fs'
import path from 'node:path'
import babel from '@rolldown/plugin-babel'
import tailwindcss from '@tailwindcss/vite'
import { tanstackRouter } from '@tanstack/router-plugin/vite'
import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

/**
 * `vite preview` serves the production headers from staticwebapp.config.json (Azure Static Web Apps),
 * so e2e tests run under the real Content-Security-Policy. The only addition: the local stand-in
 * read API is plain http://localhost, which the production CSP (https only) would block.
 */
function staticWebAppHeaders(): Record<string, string> {
  const config = JSON.parse(readFileSync(path.resolve(import.meta.dirname, 'public/staticwebapp.config.json'), 'utf8')) as {
    globalHeaders: Record<string, string>
  }
  const headers = { ...config.globalHeaders }
  headers['Content-Security-Policy'] = headers['Content-Security-Policy'].replace(
    "connect-src 'self' https:",
    "connect-src 'self' https: http://localhost:*",
  )
  return headers
}

// The router plugin must run before the React plugin (it generates routeTree.gen.ts).
export default defineConfig({
  preview: { headers: staticWebAppHeaders() },
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
