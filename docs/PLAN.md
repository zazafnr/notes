# FreeNotes: iPad-Notiz-App mit KI-Kreis-Werkzeug

## Kontext
Du willst GoodNotes durch eine eigene iPad-App für die Schule ersetzen. Die App soll können:
- mit dem Apple Pencil schreiben
- Arbeitsblätter und Buchseiten mit der Kamera scannen
- Ordner pro Fach anlegen
- Screenshots und Bilder einfügen

Das Besondere: Du **kreist eine Aufgabe mit dem Pencil ein**. Der Ausschnitt geht zusammen mit deiner Anweisung („Lös das“, „Erklär mir das“ …) an ein kostenloses KI-Modell, und die Antwort erscheint direkt in der App. Außerdem gibt es einen normalen KI-Chat. Das Design soll clean und professionell sein, mit Animationen.

Der Projektordner `C:\Users\hluka\Documents\free notes` ist leer, wir starten also bei null.

## Entscheidungen
- **Kein Mac (frühestens in ca. 1 Woche):** Wir bauen ein **Swift-Playgrounds-App-Paket** (`FreeNotes.swiftpm`). Das läuft sofort auf dem iPad in der kostenlosen App „Swift Playgrounds“. Später lässt sich dasselbe Paket in Xcode auf einem Mac öffnen und als eigenes App-Icon installieren.
- **KI:** Beide Anbieter sind in der App wählbar. Standard ist **Google Gemini Flash** (kostenloser Key von aistudio.google.com), dazu kommt **OpenRouter** mit `:free`-Modellen. Beide sprechen dasselbe Format („OpenAI-kompatibel“), deshalb reicht ein einziger KI-Client. Der Hinweis gehört auch in die App: Es gibt Tageslimits, z. B. bei OpenRouter 50 Anfragen pro Tag (1000, wenn man einmal 10 $ Guthaben kauft) und 20 pro Minute. Erreicht ein Anbieter sein Limit, kann die App automatisch zum anderen wechseln.
- **Hardware:** iPad Pro mit Magnet-Pencil, also Apple Pencil 2 oder Pencil Pro. Wir nutzen `UIPencilInteraction`: Doppeltippen und Squeeze (Drücken) schalten das KI-Werkzeug ein. Das KI-Werkzeug hat zusätzlich immer einen eigenen Button.
- **Keine externen Pakete:** Nur Apple-Frameworks (SwiftUI, PencilKit, VisionKit, PDFKit, PhotosUI, WebKit). So gibt es in Swift Playgrounds keine Probleme beim Laden von Paketen.
- **App-Sprache:** Deutsch.

