# Principios de rendimiento para agentes

Estas reglas forman parte de las instrucciones del repositorio. Aplícalas a los
componentes que modifiques, tanto en funciones nuevas como en correcciones.
El rendimiento es un requisito verificable: reducir trabajo, latencia y memoria
sin perder corrección. No añadas complejidad por una mejora meramente supuesta.

## 1. Identifica el coste antes de cambiar la arquitectura

- Localiza qué dispara el trabajo: una tecla, selección, scroll, cambio de nota,
  actualización de SwiftUI, búsqueda, guardado o fragmento de una respuesta AI.
  Considera su frecuencia además del coste de una ejecución.
- Distingue CPU, asignaciones, disco, red, layout y renderizado. Mide el camino
  afectado y compara resultados equivalentes antes y después.
- Prefiere eliminar trabajo repetido antes que introducir concurrencia o nuevas
  dependencias. Elige la solución más sencilla que resuelva el coste observado.
- Revisa la implementación actual: los [hallazgos y mediciones anteriores](editor-performance.md)
  son evidencia histórica, no una garantía del estado presente.

## 2. Protege la capacidad de respuesta de la interfaz

- Mantén pequeños los callbacks de escritura, selección, scroll y los métodos
  `body` / `updateNSView`. No añadas lecturas de disco, esperas de red, bloqueos,
  recorridos completos o análisis costosos en ellos.
- Ejecuta trabajo pesado independiente de la UI fuera de `MainActor`, con
  entradas inmutables y compatibles con Swift Concurrency. `Task {}` puede
  heredar el actor: por sí solo no traslada trabajo a otro hilo. Las mutaciones
  de SwiftUI, AppKit y WebKit deben respetar su aislamiento.
- Agrupa actualizaciones rápidas cuando proceda. Cancela trabajo obsoleto y
  limita las operaciones pendientes; no acumules una tarea por evento. Comprueba
  sesión, revisión o generación antes de publicar resultados, incluso si existe
  cancelación. Liberar observadores y tareas forma parte de su ciclo de vida.
- Usa debounce para trabajo diferible, no para ocultar un algoritmo lento ni
  retrasar acciones explícitas como seleccionar una nota. La escritura debe
  mantener los atributos tipográficos correctos desde la inserción.
- Evita gestos de clic y doble clic en competencia cuando ambos hacen lo mismo:
  el clic puede esperar todo el intervalo de doble clic. Mide desde el evento de
  entrada, no solo desde el callback, para detectar esas esperas.
- Si cambias guardado o carga a segundo plano, conserva el orden de escritura,
  el acceso de seguridad al archivo y los cambios realizados durante la operación.
  Un guardado antiguo no puede marcar como guardada una revisión más reciente.

## 3. Reutiliza trabajo con invalidación explícita

- Usa identidad de sesión y revisión para detectar cambios de contenido. Evita
  comparar documentos completos en cada notificación de scroll o actualización
  de vistas. Reabrir una misma URL no equivale a conservar la misma sesión.
- Documenta las dependencias de cada caché: contenido, documento, árbol de
  archivos, métricas tipográficas, tema u otras. Define cuándo se invalida y
  limita su tamaño o su vida útil. No retengas indefinidamente notas, HTML,
  tareas o vistas descartadas.
- Reutiliza `LineIndex` para convertir líneas y posiciones; evita crear prefijos
  del texto o contar saltos de línea al desplazar la vista. Comparte los índices
  entre consumidores cuando tengan las mismas reglas de invalidación.
- Sigue el patrón de `MarkdownHighlightCache`: vuelve a analizar y aplicar
  atributos solo en la región afectada. Propaga cambios estructurales, como
  delimitadores de código, hasta recuperar un contexto válido. Conserva una
  actualización completa para cambios que realmente la requieran.
- Prepara índices de búsqueda cuando cambien sus datos, no por cada tecla.
  Evita ordenar subárboles repetidamente, calcula resultados una vez por
  evaluación y detén la búsqueda al alcanzar el límite visible.
