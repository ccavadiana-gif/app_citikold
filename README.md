# App de operaciones Citikold

App de chofer y despacho (v43) conectada a Supabase.

- `index.html`: la app. Es la misma pantalla v43 de Apps Script; las llamadas al servidor van a la función `api` de Supabase.
- `base-de-datos/02-app.sql`: tablas y reglas. Se ejecuta en el SQL Editor de Supabase.
- `base-de-datos/puente.gs`: Apps Script para la hoja del formulario «PORTEO TPG (Respuestas)»; pasa cada viaje TPG finalizado a la hoja que lee el dashboard.
- `base-de-datos/importar.py`: convierte la hoja de Apps Script (.xlsx) en archivos SQL para cargar los datos. Esos archivos tienen PIN de choferes y no se suben aquí.

La clave de Supabase en `index.html` es la clave pública (publishable). Las tablas no se pueden leer directamente: todo pasa por `api()`, que pide PIN.