## Entwicklungsablauf ohne Mac
1. Ich schreibe den Code hier in `free notes\FreeNotes.swiftpm\`.
2. **Ich prüfe, ob der Code fehlerfrei kompiliert (empfohlen):** Eine GitHub-Actions-Pipeline baut den Code automatisch auf einem Mac in der Cloud.
   - Verwendet wird `macos-15` mit **Xcode 16** (iOS-18-SDK), weil Swift Playgrounds auf dem iPad ebenfalls ein älteres SDK nutzt.
   - So sehe und behebe ich Kompilierfehler selbst, bevor du etwas testest.
   - Du musst dafür einmal `gh auth login` ausführen. `git` und `gh` sind bei dir schon installiert, du bist aber noch nicht eingeloggt.
   - Ein öffentliches Repo hat unbegrenzte Gratis-Minuten. Ein privates Repo hat ca. 200 Mac-Minuten pro Monat, das sind ungefähr 40 Builds.
3. **Code aufs iPad bringen:** Mit „iCloud für Windows“ (kostenlos im Microsoft Store). Ein Skript `sync-to-icloud.ps1` kopiert das Paket nach iCloud Drive. Auf dem iPad öffnest du dann in der Dateien-App `FreeNotes.swiftpm`, es öffnet sich in Swift Playgrounds, und du tippst auf „Ausführen“.
   - Alternative ohne iCloud: Das Skript erstellt eine ZIP-Datei, die du per Mail oder USB aufs iPad schickst.
4. Du testest die App auf dem iPad und schickst mir Screenshots oder Fehlermeldungen.
5. **Später mit Mac:** Paket in Xcode öffnen, mit deiner kostenlosen Apple-ID signieren und installieren. Danach hat die App ein eigenes Icon, muss aber alle 7 Tage neu signiert werden. Dafür schreibe ich eine Anleitung `MAC-INSTALL.md`.

## Architektur
```
FreeNotes.swiftpm/
  Package.swift            Swift-Tools-Version 5.9, AppleProductTypes .iOSApplication,
                           nur iPad, Kamera- und Fotomediathek-Berechtigungen, Kategorie Education
  App/                     FreeNotesApp.swift, AppState (aktuelle Auswahl, Sheets)
  Models/                  Subject (Fach: Name, Farbe, Symbol), Notebook, Page
                           (Hintergrund: leer/liniert/kariert/Punkte/Bild/PDF-Seite,
                           Zeichnungsdaten, Bild-Elemente), ChatThread, ChatMessage
  Storage/                 LibraryStore (ObservableObject, als JSON gespeichert), Dateien:
                           Documents/Library/subjects.json
                           Documents/Notebooks/<id>/notebook.json, pages/<pageId>.drawing,
                           assets/<id>.jpg, thumbs/<pageId>.jpg
                           Automatisches Speichern kurz nach jeder Änderung
  Library/                 Startseite: Seitenleiste (Fächer, Zuletzt, Favoriten, KI-Chat)
                           und Raster mit Heft-Covern, Sheets zum Erstellen und Bearbeiten
  Editor/                  NotebookEditorView (SwiftUI-Hülle mit eigener Werkzeugleiste),
                           PageViewController (Blättern horizontal oder vertikal, einstellbar),
                           PageCanvasController (PKCanvasView mit Hintergrund-Ebene, die beim
                           Zoomen mit skaliert), PaperTemplateView, ImageItemView (verschieben,
                           Größe ändern, löschen), Seitenübersicht
  AI/                      AIProvider (Gemini/OpenRouter: Basis-URL, Modell), AIClient
                           (Antworten werden gestreamt, d. h. Wort für Wort angezeigt),
                           ModelCatalog (lädt die Modellliste vom Anbieter, bei OpenRouter
                           gefiltert auf kostenlos + Bilderkennung), PromptBuilder
                           (Tutor-Anweisung auf Deutsch, Fach als Kontext, Formeln in LaTeX),
                           KeychainStore (API-Keys sicher gespeichert)
  AILasso/                 LassoOverlayView (Schleife mit Leuchteffekt), SnapshotRenderer
                           (Ausschnitt in Seitenkoordinaten scharf rendern: Hintergrund + Bilder
                           + Zeichnung, max. 1600 px, JPEG), AskPopover (Vorschaubild,
                           Schnellaktionen, Eingabefeld)
  Chat/                    AIPanelView (Seitenleiste rechts), ChatView, MarkdownMathView
                           (WKWebView mit marked + KaTeX in festen Versionen von jsDelivr,
                           Text wird live nachgeladen), „Auf Seite einfügen“ (Antwort als Bild)
  Import/                  DocumentScanner (VisionKit), PhotosPicker, Einfügen aus der
                           Zwischenablage, Drag & Drop, PDF-Import (PDFKit, jede Seite als Bild)
  Export/                  PDF-Export (Hintergrund + Bilder + Zeichnung) und Teilen
  Design/                  Theme (Farben für hell und dunkel, KI-Farbverlauf), Animationen,
                           Glass-Effekt (siehe unten), Haptik
  Settings/                Anbieter, Keys, Modell, Auto-Wechsel bei Limit, Klassenstufe,
                           Doppeltippen/Squeeze-Aktion, Blätterrichtung
