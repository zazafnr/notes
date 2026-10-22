# FreeNotes mit einem Mac als eigene App installieren

Mit Swift Playgrounds läuft FreeNotes direkt auf dem iPad. Mit einem Mac bekommt die App ein eigenes Icon auf dem Home-Bildschirm, wie jede andere App.

## Was du brauchst

- einen Mac mit **Xcode** (kostenlos im Mac App Store; Version 16 oder neuer)
- eine **Apple-ID** (die normale, kein bezahlter Entwickler-Account nötig)
- ein USB-C-Kabel für das iPad

## Einmalig einrichten

1. Dieses Repo auf den Mac laden: auf GitHub **Code → Download ZIP**, entpacken.
2. Doppelklick auf **`FreeNotes.swiftpm`**. Xcode öffnet das Projekt.
3. In Xcode: **Xcode → Settings → Accounts → +** und mit deiner Apple-ID anmelden.
4. Links im Projekt-Navigator auf **FreeNotes** klicken, dann **Signing & Capabilities**:
   - **Team**: deine Apple-ID wählen (»Personal Team«)
   - Falls ein Fehler zur *Bundle Identifier* kommt: `de.freenotes.app` in etwas Eigenes ändern, z. B. `de.deinname.freenotes`.
5. iPad per Kabel verbinden und entsperren. Auf dem iPad »Diesem Computer vertrauen« bestätigen.
6. Oben in Xcode als Ziel dein iPad auswählen.

## Auf das iPad bringen

1. In Xcode auf **▶︎ (Run)** klicken. Beim ersten Mal dauert das ein paar Minuten.
2. Auf dem iPad: **Einstellungen → Datenschutz & Sicherheit → Entwicklermodus** einschalten (iPad startet neu).
3. **Einstellungen → Allgemein → VPN & Geräteverwaltung** → deine Apple-ID → **Vertrauen**.
4. FreeNotes auf dem Home-Bildschirm antippen.

## Wichtig: alle 7 Tage neu installieren

Mit einer kostenlosen Apple-ID läuft die Signatur nach **7 Tagen** ab. Danach startet die App nicht mehr. Deine Hefte bleiben erhalten. Einfach das iPad wieder an den Mac hängen und in Xcode erneut auf **▶︎** klicken.

Mit einem bezahlten Apple-Developer-Account (99 €/Jahr) gilt die Signatur ein Jahr, und du könntest die App auch über TestFlight verteilen.

## Hefte von Swift Playgrounds übernehmen?

Die Swift-Playgrounds-Version und die installierte App speichern ihre Daten getrennt. Nutze **Als PDF teilen** im Heft-Menü, um wichtige Hefte zu sichern, und importiere die PDFs in der neuen App über **Bild → PDF oder Datei importieren**.
