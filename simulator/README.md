# iOS-Simulator am PC

iPhone und iPad am Windows-PC bedienen, mit **echtem iOS** (aktuell iOS 27) und deiner eigenen App, z. B. FreeNotes.

## Wie es funktioniert

iOS läuft nur auf Apple-Hardware. Die PC-App startet deshalb über GitHub Actions einen **Mac in der Cloud**. Dort laufen Apples offizielle iPhone- und iPad-Simulatoren, und die PC-App zeigt ihren Bildschirm in einem Gerätefenster:

```
Windows-PC (PC-App)  ⇄  Cloudflare-Tunnel  ⇄  Cloud-Mac (GitHub Actions)
  Gerätefenster                               iOS-Simulator iPhone + iPad
  Maus = Finger, Tastatur                     Steuer-Server (simulator/server)
```

- **Oberfläche und Funktionen sind echtes iOS**, kein Nachbau: Home-Bildschirm, Kontrollzentrum, Einstellungen, Safari, Fotos, Dateien, Kalender, Erinnerungen, Kontakte, Karten, Nachrichten und die übrigen Apple-Apps, die im Simulator enthalten sind.
- **Deine App** wird aus einem Branch des Repos gebaut und installiert (Standard: `claude/chat-ios-notizbuch-ki-yx5ny3` = FreeNotes). Nach einem Push genügt **⚒ App neu bauen**, und der neue Stand läuft nach etwa 1–2 Minuten.
- **Andere Apps:** im Startfenster einen anderen Branch wählen (das erste `.swiftpm`, `.xcworkspace` oder `.xcodeproj` wird gebaut) oder unter **App-Datei installieren** einen Simulator-Build als `.zip` hochladen.
- **Leerer Simulator:** bei »App zum Testen« den Eintrag *Keine eigene App* wählen. Dann sind nur die Apple-Apps drauf.

## Einrichten (einmalig)

1. **PC-App laden:** auf GitHub unter **Releases → »iOS-Simulator für Windows«** die `iOS-Simulator-Setup-….exe` (Installer) oder die `…-portable.exe` herunterladen.
   - Windows warnt beim ersten Start, weil die App nicht signiert ist: **Weitere Informationen → Trotzdem ausführen**.
2. **GitHub-Token anlegen:** <https://github.com/settings/personal-access-tokens/new>
   - *Repository access*: nur `zazafnr/notes`
   - *Permissions*: **Actions** = Read and write, **Commit statuses** = Read-only, **Contents** = Read-only
3. Token in der PC-App einfügen → **Prüfen & speichern**.

## Benutzen

1. Geräte auswählen (iPhone, iPad oder beide), Modell, Profil, iOS-Version, App-Branch und Dauer.
2. **▶︎ Starten**. Der Start dauert etwa 3–6 Minuten: Mac starten, App bauen, Simulatoren hochfahren.
3. Für jedes Gerät öffnet sich ein Fenster.

| Am PC | Am Gerät |
|---|---|
| Linksklick / Ziehen | Tippen / Wischen, Zeichnen |
| Maustaste gedrückt halten oder Rechtsklick | Langes Drücken (Kontextmenüs, Symbole verschieben) |
| Mausrad | Scrollen |
| Ziehen vom unteren Bildschirmrand nach oben | Home-Geste |
| Tastatur (auch ä, ö, ü, ß, @, €) | Tastatur |
| Strg+H / Strg+Umschalt+H | Home / App-Umschalter |
| Strg+L | Sperren |
| Strg+← / Strg+→ | Drehen |
| Strg+S | Bildschirmfoto (landet in *Bilder\iOS-Simulator*) |
| Strg+V / Strg+C | Einsetzen bzw. Kopieren, mit der PC-Zwischenablage abgeglichen |

In der Leiste rechts gibt es außerdem: Siri, Hell/Dunkel, Fotos hinzufügen, Link öffnen, App neu bauen, App-Daten sichern/laden, App-Protokoll (Konsolen-Ausgabe deiner App), Bildqualität, »Immer im Vordergrund«.

