# Especificación: interlineado entre líneas lógicas del editor

## 1. Objetivo

Añadir una preferencia persistente que permita elegir, en puntos, el espacio vertical extra entre dos líneas **lógicas** distintas del fichero Markdown.

Una línea lógica es una línea delimitada por un salto de línea real (`\n`) en el contenido del fichero. Una línea visual es cada fragmento que `NSTextView` crea cuando una línea lógica larga hace *soft wrap* por falta de anchura.

La regla funcional es:

- Sí se añade espacio después de una línea que termina en `\n` y antes de la siguiente línea lógica.
- No se añade espacio entre los fragmentos visuales producidos por el *soft wrap* de una misma línea lógica.
- La preferencia solo modifica la presentación del editor. No introduce, elimina ni reemplaza caracteres en el Markdown.
- El cambio se ve inmediatamente en los documentos abiertos y persiste al reiniciar la aplicación.
- El valor por defecto es `0 pt`, que conserva exactamente el aspecto actual.

Ejemplo, donde `↵` representa un salto real del fichero y `↳` un *soft wrap* visual:

```text
Línea 1 muy larga que no cabe y se parte... ↳
...continuación visual de la línea 1          ← sin espacio extra
↵                                              ← aplicar aquí el valor configurado
Línea 2
```

Esta funcionalidad se limita al editor AppKit. No debe modificar el HTML de la previsualización, el CSS personalizado, la exportación, el scroll sincronizado, el contenido guardado ni la numeración lógica.

## 2. Decisión técnica obligatoria

Usar `NSMutableParagraphStyle.paragraphSpacing`.

No usar ninguna de estas alternativas:

- `lineSpacing`: añade espacio entre todos los fragmentos visuales, incluidos los *soft wraps*, e incumple el requisito principal.
- insertar saltos de línea o espacios en `textView.string`: modifica el documento.
- cambiar manualmente posiciones de glifos o el tamaño de los fragmentos en `NSLayoutManager`: multiplica el código y duplica una función nativa de AppKit.
- tratar cada token Markdown por separado: el espaciado es una propiedad de párrafo, no de resaltado de sintaxis.

En `NSTextView`, un párrafo termina en un separador de párrafo; para el contenido que maneja Glassmark, cada `\n` separa las líneas lógicas del fichero. `paragraphSpacing` deja intactas las continuaciones visuales de ese párrafo.

El estilo base debe fijar explícitamente:

```swift
let style = NSMutableParagraphStyle()
style.lineSpacing = 0
style.paragraphSpacing = logicalLineSpacing
```

No establecer `paragraphSpacingBefore`: tener una única fuente de espacio después de cada línea evita duplicar el hueco y mantiene el inicio del documento en la misma posición.

## 3. Contrato de la preferencia

### 3.1 Nombre, unidad y límites

Añadir a `PreferencesStore` la preferencia efectiva:

```swift
logicalLineSpacing: Double
```

Persistirla en `UserDefaults.standard` mediante `@AppStorage` con la clave exacta:

```text
logicalLineSpacing
```

Crear junto a `DocumentTextSize`, en `GlassMark/Stores/PreferencesStore.swift`, un namespace sin estado:

```swift
enum DocumentLogicalLineSpacing {
    static let defaultValue = 0.0
    static let minimumValue = 0.0
    static let maximumValue = 100.0
    static let step = 1.0

    static func normalized(_ value: Double) -> Double
}
```

Los valores están expresados en puntos AppKit. El usuario puede elegir cualquier punto entero entre `0` y `100`; no se deben crear presets como “compacto”, “normal” o “amplio”. El límite superior evita valores accidentales capaces de hacer casi inutilizable el documento, sin reducir el control normal de la persona usuaria.

`normalized(_:)` debe cumplir exactamente lo siguiente:

1. Si `value.isFinite` es `false` (`NaN`, `+infinity` o `-infinity`), devolver `defaultValue`.
2. Si es finito, devolverlo limitado al intervalo cerrado `minimumValue...maximumValue`.
3. No redondear dentro de esta función. El `Stepper` escribe incrementos enteros, pero conservar decimales válidos ya persistidos hace el almacenamiento tolerante a versiones futuras.

No exponer directamente el valor crudo de `@AppStorage`. La forma mínima que impide que una preferencia corrupta llegue a AppKit es:

```swift
@AppStorage("logicalLineSpacing")
private var storedLogicalLineSpacing = DocumentLogicalLineSpacing.defaultValue

var logicalLineSpacing: Double {
    get { DocumentLogicalLineSpacing.normalized(storedLogicalLineSpacing) }
    set { storedLogicalLineSpacing = DocumentLogicalLineSpacing.normalized(newValue) }
}
```

