import SwiftUI

/// A round, tappable control button used for the playback controls.
struct IslandIconControl: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.12), in: Circle())
            .contentShape(Circle())
            .onTapGesture(perform: action)
    }
}
