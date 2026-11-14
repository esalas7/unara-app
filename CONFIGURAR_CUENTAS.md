# Activar las cuentas y el espacio compartido de UNARA

La aplicación ya está preparada para usar Supabase. Antes de publicarla, hay que crear el proyecto gratuito de Supabase, aplicar el esquema de la base de datos y agregar dos valores a Vercel.

## 1. Crear el proyecto gratuito

1. Entra en [Supabase](https://supabase.com/dashboard) e inicia sesión.
2. Pulsa **New project** y elige el plan **Free**.
3. Ponle el nombre **UNARA**.
4. Crea una contraseña para la base de datos y guárdala en un lugar seguro. No la compartas ni la pongas en UNARA.
5. Espera a que Supabase termine de crear el proyecto.

## 2. Crear las tablas de UNARA

1. En el panel del proyecto, abre **SQL Editor**.
2. Pulsa **New query**.
3. Abre el archivo `supabase/migrations/202611140001_accounts_and_shared_workspace.sql` de este repositorio y copia todo su contenido.
4. Pégalo en la consulta nueva y pulsa **Run**.

Esto crea los perfiles, espacios de equipo, canciones y reuniones compartidas. La fecha de nacimiento queda en una tabla separada con permisos para que solo la persona propietaria pueda leerla.

## 3. Configurar los correos de confirmación

En Supabase, abre **Authentication → URL Configuration**:

- **Site URL:** `https://unara-app.vercel.app`
- Agrega `https://unara-app.vercel.app/**` a **Redirect URLs**.

Los enlaces de confirmación y recuperación de contraseña regresan a la aplicación.

## 4. Conectar Supabase con Vercel

En Vercel, abre el proyecto **unara-app**, luego **Settings → Environment Variables**, y agrega estas dos variables para **Production** y **Preview**:

| Nombre | Valor |
| --- | --- |
| `VITE_SUPABASE_URL` | La URL del proyecto, en Supabase: **Project Settings → API** |
| `VITE_SUPABASE_ANON_KEY` | La clave pública (`anon` o `publishable`) del mismo panel |

Usa solo la clave pública. **No uses `service_role` ni pegues aquí la contraseña de la base de datos.** Después de guardar las variables, Vercel debe volver a desplegar la aplicación.

## 5. Primer uso

1. Abre UNARA y crea la primera cuenta con correo, contraseña, nombre, fecha de nacimiento y cargo.
2. Confirma el correo si Supabase te lo solicita.
3. Crea el espacio del equipo. Las canciones y reuniones que existían en ese navegador se copiarán al espacio.
4. En **Integrantes**, copia el código de invitación y compártelo con el equipo.
5. Cada persona crea su cuenta, confirma el correo e ingresa ese código para compartir el mismo espacio.

El plan gratuito permite la sincronización y el uso compartido, pero no incluye copias automáticas para recuperar datos eliminados y puede pausar proyectos inactivos. No ingreses datos importantes hasta probar el acceso con una segunda cuenta.