El getter normaliza también valores inválidos que ya estuvieran en `UserDefaults`; el setter garantiza que las escrituras nuevas sean válidas. No hace falta una migración: la ausencia de la clave produce `0` y conserva el comportamiento anterior.

### 3.2 Interfaz de Ajustes

En `EditorSettingsView`, debajo de **Line numbers**, añadir un `Stepper` con:

- etiqueta visible en inglés, coherente con el resto de la aplicación: `Logical line spacing: N pt`;
- valor enlazado mediante un `Binding<Double>(get:set:)` a `preferencesStore.logicalLineSpacing`, porque la propiedad calculada no ofrece `$logicalLineSpacing`;
- rango `DocumentLogicalLineSpacing.minimumValue...DocumentLogicalLineSpacing.maximumValue`;
- paso `DocumentLogicalLineSpacing.step`;
- texto de ayuda: `Adds space between separate Markdown source lines, not between wrapped parts of one long line.`

Mostrar `N` sin decimales cuando sea entero. No añadir un botón “Apply”: el cambio es inmediato. El control debe estar siempre disponible, independientemente de que la numeración de líneas esté visible; la numeración sirve para explicar el concepto, pero no es un requisito para aplicar el espaciado.

No añadir comandos de menú ni atajos de teclado para esta primera versión.

Implementación de referencia del binding y el control (se puede extraer el binding a una propiedad privada para mantener corto el `body`):

