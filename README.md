# FabricView · instalación

Monitorización de red para FortiGate, FortiSwitch y FortiAP. Este repositorio contiene **solo lo
necesario para instalar y actualizar FabricView** en un servidor propio; la aplicación se descarga
como imágenes Docker ya compiladas.

## Instalar (un solo comando)

En un **Ubuntu Server 26.04 o 24.04** recién instalado (máquina virtual o física, 2 CPU, 4 GB de RAM y
20 GB de disco), con acceso a Internet:

```bash
curl -fsSL https://raw.githubusercontent.com/Tapionsky/fabricview-install/main/install.sh | sudo bash
```

Al terminar muestra la dirección web, el usuario y la contraseña del administrador. Tarda unos
minutos (instala Docker y descarga las imágenes).

Opciones (todas opcionales), añadiéndolas antes de `bash`:

| Variable | Para qué |
| --- | --- |
| `FV_PORT=8080` | Puerto web (por defecto 80) |
| `FV_COMPANY="Mi empresa"` · `FV_SITE="Sede Central"` | Nombres que se ven en la interfaz |
| `FV_ADMIN_EMAIL=it@empresa.com` | Correo del primer administrador |
| `FV_DEMO=1` | Datos de ejemplo para probar sin equipos |
| `FV_VERSION=0.3.0` | Instalar una versión concreta |

Ejemplo: `curl -fsSL …/install.sh | sudo FV_PORT=8080 FV_COMPANY="Acme" bash`

## Tu cuenta

Cambia la contraseña inicial y activa la **verificación en dos pasos** (Google o Microsoft
Authenticator, 1Password…) en **Mi cuenta**, en el menú del usuario (arriba a la derecha).

Si se pierde la contraseña o el móvil, desde la consola del servidor:

```bash
cd /opt/fabricview
sudo -u fabricview docker compose exec api fabricview reset-password admin@fabricview.local
sudo -u fabricview docker compose exec api fabricview reset-2fa admin@fabricview.local
```

## Plan gratuito y licencia

FabricView es gratuito hasta **10 equipos** (cada FortiGate, FortiSwitch y FortiAP cuenta como uno).
Para monitorizar más, en **Ajustes › Licencia** copia el identificador de tu instalación, envíalo a tu
proveedor y pega el código de licencia que te dé.

## Actualizar

Cuando hay una versión nueva, los administradores ven un aviso en la web: **Actualizar** hace copia de
seguridad, instala la versión y, si algo falla, vuelve sola a la anterior.

También desde la consola del servidor:

```bash
sudo -u fabricview /opt/fabricview/scripts/update.sh
```

## Datos y copias de seguridad

- Instalación: `/opt/fabricview` (configuración en `.env`, que contiene los secretos: guárdala).
- Copias de la base de datos: `/opt/fabricview/backups` (se hace una antes de cada actualización).
- Copia manual: `sudo -u fabricview /opt/fabricview/scripts/backup.sh`
