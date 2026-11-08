import SwiftUI

struct PlacementPane: View {
    @Bindable var settings: Settings
    let model: AppModel
    @State private var canReadDock = DockLocator.canReadDock

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                Picker("Side", selection: $settings.side) {
                    Label("Left of the Dock", systemImage: "rectangle.lefthalf.inset.filled").tag(DockSide.left)
                    Label("Right of the Dock", systemImage: "rectangle.righthalf.inset.filled").tag(DockSide.right)
                }
                .pickerStyle(.inline)
                LabeledContent("Distance from the Dock") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.dockGap, in: 4...120)
                        Text("\(Int(settings.dockGap)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Fit") {
                if canReadDock {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fitted exactly to the Dock")
                            Text("Tape reads the Dock's size and follows it as apps open and close.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Estimated from the Dock's settings")
                            Text("For a pixel-perfect fit, allow Tape in Privacy & Security → Accessibility. Tape only reads the Dock's size and position; it never reads or controls anything else.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Allow…") {
                                    DockLocator.askForAccess()
                                    DockLocator.openAccessibilitySettings()
                                }
                            }
                        }
                    } icon: {
                        Image(systemName: "ruler").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("When the Dock hides itself, the tape slides in and out with it. With the Dock on the left or right, the tape runs along the bottom of the screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // Access is granted in System Settings; notice it without asking to be reopened.
            while !Task.isCancelled {
                let now = DockLocator.canReadDock
                if now != canReadDock {
                    canReadDock = now
                    model.dock.measure()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