```swift
private var logicalLineSpacingBinding: Binding<Double> {
    Binding(
        get: { preferencesStore.logicalLineSpacing },
        set: { preferencesStore.logicalLineSpacing = $0 }
    )
}

Stepper(
    "Logical line spacing: \(preferencesStore.logicalLineSpacing.formatted(.number.precision(.fractionLength(0...1)))) pt",
    value: logicalLineSpacingBinding,
    in: DocumentLogicalLineSpacing.minimumValue...DocumentLogicalLineSpacing.maximumValue,
    step: DocumentLogicalLineSpacing.step
)
Text("Adds space between separate Markdown source lines, not between wrapped parts of one long line.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

No usar un binding al valor privado crudo: toda escritura debe pasar por el setter normalizado.

## 4. Flujo exacto del valor hasta AppKit

### 4.1 `EditorView`

Al construir `MarkdownTextView`, pasar:

```swift
logicalLineSpacing: preferencesStore.logicalLineSpacing
```

Colocarlo junto a `fontSize`, ya que ambos son métricas visuales del editor.

### 4.2 `MarkdownTextView`

Añadir:

```swift
let logicalLineSpacing: Double
```

En `makeNSView`, llamar a un método del coordinator para almacenar el valor **antes** de la primera llamada a `applyHighlighting()`.

En `updateNSView`, actualizar primero el tamaño de fuente y el espaciado, y ejecutar `applyHighlighting()` una sola vez si ha cambiado cualquiera de los dos:

```swift
let fontChanged = context.coordinator.setFontSize(CGFloat(fontSize))
let spacingChanged = context.coordinator.setLogicalLineSpacing(CGFloat(logicalLineSpacing))
if fontChanged || spacingChanged {
    context.coordinator.applyHighlighting()
}
```

Las dos llamadas deben ir en sentencias separadas. No escribir:

```swift
if setFontSize(...) || setLogicalLineSpacing(...) { ... }
```

porque `||` hace cortocircuito y podría omitir la actualización del espaciado cuando también cambia la fuente.

Mantener el orden actual del resto de `updateNSView`. Un cambio visual no debe reasignar `textView.string`, tocar el binding `text`, mover la selección, crear una acción de undo, marcar el documento como modificado ni disparar autosave.

### 4.3 `Coordinator`

Añadir estado privado con valor inicial seguro:

```swift
private var logicalLineSpacing = CGFloat(DocumentLogicalLineSpacing.defaultValue)
```

Añadir:

```swift
@discardableResult
func setLogicalLineSpacing(_ newValue: CGFloat) -> Bool
```

El método debe:

1. Convertir a `Double` y llamar a `DocumentLogicalLineSpacing.normalized` incluso aunque el store ya normalice. Esta segunda frontera protege al coordinator en tests y futuros usos directos.
2. Convertir el resultado a `CGFloat`.
3. Compararlo con el valor actual usando una tolerancia de `0.001`, igual que `setFontSize`.
4. Guardarlo y devolver `true` solo si cambió; en caso contrario devolver `false`.
5. No aplicar atributos por sí mismo. El llamador agrupa el cambio con otras métricas y evita resaltar dos veces.

Implementación de referencia:

```swift
@discardableResult
func setLogicalLineSpacing(_ newValue: CGFloat) -> Bool {
    let normalized = CGFloat(
        DocumentLogicalLineSpacing.normalized(Double(newValue))
    )
    guard abs(logicalLineSpacing - normalized) > 0.001 else { return false }
    logicalLineSpacing = normalized
    return true
}
```

Crear una propiedad calculada privada que devuelva un estilo nuevo e inmutable para cada aplicación:

```swift
private var baseParagraphStyle: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 0
    style.paragraphSpacing = logicalLineSpacing
    return style.copy() as! NSParagraphStyle
}
```

No conservar y mutar una única instancia de `NSMutableParagraphStyle` después de insertarla en `NSTextStorage`: los atributos pueden compartir esa referencia y provocar cambios fuera de una edición controlada.

### 4.4 Resaltado y escritura nueva

`applyHighlighting()` actualmente reemplaza todos los atributos base con `setAttributes`. Añadir `.paragraphStyle` en esa misma operación:

```swift
let paragraphStyle = baseParagraphStyle
textStorage.setAttributes(
    [
        .font: baseFont,
        .foregroundColor: NSColor.textColor,
        .paragraphStyle: paragraphStyle
    ],
    range: fullRange
)
```

Esta debe ser la única pasada sobre el documento para aplicar el espaciado. Las llamadas posteriores a `apply(_:to:)` para headings, énfasis, código, etc. usan `addAttribute` y no deben reemplazar `.paragraphStyle`.

En `syncTypingAttributes()`, incluir siempre:

```swift
.paragraphStyle: baseParagraphStyle
```

Además de fuente y color. Al copiar los atributos cercanos al cursor, seguir copiando solo fuente y color; no adoptar un estilo de párrafo arbitrario del carácter anterior. Glassmark es un editor de texto plano y toda línea usa la misma preferencia.

Esto es obligatorio para que:

- un documento vacío empiece a escribir con el estilo correcto;
- una nueva línea tenga el espaciado correcto en el mismo ciclo de edición;
- no aparezca un salto visual al esperar a que el resaltador vuelva a ejecutar.

No cambiar `MarkdownSyntaxHighlighter`: clasifica tokens y no debe conocer geometría.

## 5. Numeración de líneas y geometría

El gutter ya enumera solo el primer fragmento visual de cada línea lógica. Esa lógica debe conservarse sin cambios: el criterio `location == 0 || carácter anterior == \n` es correcto y el espaciado no crea caracteres.

Sí hay que evitar que el número quede centrado incluyendo el hueco añadido tras el párrafo. En `LineNumberGutterView.labels(in:)`, la clausura de `enumerateLineFragments` recibe tanto `fragmentRect` como `usedRect`. Usar el rectángulo ocupado por el texto como ancla vertical:

```swift
layoutManager.enumerateLineFragments(...) {
    fragmentRect, usedRect, _, fragmentGlyphRange, _ in
    let anchorRect = usedRect.height > 0 ? usedRect : fragmentRect
    // ... conservar el filtro de inicio de línea lógica ...
    rect: self.gutterRect(forContainerRect: anchorRect)
}
```

El fallback cubre fragmentos vacíos si AppKit informa un `usedRect` sin altura. Para la última línea vacía, usar `extraLineFragmentUsedRect` si tiene altura y, en caso contrario, `extraLineFragmentRect`.

No restar manualmente el espaciado ni pasar la preferencia al gutter. El gutter debe leer la geometría final de `NSLayoutManager`, que ya incluye tamaño de fuente, headings, líneas vacías y cualquier cambio futuro.

Después de aplicar el estilo, `applyHighlighting()` ya llama a `refreshGutter()`. Conservar esa llamada para recalcular y repintar las posiciones. No cambiar el ancho del gutter: el espaciado solo afecta al eje vertical.

## 6. Casos límite obligatorios

| Caso | Resultado requerido |
| --- | --- |
| Preferencia ausente | `0 pt`; apariencia idéntica a la versión anterior. |
| `0` | Ningún espacio extra. |
| `100` | Se aplica `100 pt` entre líneas lógicas y el editor sigue desplazándose correctamente. |
| Valor menor que `0` | Valor efectivo `0`. |
| Valor mayor que `100` | Valor efectivo `100`. |
| `NaN` o infinito en defaults/llamada directa | Valor efectivo `0`; nunca pasar un valor no finito a AppKit. |
| Documento vacío | No falla; al escribir, los atributos contienen el estilo. |
| Una sola línea sin `\n` | No aparece espacio dentro de sus *soft wraps*. |
| Dos líneas lógicas | Solo aumenta la distancia entre ambas. |
| Línea larga seguida de otra | Ningún hueco entre wraps; un hueco antes de la segunda línea lógica. |
| Líneas vacías consecutivas | Cada línea vacía sigue siendo una línea lógica y conserva su altura normal más el espacio configurado. |
| Salto final | El gutter sigue mostrando la última línea vacía y no falla. |
| Headings/código/listas | Mantienen fuente y color; todos reciben el mismo espaciado lógico. |
| Focus mode | Solo cambia colores; no elimina el estilo de párrafo. |
| Cambio de tamaño de texto | Fuente y espaciado sobreviven, con una sola reaplicación de highlighting. |
| Cambio de preferencia con selección/cursor | Texto y selección quedan byte/UTF-16-exactos; no hay undo ni dirty state. |
| Numeración oculta | El espaciado se sigue aplicando. |
| Documento mayor de 200 000 UTF-16 | Se omite el resaltado detallado como ahora, pero el estilo base y el espaciado se aplican a todo el texto. |

## 7. Pruebas que debe añadir la implementación

No se considera terminada la funcionalidad solo por inspección visual. Añadir pruebas automatizadas con geometría real de TextKit.

### 7.1 `PreferencesStoreTests.swift`

Ampliar el aislamiento de `UserDefaults` para guardar, borrar y restaurar también la clave `logicalLineSpacing`, incluso si una aserción falla.

Añadir como mínimo:

1. `testLogicalLineSpacingDefaultsToZero`
   - crear un store con la clave borrada;
   - comprobar `0`.

2. `testLogicalLineSpacingPersistsAcrossStores`
   - escribir un valor válido en un store;
   - crear otro store;
   - comprobar el mismo valor.

3. `testLogicalLineSpacingNormalizesInvalidValues`
   - probar por separado menor que mínimo, mayor que máximo, `Double.nan`, `.infinity` y `-.infinity`;
   - comprobar los resultados exactos descritos en §3.1.

4. `testLogicalLineSpacingPublishesChanges`
   - observar `objectWillChange` como ya hace el test de tamaño;
   - cambiar el valor mediante la propiedad pública;
   - comprobar al menos una notificación.

### 7.2 Nuevo `EditorLogicalLineSpacingTests.swift`

Construir un `NSTextView` con anchura fija, `isHorizontallyResizable = false`, `widthTracksTextView = true`, un `Coordinator` real y `ensureLayout(for:)`. No crear un algoritmo falso solo para las pruebas.

Añadir como mínimo:

1. `testParagraphStyleIsAppliedToExistingTextAndTypingAttributes`
   - texto con dos líneas;
   - fijar `17 pt` y ejecutar `applyHighlighting()`;
   - comprobar `.paragraphStyle.paragraphSpacing == 17` en caracteres de ambas líneas;
   - comprobar lo mismo en `textView.typingAttributes`;
   - comprobar `.lineSpacing == 0`.

2. `testSpacingChangesOnlyTheBoundaryBetweenLogicalLines`
   - primera línea suficientemente larga para producir al menos dos fragmentos con el ancho del test, seguida por `\nsecond`;
   - capturar los `minY` de todos los fragmentos con `0 pt` y con `20 pt`;
   - verificar la precondición de que la primera línea tiene *soft wrap*;
   - comprobar, con tolerancia `0.5`, que la distancia entre dos fragmentos consecutivos de la primera línea no cambia;
   - comprobar que la distancia desde el último fragmento de la primera línea al fragmento de `second` aumenta `20 pt`.

3. `testChangingSpacingDoesNotChangeTextSelectionOrUndo`
   - guardar el texto exacto, el rango seleccionado y `undoManager?.canUndo`;
   - cambiar solo el espaciado y aplicar highlighting;
   - comprobar que los tres valores siguen iguales.

4. `testInvalidCoordinatorSpacingIsNormalized`
   - llamar directamente con valores negativos, excesivos y no finitos;
   - ejecutar highlighting;
   - comprobar el valor de `.paragraphStyle` efectivo.

5. `testEmptyDocumentUsesSpacingForNewTyping`
   - documento vacío;
   - aplicar `12 pt`;
   - comprobar los typing attributes sin acceder al índice `0` del storage.

### 7.3 `LineNumberGutterViewTests.swift`

Permitir que el helper de construcción aplique un paragraph style con espaciado y añadir:

1. `testLogicalSpacingDoesNotCreateNumbersForWrappedFragments`
   - línea larga con varios wraps y una segunda línea;
   - comprobar que los números siguen siendo `[1, 2]` con espaciado distinto de cero.

2. `testGutterLabelsStayCenteredOnTextWhenLogicalSpacingIsLarge`
   - usar `40 pt`;
   - obtener el `usedRect` del primer fragmento de cada línea;
   - comprobar que el `midY` del rectángulo del label coincide con el `midY` convertido del `usedRect`, tolerancia `0.5`;
   - esta prueba debe fallar si se centra el número sobre un `fragmentRect` que incorpora el hueco.

3. Conservar y ejecutar los tests existentes de líneas vacías, salto final, visibilidad, ancho y documento hospedado. No debilitar sus aserciones para acomodar la función nueva.

## 8. Archivos que deben cambiar

El cambio debe quedar limitado a:

| Archivo | Cambio |
| --- | --- |
| `GlassMark/Stores/PreferencesStore.swift` | Constantes, normalización y preferencia persistente. |
| `GlassMark/Views/SettingsView.swift` | Un `Stepper` y su binding. |
| `GlassMark/Views/EditorView.swift` | Pasar el valor, guardarlo en el coordinator y aplicarlo como paragraph style/typing attribute. |
| `GlassMark/Views/LineNumberGutterView.swift` | Anclar números al `usedRect` del texto. |
| `GlassMarkTests/PreferencesStoreTests.swift` | Defaults, persistencia, normalización y publicación. |
| `GlassMarkTests/EditorLogicalLineSpacingTests.swift` | Semántica y regresiones TextKit. |
| `GlassMarkTests/LineNumberGutterViewTests.swift` | Numeración y alineación con espaciado. |

No añadir dependencias, servicios, modelos de documento, migraciones, recursos ni cambios a `project.yml`. XcodeGen incluye automáticamente los `.swift` bajo las carpetas ya declaradas.

## 9. Orden de implementación recomendado

1. Añadir `DocumentLogicalLineSpacing`, la normalización y los tests puros de preferencias.
2. Añadir el control de Ajustes.
3. Pasar el valor `EditorView → MarkdownTextView → Coordinator`.
4. Añadir `.paragraphStyle` al resaltado base y a los typing attributes.
5. Añadir las pruebas geométricas que distinguen línea lógica de *soft wrap*.
6. Cambiar el gutter a `usedRect` y añadir sus regresiones.
7. Ejecutar la suite completa.

Este orden hace que un fallo indique con claridad si pertenece a persistencia, propagación, TextKit o gutter.

## 10. Verificación final y criterios de aceptación

Antes de entregar, ejecutar desde la raíz:

```bash
xcodegen generate
xcodebuild \
  -project GlassMark.xcodeproj \
  -scheme GlassMark \
  -derivedDataPath DerivedData \
  test
