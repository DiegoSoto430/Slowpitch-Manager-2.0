# Baseball manager

PWA para registrar equipos, jugadores y juegos de baseball y slowpitch, con anotación en vivo,
estadísticas y dashboard. Se despliega en **Render** (servidor Node/Express), usa **Supabase**
(base de datos, login y archivos) y el código vive en **GitHub**.

## Estado actual (importante)

- La app completa ya funciona: login/registro, equipos, roster, nuevo partido, orden al bat,
  anotación en vivo con diamante, partidos y estadísticas.
- Por ahora **guarda los datos en el navegador** (localStorage), así que cada dispositivo ve sus propios
  datos y las cuentas no se comparten entre dispositivos.
- El esquema de Supabase (`supabase/schema.sql`) ya está listo con los permisos de manager/jugador.
  El siguiente paso es conectar el frontend a Supabase (Auth + tablas) para que los datos vivan en la nube.

## Estructura

```
baseball-manager/
├─ server.js              Servidor Express (sirve la app, /healthz y /api/config)
├─ package.json
├─ render.yaml            Configuración de Render (Blueprint)
├─ .env.example           Variables de entorno de ejemplo
├─ .gitignore
├─ public/
│  ├─ index.html          La app completa
│  ├─ manifest.webmanifest
│  ├─ sw.js               Service worker (funciona sin internet tras la primera carga)
│  └─ icons/
└─ supabase/
   └─ schema.sql          Tablas, permisos (RLS), triggers y storage de logos
```

## 1. Subir a GitHub

1. Crea un repositorio vacío en github.com (por ejemplo `baseball-manager`, privado o público).
2. En la carpeta del proyecto:

```bash
git init
git add .
git commit -m "Baseball manager: primera versión"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/baseball-manager.git
git push -u origin main
```

El archivo `.gitignore` ya evita subir `node_modules` y `.env`.

## 2. Preparar Supabase

1. En supabase.com crea un proyecto nuevo (guarda la contraseña de la base de datos).
2. Ve a **SQL Editor > New query**, pega todo `supabase/schema.sql` y presiona **Run**.
3. Ve a **Project Settings > API** y copia:
   - **Project URL** (`SUPABASE_URL`)
   - **anon public key** (`SUPABASE_ANON_KEY`)
4. En **Authentication > Providers** deja activo **Email**. Para pruebas puedes desactivar
   "Confirm email" en **Authentication > Sign In / Providers**, así el registro entra directo.
5. Cuando tengas la URL de Render (paso 3), ve a **Authentication > URL Configuration** y pon esa URL en
   **Site URL** y agrégala en **Redirect URLs**.

> La **anon key** es pública por diseño: la seguridad la dan las políticas RLS del esquema.
> La **service_role key** NUNCA va en el repositorio, ni en Render, ni en el frontend.

## 3. Desplegar en Render

Opción A, con Blueprint (usa `render.yaml`):
1. En render.com: **New > Blueprint** y elige tu repositorio de GitHub.
2. Render te pedirá `SUPABASE_URL` y `SUPABASE_ANON_KEY`: pega los valores del paso 2.

Opción B, a mano:
1. **New > Web Service** y elige el repositorio.
2. Runtime **Node**, Build Command `npm install`, Start Command `npm start`.
3. En **Environment** agrega `SUPABASE_URL` y `SUPABASE_ANON_KEY`.
4. En **Advanced > Health Check Path** pon `/healthz`.

Al terminar, Render te da una URL como `https://baseball-manager.onrender.com`.
Cada `git push` a `main` vuelve a desplegar solo.

Nota: en el plan gratuito de Render el servicio se duerme tras un rato sin uso y la primera visita
después de eso tarda en cargar.

## 4. Instalarla en el celular

Abre la URL en el navegador del celular y elige **Agregar a pantalla de inicio** (Android: menú de Chrome >
Instalar app; iPhone: Compartir > Agregar a pantalla de inicio).

## Probar en tu computadora

```bash
npm install
cp .env.example .env     # opcional por ahora
npm start                # abre http://localhost:3000
```

Después de cambiar `public/index.html`, si ya instalaste la app, sube el número de `CACHE` en
`public/sw.js` (por ejemplo `bm-v2`) para que los dispositivos tomen la versión nueva.

## Permisos (cómo los aplica Supabase)

- Todos los usuarios registrados tienen los mismos permisos.
- Quien crea un equipo queda como **manager** y es el único que puede modificar el equipo, el roster,
  los juegos, las jugadas y las estadísticas.
- Quien es invitado (tabla `invitations`, se acepta con la función `accept_invitation`) entra como
  **jugador** y solo puede ver la información.

## Modelo de datos

`profiles`, `teams`, `team_members` (manager/player), `players`, `invitations`, `games`, `game_events`
(cada jugada es un evento, deshacer es borrar el último), `game_player_stats` y la vista
`team_player_totals` con los totales del torneo por jugador.
