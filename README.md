# free-magic-switch (DeviceHop)

A free macOS menu-bar app that moves your Apple Magic Keyboard and Magic Mouse between Macs with one click: no manual unpairing and re-pairing.

## How it works

Run DeviceHop on every Mac. The copies find each other on your local network over Bonjour (`_devicehop._tcp`).

- **Send devices to → Mac:** this Mac disconnects and unpairs the selected devices. The other Mac then pairs and connects them.
- **Take devices from → Mac:** the other Mac releases its devices, and this Mac pairs them.
- If the other Mac can't be reached partway through, the devices are reclaimed, so they don't end up paired to nothing.
- **Shared key:** requests only count if both Macs use the same key, so others on your network can't take your keyboard. Set it under *Set Shared Key…*.
- **Devices to switch:** choose which paired devices move. Anything named "Magic" is selected by default.

If macOS asks for a passkey while pairing, it appears next to the menu-bar icon. Type it on the keyboard and press Return.

## Install

On each Mac, run one of these:

```bash
npx github:zeyuyang8/free-magic-switch
```

```bash
curl -fsSL https://raw.githubusercontent.com/zeyuyang8/free-magic-switch/main/install.sh | bash
```

Either one builds the app from source, copies it to `/Applications`, starts it, and sets it to launch at login (via `~/Library/LaunchAgents/local.devicehop.plist`). If Swift is missing, it tells you to run `xcode-select --install` first. From a clone, `./install.sh` does the same.

To uninstall:

```bash
npx github:zeyuyang8/free-magic-switch --uninstall
```

## Build only

Requires macOS 13+ and Swift (Xcode or the Command Line Tools).

```bash
./build.sh
```

This produces `build/DeviceHop.app`: a universal (arm64 + x86_64) build with an ad-hoc signature. On first launch, allow the Bluetooth and Local Network prompts.

To use it on another Mac, copy the app over. It isn't notarized, so right-click it and choose **Open** the first time, or run:

```bash
xattr -dr com.apple.quarantine DeviceHop.app
```

## Caveats

- Unpairing uses a private IOBluetooth method (`-[IOBluetoothDevice remove]`), the same one `blueutil` uses. A future macOS release could break it.
- If a device gets stuck, connect it to the target Mac with a cable. That always re-pairs it.
- Rebuilding changes the ad-hoc signature, so macOS may ask for the permissions again.

## Layout

- `Sources/DeviceHop/Bluetooth.swift`: list, unpair, pair and connect devices (IOBluetooth)
- `Sources/DeviceHop/Peers.swift`: Bonjour discovery and JSON-line messages between Macs (Network.framework)
- `Sources/DeviceHop/AppDelegate.swift`: menu-bar UI and the send/take flows
- `build.sh`: builds and wraps the binary into a signed `.app` with the required Info.plist keys
