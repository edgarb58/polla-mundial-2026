// build.mjs — Vercel ejecuta esto en cada despliegue.
// Toma app.template.html, inyecta las variables de entorno de Supabase
// y escribe el sitio final en dist/index.html.
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, existsSync } from 'node:fs';

const DEFAULT_SUPABASE_URL  = 'https://yomknpkcpppycsuwrobs.supabase.co';
const DEFAULT_SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlvbWtucGtjcHBweWNzdXdyb2JzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk0NzIxNzYsImV4cCI6MjA5NTA0ODE3Nn0.iztJXgtO42XVeoH0AdYmX3f72GxUlRomJeEQaFJKE1M';

const SB_URL  = process.env.SUPABASE_URL  || process.env.NEXT_PUBLIC_SUPABASE_URL  || DEFAULT_SUPABASE_URL;
const SB_ANON = process.env.SUPABASE_ANON || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || DEFAULT_SUPABASE_ANON;

if (!SB_URL || !SB_ANON) {
  console.warn('⚠  Faltan SUPABASE_URL / SUPABASE_ANON en las variables de entorno.');
  console.warn('   El sitio se construirá igual pero mostrará el aviso de "conectar backend".');
  console.warn('   Configúralas en Vercel → Settings → Environment Variables y vuelve a desplegar.');
}

let html = readFileSync(new URL('./app.template.html', import.meta.url), 'utf8');
html = html.replaceAll('%%SUPABASE_URL%%', SB_URL).replaceAll('%%SUPABASE_ANON%%', SB_ANON);
// El logo se sirve como archivo estático desde /logo.jpg
html = html.replaceAll('%%LOGO_SRC%%', '/logo.jpg');

mkdirSync(new URL('./dist/', import.meta.url), { recursive: true });
writeFileSync(new URL('./dist/index.html', import.meta.url), html);

// Copia archivos estáticos opcionales si existen
for (const f of ['favicon.ico', 'robots.txt', 'logo.jpg']) {
  const src = new URL('./public/' + f, import.meta.url);
  if (existsSync(src)) copyFileSync(src, new URL('./dist/' + f, import.meta.url));
}

console.log('✅ Build listo → dist/index.html' + (SB_URL ? ' (Supabase conectado)' : ' (sin conectar)'));
