import AppKit
import CoreGraphics
import Foundation

nonisolated enum PenMode: String, CaseIterable, Codable, Sendable {
    case shape = "Shape"
    case line = "Line"
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

nonisolated struct LayerVectorPathStyle: Codable, Equatable, Sendable {
    var mode: PenMode
    var red: Double
    var green: Double
    var blue: Double
    var lineWidth: Double
    var nodes: [VectorPathNode]
    var closed: Bool

    var isValid: Bool {
        let enoughNodes = closed ? nodes.count >= 3 : nodes.count >= 2
        guard enoughNodes,
              (mode == .shape && closed) || (mode == .line && !closed),
              nodes.count <= 10_000,
              lineWidth.isFinite,
              (1...5_000).contains(lineWidth),
              red.isFinite, green.isFinite, blue.isFinite,
              (0...1).contains(red), (0...1).contains(green), (0...1).contains(blue)
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
    var currentPenLineWidth: Double {
        penDraft?.lineWidth ?? activeLayer?.liveVectorPath?.style.lineWidth ?? penLineWidth
    }

    var canLoadPenPathSelection: Bool {
        canEditSelection && penSelectionPath() != nil
    }

    var canEditActivePenLine: Bool {
        guard penDraft == nil, let vectorPath = activeLayer?.liveVectorPath else { return false }
        return vectorPath.style.mode == .line && !vectorPath.style.closed && vectorPath.style.nodes.count >= 2
    }

    func cyclePenMode() {
        cancelPen()
        penMode = penMode == .shape ? .line : .shape
    }

    /// Loads the path being drawn, or the active vector path, as a filled selection.
    /// Open paths are joined from their last point back to their first, as when they are filled.
    func loadPenPathSelection(mode: SelectionMode = .replace) {
        guard canEditSelection, let path = penSelectionPath() else { NSSound.beep(); return }
        applySelection(path, mode: mode, name: "Load Path Selection")
    }

    @discardableResult
    func beginPenAnchor(at point: CGPoint, closeDistance: CGFloat, constrain: Bool) -> Bool {
        guard tool == .pen, canEditLayers else { return false }
        if let draft = penDraft,
           draft.mode == .shape,
           draft.nodes.count >= 3,
           hypot(point.x - draft.nodes[0].anchor.x, point.y - draft.nodes[0].anchor.y) <= closeDistance {
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
                mode: penMode,
                color: foregroundColor,
                lineWidth: penLineWidth,
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
        guard let draft = penDraft else { return false }
        let closed = draft.mode == .shape
        guard let committed = committedPenStyle(draft, closed: closed),
              let image = vectorPathImage(style: committed.style, size: committed.box.size)
        else {
            NSSound.beep()
            return false
        }

        let vectorPath = LayerVectorPath(style: committed.style, image: image)
        addPixelLayer(image, at: committed.box.origin, name: nextVectorPathName(mode: draft.mode),
                      editName: draft.mode.rawValue, dropsSelection: false, vectorPath: vectorPath)
        penDraft = nil
        selectedPenNodeIndex = nil
        selectedPenHandle = nil
        return true
    }

    func beginPenLineNodeGesture(at point: CGPoint, tolerance: CGFloat) -> Int? {
        guard tool == .pen, canEditLayers, penDraft == nil else { return nil }

        guard let document else { return nil }
        let visible = document.effectiveVisibleIDs
        for layerIndex in document.layers.indices.reversed() {
            let layer = document.layers[layerIndex]
            guard visible.contains(layer.id),
                  let vectorPath = layer.liveVectorPath,
                  vectorPath.style.mode == .line,
                  !vectorPath.style.closed
            else { continue }
            let localNodes = vectorPath.style.nodes(in: layer.transform.size)
            let documentNodes = localNodes.map { node in
                VectorPathNode(
                    anchor: penDocumentPoint(node.anchor, transform: layer.transform),
                    inHandle: penDocumentPoint(node.inHandle, transform: layer.transform),
                    outHandle: penDocumentPoint(node.outHandle, transform: layer.transform)
                )
            }

            if let hit = nearestPenHandle(to: point, in: documentNodes, tolerance: tolerance) {
                selectLayer(layer.id)
                guard activeLayerID == layer.id else { return nil }
                penMode = .line
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
                penMode = .line
                selectedPenNodeIndex = nodeIndex
                selectedPenHandle = nil
                penLineGestureHandle = nil
                beginEdit("Move Path Point")
                penLineGestureActive = true
                return nodeIndex
            }

            if let hit = nearestPenSegment(to: point, in: documentNodes, tolerance: tolerance) {
                selectLayer(layer.id)
                guard activeLayerID == layer.id else { return nil }
                penMode = .line
                beginEdit("Add Path Point")
                penLineGestureActive = true
                penLineGestureHandle = nil
                var proposed = vectorPath.style
                proposed.nodes = splitPenSegment(nodes: proposed.nodes, segmentIndex: hit.segmentIndex, t: hit.t)
                selectedPenNodeIndex = hit.segmentIndex + 1
                selectedPenHandle = nil
                replaceActivePenLine(with: proposed, preview: true)
                return selectedPenNodeIndex
            }
        }
        return nil
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
            replaceActivePenLine(with: proposed, preview: true)
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
        replaceActivePenLine(with: proposed, preview: true)
    }

    func endPenLineNodeGesture() {
        guard penLineGestureActive else { return }
        penLineGestureActive = false
        penLineGestureHandle = nil
        if let id = activeLayerID, let index = document?.layers.firstIndex(where: { $0.id == id }) { redrawVectorPath(at: index) }
        endEdit()
    }

    @discardableResult
    func removeSelectedPenNode() -> Bool {
        guard canEditLayers,
              !penLineGestureActive,
              let nodeIndex = selectedPenNodeIndex,
              let vectorPath = activeLayer?.liveVectorPath,
              vectorPath.style.nodes.count > 2,
              vectorPath.style.nodes.indices.contains(nodeIndex)
        else { return false }
        beginEdit("Delete Path Point")
        var proposed = vectorPath.style
        proposed.nodes.remove(at: nodeIndex)
        selectedPenNodeIndex = min(nodeIndex, proposed.nodes.count - 1)
        selectedPenHandle = nil
        replaceActivePenLine(with: proposed, preview: false)
        endEdit()
        return true
    }

    func setPenLineWidth(_ value: Double, preview: Bool = false) {
        let value = value.isFinite ? min(max(value, 1), 5_000) : 4
        penLineWidth = value
        if penDraft?.mode == .line { penDraft?.lineWidth = value }
        guard canEditActivePenLine, let vectorPath = activeLayer?.liveVectorPath else { return }
        let ownsEdit = !penWidthEditActive
        if ownsEdit { beginEdit("Change Path Width") }
        var proposed = vectorPath.style
        proposed.lineWidth = value
        replaceActivePenLine(with: proposed, preview: preview || penWidthEditActive)
        if ownsEdit {
            if let id = activeLayerID, let index = document?.layers.firstIndex(where: { $0.id == id }) { redrawVectorPath(at: index) }
            endEdit()
        }
    }

    func beginPenLineWidthEdit() {
        guard canEditActivePenLine, !penWidthEditActive else { return }
        beginEdit("Change Path Width")
        penWidthEditActive = true
    }

    func endPenLineWidthEdit() {
        guard penWidthEditActive else { return }
        penWidthEditActive = false
        if let id = activeLayerID, let index = document?.layers.firstIndex(where: { $0.id == id }) { redrawVectorPath(at: index) }
        endEdit()
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
              abs(transform.size.width - CGFloat(vectorPath.image.width)) >= 0.5 ||
                abs(transform.size.height - CGFloat(vectorPath.image.height)) >= 0.5
        else { return nil }
        let maxDimension = max(transform.size.width, transform.size.height)
        let scale = min(1, 2_048 / max(maxDimension, 1))
        let previewSize = CGSize(
            width: max(1, transform.size.width * scale),
            height: max(1, transform.size.height * scale)
        )
        return vectorPathImage(style: vectorPath.style, size: previewSize, lineWidthScale: scale)
    }

    private func replaceActivePenLine(with proposed: LayerVectorPathStyle, preview: Bool) {
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
            mode: .line,
            color: PaletteColor(red: CGFloat(proposed.red), green: CGFloat(proposed.green), blue: CGFloat(proposed.blue)),
            lineWidth: proposed.lineWidth,
            nodes: localNodes,
            hoverPoint: nil
        )
        guard let committed = committedPenStyle(draft, closed: false) else { return }
        let fullSize = committed.box.size
        let scale = preview ? min(1, 2_048 / max(max(fullSize.width, fullSize.height), 1)) : 1
        let imageSize = CGSize(width: max(1, fullSize.width * scale), height: max(1, fullSize.height * scale))
        guard let image = vectorPathImage(style: committed.style, size: imageSize, lineWidthScale: scale) else { return }

        let centerUnit = CGPoint(
            x: committed.box.midX / max(oldTransform.size.width, 1),
            y: committed.box.midY / max(oldTransform.size.height, 1)
        )
        let center = centerUnit.applying(oldTransform.unitToDocument)
        var transform = oldTransform
        transform.size = fullSize
        transform.origin = CGPoint(x: center.x - fullSize.width / 2, y: center.y - fullSize.height / 2)
        let vectorPath = LayerVectorPath(style: committed.style, image: image)
        let thumbnail = preview ? oldAsset.thumbnail : ((try? PixelInvert.thumbnail(of: image)) ?? oldAsset.thumbnail)
        self.document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: oldAsset.name)
        self.document?.layers[index].vectorPath = vectorPath
        self.document?.layers[index].transform = transform
        if let mask = document.layers[index].mask, mask.placement == nil {
            self.document?.layers[index].mask?.placement = oldTransform
        }
    }

    private func penSelectionPath() -> CGPath? {
        let path: CGPath
        if let draft = penDraft {
            guard draft.nodes.count >= (draft.mode == .shape ? 3 : 2),
                  draft.nodes.allSatisfy(\.isFinite)
            else { return nil }
            path = LayerVectorPathStyle.path(nodes: draft.nodes, closed: true)
        } else {
            guard let layer = activeLayer, let vectorPath = layer.liveVectorPath else { return nil }
            let local = LayerVectorPathStyle.path(nodes: vectorPath.style.nodes, closed: true)
            var toDocument = layer.transform.unitToDocument
            guard let documentPath = local.copy(using: &toDocument) else { return nil }
            path = documentPath
        }
        let bounds = path.boundingBoxOfPath
        return bounds.isNull || bounds.width <= 0 || bounds.height <= 0 ? nil : path
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
        let padding = closed ? 1 : CGFloat(draft.lineWidth / 2 + 2)
        var box = CGRect(x: minX - padding, y: minY - padding,
                         width: max(maxX - minX + padding * 2, 1),
                         height: max(maxY - minY + padding * 2, 1)).integral
        box.size.width = max(box.size.width, 1)
        box.size.height = max(box.size.height, 1)
        guard box.width <= DocumentLimits.maxSideExtent,
              box.height <= DocumentLimits.maxSideExtent,
              box.width * box.height <= DocumentLimits.maxSurfaceExtent
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
            closed: closed
        )
        guard style.isValid else { return nil }
        return (style, box)
    }

    private func vectorPathImage(
        style: LayerVectorPathStyle,
        size: CGSize,
        lineWidthScale: CGFloat = 1
    ) -> CGImage? {
        guard style.isValid,
              size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= DocumentLimits.maxSideExtent,
              size.height <= DocumentLimits.maxSideExtent,
              size.width * size.height <= DocumentLimits.maxSurfaceExtent
        else { return nil }
        let pixelWidth = max(1, Int(ceil(size.width)))
        let pixelHeight = max(1, Int(ceil(size.height)))
        guard let context = try? BrushRaster.context(width: pixelWidth, height: pixelHeight, mask: false) else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        let drawSize = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        let path = LayerVectorPathStyle.path(nodes: style.nodes(in: drawSize), closed: style.closed)
        let color = CGColor(red: style.red, green: style.green, blue: style.blue, alpha: 1)
        if style.closed {
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        } else {
            context.setStrokeColor(color)
            context.setLineWidth(CGFloat(style.lineWidth) * lineWidthScale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
        }
        return context.makeImage()
    }

    private func nextVectorPathName(mode: PenMode) -> String {
        let base = mode == .shape ? "Path" : "Pen Line"
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
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
    nodes.indices.min { lhs, rhs in
        hypot(nodes[lhs].anchor.x - point.x, nodes[lhs].anchor.y - point.y) <
            hypot(nodes[rhs].anchor.x - point.x, nodes[rhs].anchor.y - point.y)
    }.flatMap { index in
        hypot(nodes[index].anchor.x - point.x, nodes[index].anchor.y - point.y) <= tolerance ? index : nil
    }
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
            let distance = hypot(position.x - point.x, position.y - point.y)
            if distance <= tolerance, best == nil || distance < best!.distance {
                best = (index, handle, distance)
            }
        }
    }
    return best.map { ($0.nodeIndex, $0.handle) }
}

