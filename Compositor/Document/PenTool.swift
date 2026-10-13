import AppKit
import CoreGraphics
import Foundation

nonisolated enum PenMode: String, CaseIterable, Codable, Sendable {
    case shape = "Shape"
    case line = "Line"
}

nonisolated enum PenAction: String, CaseIterable, Sendable {
    case draw = "Draw"
    case bend = "Bend"
    case cut = "Cut"
    case erase = "Erase"

    var statusText: String {
        switch self {
        case .draw:
            "Click points · Drag curves · Click the first point to close · Double-click or Return to finish open · Double-click an existing point to smooth · ⌘Return loads selection"
        case .bend:
            "Drag a path segment to bend it · ⌘Z undo · Tab changes path tool"
        case .cut:
            "Click a path segment to cut it · Closed paths open; open paths split into two layers · ⌘Z undo"
        case .erase:
            "Drag the circular eraser across a path · [ ] size · Right-drag size · ⌘Z undo"
        }
    }
}

nonisolated struct VectorPathNode: Codable, Equatable, Sendable {
    var anchor: CGPoint
    var inHandle: CGPoint
    var outHandle: CGPoint

    init(anchor: CGPoint, inHandle: CGPoint? = nil, outHandle: CGPoint? = nil) {
        self.anchor = anchor
        self.inHandle = inHandle ?? anchor
        self.outHandle = outHandle ?? anchor
    }

    var isFinite: Bool {
        anchor.x.isFinite && anchor.y.isFinite &&
            inHandle.x.isFinite && inHandle.y.isFinite &&
            outHandle.x.isFinite && outHandle.y.isFinite
    }
}

nonisolated enum PenHandle: Equatable, Sendable {
    case incoming
    case outgoing
}

nonisolated struct LayerVectorPathFill: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var isValid: Bool {
        red.isFinite && green.isFinite && blue.isFinite &&
            (0...1).contains(red) && (0...1).contains(green) && (0...1).contains(blue)
    }
}

nonisolated struct LayerVectorPathBrushStroke: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var diameter: Double
    var hardness: Double
    var opacity: Double

    var isValid: Bool {
        red.isFinite && green.isFinite && blue.isFinite &&
            (0...1).contains(red) && (0...1).contains(green) && (0...1).contains(blue) &&
            diameter.isFinite && (1...2_100).contains(diameter) &&
            hardness.isFinite && (0...1).contains(hardness) &&
            opacity.isFinite && (0.01...1).contains(opacity)
    }
}

nonisolated struct LayerVectorPathStyle: Codable, Equatable, Sendable {
    var mode: PenMode
    var red: Double
    var green: Double
    var blue: Double
    var lineWidth: Double
    var nodes: [VectorPathNode]
    var closed: Bool
    var fill: LayerVectorPathFill? = nil
    var brushStroke: LayerVectorPathBrushStroke? = nil

    var isValid: Bool {
        let enoughNodes = closed ? nodes.count >= 3 : nodes.count >= 2
        guard enoughNodes,
              (mode == .shape && closed) || (mode == .line && !closed),
              nodes.count <= 10_000,
              lineWidth.isFinite,
              (1...5_000).contains(lineWidth),
              red.isFinite, green.isFinite, blue.isFinite,
              (0...1).contains(red), (0...1).contains(green), (0...1).contains(blue),
              fill?.isValid != false, brushStroke?.isValid != false
        else { return false }
        return nodes.allSatisfy { node in
            node.isFinite &&
                (0...1).contains(node.anchor.x) && (0...1).contains(node.anchor.y) &&
                (0...1).contains(node.inHandle.x) && (0...1).contains(node.inHandle.y) &&
                (0...1).contains(node.outHandle.x) && (0...1).contains(node.outHandle.y)
        }
    }

    func nodes(in size: CGSize) -> [VectorPathNode] {
        nodes.map { node in
            VectorPathNode(
                anchor: CGPoint(x: node.anchor.x * size.width, y: node.anchor.y * size.height),
                inHandle: CGPoint(x: node.inHandle.x * size.width, y: node.inHandle.y * size.height),
                outHandle: CGPoint(x: node.outHandle.x * size.width, y: node.outHandle.y * size.height)
            )
        }
    }

    static func path(nodes: [VectorPathNode], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = nodes.first else { return path }
        path.move(to: first.anchor)
        for index in 1..<nodes.count {
            let previous = nodes[index - 1]
            let node = nodes[index]
            path.addCurve(to: node.anchor, control1: previous.outHandle, control2: node.inHandle)
        }
        if closed, let last = nodes.last {
            path.addCurve(to: first.anchor, control1: last.outHandle, control2: first.inHandle)
            path.closeSubpath()
        }
        return path
    }
}

nonisolated struct LayerVectorPath: Equatable, @unchecked Sendable {
    var style: LayerVectorPathStyle
    var image: CGImage

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.style == rhs.style && lhs.image === rhs.image
    }

    static func loaded(style: LayerVectorPathStyle, image: CGImage) -> LayerVectorPath? {
        guard style.isValid else { return nil }
        return LayerVectorPath(style: style, image: image)
    }
}

nonisolated struct PenDraft {
    var mode: PenMode
    var color: PaletteColor
    var lineWidth: Double
    var nodes: [VectorPathNode]
    var hoverPoint: CGPoint?
    var fill: LayerVectorPathFill? = nil
    var brushStroke: LayerVectorPathBrushStroke? = nil
}

nonisolated struct PenBendGesture: Sendable {
    let segmentIndex: Int
    let t: CGFloat
    var lastPoint: CGPoint
}

nonisolated struct PenEraseGesture: Sendable {
    var lastPoint: CGPoint
    var changedLayerIDs: Set<UUID> = []
}

extension ImageLayer {
    var liveVectorPath: LayerVectorPath? {
        guard let vectorPath,
              asset?.image === vectorPath.image,
              shape == nil,
              text == nil
        else { return nil }
        return vectorPath
    }
}

extension EditorSession {
    var canLoadPenPathSelection: Bool {
        canEditSelection && penSelectionPath() != nil
    }

    var canFillPenPath: Bool {
        canEditLayers && penDocumentPath(closeOpenPath: true, requiresArea: true) != nil
    }

    var canStrokePenPath: Bool {
        canEditLayers && penDocumentPath(closeOpenPath: false, requiresArea: false) != nil
    }

    func cyclePenAction() {
        cancelPen()
        let actions = PenAction.allCases
        let index = actions.firstIndex(of: penAction) ?? 0
        penAction = actions[(index + 1) % actions.count]
    }

    /// Converts the path being drawn, or the active vector path, to a selection without filling pixels.
    /// Open paths are joined from their last point back to their first to define the selected area.
    func loadPenPathSelection(mode: SelectionMode = .replace) {
        guard canEditSelection, let path = penSelectionPath() else { NSSound.beep(); return }
        beginEdit("Load Path Selection")
        defer { endEdit() }
        if penDraft != nil, !finishPen() { return }
        applySelection(path, mode: mode, name: "Load Path Selection")
        if let sourceLayerID = activeLayerID,
           let index = document?.layers.firstIndex(where: { $0.id == sourceLayerID }) {
            // Older projects stored a painted preview behind the vector nodes. Replace it with the transparent
            // path backing so loading a selection never leaves a fill or stroke over the marching ants.
            redrawVectorPath(at: index)
        }
    }

