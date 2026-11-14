# UNARA 0.9 — Reconocimiento musical por posición

## Requisitos
- Node.js LTS
- Conexión a internet durante la instalación y la primera carga del modelo OCR en español.

## Ejecutar en Windows
1. Descomprime el ZIP.
2. Abre CMD dentro de la carpeta `unara-app`.
3. Ejecuta `npm install`.
4. Ejecuta `npm run dev`.
5. Abre la dirección local que muestra Vite.

## Novedades de 0.9
- El reconocimiento de imágenes usa las coordenadas de las palabras detectadas por Tesseract, agrupándolas por renglón.
- Las filas que contienen únicamente acordes se conservan como filas separadas, para que el importador pueda relacionarlas con la línea de letra siguiente.
- Se conserva el orden horizontal aproximado de los acordes dentro de cada fila.
- Se reconocen encabezados con numeración romana, como `VERSO I`, y se normalizan a la nomenclatura UNARA (`ESTROFA 1`).
- Se amplía el reconocimiento de variantes de PRE-CORO.
- Se mantiene la revisión manual antes de guardar; acordes complejos y palabras dudosas deben comprobarse.

## Cómo probar con “Fiesta en el desierto”
1. En Repertorio, agrega una canción y elige **Subir imágenes**.
2. Selecciona las tres páginas en el orden correcto.
3. Pulsa **Reconocer texto de las páginas**.
4. Revisa el contenido reconocido; si es necesario, pulsa **Interpretar contenido**.
5. Completa título, artista, tonalidad y BPM, y corrige cualquier acorde dudoso antes de guardar.

## Límites conocidos
Esta mejora utiliza la posición de las palabras entregada por OCR; no es un modelo musical especializado ni garantiza reconocimiento perfecto. Puede confundir símbolos como `#`, `b`, `7` o acordes con bajo alternativo. La colocación final de acordes todavía debe revisarse. El editor visual para arrastrar acordes y la interpretación avanzada de imágenes siguen siendo trabajo pendiente.

Los datos siguen guardándose localmente en el navegador. Esta versión no publica un enlace web ni sincroniza entre dispositivos.