private nonisolated func nearestPenSegment(
    to point: CGPoint,
    in nodes: [VectorPathNode],
    tolerance: CGFloat
) -> (segmentIndex: Int, t: CGFloat)? {
    guard nodes.count >= 2 else { return nil }
    var best: (segmentIndex: Int, t: CGFloat, distance: CGFloat)?
    let steps = 48
    for index in 0..<(nodes.count - 1) {
        let first = nodes[index]
        let second = nodes[index + 1]
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
            let distance = hypot(projected.x - point.x, projected.y - point.y)
            let t = (CGFloat(step - 1) + amount) / CGFloat(steps)
            if distance <= tolerance, best == nil || distance < best!.distance {
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
    t: CGFloat
) -> [VectorPathNode] {
    guard nodes.indices.contains(segmentIndex), nodes.indices.contains(segmentIndex + 1) else { return nodes }
    var result = nodes
    let first = nodes[segmentIndex]
    let second = nodes[segmentIndex + 1]
    let a = lerp(first.anchor, first.outHandle, t)
    let b = lerp(first.outHandle, second.inHandle, t)
    let c = lerp(second.inHandle, second.anchor, t)
    let d = lerp(a, b, t)
    let e = lerp(b, c, t)
    let middle = lerp(d, e, t)
    result[segmentIndex].outHandle = a
    result[segmentIndex + 1].inHandle = c
    result.insert(VectorPathNode(anchor: middle, inHandle: d, outHandle: e), at: segmentIndex + 1)
    return result
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

private nonisolated func lerp(_ lhs: CGPoint, _ rhs: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x + (rhs.x - lhs.x) * t, y: lhs.y + (rhs.y - lhs.y) * t)
}