    /// Adds or updates the live fill on the editable path. Filling an open path joins its endpoints visually without
    /// closing the editable path, so its original geometry is still available for a brush stroke or selection.
    func fillPenPathWithForeground() {
        guard canFillPenPath else { NSSound.beep(); return }
        let hadDraft = penDraft != nil
        finishOpacityEdit()
        beginEdit("Fill Path")
        defer { endEdit() }
        if hadDraft, !finishPen() { return }
        guard var style = activeLayer?.liveVectorPath?.style else { return }
        style.red = Double(foregroundColor.red)
        style.green = Double(foregroundColor.green)
        style.blue = Double(foregroundColor.blue)
        style.fill = LayerVectorPathFill(red: style.red, green: style.green, blue: style.blue)
        replaceActivePenPath(with: style, preview: false)
    }

    /// Adds or updates a live brush stroke on the editable path. Its current brush color, size, hardness and opacity
    /// are retained so moving a node can redraw the same stroke without losing the path.
    func strokePenPathWithBrush() {
        guard canStrokePenPath else { NSSound.beep(); return }
        let hadDraft = penDraft != nil
        finishOpacityEdit()
        beginEdit("Stroke Path")
        defer { endEdit() }
        if hadDraft, !finishPen() { return }
        guard var style = activeLayer?.liveVectorPath?.style else { return }
        style.red = Double(foregroundColor.red)
        style.green = Double(foregroundColor.green)
        style.blue = Double(foregroundColor.blue)
        style.lineWidth = Double(brushSettings.diameter)
        style.brushStroke = LayerVectorPathBrushStroke(
            red: style.red,
            green: style.green,
            blue: style.blue,
            diameter: Double(brushSettings.diameter),
            hardness: Double(brushSettings.hardness),
            opacity: Double(brushSettings.opacity)
        )
        replaceActivePenPath(with: style, preview: false)
    }

    @discardableResult
    func beginPenAnchor(at point: CGPoint, closeDistance: CGFloat, constrain: Bool) -> Bool {
        guard tool == .pen, canEditLayers else { return false }
        if var draft = penDraft,
           draft.nodes.count >= 3,
           hypot(point.x - draft.nodes[0].anchor.x, point.y - draft.nodes[0].anchor.y) <= closeDistance {
            draft.mode = .shape
            penDraft = draft
            return finishPen()
        }

        var anchor = point
        if constrain, let previous = penDraft?.nodes.last?.anchor {
            anchor = constrainedPenPoint(anchor, from: previous)
        }
        if penDraft == nil {
            selectedPenNodeIndex = nil
            selectedPenHandle = nil
            penDraft = PenDraft(
                mode: .line,
                color: foregroundColor,
                lineWidth: 4,
                nodes: [],
                hoverPoint: nil
            )
        }
        penDraft?.nodes.append(VectorPathNode(anchor: anchor))
        penDraft?.hoverPoint = nil
        return false
    }

    func dragPenHandle(to point: CGPoint, constrain: Bool) {
        guard var draft = penDraft, var node = draft.nodes.last else { return }
        var outHandle = point
        if constrain {
            outHandle = constrainedPenPoint(outHandle, from: node.anchor)
        }
        node.outHandle = outHandle
        node.inHandle = CGPoint(
            x: node.anchor.x * 2 - outHandle.x,
            y: node.anchor.y * 2 - outHandle.y
        )
        draft.nodes[draft.nodes.count - 1] = node
        penDraft = draft
    }

    func movePenCursor(to point: CGPoint?) {
        penDraft?.hoverPoint = point
    }

    func removeLastPenAnchor() {
        guard var draft = penDraft else { return }
        if !draft.nodes.isEmpty { draft.nodes.removeLast() }
        penDraft = draft.nodes.isEmpty ? nil : draft
    }

    func cancelPen() {
        penDraft = nil
        selectedPenNodeIndex = nil
        selectedPenHandle = nil
    }

