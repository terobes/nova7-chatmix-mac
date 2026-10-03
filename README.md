<p align="center"><img src="icon.png" width="128" alt="ChatMix icon"></p>

# nova7-chatmix-mac

**ChatMix for the SteelSeries Arctis Nova 7 Wireless Gen 2 on macOS.**

The ChatMix dial on the Arctis Nova 7 Gen 2 only works on Windows, because it relies on SteelSeries Sonar. On a Mac the dial does nothing. This small menu bar app reads the dial directly from the headset and balances the volume of chat apps (Discord, Teams, calls …) against everything else, like the original Arctis 7 did.

🇩🇪 [Deutsche Anleitung weiter unten](#deutsch)

> This is an unofficial community project. It is not affiliated with, endorsed or supported by SteelSeries. "SteelSeries" and "Arctis" are trademarks of their respective owner.

## Features

- Reads the ChatMix dial position directly via USB HID, no SteelSeries software needed
- Per-app routing with three channels: **Game**, **Chat** or **Normal** (untouched by the dial)
- Automatic game detection: Steam library, CrossOver / Whisky / Wine, GeForce NOW and the macOS app category "Games"
- Separate defaults for games, other apps (browser, music …) and system sounds – by default everything except chat follows "Game"
- No virtual audio driver, no kernel extension: uses Apple's Core Audio process taps
- Pre-configured chat apps: Discord, Microsoft Teams, FaceTime and iPhone calls on the Mac (Continuity), Zoom, Slack, WhatsApp, Telegram
- One-command install into the Applications folder, updates included
- Quitting the app instantly restores normal audio

## Requirements

| | |
|---|---|
| macOS | **14.2 (Sonoma) or later**. Process taps were introduced in 14.2. Tested on macOS 26 (Tahoe). |
| Mac | Apple silicon or Intel |
| Headset | Arctis Nova 7 Wireless **Gen 2** with the USB-C dongle (USB ID `1038:227e`) |
| Tools | Apple Command Line Tools (free, requested automatically if missing) |

Other Nova models are not supported yet, because they may use a different USB ID or report format. Contributions welcome, see [Protocol](#protocol).

## Installation

Open the Terminal and run:

```bash
git clone https://github.com/GITHUB_USER/nova7-chatmix-mac.git
cd nova7-chatmix-mac
bash install.sh
```

`install.sh` builds the app, installs it into **Applications** (replacing an older version) and starts it. If the Apple Command Line Tools are missing, it starts their installation; run `bash install.sh` again afterwards. Afterwards you can delete the downloaded folder.

**Allow audio access.** On first start macOS asks whether ChatMix may record system audio. This is required, otherwise the app cannot change the volume of other apps. If you missed the prompt: *System Settings › Privacy & Security › Screen & System Audio Recording*, enable ChatMix, then quit and reopen the app.

**Optional: start at login.** Open *Settings* from the menu bar icon and enable *Beim Anmelden starten* (launch at login).

## Usage

- Dial in the middle: game and chat at full volume
- Turn towards one side: the other side gets quieter, down to silent
- Menu bar: shows a game controller and a chat bubble separated by "|". The quieter side fades out as you turn the dial; the percentages can be hidden in the settings
- **Settings** (menu bar icon › *Einstellungen …* or ⌘,):
  - **Allgemein (General):** status, live bars for dial position and signal levels, volume curve, percentages in the menu bar, launch at login
  - **Kanäle (Channels):** defaults for games, other apps and system sounds, plus a **Game | Chat | Normal** switch for every app. Installed games are listed automatically; other apps appear when they play audio, or add them with *App hinzufügen …*. A separate switch covers iPhone calls and FaceTime audio. Right-click an app to reset it to the default.
  - **Info:** version and project notes
- **No sound at all?** Choose *ChatMix beenden* (quit) in the menu. Audio returns to normal immediately.

## How it works

1. The dongle sends a HID input report every time the dial moves.
2. ChatMix creates two Core Audio process taps: one for the chat apps and one for all other apps. Both are muted at the source while tapped.
3. Both streams are mixed with the dial's gain values and played back on the current output device.

This adds a few milliseconds of latency.

## Protocol

The headset sends the dial position unprompted on vendor interface `usage page 0xff00` (interface 5):

| Byte | Meaning | Range |
|---|---|---|
| 0 | Report ID `0x45` (ChatMix) | fixed |
| 1 | Game volume | 0–100 |
| 2 | Chat volume | 0–100 |

In the centre position both values are 100. Polling (as done by HeadsetControl for older models) times out on the Gen 2.

## Troubleshooting

| Problem | Solution |
|---|---|
| `install.sh` reports missing Command Line Tools | Finish the installation dialog, then run `bash install.sh` again |
| Menu shows "Headset nicht verbunden" | Plug the dongle in directly (not via an unpowered hub), switch the headset on |
| Settings show a permission warning | Check *Screen & System Audio Recording* in System Settings, then restart ChatMix |
| Permission asked again after an update | Expected: the app is ad-hoc signed, every build counts as a new app. Just allow it again |
| A chat app is not affected by the dial | Settings › Kanäle: set it to "Chat", or add it with "App hinzufügen …" |

## Update

Run `git pull` in the project folder (or download it again) and then `bash install.sh`. Your settings are kept.

## Uninstall

```bash
bash uninstall.sh
```

Quits ChatMix, removes the app, its settings and the audio permission.

## License

MIT, see [LICENSE](LICENSE).

---

<a name="deutsch"></a>

# 🇩🇪 Deutsch

**ChatMix für das SteelSeries Arctis Nova 7 Wireless Gen 2 auf dem Mac.**

Das ChatMix-Rad des Arctis Nova 7 Gen 2 funktioniert nur unter Windows, weil es die SteelSeries-Software Sonar braucht. Auf dem Mac passiert beim Drehen nichts. Diese kleine Menüleisten-App liest das Rad direkt vom Headset aus und regelt die Lautstärke von Chat-Apps (Discord, Teams, Anrufe …) gegenüber allem anderen, so wie es beim alten Arctis 7 war.

> Inoffizielles Community-Projekt, nicht von SteelSeries unterstützt oder autorisiert.

## Voraussetzungen

- **macOS 14.2 (Sonoma) oder neuer**, getestet mit macOS 26 (Tahoe)
- Apple-Silicon- oder Intel-Mac
- Arctis Nova 7 Wireless **Gen 2** mit USB-C-Dongle
- Apple Command Line Tools (kostenlos, werden bei Bedarf automatisch angefragt)

## Installation

Terminal öffnen und eingeben:

```bash
git clone https://github.com/GITHUB_USER/nova7-chatmix-mac.git
cd nova7-chatmix-mac
bash install.sh
```

`install.sh` baut die App, installiert sie in den Ordner **Programme** (eine ältere Version wird ersetzt) und startet sie. Fehlen die Apple Command Line Tools, startet das Skript deren Installation; danach `bash install.sh` einfach noch einmal ausführen. Den heruntergeladenen Ordner kannst du anschließend löschen.

**Zugriff erlauben.** Beim ersten Start fragt macOS, ob ChatMix Systemaudio aufnehmen darf. Das ist nötig, sonst kann die App die Lautstärke anderer Apps nicht regeln. Falls die Abfrage nicht kam: *Systemeinstellungen › Datenschutz & Sicherheit › Bildschirm- & Systemaudioaufnahme*, ChatMix einschalten, App beenden und neu öffnen.

**Optional: automatisch starten.** Über das Menüleisten-Symbol die *Einstellungen* öffnen und *Beim Anmelden starten* einschalten.

## Bedienung

- Rad in der Mitte: Spiel und Chat voll laut
- Zur einen Seite drehen: die andere Seite wird leiser, bis stumm
- Menüleiste: zeigt Controller und Sprechblase, getrennt durch „|“. Die leisere Seite wird beim Drehen blasser; die Prozentwerte lassen sich in den Einstellungen ausblenden
- **Einstellungen** (Menüleisten-Symbol › *Einstellungen …* oder ⌘,):
  - **Allgemein:** Status, Live-Balken für Radstellung und Signal, Lautstärkeverlauf, Prozentwerte in der Menüleiste, Start bei der Anmeldung
  - **Kanäle:** Standardregeln für Spiele, andere Apps und Systemklänge sowie ein Umschalter **Game | Chat | Normal** für jede App. „Normal“ heißt: Das Rad wirkt nicht darauf. Installierte Spiele (Steam, CrossOver/Whisky, Kategorie „Games“) werden automatisch erkannt; andere Apps erscheinen, sobald sie Ton abspielen, oder über *App hinzufügen …*. Ein eigener Schalter regelt Anrufe vom iPhone und FaceTime-Audio. Rechtsklick setzt eine App auf den Standard zurück.
  - **Info:** Version und Hinweise
- **Gar kein Ton mehr?** Im Menü *ChatMix beenden* wählen. Der Ton ist sofort wieder normal.

## Probleme

| Problem | Lösung |
|---|---|
| `install.sh` meldet fehlende Command Line Tools | Installationsdialog abschließen, dann `bash install.sh` erneut ausführen |
| Menü zeigt „Headset nicht verbunden“ | Dongle direkt anstecken, Headset einschalten |
| Menü zeigt eine Warnung zur Berechtigung | *Bildschirm- & Systemaudioaufnahme* prüfen, ChatMix neu starten |
| Nach einem Update wird erneut nach der Berechtigung gefragt | Normal: Jeder Build gilt als neue App. Einfach wieder erlauben |
| Eine Chat-App reagiert nicht aufs Rad | Einstellungen › Kanäle: auf „Chat“ stellen oder über „App hinzufügen …“ ergänzen |

## Aktualisieren

Im Projektordner `git pull` ausführen (oder neu herunterladen) und dann `bash install.sh`. Deine Einstellungen bleiben erhalten.

## Deinstallieren

```bash
bash uninstall.sh
```

Beendet ChatMix und entfernt App, Einstellungen und Audio-Berechtigung.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