.github/workflows/build.yml   Pipeline, die den Code auf einem Cloud-Mac kompiliert
sync-to-icloud.ps1            Skript: Paket in iCloud Drive kopieren oder als ZIP packen
```

Wichtige technische Entscheidungen:
- **Zeichenfläche und Zoom:** Die PencilKit-Zeichenfläche (`PKCanvasView`) übernimmt das Zoomen selbst. Dahinter liegt eine Hintergrund-Ebene (Papiermuster, Scan, Bilder), die beim Zoomen mit vergrößert wird (über `scrollViewDidZoom`). Das Papiermuster wird nach dem Zoomen in voller Auflösung neu gezeichnet, damit die Linien scharf bleiben. Mit dem Finger verschiebst und zoomst du, mit dem Pencil zeichnest du (`drawingPolicy = .pencilOnly`).
- **Zeichenwerkzeuge:** Apples eingebaute Werkzeugleiste `PKToolPicker` (Stifte, Marker, Radierer, Lasso, Lineal, Farben). Darüber kommt eine eigene schwebende Leiste: KI ✨, Bild, Scan, Seite +, KI-Panel, Rückgängig/Wiederholen.
- **Speicherung:** JSON-Dateien statt SwiftData und `ObservableObject` statt `@Observable`. Das ist sicher kompatibel mit Swift Playgrounds, weil keine Makros nötig sind.

## KI-Kreis-Werkzeug (Kernfunktion)
1. Du aktivierst das Werkzeug: per Button ✨, Doppeltippen oder Squeeze auf dem Pencil.
2. Du ziehst eine Schleife um die Aufgabe. Dabei erscheint eine leuchtende, animierte Linie mit Farbverlauf (ähnlich wie bei Siri), und du spürst ein leichtes haptisches Feedback.
3. Beim Loslassen schließt sich die Schleife. Aus dem umschließenden Rechteck plus etwas Rand wird ein scharfes Bild gerendert.
4. Ein Popover erscheint neben der Auswahl:
   - Vorschaubild des Ausschnitts
   - Schnellaktionen: **Lösen**, **Erklären**, **Schritt für Schritt**, **Nur Tipp**, **Zusammenfassen**, **Text schreiben**, **Übersetzen**
   - Ein Eingabefeld „Frag etwas…“. Dort kannst du dank Scribble auch direkt mit dem Pencil schreiben.
5. Das KI-Panel gleitet von rechts herein. Die Antwort erscheint Wort für Wort, mit Markdown und Formeln (KaTeX). Du kannst im selben Verlauf Rückfragen stellen.
   - Buttons: **Auf Seite einfügen**, **Kopieren**, **Neu generieren**
   - Der Verlauf wird pro Heft gespeichert.
6. **Allgemeiner Chat:** Erreichbar über die Seitenleiste und im Editor. Du kannst die ganze Seite oder Fotos anhängen.
7. **Fehler werden freundlich erklärt:** Kein Key, Limit erreicht (dann Wechsel zum anderen Anbieter, falls aktiviert), oder keine Internetverbindung.

## Design und Bewegung
- Ruhiges, papierartiges Grundlayout. Jedes Fach hat eine eigene Farbe, die KI hat als Akzent einen Indigo-Violett-Verlauf. Hell- und Dunkelmodus werden unterstützt.
- **Animationen:**
  - Federnde Übergänge
  - Das Heft-Cover vergrößert sich beim Öffnen fließend zum Editor (`.navigationTransition(.zoom)` ab iOS 18, auf älteren Systemen eine einfache Ersatz-Animation)
  - Kleine Animationen an Symbolen (`symbolEffect`)
  - Raster-Elemente werden beim Scrollen sanft eingeblendet (`scrollTransition`)
  - Ein Schimmer-Effekt, während die KI „nachdenkt“ (`phaseAnimator`)
  - Abheben beim Darüberfahren mit dem Pencil (`hoverEffect`)
  - Haptik (`sensoryFeedback`)
- **Glass-Effekt:** Apples neues „Liquid Glass“ (`glassEffect`) gibt es nur im neuesten SDK. Ich baue es deshalb nur ein, wenn mit Xcode 26 kompiliert wird (`#if compiler(>=6.2)`). In Swift Playgrounds wird automatisch `.ultraThinMaterial` (Milchglas-Effekt) verwendet, damit es dort keine Kompilierfehler gibt.
- **Onboarding beim ersten Start:** Kurzer Assistent zum Eintragen des API-Keys, mit Anleitung, wie man einen Gemini-Key bekommt.

