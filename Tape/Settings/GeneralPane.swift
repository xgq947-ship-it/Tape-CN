import SwiftUI

struct GeneralPane: View {
    @Bindable var settings: Settings
    let model: AppModel
    @State private var launchesAtLogin = false

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open Tape when you log in", isOn: Binding(
                    get: { launchesAtLogin },
                    set: { model.launchesAtLogin = $0; launchesAtLogin = model.launchesAtLogin }
                ))
                Toggle("Show Tape in the menu bar", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("Right-click the tape for its menu, or open Tape again to come back here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Refresh while markets are open", selection: $settings.refreshInterval) {
                    Text("Every 15 seconds").tag(15)
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Every 5 minutes").tag(300)
                }
                Text("When every market on the tape is closed, Tape waits for the next opening bell.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tape \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .font(.headline)
                        Text("Read the tape.")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Prices from Yahoo Finance, delayed up to 15 minutes on some exchanges. Logos from Parqet and Financial Modeling Prep. Not investment advice.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchesAtLogin = model.launchesAtLogin }
    }
}
