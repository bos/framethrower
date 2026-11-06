import SwiftUI

/// Output framing is a whole-recording setting; each finished slider gesture
/// or explicit choice produces one reversible change.
struct PresentationControls: View {
    let presentation: CanvasPresentation
    var onBegin: () -> Void = {}
    var onPreview: (CanvasPresentation) -> Void = { _ in }
    var onCommit: (CanvasPresentation, String) -> Void

    private static let backgrounds: [(name: String, color: CanvasColor)] = [
        ("Black", .black),
        ("Slate", CanvasColor(red: 0.12, green: 0.15, blue: 0.2)),
        ("Blue", CanvasColor(red: 0.12, green: 0.29, blue: 0.55)),
        ("Violet", CanvasColor(red: 0.3, green: 0.2, blue: 0.5)),
        ("Cream", CanvasColor(red: 0.94, green: 0.91, blue: 0.84)),
        ("White", CanvasColor(red: 1, green: 1, blue: 1))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Aspect", selection: Binding(get: { presentation.aspect }, set: { aspect in
                onBegin()
                var next = presentation; next.aspect = aspect
                onCommit(next, "Change canvas aspect")
            })) {
                Text("Source").tag(CanvasAspect.source)
                Text("16:9").tag(CanvasAspect.wide)
                Text("9:16").tag(CanvasAspect.portrait)
                Text("Square").tag(CanvasAspect.square)
            }
            .pickerStyle(.segmented)
            .frame(width: 390, height: 24)
            .help("Choose the exported frame shape. The whole recording fits inside it without cropping or stretching.")
            HStack(spacing: 24) {
                PresentationSlider(title: "Padding", value: presentation.padding * 100, range: 0...20,
                    begin: onBegin, preview: { value in
                        var next = presentation; next.padding = value / 100; onPreview(next)
                    }, commit: { value in
                        var next = presentation; next.padding = value / 100
                        onCommit(next, "Change canvas padding")
                    })
                    .help("Add space around the recording inside the output canvas.")
                PresentationSlider(title: "Corners", value: presentation.cornerRadius * 100, range: 0...20,
                    begin: onBegin, preview: { value in
                        var next = presentation; next.cornerRadius = value / 100; onPreview(next)
                    }, commit: { value in
                        var next = presentation; next.cornerRadius = value / 100
                        onCommit(next, "Round recording corners")
                    })
                    .help("Round the recording's corners. Camera shape is controlled separately.")
            }
            .frame(width: 550, height: 24)
            Picker("Background", selection: Binding(get: {
                Self.backgrounds.first { $0.color == presentation.background }?.name ?? "Custom"
            }, set: { name in
                guard let background = Self.backgrounds.first(where: { $0.name == name }) else { return }
                onBegin()
                var next = presentation; next.background = background.color
                onCommit(next, "Change canvas background")
            })) {
                ForEach(Self.backgrounds, id: \.name) { background in
                    HStack {
                        Circle().fill(Color(red: background.color.red, green: background.color.green,
                                            blue: background.color.blue)).frame(width: 10, height: 10)
                        Text(background.name)
                    }.tag(background.name)
                }
                if !Self.backgrounds.contains(where: { $0.color == presentation.background }) {
                    Text("Custom").tag("Custom")
                }
            }
            .frame(width: 230, height: 24)
            .help("Fill the space around the recording with a solid color.")
        }
    }
}

private struct PresentationSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let begin: () -> Void
    let preview: (Double) -> Void
    let commit: (Double) -> Void
    @State private var draft = 0.0
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption)
            Slider(value: $draft, in: range) { active in
                editing = active
                if active { begin() } else { commit(draft) }
            }
            .accessibilityLabel(title)
            Text("\(editing ? draft : value, specifier: "%.0f")%")
                .font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
        }
        .onChange(of: draft) { _, next in if editing { preview(next) } }
        .onAppear { draft = min(max(value, range.lowerBound), range.upperBound) }
        .onChange(of: value) { _, next in if !editing { draft = min(max(next, range.lowerBound), range.upperBound) } }
    }
}
