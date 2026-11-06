import Combine
import SwiftUI

@MainActor
final class EditorAssistantSession: ObservableObject {
    @Published var instruction = ""
    @Published private(set) var isBusy = false
    @Published private(set) var notice: String?
    @Published private(set) var errorMessage: String?
    let projectID = UUID()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var clarification: (request: String, question: String, revision: String)?
    private let transport: @Sendable (Data) async throws -> Data

    init(transport: @escaping @Sendable (Data) async throws -> Data = {
        try await LocalModelRuntime.shared.chat(payload: $0)
    }) { self.transport = transport }
    deinit { task?.cancel() }

    func submit(editor: ProjectEditor, playhead: Double, regionID: UUID?, editID: UUID?) {
        guard !isBusy else { return }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, editor.finishDraft() else { return }
        do {
            let recording = try EditorCommandDispatcher.context(editor: editor, projectID: projectID)
            let context = LocalEditContext(recording: recording, playhead: playhead,
                selectedRegionID: regionID, selectedEditID: editID, videoProcessingAvailable: !MediaProcessing.isSuspended)
            let request: String
            if let clarification, clarification.revision == recording.revision {
                request = "Earlier instruction: \(clarification.request)\nQuestion: \(clarification.question)\nAnswer: \(text)"
            } else { request = text }
            let payload = try LocalEditPlanner.payload(request: request, context: context)
            let token = UUID(); generation = token
            isBusy = true; errorMessage = nil; notice = "Preparing a local edit…"
            task = Task { @MainActor [weak self, transport] in
                do {
                    let data = try await transport(payload)
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    switch try LocalEditPlanner.result(data, context: context) {
                    case let .commands(batch, summary):
                        try EditorCommandDispatcher.apply(batch, to: editor, projectID: self.projectID)
                        self.notice = summary
                        self.clarification = nil
                    case let .clarification(question):
                        self.notice = question
                        self.clarification = (request, question, recording.revision)
                    }
                    self.instruction = ""
                } catch {
                    guard let self, self.generation == token else { return }
                    self.notice = nil
                    if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
                }
                guard let self, self.generation == token else { return }
                self.isBusy = false; self.task = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        isBusy = false; notice = nil
    }
}

struct EditorAssistantPanel: View {
    @ObservedObject var editor: ProjectEditor
    @ObservedObject var session: EditorAssistantSession
    @Binding var scribbleMode: Bool
    let selectedRegionID: UUID?
    let onSelectRegion: (UUID) -> Void
    let onRemoveRegion: (UUID) -> Void
    let onSubmit: () -> Void
    @StateObject private var instructionSpeech = LocalSpeechInput()
    @StateObject private var noteSpeech = LocalSpeechInput()
    @State private var noteDraft = ""
    @FocusState private var noteFocused: Bool

    private var regions: [EditorRegion] { editor.editingState.regions }
    private var selectedRegion: EditorRegion? { regions.first { $0.id == selectedRegionID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle(isOn: $scribbleMode) { Label("Scribble", systemImage: "pencil.tip.crop.circle") }
                    .toggleStyle(.button)
                    .help("Draw a box on the preview to refer to an area in an instruction. Turn off Scribble to pan or move the camera.")
                Spacer()
            }
            if !regions.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                            HStack(spacing: 4) {
                                Button { onSelectRegion(region.id) } label: {
                                    HStack {
                                        Image(systemName: "rectangle.dashed")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(region.note.isEmpty ? "Area \(index + 1)" : region.note).lineLimit(1)
                                            Text("\(region.time, specifier: "%.2f") s").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(6).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Select this area and show the frame where it was drawn.")
                                Button { onRemoveRegion(region.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove area \(index + 1)")
                                    .help("Remove this scribble and its note. Undo restores it.")
                                    .padding(.trailing, 6)
                            }
                            .background(selectedRegionID == region.id ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.frame(maxHeight: 180)
            }
            if let region = selectedRegion {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Area note").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        LocalVoiceButton(speech: noteSpeech, purpose: "Dictate an area note") { text in
                            noteDraft = text; noteFocused = true
                        }.disabled(instructionSpeech.phase != .idle)
                    }
                    TextField("Describe this area", text: $noteDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        .focused($noteFocused)
                        .onSubmit { saveNote(region.id) }
                        .onExitCommand { noteDraft = region.note; noteFocused = false; Task { await noteSpeech.cancel() } }
                        .help("Return saves the note. Escape or clicking away cancels. A note does not change the video.")
                    speechStatus(noteSpeech)
                }
            }
            Divider()
            TextField("Describe an edit…", text: $session.instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...6)
                .onSubmit { if instructionSpeech.phase == .idle && noteSpeech.phase == .idle { onSubmit() } }
                .disabled(session.isBusy)
                .help("For example: At one second, zoom into this area; hold for four seconds, then zoom back out.")
            HStack {
                LocalVoiceButton(speech: instructionSpeech) { text in session.instruction = text }
                    .disabled(session.isBusy || noteSpeech.phase != .idle)
                Text("On-device").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if session.isBusy {
                    ProgressView().controlSize(.small)
                    Button { session.cancel() } label: { Image(systemName: "xmark") }
                        .help("Cancel the local editing request.").accessibilityLabel("Cancel edit request")
                } else {
                    Button(action: onSubmit) { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.borderless).font(.title2)
                        .disabled(session.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instructionSpeech.phase != .idle || noteSpeech.phase != .idle)
                        .help("Apply this instruction. Undo reverses the whole request.")
                        .accessibilityLabel("Apply edit instruction")
                }
            }
            speechStatus(instructionSpeech)
            if let message = session.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let message = session.notice {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .onChange(of: selectedRegionID, initial: true) { _, _ in
            noteFocused = false; noteDraft = selectedRegion?.note ?? ""
            Task { await noteSpeech.cancel() }
        }
        .onChange(of: selectedRegion?.note) { _, note in if !noteFocused { noteDraft = note ?? "" } }
        .onChange(of: noteFocused) { _, focused in if !focused { noteDraft = selectedRegion?.note ?? "" } }
        .onExitCommand {
            session.cancel()
            Task { await instructionSpeech.cancel(); await noteSpeech.cancel() }
        }
        .onDisappear {
            session.cancel()
            Task { await instructionSpeech.cancel(); await noteSpeech.cancel() }
        }
    }

    private func saveNote(_ id: UUID) {
        guard editor.finishDraft(), let index = editor.project.state.regions.firstIndex(where: { $0.id == id }) else { return }
        var next = editor.project.state
        next.regions[index].note = noteDraft
        if editor.commit(next, name: "Edit area note") { noteFocused = false }
    }

    @ViewBuilder private func speechStatus(_ speech: LocalSpeechInput) -> some View {
        if speech.phase != .idle, !speech.transcript.isEmpty {
            Text(speech.transcript).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if let message = speech.errorMessage ?? speech.statusMessage {
            Text(message).font(.caption).foregroundStyle(speech.errorMessage == nil ? Color.secondary : .red)
        }
    }
}
