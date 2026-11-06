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
    private var framingConflict: (proposal: EditorFramingConflict, context: LocalEditContext, followup: String?)?
    private let transport: @Sendable (Data) async throws -> Data
    var awaitsClarification: Bool { clarification != nil || framingConflict != nil }

    init(transport: @escaping @Sendable (Data) async throws -> Data = {
        try await LocalModelRuntime.shared.chat(payload: $0)
    }) { self.transport = transport }
    deinit { task?.cancel() }

    @discardableResult
    func appendDictation(_ transcript: String) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // Read the current draft when recognition finishes, so typing while
        // listening is preserved along with the text that preceded dictation.
        if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            instruction = text
        } else {
            let separator = instruction.last?.isWhitespace == true ? "" : " "
            instruction += separator + text
        }
        return true
    }

    func submit(editor: ProjectEditor, playhead: Double, regionID: UUID?, editID: UUID?) {
        guard !isBusy else { return }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do { try LocalEditPlanner.validateInstruction(text) }
        catch { errorMessage = error.localizedDescription; notice = nil; return }
        // Canonical history commands are the same immediate actions as the
        // toolbar. In particular, Redo must never finish a draft and thereby
        // erase the very redo branch the user asked to restore.
        if performHistoryShortcut(text, editor: editor) { return }
        if editor.draftState != nil,
           EditorAgentControls.historyAction(in: text) == .redo {
            cancel()
            notice = "Finish or undo the current edit before using Redo."
            errorMessage = nil
            return
        }
        if framingConflict != nil, editor.draftState != nil {
            cancel()
            errorMessage = EditorCommandError.stale.localizedDescription
            return
        }
        guard editor.finishDraft() else { return }
        do {
            let recording = try EditorCommandDispatcher.context(editor: editor, projectID: projectID)
            let pendingConflict = framingConflict
            if let pendingConflict, pendingConflict.context.recording.revision != recording.revision {
                cancel()
                throw EditorCommandError.stale
            }
            let context = pendingConflict?.context ?? LocalEditContext(recording: recording, playhead: playhead,
                selectedRegionID: regionID, selectedEditID: editID, videoProcessingAvailable: !MediaProcessing.isSuspended)
            let request: String
            if let clarification, clarification.revision == recording.revision {
                request = "Earlier instruction: \(clarification.request)\nQuestion: \(clarification.question)\nAnswer: \(text)"
            } else { request = text }
            let payload = try pendingConflict.map {
                try LocalEditPlanner.conflictPayload(answer: text, conflict: $0.proposal, context: $0.context, question: $0.followup)
            } ?? LocalEditPlanner.payload(request: request, context: context)
            let token = UUID(); generation = token
            isBusy = true; errorMessage = nil; notice = "Interpreting your instruction…"
            task = Task { @MainActor [weak self, transport] in
                do {
                    let data = try await transport(payload)
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    let result = try pendingConflict.map { try LocalEditPlanner.conflictResult(data, conflict: $0.proposal) }
                        ?? LocalEditPlanner.result(data, context: context, instruction: text)
                    switch result {
                    case let .commands(batch, summary):
                        let historyName = "Director: " + String(summary.replacingOccurrences(of: "\n", with: "; ").prefix(140))
                        try EditorCommandDispatcher.apply(batch, to: editor, projectID: self.projectID, name: historyName)
                        let previousIDs = Set(recording.state.timedEdits(includeCamera: true).map(\.id))
                        let added = editor.project.state.timedEdits(includeCamera: true)
                            .filter { !previousIDs.contains($0.id) }
                            .compactMap { editor.references.editLabel(for: $0.id) }
                        self.notice = added.isEmpty ? summary : summary + "\nCreated " + added.joined(separator: ", ") + "."
                        self.clarification = nil
                        self.framingConflict = nil
                    case let .history(history):
                        try EditorHistoryDispatcher.apply(history, to: editor, projectID: self.projectID)
                        let name = (history.action == .undo ? recording.history.undo : recording.history.redo).first ?? "change"
                        let action = history.action == .undo ? "Undid" : "Redid"
                        self.notice = history.count == 1 ? "\(action) \(name)." : "\(action) \(history.count) changes in order."
                        self.clarification = nil
                        self.framingConflict = nil
                    case let .clarification(question):
                        self.notice = question
                        if let pendingConflict {
                            self.framingConflict = (pendingConflict.proposal, pendingConflict.context, question)
                        } else { self.clarification = (request, question, recording.revision) }
                    case let .framingConflict(conflict):
                        _ = try EditorCommandDispatcher.prepare(conflict.replacement, for: editor.project, projectID: self.projectID)
                        self.notice = conflict.question
                        self.clarification = nil
                        self.framingConflict = (conflict, context, nil)
                    case let .noChanges(message):
                        self.notice = message
                        self.clarification = nil
                        self.framingConflict = nil
                    }
                    self.instruction = ""
                } catch {
                    guard let self, self.generation == token else { return }
                    self.notice = nil
                    if case .stale? = error as? EditorCommandError { self.framingConflict = nil; self.clarification = nil }
                    if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
                }
                guard let self, self.generation == token else { return }
                self.isBusy = false; self.task = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        isBusy = false; notice = nil; errorMessage = nil; clarification = nil; framingConflict = nil
    }

    private func performHistoryShortcut(_ text: String, editor: ProjectEditor) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let undo = ["undo", "undo that", "undo last change", "undo the last change"].contains(normalized)
        let redo = ["redo", "redo that", "redo last change", "redo the last change"].contains(normalized)
        guard undo || redo else { return false }
        cancel()
        if redo, editor.draftState != nil {
            notice = "Finish or undo the current edit before using Redo."
        } else if undo ? editor.canUndo : editor.canRedo {
            let name = undo ? editor.undoName : editor.redoName
            let succeeded = undo ? editor.undo() : editor.redo()
            if succeeded { notice = (undo ? "Undid " : "Redid ") + name + "." }
            else { errorMessage = editor.errorMessage ?? "The history change could not be saved." }
        } else {
            notice = undo ? "Nothing to undo." : "Nothing to redo."
        }
        instruction = ""
        return true
    }
}

