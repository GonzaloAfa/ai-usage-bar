# Instalar AI Usage Bar con un agente

Guía para que un agente de terminal (Claude Code, Codex u otro) instale esta app en el Mac de quien
se lo pide. Es un procedimiento local: compila, empaqueta, copia a `/Applications` y, si se pide, la
deja arrancando al iniciar sesión.

Todos los pasos son **idempotentes**: volver a ejecutarlos sobre una instalación existente la
actualiza sin dejar restos.

## Antes de empezar

Comprueba el terreno y **detente si algo falta**, en vez de intentar arreglarlo por tu cuenta:

```bash
sw_vers -productVersion          # necesita 13 o posterior
swift --version                  # necesita Swift 5.8 o posterior
```

Sin toolchain de Swift no hay nada que hacer: pídele a la persona que instale Xcode o las Command
Line Tools (`xcode-select --install`) y espera.

Después revisa qué sesiones hay en la máquina, porque de eso depende lo que la app va a mostrar:

```bash
security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 && echo "Claude: sesión presente"
python3 -c "import json,os;p=os.path.expanduser('~/.codex/auth.json');print('Codex:', json.load(open(p)).get('auth_mode'))" 2>/dev/null
```

- `Claude: sesión presente` → aparecerá el ítem de Claude.
- `Codex: chatgpt` → aparecerá el ítem de Codex.
- `Codex: apikey` o sin salida → Codex **no** aparecerá, y es correcto: una clave de API se factura
  por consumo y no tiene límites de plan que mostrar. Dilo, no lo trates como un fallo.

Si no hay ninguna de las dos, la app se instala igual pero no tendrá nada que consultar. Avisa antes
de seguir.

Estos comandos son de sólo lectura y a propósito: **nunca leas, copies, muestres ni envíes a ninguna
parte el contenido del llavero ni de `~/.codex/auth.json`.** Sólo interesa si existen y de qué tipo
son. Tampoco intentes renovar una sesión: rotar un *refresh token* desde fuera puede cerrarle la
sesión a Claude Code o a Codex.

## Instalación

```bash
git clone https://github.com/GonzaloAfa/ai-usage-bar.git
cd ai-usage-bar
swift test                       # 49 pruebas; si alguna falla, detente y reporta
Scripts/make-app.sh              # → build/AIUsageBar.app, firmado ad-hoc
cp -R build/AIUsageBar.app /Applications/
open /Applications/AIUsageBar.app
```

Si `swift test` o `make-app.sh` fallan con `unable to lookup item 'PlatformPath'`, es macOS 13 con
las Command Line Tools 14.x: SwiftPM no arranca ahí, y además no hay XCTest. No intentes repararlo;
empaqueta con `Scripts/make-app-swiftc.sh` (mismo resultado, compilado con `swiftc`) y di que las
pruebas quedaron sin correr.

Si ya había una copia corriendo, ciérrala antes de copiar encima:

```bash
pkill -f "/Applications/AIUsageBar.app" || true
```

**Siempre se ejecuta desde `/Applications`, no desde `build/`.** El inicio automático apunta a esa
ruta, y una app lanzada desde el directorio de compilación desaparece al limpiar el proyecto.

## Verificar que quedó bien

La barra de menú **no se puede capturar** sin conceder permiso de grabación de pantalla, así que no
pierdas tiempo con `screencapture`: devuelve la barra vacía, sin reloj ni íconos, y parece un fallo
de la app cuando no lo es. Verifica por otros dos caminos.

**1. Que los datos llegan.** El modo diagnóstico consulta una vez y termina, sin tocar la barra:

```bash
AI_USAGE_BAR_PRINT=1 /Applications/AIUsageBar.app/Contents/MacOS/AIUsageBar
```

Debe imprimir una sección por proveedor con sesión, con sus porcentajes:

```
— Claude —
  Sesión actual: 14% usado — se restablece en 3 h 49 min
  Todos los modelos: 13% usado — se restablece dom, 7:00 a.m.

— Codex —
Plan: plus
  Sesión actual: 29% usado — se restablece en 4 h 52 min
  Semanal: 30% usado — se restablece mié, 1:34 p.m.
```

Si sale `Demasiadas consultas. Reintentando en un momento.`, es un 429 por haber consultado varias
veces seguidas mientras probabas. No es un error de instalación: espera un minuto y repite.

**2. Que los ítems existen.** Arrancar con los popovers abiertos los pone a la vista sin depender de
que la persona encuentre los íconos:

```bash
pkill -f "/Applications/AIUsageBar.app" || true
AI_USAGE_BAR_AUTO_OPEN=1 nohup /Applications/AIUsageBar.app/Contents/MacOS/AIUsageBar >/dev/null 2>&1 &
```

Pregúntale cuántos paneles vio. Uno por proveedor con sesión.

**Si dice que ve menos íconos de los que esperaba y el diagnóstico sí lista los dos proveedores, la
barra está llena.** macOS recorta los ítems de estado cuando la app al frente tiene muchos menús, y
en los Mac con notch pasa seguido. Pídele que cambie al Finder o cierre una app con barra de menú
larga y mire otra vez; los ítems se reordenan arrastrándolos con ⌘ presionado.

## Inicio automático al abrir sesión

La opción *Iniciar al abrir sesión* del menú contextual usa `SMAppService`, que **macOS rechaza
cuando la app está firmada ad-hoc** — el caso de `Scripts/make-app.sh`. Con un LaunchAgent funciona:

```bash
cat > ~/Library/LaunchAgents/cl.alisonvivanco.ai-usage-bar.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>cl.alisonvivanco.ai-usage-bar</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/AIUsageBar.app/Contents/MacOS/AIUsageBar</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<!-- Sin KeepAlive: «Salir» en el menú debe cerrarla de verdad, no reabrirla al instante. -->
</dict>
</plist>
PLIST

plutil -lint ~/Library/LaunchAgents/cl.alisonvivanco.ai-usage-bar.plist
pkill -f "/Applications/AIUsageBar.app" || true
launchctl bootout gui/$(id -u)/cl.alisonvivanco.ai-usage-bar 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/cl.alisonvivanco.ai-usage-bar.plist
```

Comprobación:

```bash
launchctl print gui/$(id -u)/cl.alisonvivanco.ai-usage-bar | grep -E "state =|pid ="
# state = running
# pid = 93456
```

`bootout` antes de `bootstrap` es lo que hace el paso repetible: sin eso, la segunda vez falla porque
el servicio ya está cargado. `launchctl load`/`unload` también funcionan, pero están obsoletos.

Para desactivarlo:

```bash
launchctl bootout gui/$(id -u)/cl.alisonvivanco.ai-usage-bar
rm ~/Library/LaunchAgents/cl.alisonvivanco.ai-usage-bar.plist
```

## Actualizar una instalación existente

```bash
cd ai-usage-bar && git pull
swift test
Scripts/make-app.sh
pkill -f "/Applications/AIUsageBar.app" || true
cp -R build/AIUsageBar.app /Applications/
launchctl kickstart -k gui/$(id -u)/cl.alisonvivanco.ai-usage-bar 2>/dev/null \
  || open /Applications/AIUsageBar.app
```

`kickstart -k` reinicia el servicio si hay LaunchAgent; el `||` cubre el caso sin inicio automático.

## Qué no hacer sin preguntar

- **No borrar otra app de `/Applications`.** Si encuentras una `ClaudeUsageBar.app` — el nombre
  anterior de este proyecto — tiene otro identificador y conviven sin problema. Pregunta antes de
  quitarla, y si te dicen que sí, muévela a `~/.Trash` en vez de `rm -rf`.
- **No conceder permisos por tu cuenta** (grabación de pantalla, accesibilidad, automatización).
  Explica para qué serviría y deja que la persona decida.
- **No firmar ni notarizar** salvo que te lo pidan: `Scripts/release.sh` necesita un certificado
  *Developer ID Application* y una cuenta del Apple Developer Program, y sólo hace falta para
  repartir la app a otros Macs.

## Si algo falla

| Síntoma | Causa | Qué hacer |
| --- | --- | --- |
| `missing required module 'SwiftShims'` o un error de `ModuleCache` con otra ruta | el directorio del proyecto se movió y `.build` guarda la ruta vieja | `rm -rf .build build` y volver a compilar |
| El diagnóstico dice `La sesión caducó.` | el token venció; la app no lo renueva a propósito | abrir Claude Code o Codex e iniciar sesión; el indicador se pone al día solo |
| macOS pide autorización del llavero en cada consulta | se eligió *Permitir* en vez de *Permitir siempre* | volver a intentarlo y elegir **Permitir siempre** |
| `Demasiadas consultas.` | 429 por consultar repetido | esperar un minuto |
| Sólo aparece un proveedor | el otro no tiene sesión, o usa clave de API | revisar con los comandos de **Antes de empezar** |
| La app no aparece pero el proceso está vivo | la barra de menú está llena | cambiar de app al frente; ver **Verificar que quedó bien** |

Para el detalle de qué muestra la app, de dónde saca los datos y cómo está organizado el código, ver
el [README](README.md).
