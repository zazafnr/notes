# FreeNotes: iPad-Notiz-App mit KI-Kreis-Werkzeug

Eine eigene GoodNotes-Alternative für die Schule:

- ✍️ Mit dem **Apple Pencil** schreiben (PencilKit: Stifte, Marker, Radierer, Lineal, Lasso), zoomen, Doppeltippen/Drücken auf dem Pencil
- 📚 **Fächer** mit Farbe und Symbol, Hefte mit Papier blanko, liniert, kariert oder gepunktet, sortieren und durchsuchen
- 📷 Buchseiten und Arbeitsblätter **scannen**, **Fotos/Screenshots** und **PDFs** einfügen, per Drag & Drop
- 🖼️ Bilder auf der Seite **verschieben, skalieren und löschen**
- 📄 Seiten hinzufügen, duplizieren, umsortieren und löschen; **blättern** per Wischen (seitlich oder nach oben/unten)
- ✨ **KI-Kreis**: Aufgabe einkreisen → »Lösen«, »Erklären«, »Schritt für Schritt«, »Nur Tipp« … → Antwort erscheint direkt neben der Seite und kann auf die Seite eingefügt werden
- 🧮 Formeln in KI-Antworten werden schön gesetzt (KaTeX); ohne Internet als lesbarer Text
- 💬 **KI-Chat** pro Heft und allgemein, mit Bild-Anhängen und der aktuellen Seite
- 🔎 **Handschrift durchsuchbar**: Texterkennung beim Schließen eines Hefts
- 🆓 Kostenlose KI: **Google Gemini** (Standard) oder **OpenRouter**, mit automatischem Wechsel bei Limit
- 📤 Export als **PDF**
- Animationen, Haptik, Hell-/Dunkelmodus, Liquid Glass ab iPadOS 26, Zoom-Übergang ab iPadOS 18

## Auf dem iPad starten (ohne Mac)

1. Auf dem iPad die kostenlose App **Swift Playgrounds** aus dem App Store laden.
2. In Safari dieses Repo öffnen, oben den Branch mit der App wählen (solange sie noch nicht in `main` ist: `claude/chat-ios-notizbuch-ki-yx5ny3`) → grüner Button **Code** → **Download ZIP**.
3. In der **Dateien**-App die ZIP antippen (wird entpackt) und den Ordner **`FreeNotes.swiftpm`** antippen. Er öffnet sich in Swift Playgrounds.
4. Oben auf **▶︎ Ausführen** tippen.
5. Beim ersten Start den kostenlosen Gemini-Key eintragen ([aistudio.google.com/apikey](https://aistudio.google.com/apikey)).

## Später mit einem Mac (eigenes App-Icon)

Siehe [`MAC-INSTALL.md`](MAC-INSTALL.md).

## Projektaufbau

```
FreeNotes.swiftpm/
  App/         Einstieg der App
  Models/      Fächer, Hefte, Seiten, Chats
  Storage/     Speichern als JSON und PencilKit-Dateien
  Library/     Startseite mit Fächern und Heft-Covern
  Editor/      Seite mit Pencil, Papier, Bildern, Seitenverwaltung, PDF-Export
  AILasso/     Leuchtende Kreis-Auswahl und Frage-Fenster
  AI/          Gemini/OpenRouter-Client, Prompts, Einstellungen, Schlüsselbund
  Chat/        KI-Seitenleiste, Chat, Markdown-Darstellung
  Import/      Dokumentenscanner, Kamera, Teilen
  Settings/    Einstellungen
  Onboarding/  Einführung beim ersten Start
```

Jeder Push kompiliert die App automatisch auf einem Cloud-Mac mit Xcode 16 und Xcode 26 und führt die Logik-Tests in `LogicTests/` aus (GitHub Actions, `.github/workflows/build.yml`).
Der ursprüngliche Plan steht in [`docs/PLAN.md`](docs/PLAN.md).