**FreeNotes:** Im Simulator gibt es keinen Apple Pencil. Deshalb in FreeNotes **Mit dem Finger zeichnen** einschalten. Dann schreibt die Maus wie ein Stift.

## Profile: »wie mein iPhone«

Ein Profil macht einen Simulator deinem Gerät ähnlich:

- **Fotos & Videos** aus einem Ordner. Am PC: iPhone per Kabel anschließen und in Windows die Fotos importieren, oder sie aus iCloud Fotos herunterladen.
- **Kontakte** als `.vcf` (iCloud.com → Kontakte → Exportieren)
- **Sprache & Region**, **Hell/Dunkel**, **Standort**, **Gerätemodell**
- **App-Daten behalten:** Die Daten deiner App, z. B. deine Hefte in FreeNotes, werden am Ende der Sitzung auf dem PC gesichert und beim nächsten Start wieder eingespielt.

**Was nicht geht:** Apps aus dem App Store, ein iCloud- oder iTunes-Backup und Apple-ID-Daten lassen sich nicht in einen Simulator übertragen. Apple verschlüsselt App-Store-Apps für echte Geräte, und der Simulator kann sich nicht beim App Store anmelden. Deine **eigenen** Apps laufen dagegen, und darum geht es beim Testen.

## Was der Simulator nicht kann

Kamera und Dokumentenscanner, Apple Pencil (Druck und Neigung), Face ID (nur simuliert), Telefonie, Push-Benachrichtigungen von Apple. Mehrfinger-Gesten wie Zwei-Finger-Zoom unterstützt die Steuerung noch nicht. Für diese Dinge braucht es das echte Gerät.

## Kosten: Mac-Minuten

Das Repo ist privat. GitHub Free enthält 2.000 Actions-Minuten pro Monat, und Mac-Minuten zählen zehnfach. Das sind etwa **200 Mac-Minuten pro Monat**, also rund 3 Stunden Simulator. Die PC-App zeigt eine Schätzung an.

- Die Sitzung endet automatisch nach der gewählten Dauer und nach 15 Minuten ohne verbundenes Fenster.
- **■ Beenden** in der PC-App stoppt den Mac sofort. Wird die PC-App geschlossen, wird die Sitzung ebenfalls beendet.
- In einem öffentlichen Repo wären die Minuten kostenlos.

## Technik

| Ordner | Inhalt |
|---|---|
| `.github/workflows/ios-simulator.yml` | Startet den Cloud-Mac: Xcode wählen, Simulatoren anlegen, App bauen, Tunnel öffnen |
| `.github/workflows/simulator-desktop.yml` | Baut die Windows-App und legt sie als Release `simulator-latest` ab |
| `simulator/runner/` | Skripte auf dem Mac: `boot.sh`, `build-app.sh`, `measure.py`, `start-session.sh` |
| `simulator/server/` | Steuer-Server (Node): Bild-Stream über `axe stream-video`, Live-Touch über den HID-Broker von [AXe](https://github.com/cameroncooke/AXe), `simctl` für alles andere |
| `simulator/desktop/` | PC-App (Electron): Startfenster, Profile, Gerätefenster |
| `simulator/test/` | Tests mit nachgebautem Mac (`server.test.js`, `ui-check.js`), GitHub-Ablauf (`github.test.js`) und Selbsttest auf dem echten Mac (`live-check.js`) |

Sicherheit: Jede Sitzung hat einen eigenen zufälligen Schlüssel. Die PC-App gibt GitHub nur dessen SHA-256 mit, und der Server lässt nur Anfragen mit dem passenden Schlüssel zu.

Die Adresse des Tunnels meldet der Mac als Commit-Status `ios-sim/<Sitzung>`. Daraus liest die PC-App den Fortschritt: `pending` = startet, `success` = bereit, `error` = Fehler, `failure` = beendet.

Lokal testen (ohne Mac):

```bash
cd simulator/server && npm ci && cd ..
node test/server.test.js
node test/github.test.js
```