    @discardableResult
    func finishPen() -> Bool {
        guard let draft = penDraft, let document else { return false }
        let closed = draft.mode == .shape
        guard let committed = committedPenStyle(draft, closed: closed),
              let image = PenBacking.image,
              let thumbnail = try? PixelInvert.thumbnail(of: image)
        else {
            NSSound.beep()
            return false
        }

        let vectorPath = LayerVectorPath(style: committed.style, image: image)
        let name = nextVectorPathName()
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: thumbnail, name: name),
                               origin: committed.box.origin)
        layer.name = name
        layer.transform.size = committed.box.size
        layer.vectorPath = vectorPath
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        let index = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        finishOpacityEdit()
        beginEdit("Path")
        self.document?.layers.insert(layer, at: index)
        activeLayerID = layer.id
        endEdit()
        penDraft = nil
        selectedPenNodeIndex = nil
        selectedPenHandle = nil
        return true
    }

    func beginPenLineNodeGesture(at point: CGPoint, tolerance: CGFloat) -> Int? {
        guard tool == .pen, canEditLayers, penDraft == nil else { return nil }

        for (layer, vectorPath, documentNodes) in editablePenPaths() {
            if let hit = nearestPenHandle(to: point, in: documentNodes, tolerance: tolerance) {
                selectLayer(layer.id)
                guard activeLayerID == layer.id else { return nil }
                selectedPenNodeIndex = hit.nodeIndex
                selectedPenHandle = hit.handle
                penLineGestureHandle = hit.handle
                beginEdit("Move Path Handle")
                penLineGestureActive = true
                return hit.nodeIndex
            }

            if let nodeIndex = nearestPenNode(to: point, in: documentNodes, tolerance: tolerance) {
                selectLayer(layer.id)
                guard activeLayerID == layer.id else { return nil }
                selectedPenNodeIndex = nodeIndex
                selectedPenHandle = nil
                penLineGestureHandle = nil
                beginEdit("Move Path Point")
                penLineGestureActive = true
                return nodeIndex
            }

            if let hit = nearestPenSegment(to: point, in: documentNodes,
                                           closed: vectorPath.style.closed, tolerance: tolerance) {
                selectLayer(layer.id)
                guard activeLayerID == layer.id else { return nil }
                beginEdit("Add Path Point")
                penLineGestureActive = true
                penLineGestureHandle = nil
                var proposed = vectorPath.style
                proposed.nodes = splitPenSegment(nodes: proposed.nodes, segmentIndex: hit.segmentIndex,
                                                 t: hit.t, closed: proposed.closed)
                selectedPenNodeIndex = hit.segmentIndex + 1
                selectedPenHandle = nil
                replaceActivePenPath(with: proposed, preview: true)
                return selectedPenNodeIndex
            }
        }
        return nil
    }

    /// Converts a corner anchor to a smooth point. Its handles follow the chord between the neighboring anchors,
    /// with independent lengths on each side; later handle drags keep them collinear unless Option breaks them.
    @discardableResult
    func smoothPenNode(at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard tool == .pen, canEditLayers, penDraft == nil else { return false }
        for (layer, vectorPath, nodes) in editablePenPaths() {
            let transform = layer.transform.unitToDocument
            guard let index = nearestPenNode(to: point, in: nodes, tolerance: tolerance) else { continue }
            guard vectorPath.style.closed || (index > 0 && index < nodes.count - 1) else { return false }
            let previous = nodes[(index - 1 + nodes.count) % nodes.count].anchor
            let anchor = nodes[index].anchor
            let next = nodes[(index + 1) % nodes.count].anchor
            var dx = next.x - previous.x
            var dy = next.y - previous.y
            var length = hypot(dx, dy)
            if length <= 0 {
                dx = next.x - anchor.x
                dy = next.y - anchor.y
                length = hypot(dx, dy)
            }
            guard length > 0 else { return false }
            dx /= length
            dy /= length
            let incomingLength = hypot(anchor.x - previous.x, anchor.y - previous.y) / 3
            let outgoingLength = hypot(next.x - anchor.x, next.y - anchor.y) / 3
            let incoming = CGPoint(x: anchor.x - dx * incomingLength,
                                   y: anchor.y - dy * incomingLength)
            let outgoing = CGPoint(x: anchor.x + dx * outgoingLength,
                                   y: anchor.y + dy * outgoingLength)
            let inverse = transform.inverted()
            let unitIncoming = incoming.applying(inverse)
            let unitOutgoing = outgoing.applying(inverse)
            guard unitIncoming.x.isFinite, unitIncoming.y.isFinite,
                  unitOutgoing.x.isFinite, unitOutgoing.y.isFinite else { return false }

            selectLayer(layer.id)
            guard activeLayerID == layer.id else { return false }
            beginEdit("Smooth Path Point")
            var proposed = vectorPath.style
            proposed.nodes[index].inHandle = unitIncoming
            proposed.nodes[index].outHandle = unitOutgoing
            selectedPenNodeIndex = index
            selectedPenHandle = nil
            replaceActivePenPath(with: proposed, preview: false)
            endEdit()
            return true
        }
        return false
    }

    @discardableResult
    func beginPenBendGesture(at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard tool == .pen, penAction == .bend, canEditLayers, penDraft == nil else { return false }
        for (layer, vectorPath, nodes) in editablePenPaths() {
            guard let hit = nearestPenSegment(to: point, in: nodes,
                                              closed: vectorPath.style.closed, tolerance: tolerance) else { continue }
            selectLayer(layer.id)
            guard activeLayerID == layer.id else { return false }
            beginEdit("Bend Path")
            penLineGestureActive = true
            penLineGestureHandle = nil
            penBendGesture = PenBendGesture(segmentIndex: hit.segmentIndex,
                                            t: min(0.95, max(0.05, hit.t)), lastPoint: point)
            selectedPenNodeIndex = nil
            selectedPenHandle = nil
            return true
        }
        return false
    }

    func dragPenBend(to point: CGPoint) {
        guard var gesture = penBendGesture,
              let layer = activeLayer,
              let vectorPath = layer.liveVectorPath else { return }
        let segmentCount = vectorPath.style.closed ? vectorPath.style.nodes.count : vectorPath.style.nodes.count - 1
        guard gesture.segmentIndex >= 0, gesture.segmentIndex < segmentCount else { return }
        let nextIndex = (gesture.segmentIndex + 1) % vectorPath.style.nodes.count
        let factor = max(0.01, 3 * gesture.t * (1 - gesture.t))
        let shift = CGSize(width: (point.x - gesture.lastPoint.x) / factor,
                           height: (point.y - gesture.lastPoint.y) / factor)
        guard shift.width.isFinite, shift.height.isFinite else { return }
        let transform = layer.transform.unitToDocument
        let inverse = transform.inverted()
        var proposed = vectorPath.style
        let outgoing = proposed.nodes[gesture.segmentIndex].outHandle.applying(transform)
        let incoming = proposed.nodes[nextIndex].inHandle.applying(transform)
        proposed.nodes[gesture.segmentIndex].outHandle = CGPoint(
            x: outgoing.x + shift.width, y: outgoing.y + shift.height
        ).applying(inverse)
        proposed.nodes[nextIndex].inHandle = CGPoint(
            x: incoming.x + shift.width, y: incoming.y + shift.height
        ).applying(inverse)
        replaceActivePenPath(with: proposed, preview: true)
        gesture.lastPoint = point
        penBendGesture = gesture
    }

    @discardableResult
    func cutPenPath(at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard tool == .pen, penAction == .cut, canEditLayers, penDraft == nil, let document else { return false }
        for (layer, vectorPath, nodes) in editablePenPaths() {
            guard let hit = nearestPenSegment(to: point, in: nodes,
                                              closed: vectorPath.style.closed, tolerance: tolerance) else { continue }
            selectLayer(layer.id)
            guard activeLayerID == layer.id else { return false }
            var split = splitPenSegment(nodes: vectorPath.style.nodes, segmentIndex: hit.segmentIndex,
                                        t: hit.t, closed: vectorPath.style.closed)
            let cutIndex = hit.segmentIndex == vectorPath.style.nodes.count - 1 ? split.count - 1 : hit.segmentIndex + 1
            guard split.indices.contains(cutIndex) else { return false }

            if vectorPath.style.closed {
                let cut = split[cutIndex]
                split = Array(split[cutIndex...]) + Array(split[..<cutIndex]) + [cut]
                split[0].inHandle = split[0].anchor
                split[split.count - 1].outHandle = split[split.count - 1].anchor
                var proposed = vectorPath.style
                proposed.mode = .line
                proposed.closed = false
                proposed.nodes = split
                beginEdit("Cut Path")
                selectedPenNodeIndex = 0
                selectedPenHandle = nil
                replaceActivePenPath(with: proposed, preview: false)
                endEdit()
                return true
            }

            var first = vectorPath.style
            first.nodes = Array(split[...cutIndex])
            var second = vectorPath.style
            second.nodes = Array(split[cutIndex...])
            guard first.isValid, second.isValid,
                  let firstImage = vectorPathImage(style: first, size: layer.transform.size),
                  let secondImage = vectorPathImage(style: second, size: layer.transform.size),
                  let firstThumbnail = try? PixelInvert.thumbnail(of: firstImage),
                  let secondThumbnail = try? PixelInvert.thumbnail(of: secondImage),
                  let sourceIndex = document.layers.firstIndex(where: { $0.id == layer.id }) else { return false }
            let used = document.layers.indices.filter { $0 != sourceIndex }.reduce(0) {
                $0 + (document.layers[$1].asset.map { $0.image.width * $0.image.height } ?? 0)
            }
            guard used + firstImage.width * firstImage.height + secondImage.width * secondImage.height <=
                    DocumentLimits.documentPixelBudget else {
                brushError = ProjectError.tooLarge.localizedDescription
                return false
            }
            let secondName = nextVectorPathName()
            let firstAsset = ImportedImage(image: firstImage, thumbnail: firstThumbnail, name: layer.name)
            let secondAsset = ImportedImage(image: secondImage, thumbnail: secondThumbnail, name: secondName)
            let secondLayer = ImageLayer(
                id: UUID(), asset: secondAsset, name: secondName, isVisible: layer.isVisible,
                transform: layer.transform, parentID: layer.parentID, opacity: layer.opacity,
                blendMode: layer.blendMode,
                vectorPath: LayerVectorPath(style: second, image: secondImage), effects: layer.effects
            )
            beginEdit("Cut Path")
            self.document?.layers[sourceIndex].asset = firstAsset
            self.document?.layers[sourceIndex].vectorPath = LayerVectorPath(style: first, image: firstImage)
            self.document?.layers.insert(secondLayer, at: sourceIndex + 1)
            selectedPenNodeIndex = first.nodes.count - 1
            selectedPenHandle = nil
            endEdit()
            return true
        }
        return false
    }

    @discardableResult
    func beginPenErase(at point: CGPoint, diameter: CGFloat) -> Bool {
        guard tool == .pen, penAction == .erase, canEditLayers, penDraft == nil,
              diameter.isFinite, diameter > 0 else { return false }
        finishOpacityEdit()
        beginEdit("Erase Path")
        penEraseGesture = PenEraseGesture(lastPoint: point)
        erasePenPath(at: point, radius: diameter / 2)
        return true
    }

    func dragPenErase(to point: CGPoint, diameter: CGFloat) {
        guard var gesture = penEraseGesture, diameter.isFinite, diameter > 0 else { return }
        let dx = point.x - gesture.lastPoint.x
        let dy = point.y - gesture.lastPoint.y
        let distance = hypot(dx, dy)
        let spacing = max(1, diameter / 4)
        let steps = min(256, max(1, Int(ceil(distance / spacing))))
        for step in 1...steps {
            let amount = CGFloat(step) / CGFloat(steps)
            erasePenPath(at: CGPoint(x: gesture.lastPoint.x + dx * amount,
                                     y: gesture.lastPoint.y + dy * amount),
                         radius: diameter / 2)
        }
        gesture.lastPoint = point
        if let current = penEraseGesture { gesture.changedLayerIDs.formUnion(current.changedLayerIDs) }
        penEraseGesture = gesture
    }

    func endPenErase() {
        guard let gesture = penEraseGesture else { return }
        penEraseGesture = nil
        if let document {
            for id in gesture.changedLayerIDs {
                if let index = document.layers.firstIndex(where: { $0.id == id }) { redrawVectorPath(at: index) }
            }
        }
        endEdit()
    }

    func dragPenLineNode(to documentPoint: CGPoint, constrain: Bool = false, breakHandles: Bool = false) {
        guard penLineGestureActive,
              let index = selectedPenNodeIndex,
              let layer = activeLayer,
              let vectorPath = layer.liveVectorPath,
              vectorPath.style.nodes.indices.contains(index)
        else { return }
        let transform = layer.transform.unitToDocument
        let inverse = transform.inverted()
        let anchor = vectorPath.style.nodes[index].anchor.applying(transform)
        let target = constrain ? constrainedPenPoint(documentPoint, from: anchor) : documentPoint
        let unit = target.applying(inverse)
        guard unit.x.isFinite, unit.y.isFinite else { return }
        var proposed = vectorPath.style

        if let handle = penLineGestureHandle {
            let oppositeKeyPath: WritableKeyPath<VectorPathNode, CGPoint>
            switch handle {
            case .incoming:
                proposed.nodes[index].inHandle = unit
                oppositeKeyPath = \.outHandle
            case .outgoing:
                proposed.nodes[index].outHandle = unit
                oppositeKeyPath = \.inHandle
            }
            if !breakHandles {
                let opposite = proposed.nodes[index][keyPath: oppositeKeyPath].applying(transform)
                let oppositeLength = hypot(opposite.x - anchor.x, opposite.y - anchor.y)
                let dx = target.x - anchor.x
                let dy = target.y - anchor.y
                let length = hypot(dx, dy)
                if length > 0, oppositeLength > 0 {
                    let mirrored = CGPoint(
                        x: anchor.x - dx / length * oppositeLength,
                        y: anchor.y - dy / length * oppositeLength
                    ).applying(inverse)
                    if mirrored.x.isFinite, mirrored.y.isFinite {
                        proposed.nodes[index][keyPath: oppositeKeyPath] = mirrored
                    }
                }
            }
            replaceActivePenPath(with: proposed, preview: true)
            return
        }

        let delta = CGPoint(
            x: unit.x - proposed.nodes[index].anchor.x,
            y: unit.y - proposed.nodes[index].anchor.y
        )
        proposed.nodes[index].anchor.x += delta.x
        proposed.nodes[index].anchor.y += delta.y
        proposed.nodes[index].inHandle.x += delta.x
        proposed.nodes[index].inHandle.y += delta.y
        proposed.nodes[index].outHandle.x += delta.x
        proposed.nodes[index].outHandle.y += delta.y
        replaceActivePenPath(with: proposed, preview: true)
    }

    func endPenLineNodeGesture() {
        guard penLineGestureActive else { return }
        penLineGestureActive = false
        penLineGestureHandle = nil
        penBendGesture = nil
        if let id = activeLayerID,
           let index = document?.layers.firstIndex(where: { $0.id == id }) {
            redrawVectorPath(at: index)
        }
        endEdit()
    }

    @discardableResult
    func removeSelectedPenNode() -> Bool {
        guard canEditLayers,
              !penLineGestureActive,
              let nodeIndex = selectedPenNodeIndex,
              let vectorPath = activeLayer?.liveVectorPath,
              vectorPath.style.nodes.count > (vectorPath.style.closed ? 3 : 2),
              vectorPath.style.nodes.indices.contains(nodeIndex)
        else { return false }
        beginEdit("Delete Path Point")
        var proposed = vectorPath.style
        proposed.nodes.remove(at: nodeIndex)
        selectedPenNodeIndex = min(nodeIndex, proposed.nodes.count - 1)
        selectedPenHandle = nil
        replaceActivePenPath(with: proposed, preview: false)
        endEdit()
        return true
    }

    func redrawVectorPath(at index: Int) {
        guard let document,
              document.layers.indices.contains(index),
              let vectorPath = document.layers[index].liveVectorPath,
              let asset = document.layers[index].asset,
              let image = vectorPathImage(style: vectorPath.style, size: document.layers[index].transform.size),
              let thumbnail = try? PixelInvert.thumbnail(of: image)
        else { return }
        self.document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        self.document?.layers[index].vectorPath?.image = image
    }

    func vectorPathTransformPreview(for layer: ImageLayer, transform: LayerTransform) -> CGImage? {
        guard transformEdit != nil,
              let vectorPath = layer.liveVectorPath,
              vectorPath.style.fill != nil || vectorPath.style.brushStroke != nil,
              abs(transform.size.width - CGFloat(vectorPath.image.width)) >= 0.5 ||
                abs(transform.size.height - CGFloat(vectorPath.image.height)) >= 0.5
        else { return nil }
        let scale = min(1, 2_048 / max(max(transform.size.width, transform.size.height), 1))
        return vectorPathImage(
            style: vectorPath.style,
            size: CGSize(width: max(1, transform.size.width * scale),
                         height: max(1, transform.size.height * scale)),
            appearanceScale: scale
        )
    }

    private func replaceActivePenPath(with proposed: LayerVectorPathStyle, preview: Bool) {
        guard let id = activeLayerID,
              let document,
              let index = document.layers.firstIndex(where: { $0.id == id }),
              document.layers.indices.contains(index),
              document.layers[index].liveVectorPath != nil,
              let oldAsset = document.layers[index].asset
        else { return }
        let oldTransform = document.layers[index].transform
        let localNodes = proposed.nodes(in: oldTransform.size)
        let draft = PenDraft(
            mode: proposed.mode,
            color: PaletteColor(red: CGFloat(proposed.red), green: CGFloat(proposed.green), blue: CGFloat(proposed.blue)),
            lineWidth: proposed.lineWidth,
            nodes: localNodes,
            hoverPoint: nil,
            fill: proposed.fill,
            brushStroke: proposed.brushStroke
        )
        guard let committed = committedPenStyle(draft, closed: proposed.closed) else { return }
        let fullSize = committed.box.size
        let painted = committed.style.fill != nil || committed.style.brushStroke != nil
        let pixelCount = painted ? Int(ceil(fullSize.width)) * Int(ceil(fullSize.height)) : 1
        let used = document.layers.indices.filter { $0 != index }.reduce(0) {
            $0 + (document.layers[$1].asset.map { $0.image.width * $0.image.height } ?? 0)
        }
        guard used + pixelCount <= DocumentLimits.documentPixelBudget else {
            brushError = ProjectError.tooLarge.localizedDescription
            return
        }
        let scale = preview && painted ? min(1, 2_048 / max(max(fullSize.width, fullSize.height), 1)) : 1
        let imageSize = CGSize(width: max(1, fullSize.width * scale), height: max(1, fullSize.height * scale))
        guard let image = vectorPathImage(style: committed.style, size: imageSize, appearanceScale: scale) else {
            brushError = BrushStrokeError.pathTooComplex.localizedDescription
            return
        }

        let centerUnit = CGPoint(
            x: committed.box.midX / max(oldTransform.size.width, 1),
            y: committed.box.midY / max(oldTransform.size.height, 1)
        )
        let center = centerUnit.applying(oldTransform.unitToDocument)
        var transform = oldTransform
        transform.size = fullSize
        transform.origin = CGPoint(x: center.x - fullSize.width / 2, y: center.y - fullSize.height / 2)
        let thumbnail = preview ? oldAsset.thumbnail : ((try? PixelInvert.thumbnail(of: image)) ?? oldAsset.thumbnail)
        self.document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: oldAsset.name)
        self.document?.layers[index].vectorPath = LayerVectorPath(style: committed.style, image: image)
        self.document?.layers[index].transform = transform
        if let mask = document.layers[index].mask, mask.placement == nil {
            self.document?.layers[index].mask?.placement = oldTransform
        }
    }

    private func penDocumentGeometry(closeOpenPath: Bool) -> (nodes: [VectorPathNode], closed: Bool)? {
        if let draft = penDraft {
            guard draft.nodes.count >= (draft.mode == .shape ? 3 : 2),
                  draft.nodes.allSatisfy(\.isFinite)
            else { return nil }
            return (draft.nodes, closeOpenPath || draft.mode == .shape)
        }
        guard let layer = activeLayer, let vectorPath = layer.liveVectorPath else { return nil }
        let nodes = vectorPath.style.nodes(in: layer.transform.size).map { node in
            VectorPathNode(
                anchor: penDocumentPoint(node.anchor, transform: layer.transform),
                inHandle: penDocumentPoint(node.inHandle, transform: layer.transform),
                outHandle: penDocumentPoint(node.outHandle, transform: layer.transform)
            )
        }
        return (nodes, closeOpenPath || vectorPath.style.closed)
    }

    private func penDocumentPath(closeOpenPath: Bool, requiresArea: Bool) -> CGPath? {
        guard let geometry = penDocumentGeometry(closeOpenPath: closeOpenPath) else { return nil }
        let path = LayerVectorPathStyle.path(nodes: geometry.nodes, closed: geometry.closed)
        let bounds = path.boundingBoxOfPath
        if bounds.isNull || (requiresArea ? bounds.width <= 0 || bounds.height <= 0 : bounds.width <= 0 && bounds.height <= 0) {
            return nil
        }
        return path
    }

    private func penSelectionPath() -> CGPath? {
        penDocumentPath(closeOpenPath: true, requiresArea: true)
    }

    private func committedPenStyle(_ draft: PenDraft, closed: Bool) -> (style: LayerVectorPathStyle, box: CGRect)? {
        guard draft.nodes.count >= (closed ? 3 : 2),
              draft.nodes.allSatisfy(\.isFinite),
              draft.lineWidth.isFinite
        else { return nil }
        let points = draft.nodes.flatMap { [$0.anchor, $0.inHandle, $0.outHandle] }
        guard let first = points.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        let padding = max(1, CGFloat(draft.brushStroke?.diameter ?? 0) / 2 + (draft.brushStroke == nil ? 0 : 2))
        var box = CGRect(x: minX - padding, y: minY - padding,
                         width: max(maxX - minX + padding * 2, 1),
                         height: max(maxY - minY + padding * 2, 1)).integral
        box.size.width = max(box.size.width, 1)
        box.size.height = max(box.size.height, 1)
        guard box.width <= DocumentLimits.maxSideExtent,
              box.height <= DocumentLimits.maxSideExtent,
              (draft.fill == nil && draft.brushStroke == nil || box.width * box.height <= DocumentLimits.maxSurfaceExtent)
        else { return nil }
        let normalized = draft.nodes.map { node in
            VectorPathNode(
                anchor: CGPoint(x: (node.anchor.x - box.minX) / box.width, y: (node.anchor.y - box.minY) / box.height),
                inHandle: CGPoint(x: (node.inHandle.x - box.minX) / box.width, y: (node.inHandle.y - box.minY) / box.height),
                outHandle: CGPoint(x: (node.outHandle.x - box.minX) / box.width, y: (node.outHandle.y - box.minY) / box.height)
            )
        }
        let style = LayerVectorPathStyle(
            mode: draft.mode,
            red: Double(draft.color.red),
            green: Double(draft.color.green),
            blue: Double(draft.color.blue),
            lineWidth: min(max(draft.lineWidth, 1), 5_000),
            nodes: normalized,
            closed: closed,
            fill: draft.fill,
            brushStroke: draft.brushStroke
        )
        guard style.isValid else { return nil }
        return (style, box)
    }

    private func nextVectorPathName() -> String {
        nextPenResultName("Path")
    }

    private func erasePenPath(at center: CGPoint, radius: CGFloat) {
        guard var gesture = penEraseGesture, radius.isFinite, radius > 0 else { return }
        for (layer, vectorPath, _) in editablePenPaths() {
            guard let fragments = penPathFragmentsOutsideCircle(
                nodes: vectorPath.style.nodes,
                closed: vectorPath.style.closed,
                transform: layer.transform.unitToDocument,
                center: center,
                radius: radius
            ) else { continue }
            gesture.changedLayerIDs.formUnion(replacePenLayer(layer, with: fragments))
        }
        penEraseGesture = gesture
    }

    private func replacePenLayer(_ source: ImageLayer, with fragments: [[VectorPathNode]]) -> Set<UUID> {
        guard let document, let sourceIndex = document.layers.firstIndex(where: { $0.id == source.id }),
              let sourceStyle = source.liveVectorPath?.style else { return [] }
        selectedPenNodeIndex = nil
        selectedPenHandle = nil

        guard !fragments.isEmpty else {
            self.document?.layers.remove(at: sourceIndex)
            if activeLayerID == source.id {
                let layers = self.document?.layers ?? []
                activeLayerID = layers.isEmpty ? nil : layers[min(sourceIndex, layers.count - 1)].id
            }
            return []
        }

        var names = Set(document.layers.map(\.name))
        var number = 1
        func nextName() -> String {
            while names.contains("Path \(number)") { number += 1 }
            let name = "Path \(number)"
            names.insert(name)
            number += 1
            return name
        }

        var replacements: [ImageLayer] = []
        var fullPixelCount = 0
        for (index, nodes) in fragments.enumerated() {
            var style = sourceStyle
            style.mode = .line
            style.closed = false
            style.nodes = nodes
            // A cut path no longer encloses an area. Keeping its old fill would silently join the new endpoints
            // and paint straight across the erased gap, so only an explicit path stroke survives the eraser.
            style.fill = nil
            let id = index == 0 ? source.id : UUID()
            let name = index == 0 ? source.name : nextName()
            guard let built = erasedPenLayer(style: style, source: source, id: id, name: name) else { return [] }
            replacements.append(built.layer)
            fullPixelCount += built.fullPixelCount
        }

        let used = document.layers.indices.filter { $0 != sourceIndex }.reduce(0) {
            $0 + (document.layers[$1].asset.map { $0.image.width * $0.image.height } ?? 0)
        }
        guard used + fullPixelCount <= DocumentLimits.documentPixelBudget else {
            brushError = ProjectError.tooLarge.localizedDescription
            return []
        }
        self.document?.layers.replaceSubrange(sourceIndex...sourceIndex, with: replacements)
        if activeLayerID == source.id { activeLayerID = replacements[0].id }
        return Set(replacements.map(\.id))
    }

    private func erasedPenLayer(
        style: LayerVectorPathStyle,
        source: ImageLayer,
        id: UUID,
        name: String
    ) -> (layer: ImageLayer, fullPixelCount: Int)? {
        guard let oldAsset = source.asset else { return nil }
        let oldTransform = source.transform
        let localNodes = style.nodes(in: oldTransform.size)
        let draft = PenDraft(
            mode: .line,
            color: PaletteColor(red: CGFloat(style.red), green: CGFloat(style.green), blue: CGFloat(style.blue)),
            lineWidth: style.lineWidth,
            nodes: localNodes,
            hoverPoint: nil,
            brushStroke: style.brushStroke
        )
        guard let committed = committedPenStyle(draft, closed: false) else { return nil }
        let fullSize = committed.box.size
        let painted = committed.style.brushStroke != nil
        let fullPixelCount = painted ? Int(ceil(fullSize.width)) * Int(ceil(fullSize.height)) : 1
        let scale = painted ? min(1, 1_024 / max(max(fullSize.width, fullSize.height), 1)) : 1
        let imageSize = CGSize(width: max(1, fullSize.width * scale), height: max(1, fullSize.height * scale))
        guard let image = vectorPathImage(style: committed.style, size: imageSize, appearanceScale: scale) else {
            brushError = BrushStrokeError.pathTooComplex.localizedDescription
            return nil
        }

        let centerUnit = CGPoint(x: committed.box.midX / max(oldTransform.size.width, 1),
                                 y: committed.box.midY / max(oldTransform.size.height, 1))
        let center = centerUnit.applying(oldTransform.unitToDocument)
        var transform = oldTransform
        transform.size = fullSize
        transform.origin = CGPoint(x: center.x - fullSize.width / 2, y: center.y - fullSize.height / 2)
        let asset = ImportedImage(image: image, thumbnail: oldAsset.thumbnail, name: name)
        let layer = ImageLayer(
            id: id, asset: asset, name: name, isVisible: source.isVisible, transform: transform,
            parentID: source.parentID, opacity: source.opacity, blendMode: source.blendMode,
            mask: source.mask, maskSourceID: source.maskSourceID,
            vectorPath: LayerVectorPath(style: committed.style, image: image), effects: source.effects
        )
        return (layer, fullPixelCount)
    }

    private func vectorPathImage(
        style: LayerVectorPathStyle,
        size: CGSize,
        appearanceScale: CGFloat = 1
    ) -> CGImage? {
        guard style.isValid else { return nil }
        guard style.fill != nil || style.brushStroke != nil else { return PenBacking.image }
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= DocumentLimits.maxSideExtent,
              size.height <= DocumentLimits.maxSideExtent,
              size.width * size.height <= DocumentLimits.maxSurfaceExtent
        else { return nil }

        let width = max(1, Int(ceil(size.width)))
        let height = max(1, Int(ceil(size.height)))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        let drawSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        let nodes = style.nodes(in: drawSize)

        if let fill = style.fill {
            context.setFillColor(CGColor(srgbRed: CGFloat(fill.red), green: CGFloat(fill.green),
                                         blue: CGFloat(fill.blue), alpha: 1))
            context.addPath(LayerVectorPathStyle.path(nodes: nodes, closed: true))
            context.fillPath(using: .winding)
        }

        if let painted = style.brushStroke {
            var settings = BrushSettings()
            settings.diameter = max(1, CGFloat(painted.diameter) * appearanceScale)
            settings.hardness = CGFloat(painted.hardness)
            settings.opacity = CGFloat(painted.opacity)
            settings.red = CGFloat(painted.red)
            settings.green = CGFloat(painted.green)
            settings.blue = CGFloat(painted.blue)
            guard let points = flattenedPenPoints(
                nodes: nodes,
                closed: style.closed,
                flatness: max(0.2, min(0.75, settings.diameter / 32))
            ), points.count >= 2 else { return nil }
            do {
                let blank = ImageLayer(name: "Path Stroke", blankSize: drawSize)
                let stroke = try BrushStroke(layer: blank, mask: false, settings: settings,
                                             canvas: drawSize, useGPU: false)
                stroke.pixelLimit = width * height
                try stroke.appendPolyline(points)
                for patch in stroke.patches {
                    context.saveGState()
                    context.setBlendMode(.normal)
                    context.translateBy(x: patch.rect.minX, y: patch.rect.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(patch.image, in: CGRect(origin: .zero, size: patch.rect.size))
                    context.restoreGState()
                }
            } catch { return nil }
        }
        return context.makeImage()
    }

    private func nextPenResultName(_ base: String) -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private func editablePenPaths() -> [(ImageLayer, LayerVectorPath, [VectorPathNode])] {
        guard let document else { return [] }
        let visible = document.effectiveVisibleIDs
        return document.layers.reversed().compactMap { layer in
            guard (visible.contains(layer.id) || layer.id == activeLayerID),
                  let vectorPath = layer.liveVectorPath else { return nil }
            let transform = layer.transform.unitToDocument
            let nodes = vectorPath.style.nodes.map { node in
                VectorPathNode(anchor: node.anchor.applying(transform),
                               inHandle: node.inHandle.applying(transform),
                               outHandle: node.outHandle.applying(transform))
            }
            return (layer, vectorPath, nodes)
        }
    }
}

