import Foundation

/// Action words describe the current framing; the existing letter remains the
/// durable identity when a target changes, moves, or is undone.
struct EditorActionDescription: Equatable, Sendable {
    enum Kind: String, Sendable {
        case zoom = "Zoom", pan = "Pan", fullFrame = "Full frame", hold = "Hold", reference = "Reference", camera = "Camera"
    }

    let kind: Kind
    let shortLabel: String
    let detail: String
    let tooltip: String
    let legacyLabel: String?
    let aliases: [String]
    let isMovement: Bool

    static func describe(_ edit: TimedEdit, in state: EditState, references: EditorReferences) -> Self {
        let zoom = state.zoomKeyframes.first { $0.id == edit.zoomID }
        let camera = state.pipKeyframes.first { $0.id == edit.cameraID }
        let priorZoom = state.zoomKeyframes.last { $0.time < (zoom?.time ?? edit.time) }
        let priorCamera = state.pipKeyframes.last { $0.time < (camera?.time ?? edit.time) }
        let previous = priorZoom?.placement.clamped ?? ZoomPlacement()
        let target = zoom?.placement.clamped ?? previous
        let scaleChanged = abs(target.scale - previous.scale) > 0.000001
        let positionChanged = abs(target.x - previous.x) > 0.000001 || abs(target.y - previous.y) > 0.000001
        let screenChanged = zoom != nil && (scaleChanged || positionChanged)
        let cameraChanged = camera.map { $0.placement != (priorCamera?.placement ?? PIPPlacement()) } ?? false
        let kind: Kind
        if zoom == nil && camera == nil { kind = .reference }
        else if !screenChanged && cameraChanged { kind = .camera }
        else if zoom != nil && target.scale == 1 && (screenChanged || edit.time == 0) { kind = .fullFrame }
        else if scaleChanged { kind = .zoom }
        else if positionChanged { kind = .pan }
        else { kind = .hold }

        let destination = zoom?.sourceRegionID.flatMap { id in
            state.regions.contains(where: { $0.id == id }) ? references.boxLabel(for: id).map { " to " + $0 } : nil
        } ?? ""
        let factor = String(format: "%.2f×", target.scale)
        var detail: String
        switch kind {
        case .reference: detail = "Reference mark; adds no framing change."
        case .fullFrame: detail = edit.time == 0 && !screenChanged ? "Start with the full recording frame." : "Show the full recording frame."
        case .zoom:
            detail = "Zoom \(target.scale > previous.scale ? "in" : "out") to \(factor)"
            if positionChanged { detail += " and pan" }
            detail += destination + "."
        case .pan: detail = "Pan\(destination) at \(factor)."
        case .hold:
            detail = zoom != nil ? "Keep the screen framing at \(factor)." : "Keep the camera framing."
        case .camera: detail = cameraDetail(camera!.placement, previous: priorCamera?.placement ?? PIPPlacement())
        }
        if screenChanged && cameraChanged, let camera {
            detail += " " + cameraDetail(camera.placement, previous: priorCamera?.placement ?? PIPPlacement())
        }
        let legacy = references.editLabel(for: edit.id)
        let letter = legacy.map { String($0.dropFirst("Edit ".count)) }
        let label = kind.rawValue + (letter.map { " " + $0 } ?? "")
        let pointTime = String(format: "%.2f s", edit.time)
        var tooltip = "\(label) at \(pointTime). \(detail)"
        if screenChanged, let zoom, zoom.transition == .smooth {
            let start = max(priorZoom?.time ?? 0, edit.time - zoom.duration)
            tooltip += String(format: " Smooth movement from %.2f to %.2f s.", start, edit.time)
        } else if kind == .hold, edit.time > 0 {
            let start = zoom != nil ? priorZoom?.time ?? 0 : priorCamera?.time ?? 0
            tooltip += String(format: " Hold from %.2f to %.2f s.", start, edit.time)
        }
        let abbreviatedReference = kind == .reference ? letter.map { "Ref " + $0 } : nil
        return Self(kind: kind, shortLabel: label, detail: detail, tooltip: tooltip, legacyLabel: legacy,
                    aliases: [label, legacy, letter, abbreviatedReference].compactMap { $0 }, isMovement: screenChanged || cameraChanged)
    }

