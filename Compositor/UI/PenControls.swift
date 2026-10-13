import SwiftUI

struct PenControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text("Pen").font(ToolHeaderStyle.titleFont)
            Picker("Path", selection: Binding(get: { session.penMode }, set: { mode in
                guard mode != session.penMode else { return }
                session.cancelPen()
                session.penMode = mode
            })) {
                ForEach(PenMode.allCases, id: \.self) { mode in
                    Text(mode == .shape ? "Closed" : "Open").tag(mode)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Create a closed or open editable path. The path has no pixels until it is filled or stroked. Tab switches modes")

            HStack(spacing: 6) {
                Text("Foreground")
                Button { session.openColorPicker(background: false) } label: {
                    let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    swatch.fill(Color(nsColor: session.foregroundColor.nsColor))
                        .overlay { swatch.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                        .frame(width: 36, height: 18)
                }
                .buttonStyle(.plain)
                .help("Use the foreground color")
            }

            Button("Fill Path") { session.fillPenPathWithForeground() }
                .disabled(!session.canFillPenPath)
                .help("Fill the path with the current foreground color on a new pixel layer")
            Button("Stroke Path with Brush") { session.strokePenPathWithBrush() }
                .disabled(!session.canStrokePenPath)
                .help("Stroke the path on a new pixel layer with the current \(Int(session.brushSettings.diameter.rounded())) px Brush, hardness and opacity")
            Button("Load Path as Selection") { session.loadPenPathSelection() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!session.canLoadPenPathSelection)
                .help("Convert the current path to a selection without filling it (⌘Return). Open paths close between their endpoints")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }
}