private nonisolated func penDocumentPoint(_ local: CGPoint, transform: LayerTransform) -> CGPoint {
    CGPoint(x: local.x / max(transform.size.width, 1),
            y: local.y / max(transform.size.height, 1)).applying(transform.unitToDocument)
}

private nonisolated func constrainedPenPoint(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
    let dx = point.x - origin.x
    let dy = point.y - origin.y
    let distance = hypot(dx, dy)
    guard distance > 0 else { return point }
    let angle = atan2(dy, dx)
    let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
    return CGPoint(x: origin.x + cos(snapped) * distance, y: origin.y + sin(snapped) * distance)
}

private nonisolated func nearestPenNode(
    to point: CGPoint,
    in nodes: [VectorPathNode],
    tolerance: CGFloat
) -> Int? {
    let limit = tolerance * tolerance
    return nodes.indices.min { squaredDistance(nodes[$0].anchor, point) < squaredDistance(nodes[$1].anchor, point) }
        .flatMap { squaredDistance(nodes[$0].anchor, point) <= limit ? $0 : nil }
}

private nonisolated func nearestPenHandle(
    to point: CGPoint,
    in nodes: [VectorPathNode],
    tolerance: CGFloat
) -> (nodeIndex: Int, handle: PenHandle)? {
    var best: (nodeIndex: Int, handle: PenHandle, distance: CGFloat)?
    for (index, node) in nodes.enumerated() {
        for (handle, position) in [(PenHandle.incoming, node.inHandle), (.outgoing, node.outHandle)]
        where position != node.anchor {
            let distance = squaredDistance(position, point)
            if distance <= tolerance * tolerance, best == nil || distance < best!.distance {
                best = (index, handle, distance)
            }
        }
    }
    return best.map { ($0.nodeIndex, $0.handle) }
}

