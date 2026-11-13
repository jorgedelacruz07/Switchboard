# Anuncio de voz en el Echo (Home Assistant + Matter)

```
monitor (Mini) --POST webhook--> Home Assistant (NAS) --pulso 10 s--> input_boolean
   --> binary_sensor de contacto --Matter (matter-hub)--> Alexa --rutina--> Echo dice "Claude ya está disponible"
```

El webhook y el enlace Matter funcionan en la red local, sin Nabu Casa. Las rutinas y la
voz de Alexa dependen de los servicios de Amazon e Internet; no es un sistema de voz
completamente local. Home Assistant y el puente corren en el NAS (Linux,
`network_mode: host`) para que Matter tenga acceso a mDNS/UDP e IPv6.

## 1. Preparar el NAS (una vez)

```bash
ssh nas 'mkdir -p /volume1/docker/homeassistant/config/packages /volume1/docker/homeassistant/matter-hub'
scp Features/ProviderStatus/integrations/homeassistant/packages/ai_status.yaml nas:/volume1/docker/homeassistant/config/packages/
```

Crear `/volume1/docker/homeassistant/config/secrets.yaml` en el NAS con un webhook id
aleatorio (`openssl rand -hex 24`) y guardar **el mismo valor** como parte de
`HA_WEBHOOK_URL` en Doppler (`dev-tools/dev`). `configuration.yaml` debe incluir:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

## 2. Levantar Home Assistant

```bash
cd Features/ProviderStatus/integrations/homeassistant
DOCKER_HOST=ssh://nas HAMH_HA_TOKEN=pendiente docker compose up -d homeassistant
```

Abrir `http://<nas-ip>:8123`, crear el usuario propietario y, en el perfil, un
**token de acceso de larga duración**. Guardarlo en Doppler como `HAMH_HA_TOKEN`.

## 3. Levantar el puente Matter

```bash
DOCKER_HOST=ssh://nas doppler run -p dev-tools -c dev -- docker compose --profile bridge up -d
```

En `http://<nas-ip>:8482` crear un puente que incluya solo los cuatro sensores
de contacto con el filtro `pattern: binary_sensor.ai_*` y copiar su código de
emparejamiento. No incluir `input_boolean.ai_*`: son interruptores internos de la
automatización y publicarlos crea otros cuatro dispositivos «IA … disponible» en Alexa.
Conservar esos interruptores en Home Assistant.

Si el puente ya está emparejado, editarlo y quitar la regla de inclusión
`input_boolean.ai_*`, conservando `binary_sensor.ai_*`. Al guardar deben quedar solo
«AI Claude aviso», «AI GPT aviso», «AI Antigravity aviso» y «AI OpenCode aviso».

## 4. Alexa

1. App Alexa → Dispositivos → + → Añadir dispositivo → Otro → Matter. Introducir el código.
2. Rutinas → crear una por herramienta: **Cuando** el sensor de contacto «AI Claude aviso»
   se abra → **Alexa dice** «Claude ya está disponible» en tu Echo Dot. Repetir con las otras tres.
3. Si aún aparecen los antiguos «IA … disponible», eliminarlos individualmente desde
   Dispositivos en la app Alexa. Conservar los cuatro «AI … aviso» y el puente emparejado.

## 5. Conectar el monitor y probar

Guardar en Doppler (`dev-tools/dev`) `HA_WEBHOOK_URL` con el endpoint ya configurado en
Home Assistant: `http://<nas-ip>:8123/api/webhook/<id>` en LAN, o el host de Tailscale
si se necesita ese recorrido cifrado. No pegar el valor real en comandos, documentación
ni archivos del repositorio.

`npm run status` solo comprueba proveedores: no envía avisos ni activa el monitor
periódico. El monitor avisa al Echo únicamente ante `recovered`, tras una incidencia
seguida de 10 minutos estables; una primera lectura correcta no dispara la rutina.
Antigravity sigue siendo una aproximación por incidentes de Gemini/Vertex AI, y estos
avisos no verifican cuotas ni capacidad de una cuenta concreta para procesar trabajos.

Para ejecutar un ciclo con avisos habilitados:

```bash
cd ~/Projects/Switchboard
doppler run -p dev-tools -c dev -- npm run status:once
```

El panel de Switchboard muestra disponibilidad cuando la app está abierta. Para
emitir un ciclo de transiciones manual con avisos, ejecuta `npm run status:once`
bajo Doppler desde la raíz de `Switchboard`. No hay un LaunchAgent activo ni una plantilla
con rutas específicas de máquina. Tener Home Assistant y Matter activos no
programa esas consultas.

Prueba manual de punta a punta sin esperar una caída (envía un aviso real al Echo si
la rutina está creada):

```bash
doppler run -p dev-tools -c dev -- node --input-type=module <<'JS'
const response = await fetch(process.env.HA_WEBHOOK_URL, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ tool: "claude", event: "recovered", message: "prueba" }),
  signal: AbortSignal.timeout(10000),
});
console.log(`Home Assistant: HTTP ${response.status}`);
if (!response.ok) process.exitCode = 1;
JS
```

Un HTTP correcto no confirma que el Echo haya hablado: comprobar que «AI Claude aviso»
se abre durante 10 segundos, vuelve a cerrarse y la rutina anuncia la frase. Repetir con
`openai`, `antigravity` y `opencode` cuando se quiera verificar cada rutina.

## Riesgos conocidos

- **Memoria del NAS**: ~3.3 GB libres con Immich activo; los límites (768 m + 384 m) acotan el impacto.
- **IPv6**: el puente Matter lo requiere en el host; si el emparejamiento falla, es el primer sospechoso.
- **Alexa y Matter**: los avisos se publican como sensores de contacto virtuales porque los
  interruptores Matter no dieron el disparador necesario. El paso 5 comprueba el anuncio
  completo en el Echo.
- Las imágenes usan `stable`/`latest` (así lo recomienda cada proyecto); conviene fijar versión
  una vez que funcione.
