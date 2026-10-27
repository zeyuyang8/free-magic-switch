import SwiftUI

/// Stand-in for @State, whose macro plugin ships only with Xcode, not the Command Line Tools.
final class Flag: ObservableObject {
    @Published var on = false
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var settingsOpen = Flag()

    private var showSettings: Bool { settingsOpen.on }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let code = model.passkey { passkeyBanner(code) }
            if let v = model.availableUpdate, !model.autoUpdate || model.updating { updateBanner(v) }
            devicesSection
            macsSection
            if showSettings { settingsSection }
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { model.refreshDevices() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("DeviceHop").font(.headline)
                HStack(spacing: 6) {
                    if model.busy || model.updating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func passkeyBanner(_ code: String) -> some View {
        Banner(symbol: "keyboard", tint: .orange) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Type this code on the keyboard, then press Return").font(.caption)
                Text(code).font(.system(.title2, design: .monospaced).weight(.semibold))
            }
        }
    }

    private func updateBanner(_ version: String) -> some View {
        Banner(symbol: "arrow.down.circle.fill", tint: .blue) {
            HStack {
                Text(model.updating ? "Installing version \(version)…" : "Version \(version) is available")
                    .font(.callout)
                Spacer()
                if !model.updating {
                    Button("Update") { model.installUpdate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.busy)
                }
            }
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        Section(title: "Devices to switch", trailing: "\(model.selectedCount) selected") {
            if model.devices.isEmpty {
                Text("No paired Bluetooth devices")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            ForEach(model.devices) { d in
                DeviceRow(device: d, isOn: Binding(
                    get: { model.selected.contains(d.address) },
                    set: { model.setSelected(d.address, $0) }
                ))
            }
        }
    }

    // MARK: Macs

    private var macsSection: some View {
        Section(title: "Your other Macs", trailing: nil) {
            if model.peerNames.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Looking for Macs on your network…", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Install DeviceHop on your other Mac and it will appear here:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    CommandChip(command: "npx free-magic-switch")
                }
                .padding(.vertical, 4)
            }
            ForEach(model.peerNames, id: \.self) { name in
                HStack(spacing: 10) {
                    IconTile(symbol: "desktopcomputer", tint: .indigo)
                    Text(name).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { model.take(from: name) } label: {
                        Label("Take", systemImage: "arrow.down.left")
                    }
                    .controlSize(.small)
                    .help("Bring the devices from \(name) to this Mac")
                    Button { model.send(to: name) } label: {
                        Label("Send", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Move the selected devices to \(name)")
                }
                .padding(.vertical, 3)
                .disabled(model.busy || model.updating)
            }
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section(title: "Settings", trailing: nil) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared key").font(.caption).foregroundStyle(.secondary)
                    TextField("Same on every Mac", text: $model.sharedKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("Only Macs with this key can move your devices.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Toggle("Install updates automatically", isOn: $model.autoUpdate)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                HStack {
                    Button("Check for Updates") { model.checkForUpdates(manual: true) }
                        .controlSize(.small)
                        .disabled(model.updating)
                    Spacer()
                    Text("Version \(model.version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { settingsOpen.on.toggle() }
            } label: {
                Label(showSettings ? "Hide Settings" : "Settings", systemImage: "gearshape")
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Components

private struct Section<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 2) { content }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct DeviceRow: View {
    let device: BTDevice
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: device.symbol, tint: isOn ? .blue : .gray)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(device.connected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(device.connected ? "Connected" : "Not connected")
                    if let b = device.battery {
                        Text("·")
                        Image(systemName: batterySymbol(b))
                            .foregroundStyle(b <= 20 ? Color.red : Color.secondary)
                        Text("\(b)%")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Move this device when switching")
        }
        .padding(.vertical, 3)
    }

    private func batterySymbol(_ b: Int) -> String {
        switch b {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct IconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct Banner<Content: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CommandChip: View {
    let command: String
    @StateObject private var copiedFlag = Flag()

    private var copied: Bool { copiedFlag.on }

    var body: some View {
        HStack {
            Text(command).font(.system(.caption, design: .monospaced))
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copiedFlag.on = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedFlag.on = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