private nonisolated func nearestPenSegment(
    to point: CGPoint,
    in nodes: [VectorPathNode],
    closed: Bool,
    tolerance: CGFloat
) -> (segmentIndex: Int, t: CGFloat)? {
    guard nodes.count >= 2 else { return nil }
    var best: (segmentIndex: Int, t: CGFloat, distance: CGFloat)?
    let segmentCount = closed ? nodes.count : nodes.count - 1
    for index in 0..<segmentCount {
        let first = nodes[index]
        let second = nodes[(index + 1) % nodes.count]
        let minX = min(min(first.anchor.x, first.outHandle.x), min(second.inHandle.x, second.anchor.x)) - tolerance
        let maxX = max(max(first.anchor.x, first.outHandle.x), max(second.inHandle.x, second.anchor.x)) + tolerance
        let minY = min(min(first.anchor.y, first.outHandle.y), min(second.inHandle.y, second.anchor.y)) - tolerance
        let maxY = max(max(first.anchor.y, first.outHandle.y), max(second.inHandle.y, second.anchor.y)) + tolerance
        guard point.x >= minX, point.x <= maxX, point.y >= minY, point.y <= maxY else { continue }
        let controlLength = hypot(first.outHandle.x - first.anchor.x, first.outHandle.y - first.anchor.y)
            + hypot(second.inHandle.x - first.outHandle.x, second.inHandle.y - first.outHandle.y)
            + hypot(second.anchor.x - second.inHandle.x, second.anchor.y - second.inHandle.y)
        let steps = min(64, max(4, Int(ceil(controlLength / max(tolerance, 0.25)))))
        var previous = first.anchor
        for step in 1...steps {
            let endT = CGFloat(step) / CGFloat(steps)
            let current = cubicPoint(first.anchor, first.outHandle, second.inHandle, second.anchor, t: endT)
            let vx = current.x - previous.x
            let vy = current.y - previous.y
            let lengthSquared = vx * vx + vy * vy
            let amount: CGFloat
            if lengthSquared > 0 {
                amount = min(max(((point.x - previous.x) * vx + (point.y - previous.y) * vy) / lengthSquared, 0), 1)
            } else {
                amount = 0
            }
            let projected = CGPoint(x: previous.x + vx * amount, y: previous.y + vy * amount)
            let distance = squaredDistance(projected, point)
            let t = (CGFloat(step - 1) + amount) / CGFloat(steps)
            if distance <= tolerance * tolerance, best == nil || distance < best!.distance {
                best = (index, t, distance)
            }
            previous = current
        }
    }
    return best.map { ($0.segmentIndex, $0.t) }
}

