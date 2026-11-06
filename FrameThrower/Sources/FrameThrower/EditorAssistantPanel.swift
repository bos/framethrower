import Combine
import SwiftUI

@MainActor
final class EditorAssistantSession: ObservableObject {
    @Published var instruction = "" {
        didSet { if instruction != oldValue { scheduleDraftSave() } }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var notice: String?
    @Published private(set) var errorMessage: String?
    let projectID = UUID()
    private var task: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var generation = UUID()
    private var clarification: DirectorPendingQuestion?
    private var framingConflict: DirectorPendingConflict?
    private var currentRequestID: UUID?
    private var speechID: UUID?
    private var pendingSpeechID: UUID?
    private let transport: @Sendable (Data) async throws -> Data
    private let diagnostics: DirectorDiagnostics?
    private let persistsConversation: Bool
    private let conversationStorageURL: URL?
    private(set) var conversation = DirectorConversation()
    private weak var observedEditor: ProjectEditor?
    private var projectObservation: AnyCancellable?
    private var observedProject: RecordingProject?
    private var applyingDirectorChange = false
    var awaitsClarification: Bool { clarification != nil || framingConflict != nil }

    init(transport: (@Sendable (Data) async throws -> Data)? = nil,
         diagnostics: DirectorDiagnostics? = nil, persistsConversation: Bool? = nil,
         conversationStorageURL: URL? = nil) {
        self.transport = transport ?? { try await LocalModelRuntime.shared.chat(payload: $0) }
        self.diagnostics = diagnostics ?? (transport == nil ? .shared : nil)
        self.persistsConversation = persistsConversation ?? (transport == nil || conversationStorageURL != nil)
        self.conversationStorageURL = conversationStorageURL
    }
    deinit { task?.cancel(); draftSaveTask?.cancel() }

    func attach(to editor: ProjectEditor) {
        guard observedEditor !== editor else { return }
        projectObservation?.cancel()
        observedEditor = editor
        let history = DirectorConversation(storageURL: persistsConversation ? (conversationStorageURL ?? DirectorConversation.storageURL(for: editor.url)) : nil)
        conversation = history
        if instruction.isEmpty { instruction = history.draftInstruction }
        if let previous = history.lastProject, previous.revision != (try? EditorCommandDispatcher.revision(for: editor.project)) {
            let event = DirectorConversation.restoredProjectEvent(from: previous, to: editor.project)
            conversation.event(event)
            record("editor_changed_while_closed", details: event)
        }
        let revision = (try? EditorCommandDispatcher.revision(for: editor.project)) ?? ""
        if var question = history.question, question.revision == revision {
            question.context.recording.projectID = projectID
            clarification = question
            notice = question.question
        }
        if var conflict = history.conflict, conflict.context.recording.revision == revision {
            conflict.context.recording.projectID = projectID
            conflict.proposal.proposal.projectID = projectID
            framingConflict = conflict
            notice = conflict.followup ?? conflict.proposal.question
        }
        observedProject = editor.project
        conversation.lastProject = DirectorProjectSnapshot(editor.project)
        projectObservation = editor.$project.dropFirst().sink { [weak self] next in
            self?.observeProject(next)
        }
        record("session_opened", details: ["project": editor.url.path, "revision": revision,
            "restored_exchanges": conversation.exchanges.count, "pending_question": awaitsClarification,
            "state": DirectorConversation.object(editor.project.state)])
        persist()
    }

    private func observeProject(_ next: RecordingProject) {
        guard let previous = observedProject, previous != next else { return }
        observedProject = next
        var event = DirectorConversation.projectEvent(from: previous, to: next,
            operation: observedEditor?.publishingHistoryOperation)
        event["actor"] = applyingDirectorChange ? "director" : "user"
        record("editor_changed", requestID: applyingDirectorChange ? currentRequestID : nil, details: event)
        if !applyingDirectorChange { conversation.event(event) }
        conversation.lastProject = DirectorProjectSnapshot(next)
        persist()
    }

    func beginVoiceInstruction() {
        speechID = UUID()
        record("speech_started", requestID: speechID, details: [:])
    }

    func recordSpeechHypothesis(_ text: String, phase: String) {
        guard !text.isEmpty else { return }
        record("speech_hypothesis", requestID: speechID, details: ["text": text, "phase": phase])
    }

    func recordSpeechState(phase: String, recognizer: String, status: String?, error: String?) {
        guard let speechID else { return }
        var details: [String: Any] = ["phase": phase, "recognizer": recognizer]
        if let status { details["status"] = status }
        if let error { details["error"] = error }
        record("speech_state", requestID: speechID, details: details)
    }

    @discardableResult
    func appendDictation(_ transcript: String) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        pendingSpeechID = speechID ?? UUID()
        record("speech_final", requestID: pendingSpeechID, details: ["text": transcript])
        if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            instruction = text
        } else {
            instruction += (instruction.last?.isWhitespace == true ? "" : " ") + text
        }
        return true
    }

    func submit(editor: ProjectEditor, playhead: Double, regionID: UUID?, editID: UUID?) {
        guard !isBusy else { return }
        attach(to: editor)
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let token = pendingSpeechID ?? UUID()
        pendingSpeechID = nil
        record("user_request", requestID: token, details: ["text": text, "playhead": playhead,
            "selected_box_id": regionID.map { $0.uuidString as Any } ?? NSNull(),
            "selected_edit_id": editID.map { $0.uuidString as Any } ?? NSNull()])
        do { try LocalEditPlanner.validateInstruction(text) }
        catch {
            errorMessage = error.localizedDescription; notice = nil
            conversation.begin(text, requestID: token)
            finish(token, response: nil, outcome: ["status": "rejected", "error": error.localizedDescription])
            return
        }
        // These use exactly the ordinary stack; report their real outcome to
        // the conversation even though no model round trip is necessary.
        if isHistoryShortcut(text) {
            conversation.begin(text, requestID: token)
            _ = performHistoryShortcut(text, editor: editor)
            finish(token, response: nil, outcome: ["status": errorMessage == nil ? "completed" : "rejected",
                "summary": notice ?? errorMessage ?? "", "history": DirectorConversation.object(editor.historyState)])
            return
        }
        if editor.draftState != nil, EditorAgentControls.historyAction(in: text) == .redo {
            notice = "Finish or undo the current edit before using Redo."
            errorMessage = nil
            conversation.begin(text, requestID: token)
            finish(token, response: nil, outcome: ["status": "rejected", "error": notice ?? ""])
            return
        }
        if (framingConflict != nil || clarification != nil), editor.draftState != nil {
            cancel()
            errorMessage = EditorCommandError.stale.localizedDescription
            conversation.begin(text, requestID: token)
            finish(token, response: nil, outcome: ["status": "rejected", "error": errorMessage ?? ""])
            return
        }
        guard editor.finishDraft() else {
            errorMessage = editor.errorMessage ?? "The current edit could not be saved. Your instruction has not been applied."
            notice = nil
            conversation.begin(text, requestID: token)
            finish(token, response: nil, outcome: ["status": "rejected", "error": errorMessage ?? "", "applied": false])
            return
        }
        do {
            let recording = try EditorCommandDispatcher.context(editor: editor, projectID: projectID)
            let pendingConflict = framingConflict
            let pendingQuestion = clarification
            let priorRevision = pendingConflict?.context.recording.revision ?? pendingQuestion?.revision
            if let priorRevision, priorRevision != recording.revision {
                cancel()
                throw EditorCommandError.stale
            }
            var context = pendingConflict?.context ?? pendingQuestion?.context ?? LocalEditContext(
                recording: recording, playhead: playhead, selectedRegionID: regionID,
                selectedEditID: editID, videoProcessingAvailable: !MediaProcessing.isSuspended)
            context.liveUI = LocalEditUIContext(playhead: playhead, selectedRegionID: regionID, selectedEditID: editID)
            let routingRequest = pendingQuestion?.request ?? text
            let payload = try modelPayload(text: text, context: context, routingRequest: routingRequest,
                question: pendingQuestion, conflict: pendingConflict)
            conversation.begin(text, requestID: token)
            persist()
            record("model_request", requestID: token, details: ["payload": object(payload),
                "routing_instruction": routingRequest, "context": DirectorConversation.object(context)])
            generation = token; currentRequestID = token
            isBusy = true; errorMessage = nil; notice = "Interpreting your instruction…"
            task = Task { @MainActor [weak self, transport] in
                var response: Data?
                var requestPayload = payload
                var attempt = 0
                do {
                    while true {
                    let data = try await transport(requestPayload)
                    response = data
                    guard let self else { return }
                    self.record("model_response", requestID: token, details: ["response": self.object(data)])
                    try Task.checkCancellation()
                    guard self.generation == token else {
                        self.record("ignored_response", requestID: token, details: ["reason": "superseded or cancelled"])
                        return
                    }
                    // Initial commands retain literal timing/reference checks.
                    // A genuine followup may change those constraints; its
                    // ordered conversation supplies intent, while typed command
                    // validation still enforces scope, bounds and atomicity.
                    let validationInstruction = pendingQuestion == nil ? text : nil
                    let result = try pendingConflict.map { try LocalEditPlanner.conflictResult(data, conflict: $0.proposal) }
                        ?? LocalEditPlanner.result(data, context: context, instruction: validationInstruction, routingRequest: routingRequest)
                    var outcome: [String: Any]
                    switch result {
                    case let .rejectedPlan(reason):
                        guard attempt == 0 else {
                            throw EditorCommandError.invalid("Director couldn’t produce a movement matching your instruction. No changes were applied. " + reason)
                        }
                        guard try EditorCommandDispatcher.revision(for: editor.project) == context.recording.revision else {
                            throw EditorCommandError.stale
                        }
                        self.finish(token, response: data, outcome: ["status": "rejected", "error": reason,
                            "retryable": true, "applied": false])
                        attempt += 1
                        requestPayload = try self.modelPayload(text: text, context: context, routingRequest: routingRequest,
                            question: pendingQuestion, conflict: pendingConflict, continuation: true)
                        self.record("model_request", requestID: token, details: ["attempt": attempt,
                            "payload": self.object(requestPayload), "repair_reason": reason])
                        continue
                    case let .commands(batch, summary):
                        let name = "Director: " + String(summary.replacingOccurrences(of: "\n", with: "; ").prefix(140))
                        try self.withDirectorChange { try EditorCommandDispatcher.apply(batch, to: editor, projectID: self.projectID, name: name) }
                        let oldIDs = Set(recording.state.timedEdits(includeCamera: true).map(\.id))
                        let created = editor.project.state.timedEdits(includeCamera: true).filter { !oldIDs.contains($0.id) }
                        let labels = created.compactMap { editor.references.editLabel(for: $0.id) }
                        self.notice = labels.isEmpty ? summary : summary + "\nCreated " + labels.joined(separator: ", ") + "."
                        self.clarification = nil; self.framingConflict = nil
                        outcome = ["status": "applied", "summary": self.notice ?? summary,
                            "commands": DirectorConversation.object(batch.commands),
                            "created_edits": created.map { ["id": $0.id.uuidString, "time": $0.time,
                                "label": editor.references.editLabel(for: $0.id) ?? ""] as [String: Any] }]
                    case let .history(history):
                        try self.withDirectorChange { try EditorHistoryDispatcher.apply(history, to: editor, projectID: self.projectID) }
                        let name = (history.action == .undo ? recording.history.undo : recording.history.redo).first ?? "change"
                        let action = history.action == .undo ? "Undid" : "Redid"
                        self.notice = history.count == 1 ? "\(action) \(name)." : "\(action) \(history.count) changes in order."
                        self.clarification = nil; self.framingConflict = nil
                        outcome = ["status": "applied", "summary": self.notice ?? "", "action": history.action.rawValue, "count": history.count]
                    case let .clarification(question):
                        self.notice = question
                        if let pendingConflict {
                            self.framingConflict = DirectorPendingConflict(proposal: pendingConflict.proposal,
                                context: pendingConflict.context, followup: question)
                        } else {
                            self.clarification = DirectorPendingQuestion(request: routingRequest, question: question, context: context)
                        }
                        outcome = ["status": "needs_answer", "question": question, "applied": false]
                    case let .framingConflict(conflict):
                        _ = try EditorCommandDispatcher.prepare(conflict.replacement, for: editor.project, projectID: self.projectID)
                        self.notice = conflict.question
                        self.clarification = nil
                        self.framingConflict = DirectorPendingConflict(proposal: conflict, context: context, followup: nil)
                        outcome = ["status": "conflict", "question": conflict.question, "applied": false,
                            "proposed_commands": DirectorConversation.object(conflict.proposal.commands),
                            "conflicting_framing_ids": conflict.framingIDs.map(\.uuidString)]
                    case let .noChanges(message):
                        self.notice = message; self.clarification = nil; self.framingConflict = nil
                        outcome = ["status": "unchanged", "summary": message]
                    }
                    outcome["revision"] = try EditorCommandDispatcher.revision(for: editor.project)
                    outcome["history"] = DirectorConversation.object(editor.historyState)
                    self.instruction = ""
                    self.finish(token, response: data, outcome: outcome)
                    break
                    }
                } catch {
                    guard let self, self.generation == token else { return }
                    self.notice = nil
                    if case .stale? = error as? EditorCommandError { self.framingConflict = nil; self.clarification = nil }
                    if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
                    self.finish(token, response: response, outcome: ["status": "rejected", "error": error.localizedDescription,
                        "revision": (try? EditorCommandDispatcher.revision(for: editor.project)) ?? ""])
                }
                guard let self, self.generation == token else { return }
                self.isBusy = false; self.task = nil; self.currentRequestID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            conversation.begin(text, requestID: token)
            finish(token, response: nil, outcome: ["status": "rejected", "error": error.localizedDescription])
        }
    }

    private func modelPayload(text: String, context: LocalEditContext, routingRequest: String,
                              question: DirectorPendingQuestion?, conflict: DirectorPendingConflict?,
                              continuation: Bool = false) throws -> Data {
        var budget = 12_000
        while true {
            var messages = conversation.messages(byteBudget: budget)
            if let question, !continuation {
                let active: [String: Any] = ["app_event": ["kind": "pending_question",
                    "original_instruction": question.request, "question": question.question,
                    "frozen_playhead": question.context.playhead]]
                messages.append(["role": "user", "content": String(decoding:
                    try JSONSerialization.data(withJSONObject: active, options: .sortedKeys), as: UTF8.self)])
            }
            let payload = try conflict.map {
                try LocalEditPlanner.conflictPayload(answer: text, conflict: $0.proposal, context: context,
                    question: $0.followup, conversation: messages)
            } ?? LocalEditPlanner.payload(request: text, context: context,
                routingRequest: routingRequest, conversation: messages, continuation: continuation)
            if payload.count <= 20_000 { return payload }
            guard budget > 0 else {
                throw EditorCommandError.invalid("This recording has more editing state than Director can currently process. No changes were made.")
            }
            budget = budget > 1_000 ? budget / 2 : 0
        }
    }

    func cancel() {
        if let id = currentRequestID {
            finish(id, response: nil, outcome: ["status": "cancelled", "summary": "Request cancelled; no pending proposal applied."])
        } else if awaitsClarification {
            conversation.event(["kind": "question_dismissed", "actor": "user"])
            record("question_dismissed", details: [:])
        }
        generation = UUID(); task?.cancel(); task = nil; currentRequestID = nil
        isBusy = false; notice = nil; errorMessage = nil; clarification = nil; framingConflict = nil
        persist()
    }

    /// Closing a window or restarting must not discard the conversation's
    /// pending question. Explicit Cancel/Dismiss still uses cancel().
    func suspend() {
        if let id = currentRequestID {
            finish(id, response: nil, outcome: ["status": "interrupted", "summary": "Request interrupted before completion."])
        }
        generation = UUID(); task?.cancel(); task = nil; currentRequestID = nil
        isBusy = false
        persist()
    }

    private func finish(_ id: UUID, response: Data?, outcome: [String: Any]) {
        conversation.finish(requestID: id, response: response, outcome: outcome)
        record("tool_result", requestID: id, details: outcome)
        persist()
    }
    private func persist() {
        draftSaveTask?.cancel(); draftSaveTask = nil
        conversation.question = clarification; conversation.conflict = framingConflict
        conversation.draftInstruction = instruction
        if !conversation.save() { record("conversation_save_failed", details: [:]) }
    }
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        guard conversation.storageURL != nil else { return }
        draftSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            self?.persist()
        }
    }
    private func record(_ event: String, requestID: UUID? = nil, details: [String: Any]) {
        _ = diagnostics?.record(event, sessionID: projectID, requestID: requestID, details: details)
    }
    private func object(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
    }
    private func withDirectorChange(_ action: () throws -> Void) rethrows {
        applyingDirectorChange = true
        defer { applyingDirectorChange = false }
        try action()
    }
    private func isHistoryShortcut(_ text: String) -> Bool {
        let value = normalized(text)
        return ["undo", "undo that", "undo last change", "undo the last change", "redo", "redo that", "redo last change", "redo the last change"].contains(value)
    }
    private func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private func performHistoryShortcut(_ text: String, editor: ProjectEditor) -> Bool {
        let undo = normalized(text).hasPrefix("undo")
        cancel()
        if !undo, editor.draftState != nil {
            notice = "Finish or undo the current edit before using Redo."
        } else if undo ? editor.canUndo : editor.canRedo {
            let name = undo ? editor.undoName : editor.redoName
            let succeeded = undo ? editor.undo() : editor.redo()
            if succeeded { notice = (undo ? "Undid " : "Redid ") + name + "." }
            else { errorMessage = editor.errorMessage ?? "The history change could not be saved." }
        } else { notice = undo ? "Nothing to undo." : "Nothing to redo." }
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
                LocalVoiceButton(speech: instructionSpeech, finishPurpose: "Finish and apply instruction", onBegin: {
                    session.beginVoiceInstruction()
                    instructionSpeech.contextualStrings = editor.editingState.regions.compactMap {
                        editor.references.boxLabel(for: $0.id)
                    } + editor.editingState.timedEdits(includeCamera: true).compactMap {
                        editor.references.editLabel(for: $0.id)
                    }
                    onVoiceBegin()
                }) { text in
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
        .onChange(of: instructionSpeech.transcript) { _, text in
            session.recordSpeechHypothesis(text, phase: String(describing: instructionSpeech.phase))
        }
        .onChange(of: instructionSpeech.phase) { _, _ in recordSpeechState() }
        .onChange(of: instructionSpeech.recognizerIdentifier) { _, _ in recordSpeechState() }
        .onChange(of: instructionSpeech.statusMessage) { _, _ in recordSpeechState() }
        .onChange(of: instructionSpeech.errorMessage) { _, _ in recordSpeechState() }
        .onExitCommand {
            if instructionSpeech.isActive || session.isBusy || session.awaitsClarification {
                session.cancel()
                Task { await instructionSpeech.cancel() }
            } else { onCancel() }
        }
        .onDisappear {
            session.suspend()
            Task { await instructionSpeech.cancel() }
        }
    }

    private func recordSpeechState() {
        session.recordSpeechState(phase: String(describing: instructionSpeech.phase),
            recognizer: instructionSpeech.recognizerIdentifier,
            status: instructionSpeech.statusMessage, error: instructionSpeech.errorMessage)
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
