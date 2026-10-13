import SwiftUI

struct PenControls: View {
    @Bindable var session: EditorSession

    private var width: Binding<Double> {
        Binding(
            get: { session.currentPenLineWidth },
            set: { session.setPenLineWidth($0) }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("Pen").font(ToolHeaderStyle.titleFont)
            Picker("Mode", selection: Binding(get: { session.penMode }, set: { mode in
                session.cancelPen()
                session.penMode = mode
            })) {
                ForEach(PenMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Shape closes and fills a path; Line keeps it open and stroked. Tab switches modes")

            HStack(spacing: 6) {
                Text(session.penMode == .shape ? "Fill" : "Stroke")
                Button { session.openColorPicker(background: false) } label: {
                    let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    swatch.fill(Color(nsColor: session.foregroundColor.nsColor))
                        .overlay { swatch.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                        .frame(width: 36, height: 18)
                }
                .buttonStyle(.plain)
                .help("Use the foreground color")
            }

            if session.penMode == .line || session.canEditActivePenLine {
                HStack(spacing: 6) {
                    Text("Width")
                    Slider(value: Binding(
                        get: { min(100, session.currentPenLineWidth) },
                        set: { session.setPenLineWidth($0.rounded(), preview: true) }
                    ), in: 1...100, onEditingChanged: { editing in
                        if editing { session.beginPenLineWidthEdit() }
                        else { session.endPenLineWidthEdit() }
                    })
                    .frame(width: 100)
                    TextField("Width", value: width, format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .arrowSteps(value: { session.currentPenLineWidth },
                                    change: { session.setPenLineWidth($0) })
                        .unitSuffix("px")
                }
            }
            Button("Load Path as Selection") { session.loadPenPathSelection() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!session.canLoadPenPathSelection)
                .help("Load the current path as a selection (⌘Return). Open paths close between their endpoints")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }
}