private nonisolated func splitPenSegment(
    nodes: [VectorPathNode],
    segmentIndex: Int,
    t: CGFloat,
    closed: Bool
) -> [VectorPathNode] {
    let segmentCount = closed ? nodes.count : max(0, nodes.count - 1)
    guard nodes.indices.contains(segmentIndex), segmentIndex < segmentCount else { return nodes }
    let nextIndex = (segmentIndex + 1) % nodes.count
    var result = nodes
    let first = nodes[segmentIndex]
    let second = nodes[nextIndex]
    let a = lerp(first.anchor, first.outHandle, t)
    let b = lerp(first.outHandle, second.inHandle, t)
    let c = lerp(second.inHandle, second.anchor, t)
    let d = lerp(a, b, t)
    let e = lerp(b, c, t)
    let middle = lerp(d, e, t)
    result[segmentIndex].outHandle = a
    result[nextIndex].inHandle = c
    let node = VectorPathNode(anchor: middle, inHandle: d, outHandle: e)
    if nextIndex == 0 { result.append(node) }
    else { result.insert(node, at: nextIndex) }
    return result
}

private nonisolated struct PenCubic {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint

    func applying(_ transform: CGAffineTransform) -> PenCubic {
        PenCubic(start: start.applying(transform), control1: control1.applying(transform),
                 control2: control2.applying(transform), end: end.applying(transform))
    }
}

