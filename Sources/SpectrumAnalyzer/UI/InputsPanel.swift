import SwiftUI

/// Device menu and channel checklist for the guitar input (R2, R3).
struct InputsPanel: View {
    let devices: [AudioInputDevice]
    let selectedDeviceUID: String?
    let ticks: Set<Int>
    /// Why the selected device could not be opened, nil while it runs or is off.
    let failure: OSStatus?
    let onSelect: (String?, Set<Int>) -> Void

    var body: some View {
        HStack {
            Picker("Interface", selection: deviceBinding) {
                Text("None").tag(String?.none)
                ForEach(devices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            .frame(width: 220)

            if let device = devices.first(where: { $0.uid == selectedDeviceUID }) {
                ForEach(1...device.channels, id: \.self) { channel in
                    Toggle("\(channel)", isOn: channelBinding(channel))
                        .toggleStyle(.button)
                }
            }

            if let failure {
                Text("Input unavailable (OSStatus \(failure))")
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
    }

    private var deviceBinding: Binding<String?> {
        Binding(get: { selectedDeviceUID }, set: { onSelect($0, ticks) })
    }

    private func channelBinding(_ channel: Int) -> Binding<Bool> {
        Binding(get: { ticks.contains(channel) },
               set: { isOn in
            var next = ticks
            if isOn { next.insert(channel) } else { next.remove(channel) }
            onSelect(selectedDeviceUID, next)
        })
    }
}
