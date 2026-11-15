# Pomodoro

Un pomodoro para Mac que vive en el notch. Mientras corre, muestra el tiempo a los lados
de la cámara. Al pasar el mouse se abre con los controles, y al terminar cada sesión suena
y avisa. Se puede usar solo o con otras personas cerca, compartiendo el mismo timer.

El diseño sigue a [notch-toast](https://github.com/Devsethi3/notch-toast) (MIT): la silueta
del notch con orejas, el resorte "fluid" y las transiciones con blur.

## Instalar

Requiere macOS 15 o posterior, en un Mac con Apple Silicon o Intel.

- **Con Claude Code u otro agente:** pídele "instala github.com/ignaciobernardo/notch-pomodoro".
  Las instrucciones para el agente están en [AGENTS.md](AGENTS.md).
- **Con Homebrew:** `brew install --cask ignaciobernardo/tap/pomodoro`
- **A mano:** baja `Pomodoro.zip` de [la última versión](https://github.com/ignaciobernardo/notch-pomodoro/releases/latest),
  descomprímelo y arrastra la app a Aplicaciones.

La app no está notarizada por Apple. Si la instalas con Homebrew o a mano, la primera vez
ábrela, cierra el aviso y ve a Ajustes del Sistema → Privacidad y seguridad →
Abrir igualmente. Si la compilas desde el código (`./build.sh install`), no aparece ese aviso.

## Actualizar

La app revisa una vez al día si hay versión nueva. Cuando la hay, el notch muestra
"versión X disponible · actualizar", y con un clic se descarga, se verifica y se reabre.
Clic derecho → "buscar actualizaciones" revisa en el momento. Cada versión va firmada, y la
app rechaza cualquier descarga que no traiga esa firma.

También puedes actualizar con `brew upgrade --cask pomodoro`, o con `git pull && ./build.sh install`.

## Usar

| Quieres | Haz esto |
| --- | --- |
| Abrir los controles | Pasa el mouse por el notch |
| Empezar o pausar | Botón blanco de play |
| Cambiar la duración | Clic en el tiempo grande: aparecen − y + (también sirve el scroll) |
| Anotar en qué estás | Escribe en "¿en qué estás?" y Enter |
| Hacer pomodoros con alguien cerca | Botón de dos personas; la otra persona hace lo mismo |
| Duraciones, registro, sonido, calendario | Clic derecho en el notch |

- **Notch cerrado:** muestra el anillo de progreso y el tiempo, una taza en los descansos, y
  un ícono de personas cuando estás en grupo.
- **Juntos:** usa Wi-Fi, en la misma red o directo entre los Mac. Caben hasta 8 personas y
  se comparten play, pausa, saltar y duraciones; cada uno guarda su propio registro.
- **Registro:** cada foco terminado queda en `~/Documents/pomodoros.md`.
- **Calendario:** opcional, se activa con clic derecho → calendario.

## Consumo

Sin un pomodoro corriendo no hace nada: 0 % de CPU, ningún timer, unos 12 MB. Corriendo,
despierta una vez por segundo para el reloj (≈0,2 % de CPU). No revisa el mouse en loop, y
el modo juntos solo manda mensajes cuando alguien toca algo.

## Desarrollo

```sh
./build.sh           # build/Pomodoro.app (universal)
./build.sh install   # la copia a ~/Applications y la abre
./build.sh share     # build/Pomodoro.zip
./release.sh 1.1.0 "qué cambió"   # publica una versión (solo quien tiene la clave de firma)
```

Arquitectura, pruebas y reglas de rendimiento: [AGENTS.md](AGENTS.md).