/// Removes the portions of a path covered by a circular vector eraser. Nil means the circle missed the path;
/// an empty array means it erased the path completely. Retained cubic pieces stay cubic rather than becoming
/// a dense polyline, so repeated erasing does not steadily degrade the original curve.
private nonisolated func penPathFragmentsOutsideCircle(
    nodes: [VectorPathNode],
    closed: Bool,
    transform: CGAffineTransform,
    center: CGPoint,
    radius: CGFloat
) -> [[VectorPathNode]]? {
    guard nodes.count >= 2, radius.isFinite, radius > 0 else { return nil }
    let radiusSquared = radius * radius
    var pieces: [(curve: PenCubic, outside: Bool)] = []
    var erased = false
    let segmentCount = closed ? nodes.count : nodes.count - 1

    for index in 0..<segmentCount {
        let first = nodes[index]
        let second = nodes[(index + 1) % nodes.count]
        let curve = PenCubic(start: first.anchor, control1: first.outHandle,
                             control2: second.inHandle, end: second.anchor)
        let documentCurve = curve.applying(transform)
        let xs = [documentCurve.start.x, documentCurve.control1.x, documentCurve.control2.x, documentCurve.end.x]
        let ys = [documentCurve.start.y, documentCurve.control1.y, documentCurve.control2.y, documentCurve.end.y]
        if center.x + radius < xs.min()! || center.x - radius > xs.max()! ||
            center.y + radius < ys.min()! || center.y - radius > ys.max()! {
            pieces.append((curve, true))
            continue
        }

        let samples = penCubicSamples(documentCurve, maximumStep: max(0.5, radius / 2))
        var crossings: [CGFloat] = []
        for pair in zip(samples, samples.dropFirst()) {
            let firstInside = squaredDistance(pair.0.point, center) <= radiusSquared
            let secondInside = squaredDistance(pair.1.point, center) <= radiusSquared
            guard firstInside != secondInside else { continue }
            var low = pair.0.t
            var high = pair.1.t
            let lowInside = firstInside
            for _ in 0..<14 {
                let middle = (low + high) / 2
                let point = cubicPoint(documentCurve.start, documentCurve.control1,
                                       documentCurve.control2, documentCurve.end, t: middle)
                if (squaredDistance(point, center) <= radiusSquared) == lowInside { low = middle }
                else { high = middle }
            }
            crossings.append((low + high) / 2)
        }

        let boundaries = [CGFloat.zero] + crossings + [CGFloat(1)]
        for boundaryIndex in 0..<(boundaries.count - 1) {
            let start = boundaries[boundaryIndex]
            let end = boundaries[boundaryIndex + 1]
            guard end - start > 0.000_001 else { continue }
            let middle = (start + end) / 2
            let point = cubicPoint(documentCurve.start, documentCurve.control1,
                                   documentCurve.control2, documentCurve.end, t: middle)
            let outside = squaredDistance(point, center) > radiusSquared
            erased = erased || !outside
            pieces.append((penCubicSubcurve(curve, from: start, to: end), outside))
        }
    }
    guard erased else { return nil }

    // A closed path has no natural beginning. Start just after an erased piece so a retained run that crosses
    // the old first anchor is emitted as one path instead of two artificial fragments.
    if closed, let gap = pieces.firstIndex(where: { !$0.outside }) {
        let next = gap + 1
        pieces = (next < pieces.count ? Array(pieces[next...]) : []) + Array(pieces[...gap])
    }

    var fragments: [[VectorPathNode]] = []
    var current: [VectorPathNode] = []
    func finishFragment() {
        if current.count >= 2,
           current.dropFirst().contains(where: { squaredDistance($0.anchor, current[0].anchor) > 0.000_000_000_001 }) {
            fragments.append(current)
        }
        current.removeAll(keepingCapacity: true)
    }
    for piece in pieces {
        guard piece.outside else { finishFragment(); continue }
        if current.isEmpty {
            current.append(VectorPathNode(anchor: piece.curve.start))
        } else if squaredDistance(current[current.count - 1].anchor, piece.curve.start) > 0.000_000_000_001 {
            finishFragment()
            current.append(VectorPathNode(anchor: piece.curve.start))
        }
        current[current.count - 1].outHandle = piece.curve.control1
        current.append(VectorPathNode(anchor: piece.curve.end, inHandle: piece.curve.control2))
    }
    finishFragment()
    return fragments
}

