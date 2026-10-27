# free-magic-switch (DeviceHop)

A free macOS menu-bar app that moves your Apple Magic Keyboard and Magic Mouse between Macs with one click: no manual unpairing and re-pairing.

## How it works

Run DeviceHop on every Mac. The copies find and talk to each other directly over Bluetooth LE, so the Macs don't need to share a network (corporate Wi-Fi and disabled AirDrop are fine). They just need to be within Bluetooth range.

- **Send devices to → Mac:** this Mac disconnects and unpairs the selected devices. The other Mac then pairs and connects them.
- **Take devices from → Mac:** the other Mac releases its devices, and this Mac pairs them.
- If the other Mac can't be reached partway through, the devices are reclaimed, so they don't end up paired to nothing.
- **Shared key:** requests only count if both Macs use the same key, so other nearby Macs running DeviceHop can't take your keyboard. The link between Macs is also encrypted: the first time two Macs talk, macOS asks you to accept a Bluetooth pairing request between them. Set it under **Settings**.
- **Keyboard & mouse:** only Bluetooth keyboards and mice (and trackpads) are listed and moved. Other Bluetooth devices, such as headphones, speakers and phones, are ignored. Each one has a switch, in case you want to move just one of them.

The menu-bar panel shows each device's connection and battery level, lists the other Macs it found with **Send** and **Take** buttons, and keeps the shared key and update settings under **Settings**. If macOS asks for a passkey while pairing, it appears in the panel. Type it on the keyboard and press Return.

## Updates

DeviceHop checks npm shortly after launch and then every 6 hours. When a newer version exists, it rebuilds itself from that release's GitHub tag (`vX.Y.Z`) and restarts, but never in the middle of a switch. To get an **Update** button instead, turn off *Install updates automatically* in Settings. The update log is at `~/Library/Logs/DeviceHop-update.log`.

To release a new version:

```bash
npm version minor && git push --follow-tags && npm publish --auth-type=web
```

## Install

On each Mac, run one of these:

```bash
npx free-magic-switch
```

```bash
curl -fsSL https://raw.githubusercontent.com/zeyuyang8/free-magic-switch/main/install.sh | bash
```

Either one builds the app from source, copies it to `/Applications`, starts it, and sets it to launch at login (via `~/Library/LaunchAgents/local.devicehop.plist`). If Swift is missing, it tells you to run `xcode-select --install` first. From a clone, `./install.sh` does the same.

To uninstall:

```bash
npx free-magic-switch --uninstall
```

## Build only

Requires macOS 13+ and Swift (Xcode or the Command Line Tools).

```bash
./build.sh
```

This produces `build/DeviceHop.app`: a universal (arm64 + x86_64) build with an ad-hoc signature. On first launch, allow the Bluetooth prompt.

To use it on another Mac, copy the app over. It isn't notarized, so right-click it and choose **Open** the first time, or run:

```bash
xattr -dr com.apple.quarantine DeviceHop.app
```

## Caveats

- Unpairing uses a private IOBluetooth method (`-[IOBluetoothDevice remove]`), the same one `blueutil` uses. A future macOS release could break it.
- If a device gets stuck, connect it to the target Mac with a cable. That always re-pairs it.
- Every rebuild, including automatic updates, changes the ad-hoc signature, so macOS may ask for the Bluetooth permission again.
- The app is built from source on each Mac with the Command Line Tools, so it avoids SwiftUI features that need full Xcode, such as `@State`.

## Layout

- `Sources/DeviceHop/DeviceHopApp.swift`: app entry point (SwiftUI `MenuBarExtra`)
- `Sources/DeviceHop/ContentView.swift`: the menu-bar panel
- `Sources/DeviceHop/AppModel.swift`: app state, the send/take flows, and update scheduling
- `Sources/DeviceHop/Bluetooth.swift`: list devices and battery levels; unpair, pair and connect (IOBluetooth and IOKit)
- `Sources/DeviceHop/Peers.swift`: Bluetooth LE discovery and encrypted JSON-line messages between Macs (CoreBluetooth)
- `Sources/DeviceHop/Updater.swift`: checks npm for new versions and reinstalls from the release tag
- `build.sh`: builds and wraps the binary into a signed `.app` with the required Info.plist keys
