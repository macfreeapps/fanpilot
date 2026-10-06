# Changelog

## 1.0.0

First release. Install with `brew install --cask macfreeapps/tap/fanpilot` or from the DMG on the release page; see the [README](README.md).

**Control**
- Three modes: **Normal** (macOS controls the fans), **Daily** (FanPilot keeps the Mac cool but quiet, and hands the fans back when it cools down), and **Turbo** (both fans at their maximum).
- Daily has three styles, **Quieter / Balanced / Cooler**, plus expert sliders under *Fine-tune*.
- Works out the fan keys, the Apple Silicon unlock sequence and the sensor set at runtime; nothing is keyed to a Mac model.
- A privileged helper is the only component that writes to the SMC, and only to the fan mode, fan target and unlock keys.

**Safety**
- Fans go back to macOS when FanPilot quits, crashes, loses its connection, stops responding, or the Mac goes to sleep.
- The helper restores control itself after its own crash or restart, retries if restoring fails, and falls back to maximum speed if it cannot release the fans.
- Maximum fan speed at 95 °C, and whenever macOS reports serious or critical thermal pressure.
- Refuses to take over fans that another tool is already controlling.

**Interface**
- Animated fan and temperature gauge, plain-language status, three mode cards, a collapsed *Details* view.
- Menu-bar item (can be hidden) showing the icon, temperature, fan speed or both, with a mode-coloured icon.
- Celsius or Fahrenheit everywhere, defaulting to your region.
- Settings: General, Menu Bar, Daily Mode, Fan Control, About. Light and dark appearance, VoiceOver labels, Reduce Motion respected.
- First-run welcome and a one-button "Turn On Fan Control".

**Requirements:** macOS 14 or later, Apple Silicon Mac with fans. Fanless Macs run in monitor-only mode.

See [docs/ENGINEERING_NOTES.md](docs/ENGINEERING_NOTES.md) for what was tested on hardware and what was not.
