const express = require('express');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;
const PUBLIC = path.join(__dirname, 'public');

app.disable('x-powered-by');

// Render usa esta ruta para saber si el servicio está vivo
app.get('/healthz', (_req, res) => res.json({ ok: true }));

// La URL y la anon key de Supabase son públicas por diseño (la seguridad la dan las políticas RLS).
// NUNCA pongas aquí la service_role key.
app.get('/api/config', (_req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json({
    supabaseUrl: process.env.SUPABASE_URL || null,
    supabaseAnonKey: process.env.SUPABASE_ANON_KEY || null,
  });
});

app.use(
  express.static(PUBLIC, {
    setHeaders(res, file) {
      const base = path.basename(file);
      if (base === 'sw.js' || base === 'index.html') res.setHeader('Cache-Control', 'no-cache');
      else if (file.includes(path.sep + 'icons' + path.sep)) res.setHeader('Cache-Control', 'public, max-age=604800');
    },
  })
);

// Cualquier otra ruta GET devuelve la app
app.get('*', (_req, res) => res.sendFile(path.join(PUBLIC, 'index.html')));

app.listen(PORT, '0.0.0.0', () => console.log('Baseball manager escuchando en el puerto ' + PORT));
