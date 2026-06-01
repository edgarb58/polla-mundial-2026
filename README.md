# ⚽ Polla Mundial 2026

App web para administrar una polla (quiniela) del Mundial 2026 con +100 participantes.
**Frontend** estático en **Vercel** · **Backend** (base de datos, login, tiempo real y seguridad) en **Supabase** · **Código** versionado en **GitHub** con despliegue automático.

- Registro con usuario y contraseña (nombre, cédula, teléfono).
- Panel Admin para **aprobar participantes** y controlar pagos: debe, saldo pendiente o pagado.
- Pronósticos de marcador que se **bloquean en el servidor** 10 min antes de cada partido.
- Puntaje automático: 6 (exacto) / 3 (resultado) / 1 (parcial). Bonus de goleador y Top 4.
- Tabla de posiciones, **notificaciones en tiempo real** y **estadísticas con gráficas**.
- Datos reales: 48 selecciones y 72 partidos de fase de grupos ya cargados.

---

## 🧱 Arquitectura

| Pieza | Rol |
|---|---|
| **GitHub** | Guarda el código. Cada `push` dispara un despliegue. |
| **Supabase** | Postgres + autenticación + *realtime* + seguridad por filas (RLS). Las reglas anti-trampa viven aquí. |
| **Vercel** | Construye y publica el sitio. Inyecta las llaves de Supabase como variables de entorno en el build. |

Las llaves **nunca** se guardan en el código: se configuran en Vercel y el script `build.mjs` las inserta al compilar.

---

## 🚀 Despliegue paso a paso (≈ 20 min)

### 1) Backend en Supabase
1. Crea un proyecto en **https://supabase.com** (elige región *East US* para Colombia).
2. Menú **SQL Editor → New query**, pega TODO el contenido de [`supabase-setup.sql`](./supabase-setup.sql) y dale **Run**. Esto crea las tablas, la seguridad y carga las 48 selecciones + 72 partidos.
3. **Authentication → Providers → Email**: desactiva **Confirm email** (los usuarios entran con usuario interno, no con correo real).
4. **Project Settings → API**: copia el **Project URL** y la **anon public key**.

### 2) Código en GitHub
1. Crea un repositorio nuevo en GitHub (ej. `polla-mundial-2026`).
2. Sube estos archivos. Desde tu computador:
   ```bash
   git init
   git add .
   git commit -m "Polla Mundial 2026 inicial"
   git branch -M main
   git remote add origin https://github.com/TU_USUARIO/polla-mundial-2026.git
   git push -u origin main
   ```
   (O usa la opción "subir archivos" de la web de GitHub si prefieres no usar la terminal.)

### 3) Hosting en Vercel
1. Entra a **https://vercel.com**, inicia sesión con GitHub.
2. **Add New → Project → Import** tu repositorio.
3. Vercel detecta `vercel.json` (build: `node build.mjs`, salida: `dist`). No cambies nada.
4. Antes de desplegar, abre **Environment Variables** y agrega:
   | Name | Value |
   |---|---|
   | `SUPABASE_URL` | tu Project URL |
   | `SUPABASE_ANON` | tu anon public key |
5. **Deploy**. En ~1 min tendrás tu dirección pública (ej. `polla-mundial-2026.vercel.app`). ¡Compártela!

> Cada vez que hagas `git push`, Vercel redespliega solo.

### 4) Crea tu cuenta de administrador
1. Abre la app publicada y **regístrate** (recuerda tu usuario).
2. En Supabase → **SQL Editor**, ejecuta (cambia `tu_usuario`):
   ```sql
   update profiles set is_admin = true where username = 'tu_usuario';
   ```
3. Vuelve a entrar: aparecerá la pestaña **🛠️ Admin**.

---

### Actualizar una base Supabase existente
Si ya habías creado el proyecto antes de esta versión, no vuelvas a borrar la base. Ejecuta primero [`parche-aprobacion-pagos-polla.sql`](./parche-aprobacion-pagos-polla.sql) en **SQL Editor → New query**. Luego sube el nuevo código a GitHub y Vercel redesplegará la app.

## 🖥️ Probar en local (opcional)

```bash
cp .env.example .env.local      # pega ahí tu SUPABASE_URL y SUPABASE_ANON
npm run dev                     # construye e inicia un servidor local
```

---

## 🎮 Administración durante el Mundial

Desde **🛠️ Admin**: aprobar participantes, controlar pagos, cargar resultados (recalcula puntos de todos y notifica), publicar cruces de eliminatorias, registrar el goleador y Top 4 oficiales, enviar avisos, ajustar puntajes/fechas y un **modo simulación** para probar el bloqueo de partidos antes de junio.

## 🔐 Seguridad

Las reglas (Row Level Security de Postgres) viven en Supabase: cada quien solo escribe sus pronósticos y solo antes del cierre, los usuarios pendientes no pueden pronosticar hasta aprobación del admin, nadie ve los ajenos hasta que el partido se cierre, el puntaje lo calcula el servidor y nadie puede auto-nombrarse admin ni cambiar su estado de pago. La *anon key* es pública por diseño; lo que protege los datos es la RLS, no esconder la llave.

## 📁 Estructura

```
.
├── app.template.html     # la app (con placeholders de las llaves)
├── build.mjs             # inyecta las variables de entorno → dist/index.html
├── supabase-setup.sql    # esquema + seguridad + datos del Mundial
├── parche-aprobacion-pagos-polla.sql # migración para bases ya creadas
├── vercel.json           # configuración de build de Vercel
├── package.json
├── .env.example          # plantilla de variables (no subir .env.local)
└── .gitignore
```