private nonisolated func penCubicSamples(
    _ curve: PenCubic,
    maximumStep: CGFloat
) -> [(t: CGFloat, point: CGPoint)] {
    var samples: [(CGFloat, CGPoint)] = [(0, curve.start)]
    func append(_ part: PenCubic, from start: CGFloat, to end: CGFloat, depth: Int) {
        let length = hypot(part.control1.x - part.start.x, part.control1.y - part.start.y)
            + hypot(part.control2.x - part.control1.x, part.control2.y - part.control1.y)
            + hypot(part.end.x - part.control2.x, part.end.y - part.control2.y)
        if length <= maximumStep || depth >= 12 {
            samples.append((end, part.end))
            return
        }
        let split = splitPenCubic(part, at: 0.5)
        let middle = (start + end) / 2
        append(split.left, from: start, to: middle, depth: depth + 1)
        append(split.right, from: middle, to: end, depth: depth + 1)
    }
    append(curve, from: 0, to: 1, depth: 0)
    return samples
}

private nonisolated func penCubicSubcurve(_ curve: PenCubic, from start: CGFloat, to end: CGFloat) -> PenCubic {
    let left = end >= 1 ? curve : splitPenCubic(curve, at: end).left
    guard start > 0 else { return left }
    return splitPenCubic(left, at: min(1, start / end)).right
}

private nonisolated func splitPenCubic(_ curve: PenCubic, at amount: CGFloat) -> (left: PenCubic, right: PenCubic) {
    let a = lerp(curve.start, curve.control1, amount)
    let b = lerp(curve.control1, curve.control2, amount)
    let c = lerp(curve.control2, curve.end, amount)
    let d = lerp(a, b, amount)
    let e = lerp(b, c, amount)
    let middle = lerp(d, e, amount)
    return (
        PenCubic(start: curve.start, control1: a, control2: d, end: middle),
        PenCubic(start: middle, control1: e, control2: c, end: curve.end)
    )
}

private nonisolated func cubicPoint(
    _ p0: CGPoint,
    _ p1: CGPoint,
    _ p2: CGPoint,
    _ p3: CGPoint,
    t: CGFloat
) -> CGPoint {
    let oneMinusT = 1 - t
    let a = oneMinusT * oneMinusT * oneMinusT
    let b = 3 * oneMinusT * oneMinusT * t
    let c = 3 * oneMinusT * t * t
    let d = t * t * t
    return CGPoint(
        x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
        y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
    )
}

/// Flattens the Pen's cubic segments for the brush engine. A path that exceeds the cap is rejected rather than
/// truncated: joining distant points after truncation could paint an unrelated slash across the document.
private nonisolated func flattenedPenPoints(
    nodes: [VectorPathNode], closed: Bool, flatness: CGFloat
) -> [CGPoint]? {
    guard nodes.count >= 2, flatness.isFinite, flatness > 0 else { return nil }
    let pointLimit = 250_000
    var result = [nodes[0].anchor]
    var exceededLimit = false
    let segmentCount = closed ? nodes.count : nodes.count - 1

    func distanceToChord(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squared = dx * dx + dy * dy
        guard squared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let amount = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / squared, 0), 1)
        return hypot(point.x - start.x - amount * dx, point.y - start.y - amount * dy)
    }

    func appendCurve(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, depth: Int) {
        guard !exceededLimit else { return }
        let error = max(distanceToChord(p1, from: p0, to: p3),
                        distanceToChord(p2, from: p0, to: p3))
        if error <= flatness || depth >= 12 {
            guard result.last == p3 || result.count < pointLimit else { exceededLimit = true; return }
            if result.last != p3 { result.append(p3) }
            return
        }
        let p01 = lerp(p0, p1, 0.5)
        let p12 = lerp(p1, p2, 0.5)
        let p23 = lerp(p2, p3, 0.5)
        let p012 = lerp(p01, p12, 0.5)
        let p123 = lerp(p12, p23, 0.5)
        let midpoint = lerp(p012, p123, 0.5)
        appendCurve(p0, p01, p012, midpoint, depth: depth + 1)
        appendCurve(midpoint, p123, p23, p3, depth: depth + 1)
    }

    for index in 0..<segmentCount {
        let first = nodes[index]
        let second = nodes[(index + 1) % nodes.count]
        appendCurve(first.anchor, first.outHandle, second.inHandle, second.anchor, depth: 0)
        if exceededLimit { return nil }
    }
    return result
}

private nonisolated func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = lhs.x - rhs.x, dy = lhs.y - rhs.y
    return dx * dx + dy * dy
}

nonisolated enum PenBacking {
    static let image: CGImage? = {
        guard let context = try? BrushRaster.context(width: 1, height: 1, mask: false) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }()
}

private nonisolated func lerp(_ lhs: CGPoint, _ rhs: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x + (rhs.x - lhs.x) * t, y: lhs.y + (rhs.y - lhs.y) * t)
}
