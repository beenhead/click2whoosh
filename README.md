# click2whoosh

Use a **Zwift Click v2** to change gears in **MyWhoosh** on macOS.

A small native helper connects to the Click v2 over Bluetooth LE and turns button presses into
keystrokes for MyWhoosh. It doesn't use MyWhoosh Link, the network, or trainer emulation.

It comes in two forms that share the same core and the same button mapping:

- **`click2whoosh.app`**: a menu bar app with a status window. It shows connected pucks and
  battery, live button presses, the Accessibility permission state, and lets you remap buttons.
- **`click2whoosh`**: a terminal version (`-v` prints raw Bluetooth traffic, `--any-app` sends keys
  whatever app is in front).

## Build & run

Requires macOS 13+ and the Xcode command line tools (`swiftc`).

```sh
./build.sh
open click2whoosh.app      # or: ./click2whoosh -v
```

1. Allow **Bluetooth** when asked.
2. Allow the app in **System Settings › Privacy & Security › Accessibility**. Without this, macOS
   silently drops the keystrokes. For the terminal version, allow your terminal app instead, then
   quit and reopen it.
3. Press a button on each puck to wake it, put MyWhoosh in front, and ride.

## Default mapping

| Button | Key | MyWhoosh |
|---|---|---|
| **+** (right puck) | K | shift up (harder), repeats while held |
| **B** (right puck) | I | shift down (easier), repeats while held |
| **−** (left puck) | I | shift down |
| D-pad / A / Y | arrows / Return / H | navigation / select / toggle UI |

By default, keys are only sent while MyWhoosh is the frontmost app.

## The left-puck lock

Zwift's firmware locks the **left** puck (D-pad and −). It only sends presses if it has been
unlocked by the Zwift app within roughly the last 24 hours. To unlock it, log in to Zwift (free),
pair the Click and press a button. The **right** puck isn't locked, which is why **B** also maps to
shift down: **+** and **B** give full gear control from the right puck alone.

## How it works

- Scans for BLE adverts with Zwift's manufacturer ID `0x094A`. Device type `0x0A` is the right
  puck and `0x0B` the left one.
- Connects to service `FC82`, subscribes to the async/sync characteristics and writes the
  `RideOn` handshake.
- Decodes button notifications (opcode `0x23`, a protobuf `ButtonMap` where a cleared bit means
  "pressed") and posts keyboard events with `CGEvent`.

Source layout:

- `Sources/Core/ClickManager.swift`: Bluetooth, protocol decoding, key sending
- `Sources/App/App.swift`: menu bar app UI
- `Sources/CLI/main.swift`: terminal version

The app is ad-hoc signed with a designated requirement pinned to its bundle ID
(`local.click2whoosh`), so macOS keeps the Accessibility permission across rebuilds.

`CLICK2WHOOSH_SIMULATE=1 ./click2whoosh.app/Contents/MacOS/click2whoosh` runs a test mode with a
fake puck sending rapid presses. It never sends keystrokes.

## Acknowledgements

The Zwift Click v2 protocol details used here come from the reverse-engineering work in
[**OpenBikeControl / BikeControl**](https://github.com/OpenBikeControl/bikecontrol)
(© OpenBikeControl UG). They include the BLE service and characteristic UUIDs, the
manufacturer and device-type bytes, the `RideOn` handshake, the opcodes, the button bit
masks, the left-puck lock behaviour and the MyWhoosh keyboard shortcuts. Thank you!

click2whoosh is an independent implementation written from scratch in Swift. It contains no
code from BikeControl. If you want a full-featured, multi-platform solution supporting many
controllers and trainer apps, use BikeControl.

This project isn't affiliated with Zwift, MyWhoosh or OpenBikeControl. "Zwift", "Zwift Click"
and "MyWhoosh" are trademarks of their respective owners.