```

La implementación solo se acepta si se cumplen todos estos puntos:

- La suite completa compila y pasa, no solo los tests nuevos.
- Con `0 pt`, la geometría coincide con el comportamiento anterior.
- Al aumentar el valor, se separan las líneas que tienen números distintos.
- Los fragmentos envueltos que comparten número conservan su separación normal.
- El gutter mantiene exactamente un número por línea lógica y el número se alinea con el texto, no con el hueco.
- Cambiar el valor actualiza el editor abierto sin modificar el Markdown, dirty state, selección ni historial de undo.
- Cerrar y volver a abrir la aplicación conserva el valor.
- Valores corruptos o no finitos nunca llegan a `NSMutableParagraphStyle`.
- No se modifica la previsualización ni la exportación.
- No se introduce código alternativo para documentos grandes: el estilo base sigue aplicándose aunque se omita el resaltado detallado.

## 11. Comprobación manual breve

Después de pasar los tests, abrir un fichero con este contenido en una ventana estrecha:

```markdown
Esta es una línea lógica deliberadamente muy larga para que se divida visualmente en tres o más fragmentos sin contener ningún salto manual.
Segunda línea lógica.

# Cuarta línea lógica y heading
```

Con los números visibles, alternar entre `0`, `12` y `40 pt` y comprobar:

1. Los fragmentos de la primera línea siguen juntos y todos pertenecen al número `1`.
2. El hueco aparece antes de los números `2`, `3` y `4`.
3. La línea vacía número `3` sigue existiendo.
4. Los números permanecen centrados junto al primer fragmento de cada línea.
5. Guardar el fichero no produce ningún diff si no se ha escrito texto.
6. Reiniciar la aplicación conserva el último valor elegido.