## Umsetzung in Phasen (jede Phase ist auf dem iPad testbar)
1. **Grundgerüst:** `Package.swift`, eine minimale App, Build-Pipeline und `sync-to-icloud.ps1`. Damit prüfen wir, dass der Weg auf dein iPad funktioniert.
2. **Bibliothek und Editor:**
   - Fächer, Ordner und Hefte anlegen, umbenennen, löschen und sortieren
   - Papiervorlagen
   - Mit dem Pencil zeichnen
   - Seiten hinzufügen, löschen und blättern
   - Automatisches Speichern und Vorschaubilder
3. **KI:** Einstellungen und Keys, KI-Client mit Live-Antwort, Kreis-Werkzeug, Popover, KI-Panel mit Formeln, Chat, Pencil-Gesten, Antwort auf der Seite einfügen.
4. **Import und Export:** Scanner, Fotos und Screenshots, Einfügen, Drag & Drop, PDF-Import, Bilder verschieben und skalieren, PDF-Export und Teilen.
5. **Feinschliff:**
   - Animationen und Übergänge
   - Onboarding, App-Icon und Suche nach Titeln
   - Optional: Handschrift durchsuchbar machen (Texterkennung mit Vision)
   - Anleitung `MAC-INSTALL.md`

## Risiken und Ausweichlösungen
- **Swift Playgrounds hinkt dem neuesten SDK hinterher:** Darum kompiliert die Pipeline mit Xcode 16 und ich verwende keine Funktionen, die nur in iOS 26 existieren.
- **VisionKit-Scanner in Playgrounds nicht bestätigt:** Falls er dort nicht funktioniert, nehme ich die Kamera mit `UIImagePickerController` und schneide die Seite mit Vision-Rechteckerkennung zu.
- **Kostenlose Modelle ändern sich häufig:** Die Modellliste wird deshalb live vom Anbieter geladen, und du kannst die Modell-ID selbst eintragen.
- **Keychain in Playgrounds:** Falls das sichere Speichern der Keys dort nicht klappt, speichere ich sie notfalls in `UserDefaults` und zeige einen Hinweis.

## Verifikation
- **Bei jedem Schritt:** Die Pipeline kompiliert für den iPad-Simulator (`xcodebuild … -destination 'generic/platform=iOS Simulator'`). Ich lese die Logs mit `gh run view --log-failed` und behebe Fehler, bevor du etwas aufs iPad lädst.
- **Logik testen:** Kleine Unit-Tests in der Pipeline für den Antwort-Parser des KI-Clients, das Laden und Speichern der JSON-Dateien und die Prompt-Erstellung.
- **Auf dem iPad, nach jeder Phase eine Checkliste:**
  - Heft anlegen, schreiben, App schließen und wieder öffnen: Ist alles noch da?
  - Aufgabe im gescannten Mathebuch einkreisen, „Lösen“ tippen: Kommt die Antwort mit Formeln?
  - Mit ungültigem Key testen: Erscheint eine verständliche Fehlermeldung?
  - Doppeltippen bzw. Squeeze: Wird das KI-Werkzeug aktiviert?
  - PDF exportieren.