- No presupongas que una cadena `lazy` o una caché será más rápida: mide las
  evaluaciones reales y el coste de construir, consultar e invalidar los datos.

## 4. Conserva las vistas y el DOM sin cambios

- Mantén estable la identidad de los componentes nativos. No recrees el editor
  o la WebView por cada revisión, selección o movimiento de scroll.
- En la vista previa, conserva los bloques DOM sin cambios y ejecuta el
  resaltado de código, KaTeX y Mermaid solo donde sea necesario. No restaures
  la sustitución completa de `main.innerHTML` para una edición local.
- Distingue el HTML original del DOM transformado por esas bibliotecas.
  Conserva nodos distintos para bloques duplicados, actualiza `data-line` aunque
  el contenido sea igual y reinicia la reutilización al cambiar de documento
  para no reutilizar recursos relativos de otra nota.
- Evita barridos de geometría por cada evento de scroll. Usa búsquedas acotadas
  y posiciones vigentes; imágenes, fórmulas, tamaño de letra y redimensionado
  pueden invalidar la geometría. Suprime publicaciones de scroll duplicadas.
- Conserva el renderizado local, el escape de contenido y las restricciones de
  URL. La optimización no debe introducir dependencias de red para la vista previa.

## 5. Verifica corrección, rendimiento y límites

- Para cambios de análisis incremental, comprueba equivalencia con el resultado
  completo. Según el alcance, cubre inserción, borrado, deshacer/rehacer,
  cambios de delimitadores, notas vacías y cambios rápidos de documento.
- Los rangos de AppKit son UTF-16 sobre el texto original. Conserva emoji,
  caracteres combinados y CRLF; no normalices texto antes de calcular posiciones
  que después aplicarás al original. Respeta composición IME, selección y undo.
- Prueba invalidación y resultados asíncronos fuera de orden cuando los cambies.
  En WebKit, verifica identidad de nodos y número de renderizados, además del
  contenido final. En tests con vistas ocultas, controla la planificación de
  frames para evitar esperas indefinidas.
- Añade pruebas de regresión que detecten fallos de comportamiento o trabajo
  excesivo; evita pruebas que solo reproduzcan la implementación y umbrales de
  tiempo frágiles. Usa límites de operaciones cuando sean más fiables.
- Ejecuta las suites afectadas; amplía la validación cuando el alcance o los
  fallos lo requieran. Comprueba compilación Release en cambios de rendimiento.
  No repitas pruebas ya satisfactorias sin una modificación o duda que lo justifique.
- Para modificaciones solo de documentación, verifica enlaces y coherencia;
  no es necesario compilar ni ejecutar la aplicación.

## 6. Comunica evidencia reproducible

- Mide con Release o `swiftc -O`, con entradas y configuración comparables.
  `script/build_and_run.sh` usa Debug por defecto. No atribuyas diferencias de
  configuración de compilación a un cambio de algoritmo.
- Usa [el benchmark reproducible](../script/benchmark_performance.swift) y sus
  [instrucciones](editor-performance.md#reproducible-measurements) cuando cubran
  el cambio; amplíalo solo si hace falta. Incluye documentos normales y grandes,
  o árboles amplios, según el camino afectado.
- Especifica qué incluye cada medición: creación del índice, caché fría o
  caliente, parsing, atributos, layout, disco, etc. Contrasta también memoria y
  latencia inicial cuando el ahorro dependa de una caché.
- Para afirmar mejoras de fluidez global, mide interacciones completas en la
  aplicación. Un microbenchmark solo demuestra la mejora del trabajo medido.
- Al entregar, indica qué cambió, su evidencia, pruebas ejecutadas y límites.
  Si una suite falla o se excluye, dilo. Un fallo parecido a uno histórico debe
  investigarse antes de atribuirlo a la misma causa; no lo conviertas en una
  excepción permanente ni declares la batería completa satisfactoria.

Las limitaciones conocidas no obligan a reescribir componentes ajenos al encargo.
Evita extenderlas y deja identificados los costes pendientes que encuentres.
