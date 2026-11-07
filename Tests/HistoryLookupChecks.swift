import Darwin
import Foundation

private enum LookupFailure: Error { case failed(String) }
actor HistoryLookupTransport {
    private(set) var payloads = [Data]()
    private var replies = [Int: CheckedContinuation<Data, any Error>]()
    func send(_ data: Data) async throws -> Data {
        let index = payloads.count; payloads.append(data)
        return try await withCheckedThrowingContinuation { replies[index] = $0 }
    }
    func reply(_ index: Int, _ data: Data) { replies.removeValue(forKey: index)?.resume(returning: data) }
}

/// Actual history, parser, inspector and session continuations using metadata
/// only. Native Metal text inference is an explicit opt-in; never source media.
@main @MainActor
struct HistoryLookupChecks {
    static let instruction = "Undo the latest change after inspecting its actual saved history."
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw LookupFailure.failed(message) }
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: .sortedKeys) }
    static func wait(seconds: Double = 3, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw LookupFailure.failed("controlled history operation timed out")
    }
    static func tool(_ name: String, _ args: [String: Any], id: String = UUID().uuidString) throws -> Data {
        try json(["choices": [["message": ["tool_calls": [["id": id, "type": "function", "function": ["name": name, "arguments": String(decoding: json(args), as: UTF8.self)]]]]]]])
    }
    @MainActor
    struct Fixture {
        let directory: URL
        let editor: ProjectEditor
        let transport = HistoryLookupTransport()
        let session: EditorAssistantSession
        let archive: URL
        init(native: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-history-lookup-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "missing-screen.mov", duration: 20)
            project.title = "Original title"
            editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
            try require(editor.save() && editor.rename(to: "Renamed title"), "create rename snapshot")
            var next = editor.project.state; next.cursorStyle.size = 2
            try require(editor.commit(next, name: "Manual pointer"), "create pointer snapshot")
            next.zoomKeyframes = [ZoomKeyframe(time: 3, scale: 2)]
            try require(editor.commit(next, name: "Director: Zoom Box 1"), "create framing snapshot")
            for index in 4...12 {
                next.audio.volume = Double(index) / 20
                try require(editor.commit(next, name: "Audio adjustment \(index)"), "create paginated snapshot")
            }
            archive = directory.appendingPathComponent("conversation.json")
            let diagnostics = DirectorDiagnostics(directory: directory.appendingPathComponent("diagnostics"))
            if native { session = EditorAssistantSession(diagnostics: diagnostics, conversationStorageURL: archive) }
            else { let transport = self.transport; session = EditorAssistantSession(transport: { try await transport.send($0) }, diagnostics: diagnostics, conversationStorageURL: archive) }
        }
        func close() { session.cancel(); try? FileManager.default.removeItem(at: directory) }
        func context() throws -> LocalEditContext {
            LocalEditContext(recording: try EditorCommandDispatcher.context(editor: editor, projectID: session.projectID), playhead: 2.5, selectedRegionID: nil, selectedEditID: nil, videoProcessingAvailable: false)
        }
        func scope() throws -> [String: Any] { try ["version": 1, "project_id": session.projectID.uuidString, "expected_revision": EditorCommandDispatcher.revision(for: editor.project)] }
        func lookup(offset: Int = 0, limit: Int = 8, stack: EditorHistoryAction = .undo) throws -> Data {
            try tool("inspect_history", scope().merging(["stack": stack.rawValue, "offset": offset, "limit": limit]) { _, value in value })
        }
        func request(offset: Int = 0, limit: Int = 8, stack: EditorHistoryAction = .undo) throws -> EditorHistoryLookupRequest {
            try EditorHistoryLookupRequest(projectID: session.projectID, revision: EditorCommandDispatcher.revision(for: editor.project), stack: stack, offset: offset, limit: limit)
        }
        func page(offset: Int = 0, limit: Int = 8, stack: EditorHistoryAction = .undo) throws -> [String: Any] {
            try EditorHistoryInspector.page(request(offset: offset, limit: limit, stack: stack), to: editor, projectID: session.projectID)
        }
        func begin(_ text: String = instruction) async throws {
            session.instruction = text; session.submit(editor: editor, playhead: 2.5, regionID: nil, editID: nil)
            try await wait { await transport.payloads.count == 1 }
        }
        func assertUnchanged(_ before: RecordingProject, bytes: Data) throws {
            try require(editor.project == before && Data(contentsOf: editor.url) == bytes, "history inspection mutated saved project/Undo/Redo")
        }
    }
    static func entries(_ page: [String: Any]) throws -> [[String: Any]] {
        guard let entries = page["entries"] as? [[String: Any]] else { throw LookupFailure.failed("history page entries missing") }
        return entries
    }
    static func summary(_ item: [String: Any], _ side: String) throws -> [String: Any] {
        guard let value = item[side] as? [String: Any] else { throw LookupFailure.failed("history summary side missing") }
        return value
    }
    static func main() async throws {
        let native = CommandLine.arguments.contains("--native-model")
        DispatchQueue.global().asyncAfter(deadline: .now() + (native ? 180 : 30)) { Darwin.exit(2) }
        try require(MediaProcessing.isSuspended, "requires suspended media")
        try snapshotDirectionAndPagination()
        try parserAndScopeGuards()
        try compactContinuation()
        try await directHistoryShortcut()
        try await lookupThenUndo()
        try await lookupThenReportOrClarify(report: true)
        try await lookupThenReportOrClarify(report: false)
        try await boundedLoops()
        try await cancellationAndStale()
        try await changedAfterLookup()
        if native { try await nativeLookup() }
        print("History lookup checks passed (real snapshot direction/pagination, scope/ranges, compact paired continuations, lookup→Undo/report/clarify, read-only bytes, loop/cancel/stale guards; project metadata only).")
    }
    static func snapshotDirectionAndPagination() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let before = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
        let first = try fixture.page(); let last = try fixture.page(offset: 8)
        let all = try entries(first) + entries(last)
        try require(first["total"] as? Int == 12 && first["has_more"] as? Bool == true && (try entries(first)).count == 8 && last["has_more"] as? Bool == false && (try entries(last)).count == 4, "history did not paginate 8+4 actual snapshots")
        try require(all.compactMap { $0["name"] as? String } == fixture.editor.historyState.undo && all.compactMap { $0["index"] as? Int } == Array(0..<12), "Undo pages are not next-action first")
        try require((try summary(all[0], "before"))["description"] as? String == "Audio: unmuted, volume 0.55, fades 0.00/0.00s." && (try summary(all[0], "after"))["description"] as? String == "Audio: unmuted, volume 0.60, fades 0.00/0.00s.", "Undo summaries reversed original before→after direction")
        let rename = all.last!
        try require(rename["changed_components"] as? [String] == ["title"] && (try summary(rename, "before"))["title"] as? String == "Original title" && (try summary(rename, "after"))["title"] as? String == "Renamed title", "title-only history invented state changes or reversed the rename")
        for item in all {
            try require((item["name"] as? String)?.count ?? 999 <= 140, "history name exceeded bound")
            for side in ["before", "after"] {
                let value = try summary(item, side)
                try require((value["description"] as? String)?.count ?? 999 <= 160 && value["description_truncated"] is Bool, "snapshot description exceeded bound or omitted its truncation flag")
            }
        }
        try require(try entries(fixture.page(offset: Int.max)).isEmpty, "out-of-range positive pagination did not return an empty page")
        try fixture.assertUnchanged(before, bytes: bytes)
        try require(fixture.editor.undo(count: 12), "prepare actual Redo stack")
        let undone = fixture.editor.project; let undoneBytes = try Data(contentsOf: fixture.editor.url)
        let redo = try entries(fixture.page(stack: .redo)) + entries(fixture.page(offset: 8, stack: .redo))
        try require(redo.compactMap { $0["name"] as? String } == fixture.editor.historyState.redo && redo.first?["name"] as? String == "Rename recording", "Redo pages reversed next-action order")
        let oldByName = Dictionary(uniqueKeysWithValues: all.map { ($0["name"] as! String, $0) })
        for item in redo {
            let old = oldByName[item["name"] as! String]!
            for side in ["before", "after"] { try require(json(summary(item, side)) == json(summary(old, side)), "Redo summary described the reverse of the original change") }
        }
        try require(try entries(fixture.page()).isEmpty, "empty Undo stack fabricated entries")
        try fixture.assertUnchanged(undone, bytes: undoneBytes)
    }
    static func parserAndScopeGuards() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let context = try fixture.context(); let before = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
        let scope = try fixture.scope()
        let args = scope.merging(["stack": "undo", "offset": 8, "limit": 4]) { _, value in value }
        guard case let .historyLookup(parsed) = try LocalEditPlanner.result(tool("inspect_history", args), context: context, instruction: instruction, routingRequest: instruction) else { throw LookupFailure.failed("production parser did not return historyLookup") }
        try require(parsed == fixture.request(offset: 8, limit: 4), "parser changed requested page or scope")
        for patch: [String: Any] in [["version": 2], ["stack": "all"], ["offset": -1], ["offset": true], ["offset": 0.5], ["limit": 0], ["limit": 9], ["limit": true], ["extra": true]] {
            do { _ = try EditorAgentControls.result(name: "inspect_history", args: args.merging(patch) { _, value in value }, context: context); throw LookupFailure.failed("malformed lookup accepted") } catch is EditorCommandError {}
        }
        var bad = try fixture.request(); bad.projectID = UUID()
        do { _ = try EditorHistoryInspector.page(bad, to: fixture.editor, projectID: fixture.session.projectID); throw LookupFailure.failed("foreign lookup accepted") } catch EditorCommandError.stale {}
        bad = try fixture.request(); bad.revision = "stale"
        do { _ = try EditorHistoryInspector.page(bad, to: fixture.editor, projectID: fixture.session.projectID); throw LookupFailure.failed("stale lookup accepted") } catch EditorCommandError.stale {}
        for (offset, limit) in [(-1, 1), (0, 0), (0, 9)] {
            do { _ = try fixture.page(offset: offset, limit: limit); throw LookupFailure.failed("invalid direct page range accepted") } catch is EditorCommandError {}
        }
        let report = try tool("report_history", scope.merging(["summary": "The ninth saved change adjusts audio."]) { _, value in value })
        do { _ = try LocalEditPlanner.result(report, context: context); throw LookupFailure.failed("uninspected invented history report accepted") } catch is EditorCommandError {}
        guard case .rejectedPlan = try LocalEditPlanner.result(report, context: context, routingRequest: instruction) else { throw LookupFailure.failed("initial tool scope offered report_history") }
        guard case .noChanges = try LocalEditPlanner.result(report, context: context, routingRequest: instruction, historyInspected: true) else { throw LookupFailure.failed("inspected report did not complete read-only") }
        try fixture.assertUnchanged(before, bytes: bytes)
        var draft = before.state; draft.audio.volume = 0.2
        try require(fixture.editor.updateDraft(draft, at: 4), "draft fixture")
        do { _ = try fixture.page(); throw LookupFailure.failed("lookup consumed a pending draft") } catch EditorCommandError.pendingDraft {}
        try require(fixture.editor.draftState == draft && fixture.editor.project == before, "lookup guard modified a pending draft")
    }
    static func compactContinuation() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let conversation = DirectorConversation(); let id = UUID()
        conversation.begin(instruction, requestID: id)
        for offset in [0, 2, 4] {
            conversation.finish(requestID: id, response: try fixture.lookup(offset: offset, limit: 2), outcome: ["status": "inspected", "applied": false, "history_page": try fixture.page(offset: offset, limit: 2)])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let archived = try encoder.encode(conversation.exchanges)
        let compact = conversation.messages(byteBudget: 200, continuing: id)
        try require(compact.count == 4 && compact.first?["content"] as? String == instruction && compact.last?["role"] as? String == "tool", "compaction dropped the original instruction or actual final tool result")
        let note = try JSONSerialization.jsonObject(with: Data((compact[1]["content"] as! String).utf8)) as! [String: Any]
        let event = note["app_event"] as! [String: Any]
        try require(event["kind"] as? String == "continuation_compacted" && (event["omitted_lookup_pages"] as? [[String: Any]])?.count == 2, "compaction omitted no page metadata")
        let call = (compact[2]["tool_calls"] as! [[String: Any]])[0]
        try require(compact[3]["tool_call_id"] as? String == call["id"] as? String, "compaction fabricated or mismatched a tool ID")
        let actual = try JSONSerialization.jsonObject(with: Data((compact[3]["content"] as! String).utf8)) as! [String: Any]
        try require(json(actual["history_page"]!) == json(fixture.page(offset: 4, limit: 2)), "latest compact tool value was not the real page")
        try require(encoder.encode(conversation.exchanges) == archived, "context compaction rewrote the full archive")
    }
    static func continuation(_ fixture: Fixture, index: Int) async throws -> [[String: Any]] {
        try await wait { await fixture.transport.payloads.count == index + 1 }
        let data = await fixture.transport.payloads[index]
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let messages = root["messages"] as! [[String: Any]]
        let offered = (root["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } ?? []
        try require(root["tool_choice"] as? String == "required" && offered.contains("report_history") && offered.contains("ask_clarification"), "history continuation allowed untyped prose or omitted safe read-only responses")
        try require(messages.last?["role"] as? String == "tool", "lookup continuation was replaced by a new user turn")
        let preceding = messages[messages.count - 2]
        let call = (preceding["tool_calls"] as! [[String: Any]])[0]
        try require(messages.last?["tool_call_id"] as? String == call["id"] as? String && (call["function"] as? [String: Any])?["name"] as? String == "inspect_history", "session lost the actual lookup call/result pairing")
        try require(messages.filter { $0["role"] as? String == "user" && $0["content"] as? String == fixture.session.instruction }.count == 1, "continuation duplicated or lost the user's instruction")
        let value = try JSONSerialization.jsonObject(with: Data((messages.last!["content"] as! String).utf8)) as! [String: Any]
        try require(value["status"] as? String == "inspected" && value["applied"] as? Bool == false && value["history_page"] != nil && fixture.session.isBusy, "lookup ended the request or claimed an edit")
        return messages
    }
    static func directHistoryShortcut() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let original = fixture.editor.project
        fixture.session.instruction = "undo that last edit"
        fixture.session.submit(editor: fixture.editor, playhead: 18, regionID: nil, editID: nil)
        try require(!fixture.session.isBusy && fixture.session.errorMessage == nil && fixture.editor.project.state == original.undoHistory.last?.state && fixture.editor.project.undoHistory.count == 11 && fixture.editor.project.redoHistory.count == 1, "literal undo that last edit did not use the ordinary shared stack")
        fixture.session.instruction = "redo last edit"
        fixture.session.submit(editor: fixture.editor, playhead: 1, regionID: nil, editID: nil)
        let calls = await fixture.transport.payloads.count
        try require(calls == 0 && !fixture.session.isBusy && fixture.session.errorMessage == nil && fixture.editor.project.state == original.state && fixture.editor.project.undoHistory == original.undoHistory && fixture.editor.project.redoHistory.isEmpty, "literal Undo/Redo required a model call or changed normal history semantics")
    }
    static func lookupThenUndo() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let before = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
        try await fixture.begin(); await fixture.transport.reply(0, try fixture.lookup(limit: 2))
        _ = try await continuation(fixture, index: 1); try fixture.assertUnchanged(before, bytes: bytes)
        await fixture.transport.reply(1, try tool("change_history", fixture.scope().merging(["action": "undo", "count": 1]) { _, value in value }))
        try await wait { !fixture.session.isBusy }
        try require(fixture.editor.project.state == before.undoHistory.last?.state && fixture.editor.project.undoHistory.count == 11 && fixture.editor.project.redoHistory.count == 1 && fixture.session.errorMessage == nil, "final explicit Undo did not use the ordinary shared stack")
    }
    static func lookupThenReportOrClarify(report: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let before = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
        try await fixture.begin(); await fixture.transport.reply(0, try fixture.lookup(offset: 8, limit: 4))
        _ = try await continuation(fixture, index: 1); try fixture.assertUnchanged(before, bytes: bytes)
        let response = report ? try tool("report_history", fixture.scope().merging(["summary": "Audio adjustment 4 is the ninth next Undo change. No changes were made."]) { _, value in value }) : try tool("ask_clarification", ["question": "Undoing that Director change would also undo newer manual edits. Continue?"])
        await fixture.transport.reply(1, response); try await wait { !fixture.session.isBusy }
        try fixture.assertUnchanged(before, bytes: bytes)
        try require(fixture.session.errorMessage == nil && (report ? !fixture.session.awaitsClarification : fixture.session.awaitsClarification), "lookup did not finish with the requested read-only report/question")
        try require(DirectorConversation(storageURL: fixture.archive).exchanges.flatMap(\.messages).contains { $0.role == "tool" && ($0.content?.contains("history_page") ?? false) }, "actual lookup result was not persisted")
    }
    static func boundedLoops() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let before = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
        try await fixture.begin()
        for index in 0..<4 {
            await fixture.transport.reply(index, try fixture.lookup(offset: index * 2, limit: 2))
            _ = try await continuation(fixture, index: index + 1)
        }
        await fixture.transport.reply(4, try fixture.lookup(offset: 8, limit: 2))
        try await wait { !fixture.session.isBusy }
        let calls = await fixture.transport.payloads.count
        try require(calls == 5 && fixture.session.errorMessage?.contains("lookup limit") == true, "history lookup loop was not bounded to four pages")
        try fixture.assertUnchanged(before, bytes: bytes)
    }
    static func cancellationAndStale() async throws {
        for cancel in [true, false] {
            let fixture = try Fixture(); defer { fixture.close() }
            let before = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
            try await fixture.begin(); let reply = try fixture.lookup()
            if cancel { fixture.session.cancel() }
            else { try require(fixture.editor.rename(to: "Manual intervening change"), "manual change fixture") }
            let current = fixture.editor.project; let currentBytes = try Data(contentsOf: fixture.editor.url)
            await fixture.transport.reply(0, reply)
            if cancel { try await Task.sleep(for: .milliseconds(15)) }
            else { try await wait { !fixture.session.isBusy } }
            let count = await fixture.transport.payloads.count
            try require(count == 1 && !fixture.session.isBusy && fixture.editor.project == current && Data(contentsOf: fixture.editor.url) == currentBytes, "cancelled/stale lookup continued or mutated the editor")
            if cancel { try fixture.assertUnchanged(before, bytes: bytes) }
            else { try require(fixture.session.errorMessage == EditorCommandError.stale.localizedDescription, "intervening change did not reject the lookup revision") }
        }
    }
    static func changedAfterLookup() async throws {
        for report in [false, true] {
            let fixture = try Fixture(); defer { fixture.close() }
            try await fixture.begin(); let scope = try fixture.scope()
            await fixture.transport.reply(0, try fixture.lookup())
            _ = try await continuation(fixture, index: 1)
            try require(fixture.editor.rename(to: "Changed after inspection"), "post-lookup revision fixture")
            let current = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
            let response = report ? try tool("report_history", scope.merging(["summary": "The old inspected entry adjusts audio."]) { _, value in value }) : try tool("change_history", scope.merging(["action": "undo", "count": 1]) { _, value in value })
            await fixture.transport.reply(1, response); try await wait { !fixture.session.isBusy }
            try fixture.assertUnchanged(current, bytes: bytes)
            try require(fixture.session.errorMessage == EditorCommandError.stale.localizedDescription, "old lookup authorized a stale final report/Undo")
        }
    }
    static func nativeLookup() async throws {
        let fixture = try Fixture(native: true); defer { fixture.close() }
        let before = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
        fixture.session.instruction = "Before undoing anything, inspect the older saved Undo entry starting with the ninth change (undo stack, offset 8, limit 1). Tell me which saved change is there. Do not undo or redo anything."
        fixture.session.submit(editor: fixture.editor, playhead: 9.5, regionID: nil, editID: nil)
        try await wait(seconds: 150) { !fixture.session.isBusy }
        try fixture.assertUnchanged(before, bytes: bytes)
        let messages = fixture.session.conversation.exchanges.flatMap(\.messages)
        var actualPages = [[String: Any]]()
        for index in messages.indices where messages[index].role == "assistant" && messages[index].toolCalls?.first?.function.name == "inspect_history" {
            guard index + 1 < messages.count else { continue }
            let call = messages[index].toolCalls!.first!
            let result = messages[index + 1]
            try require(result.role == "tool" && result.toolCallID == call.id, "native inspection lost its actual paired result")
            if let content = result.content, let value = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any], let page = value["history_page"] as? [String: Any] { actualPages.append(page) }
        }
        let evidence = "NATIVE history lookup pages=" + String(decoding: try json(actualPages), as: UTF8.self) + "\nNATIVE history report=" + (fixture.session.notice ?? "<no notice>") + "\nNATIVE history error=" + (fixture.session.errorMessage ?? "<none>") + "\nNATIVE history tool names=" + messages.flatMap { $0.toolCalls?.map { $0.function.name } ?? [] }.joined(separator: ",") + "\n"
        FileHandle.standardOutput.write(Data(evidence.utf8))
        if fixture.session.errorMessage != nil {
            let diagnostics = fixture.directory.appendingPathComponent("diagnostics/interactions.jsonl")
            if let data = try? Data(contentsOf: diagnostics) { FileHandle.standardOutput.write(data) }
        }
        try require(!actualPages.isEmpty && actualPages.contains { ($0["offset"] as? Int) == 8 }, "native model never inspected the requested older saved entry")
        try require(fixture.session.errorMessage == nil && fixture.session.notice?.contains("Audio adjustment 4") == true && messages.contains { $0.toolCalls?.contains { $0.function.name == "report_history" } == true }, "native model did not report the actual inspected ninth entry")
        let reported = fixture.session.notice?.lowercased() ?? ""
        try require(!reported.contains("unmuting") && !reported.contains("unmuted it"), "native report invented an unmute action absent from the inspected before/after snapshots")
    }
}