struct EditorAssistantPanel: View {
    @ObservedObject var editor: ProjectEditor
    @ObservedObject var session: EditorAssistantSession
    let selectedRegionID: UUID?
    let onSelectRegion: (UUID) -> Void
    let onRemoveRegion: (UUID) -> Void
    var onShowOriginalFrame: (UUID) -> Void = { _ in }
    let onSubmit: () -> Void
    var onVoiceBegin: () -> Void = {}
    var onCancel: () -> Void = {}
    @StateObject private var instructionSpeech = LocalSpeechInput()
    @State private var namingRegionID: UUID?
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    private var regions: [EditorRegion] { editor.editingState.regions }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !regions.isEmpty {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(regions) { region in regionRow(region).id(region.id) }
                        }
                    }
                    .onChange(of: selectedRegionID) { _, selected in
                        if let selected { reader.scrollTo(selected, anchor: .center) }
                    }
                }
                .frame(height: min(180, CGFloat(regions.count) * 44 + CGFloat(max(0, regions.count - 1)) * 4))
                Divider()
            }
            TextField(session.awaitsClarification ? "Your answer…" : "What would you like to change?", text: $session.instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...6)
                .onSubmit { if instructionSpeech.phase == .idle { onSubmit() } }
                .disabled(session.isBusy)
                .accessibilityLabel("Editing instruction")
                .help("For example: At Edit A, zoom into Box 1. Then smoothly zoom out and into Box 2 at Edit B.")
            HStack {
                LocalVoiceButton(speech: instructionSpeech, finishPurpose: "Finish and apply instruction", onBegin: onVoiceBegin) { text in
                    if session.appendDictation(text) { onSubmit() }
                }
                    .disabled(session.isBusy)
                Text("On-device").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if session.isBusy {
                    ProgressView().controlSize(.small)
                    Button { session.cancel() } label: { Image(systemName: "xmark") }
                        .help("Cancel the local editing request.").accessibilityLabel("Cancel edit request")
                } else if instructionSpeech.phase == .idle {
                    Button(action: onSubmit) { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.borderless).font(.title2)
                        .disabled(session.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instructionSpeech.phase != .idle)
                        .help("Apply this instruction. Undo reverses the whole request.")
                        .accessibilityLabel("Apply edit instruction")
                }
            }
            .frame(minHeight: 28)
            speechStatus(instructionSpeech)
            if let message = session.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let message = session.notice {
                HStack(alignment: .top) {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if session.awaitsClarification {
                        Button { session.cancel() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Dismiss question")
                            .help("Dismiss this question and start a new instruction. Escape also dismisses it.")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .onExitCommand {
            if instructionSpeech.isActive || session.isBusy || session.awaitsClarification {
                session.cancel()
                Task { await instructionSpeech.cancel() }
            } else { onCancel() }
        }
        .onDisappear {
            session.cancel()
            Task { await instructionSpeech.cancel() }
        }
    }

    private func regionRow(_ region: EditorRegion) -> some View {
        let label = editor.references.boxLabel(for: region.id) ?? "Box"
        let editLabel = region.editID.flatMap { editor.references.editLabel(for: $0) }
        let editExists = region.editID.flatMap { editor.references.edit(in: editor.editingState, id: $0) } != nil
        let association = editLabel.map { "from " + $0 + (editExists ? "" : " · removed") }
        let selected = region.id == selectedRegionID
        return HStack(spacing: 4) {
            regionSelectButton(region, label: label, editLabel: editLabel, association: association, selected: selected)
            Button { onRemoveRegion(region.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove " + label)
                .help("Remove " + label + ". Undo restores it.")
                .padding(.trailing, 8)
        }
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contextMenu {
            Button("Go to \(label)'s Frame") { onShowOriginalFrame(region.id) }
                .help("Move the playhead to the frame where this box was drawn.")
            Divider()
            Button("Name " + label + "…") { nameDraft = region.note; namingRegionID = region.id }
        }
        .popover(isPresented: Binding(get: { namingRegionID == region.id }, set: { if !$0 { namingRegionID = nil } })) {
            TextField("Name " + label, text: $nameDraft)
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .onSubmit { saveName(region.id) }
                .onExitCommand { namingRegionID = nil }
                .help("Return saves the optional name. Escape or clicking outside cancels.")
                .frame(width: 220).padding(12)
                .onAppear { nameFocused = true }
        }
    }

    private func regionSelectButton(_ region: EditorRegion, label: String, editLabel: String?, association: String?, selected: Bool) -> some View {
        let accessibilityName: String = label + (editLabel.map { ", drawn at " + $0 } ?? "")
        let time: String = String(format: "%.2f", region.time)
        let tooltip: String = selected
            ? "Click again or press Escape to deselect \(label)."
            : "Use \(label) as a reference without moving the playhead. Its original frame (\(time) s) is available from the context menu."
        return Button(action: { onSelectRegion(region.id) }, label: {
            regionButtonLabel(region, label: label, association: association, selected: selected)
        })
        .buttonStyle(.plain)
        .accessibilityValue(Text(selected ? "Selected" : ""))
        .accessibilityLabel(Text(accessibilityName))
        .help(Text(tooltip))
    }

    private func regionButtonLabel(_ region: EditorRegion, label: String, association: String?, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "rectangle.inset.filled" : "rectangle.dashed")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label).fontWeight(selected ? .semibold : .regular)
                    if let association { Text(association).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
                if !region.note.isEmpty {
                    Text(region.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 44).contentShape(Rectangle())
    }

    private func saveName(_ id: UUID) {
        guard editor.finishDraft(), let index = editor.project.state.regions.firstIndex(where: { $0.id == id }) else { return }
        var next = editor.project.state
        next.regions[index].note = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if editor.commit(next, name: "Name box") { namingRegionID = nil }
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
