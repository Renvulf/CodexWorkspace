# Time Addon

Time is a lightweight World of Warcraft addon that provides a customizable clock with a companion minimap button and configuration panel. It also tracks play time and allows you to configure combat text fonts.

## Features
- Movable clock display with configurable font, color and size
- Optional date, seconds, server time and hourly chime
- Alarm with custom reminder text, adjustable duration and fullscreen notification
- Playtime tracking (session/day/week/month/year) shown in tooltips
- Quality of life options for the Objective Tracker
- Combat text configuration including font overrides
- Minimap button with drag repositioning
- **New:** LibDataBroker feed for compatibility with LDB displays

## Usage
Install the addon in your `Interface/AddOns` directory and type `/time` in game to open the settings window. Hover the minimap icon or the LDB entry to view tracked play time. Drag the clock or minimap icon while "Tick to move" is enabled.

## Commands
Use these chat commands for quick actions:

* `/time` – toggle the configuration window.
* `/alarm <minutes> [message]` – set an alarm that triggers after the specified number of minutes with optional reminder text. Multiple alarms can be queued.
  * Example: `/alarm 10 Brew coffee`
* `/time remind me in <number>[s|m|h|d] <message>` – show a toast reminder after the specified delay.
  * Example: `/time remind me in 5m Check the auction house`

If an alarm triggers, a fullscreen overlay with your reminder text and an alarm sound will appear. Reminders created with the `remind me in` command appear as small toasts near the top‑right of the screen. Any alarms you create are listed under **Upcoming Alarms** in the settings window; click an entry there to cancel it.

## License
This project is released under the MIT License. See `LICENSE` for details.