    /// Descriptive prefixes can change after a revision. Resolve all known
    /// screen action prefixes through the stable letter, including old Edit/bare
    /// names. Camera and reference qualifiers identify their own components.
    static func resolve(_ label: String, in state: EditState, references: EditorReferences,
                        includeCamera: Bool = true) -> TimedEdit? {
        guard let letter = letter(in: label) else { return nil }
        let expected = "Edit " + letter
        let matches = state.timedEdits(includeCamera: includeCamera).filter { edit in
            [edit.id, edit.zoomID, edit.cameraID, edit.anchorID].compactMap { $0 }
                .contains { references.editLabel(for: $0) == expected }
        }
        // A Screen and Camera animation can retain the same stable letter
        // after being moved apart. Qualified names identify their own lane;
        // an unqualified Edit/letter remains ambiguous and needs clarification.
        let prefix = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let qualified: [TimedEdit]
        if prefix.hasPrefix("camera ") { qualified = matches.filter { $0.cameraID.map { references.editLabel(for: $0) == expected } == true } }
        else if ["zoom ", "pan ", "full frame ", "full-frame ", "hold "].contains(where: { prefix.hasPrefix($0) }) {
            qualified = matches.filter { $0.zoomID.map { references.editLabel(for: $0) == expected } == true }
        } else if ["ref ", "reference "].contains(where: { prefix.hasPrefix($0) }) {
            qualified = matches.filter { $0.anchorID.map { references.editLabel(for: $0) == expected } == true }
        } else { return matches.count == 1 ? matches[0] : nil }
        return qualified.count == 1 ? qualified[0] : nil
    }

    static func unambiguousLabel(for edit: TimedEdit, in state: EditState, references: EditorReferences) -> String {
        if let legacy = references.editLabel(for: edit.id), resolve(legacy, in: state, references: references)?.id == edit.id { return legacy }
        if edit.zoomID == nil, edit.cameraID != nil, let legacy = references.editLabel(for: edit.id) {
            return "Camera " + String(legacy.dropFirst(5))
        }
        return describe(edit, in: state, references: references).shortLabel
    }

    static func mentions(_ edit: TimedEdit, in request: String, state: EditState, references: EditorReferences) -> Bool {
        guard let legacy = references.editLabel(for: edit.id), let letter = letter(in: legacy) else { return false }
        let prefixed = "(?i)(?<![A-Za-z0-9])(?:edit|step|zoom|pan|full[ -]?frame|hold|ref(?:erence)?|camera)\\s*" + letter + "(?![A-Za-z0-9])"
        if request.range(of: prefixed, options: .regularExpression) != nil { return true }
        // Require a label-shaped context for bare letters. The article in
        // 'move to a box' must not silently identify timeline reference A.
        let bare = "(?i)\\b(?:at|from|to|between|and)\\s+" + letter + "(?=\\s*(?:$|[,.;!?]|\\b(?:and|to|frame|zoom|pan|hold|show|use|move|return|then|please)\\b))"
        return request.range(of: bare, options: .regularExpression) != nil
    }

    /// Action words inside an identifier are not new movement instructions.
    /// In particular, mentioning Full frame E does not request a waypoint.
    static func neutralizingLabels(in request: String, state: EditState, references: EditorReferences) -> String {
        let pattern = "\\b(?i:edit|step|zoom|pan|full[ -]?frame|hold|ref(?:erence)?|camera)\\s+(?:[A-Za-z]|[A-Z]{2,6})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return request }
        let source = request as NSString
        let result = NSMutableString(string: request)
        for match in regex.matches(in: request, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let edit = resolve(source.substring(with: match.range), in: state, references: references),
                  let legacy = references.editLabel(for: edit.id) else { continue }
            result.replaceCharacters(in: match.range, with: legacy)
        }
        return result as String
    }

    private static func letter(in label: String) -> String? {
        let pattern = "^\\s*(?:(?:edit|step|zoom|pan|full[ -]?frame|hold|ref(?:erence)?|camera)\\s*)?([a-z]{1,6})\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let value = label as NSString
        guard let match = regex.firstMatch(in: label, range: NSRange(location: 0, length: value.length)) else { return nil }
        return value.substring(with: match.range(at: 1)).uppercased()
    }

    private static func cameraDetail(_ target: PIPPlacement, previous: PIPPlacement) -> String {
        if target.visible != previous.visible { return target.visible ? "Show the camera." : "Hide the camera." }
        if target.fullscreenFraction != previous.fullscreenFraction {
            if target.fullscreenFraction == 1 { return "Expand the camera to full screen." }
            if target.fullscreenFraction == 0 { return "Return the camera to its picture-in-picture layout." }
            return "Resize the camera toward full screen."
        }
        let moved = target.x != previous.x || target.y != previous.y
        let resized = target.scale != previous.scale
        let reframed = target.shape != previous.shape || target.aspectRatio != previous.aspectRatio || target.crop != previous.crop || target.sourceZoom != previous.sourceZoom
        if reframed { return "Change the camera framing." }
        if moved && resized { return "Move and resize the camera." }
        if moved { return "Move the camera." }
        if resized { return "Resize the camera." }
        return "Keep the camera framing."
    }
}
