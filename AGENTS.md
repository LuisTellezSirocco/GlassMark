# GlassMark

Antes de modificar la implementación, lee y sigue [los principios de rendimiento](docs/performance-principles.md).

- Minimiza el trabajo del hilo de la interfaz; reutiliza índices, análisis y vistas sin cambios.
- Toda caché debe tener invalidación correcta y memoria acotada; todo resultado asíncrono debe pertenecer al estado vigente.
- Conserva la corrección del editor, los archivos y la vista previa al optimizar.
- Justifica las mejoras con mediciones optimizadas y pruebas pertinentes. Informa de límites y fallos; no extrapoles un microbenchmark a toda la aplicación.
