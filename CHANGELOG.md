# Changelog

## 1.3.1 – 2026-10-04

First public release.

### Features
- ChatMix dial support for the SteelSeries Arctis Nova 7 Wireless Gen 2 on macOS 14.2+ via the USB-C dongle
- Per-app routing with three channels: Game, Chat, Normal
- Automatic game detection (Steam, CrossOver/Whisky/Wine, GeForce NOW, app category "Games")
- Defaults for games, other apps and system sounds; iPhone calls and FaceTime as chat
- Menu bar indicator (controller | chat bubble) with live percentages
- Settings window: General, Channels, Battery, Info
- Battery level and charging state, history chart, runtime and charge-time estimates, comparison with the 54 h spec
- Charge-limit notification with optional Shortcut, low-battery warning, detection of charging that stalls below 100 %
- Capacity estimate in mAh from USB-C power meter readings
- One-command install (`install.sh`) and uninstall (`uninstall.sh`)

### Known limitations
- Bluetooth only: the headset sends no dial or battery data over Bluetooth, the dongle is required
- The USB-C charging cable provides power only, no extra data
- The app is ad-hoc signed and built locally; macOS asks for the audio permission again after every update
