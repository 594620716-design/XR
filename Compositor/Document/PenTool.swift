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
    var canLoadPenPathSelection: Bool {
        canEditSelection && penSelectionPath() != nil
    }

    var canFillPenPath: Bool {
        canEditLayers && penDocumentPath(closeOpenPath: true, requiresArea: true) != nil
    }

    var canStrokePenPath: Bool {
        canEditLayers && penDocumentPath(closeOpenPath: false, requiresArea: false) != nil
    }

    func cyclePenMode() {
        cancelPen()
        penMode = penMode == .shape ? .line : .shape
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

    /// Fills the current editable path on a new pixel layer. The Pen layer remains the active, editable source.
    /// As in other path editors, filling an open path joins its endpoints for the duration of the fill.
    func fillPenPathWithForeground() {
        guard canEditLayers,
              let document,
              let path = penDocumentPath(closeOpenPath: true, requiresArea: true)
        else { NSSound.beep(); return }
        let name = nextPenResultName("Path Fill")
        do {
            let result = try filledPenPath(path, color: foregroundColor, canvas: document.size, name: name)
            installPenResult(result.asset, transform: result.transform, name: name, editName: "Fill Path")
        } catch {
            brushError = error.localizedDescription
        }
    }

    /// Paints the current editable path on a new pixel layer with the current Brush size, hardness and opacity.
    /// The stroke uses the current foreground color and does not consume or rasterize the Pen path.
    func strokePenPathWithBrush() {
        guard canEditLayers,
              let document,
              let geometry = penDocumentGeometry(closeOpenPath: false),
              penDocumentPath(closeOpenPath: false, requiresArea: false) != nil
        else { NSSound.beep(); return }
        let name = nextPenResultName("Path Stroke")
        do {
            var settings = brushSettings
            settings.red = foregroundColor.red
            settings.green = foregroundColor.green
            settings.blue = foregroundColor.blue
            settings.smoothing = 0
            settings.erasing = false
            settings.healing = false
            guard let points = flattenedPenPoints(nodes: geometry.nodes, closed: geometry.closed,
                                                  flatness: max(0.2, min(0.75, settings.diameter / 32))),
                  points.count >= 2 else { throw BrushStrokeError.pathTooComplex }
            let blank = ImageLayer(name: name, blankSize: document.size)
            let stroke = try BrushStroke(layer: blank, mask: false, settings: settings,
                                         canvas: document.size, useGPU: false)
            let used = document.layers.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) }
            stroke.pixelLimit = max(0, DocumentLimits.documentPixelBudget - used)
            try stroke.appendPolyline(points)
            guard !stroke.patches.isEmpty else { NSSound.beep(); return }
            let result = try stroke.paintSnapshot()
            installPenResult(result.asset, transform: result.transform, name: name, editName: "Stroke Path")
        } catch {
            brushError = error.localizedDescription
        }
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

        guard let document else { return nil }
        let visible = document.effectiveVisibleIDs
        for layerIndex in document.layers.indices.reversed() {
            let layer = document.layers[layerIndex]
            guard (visible.contains(layer.id) || layer.id == activeLayerID),
                  let vectorPath = layer.liveVectorPath
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
                penMode = vectorPath.style.mode
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
                penMode = vectorPath.style.mode
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
                penMode = vectorPath.style.mode
                beginEdit("Add Path Point")
                penLineGestureActive = true
                penLineGestureHandle = nil
                var proposed = vectorPath.style
                proposed.nodes = splitPenSegment(nodes: proposed.nodes, segmentIndex: hit.segmentIndex,
                                                 t: hit.t, closed: proposed.closed)
                selectedPenNodeIndex = hit.segmentIndex + 1
                selectedPenHandle = nil
                replaceActivePenPath(with: proposed)
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
            replaceActivePenPath(with: proposed)
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
        replaceActivePenPath(with: proposed)
    }

    func endPenLineNodeGesture() {
        guard penLineGestureActive else { return }
        penLineGestureActive = false
        penLineGestureHandle = nil
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
        replaceActivePenPath(with: proposed)
        endEdit()
        return true
    }

    func redrawVectorPath(at index: Int) {
        guard let document,
              document.layers.indices.contains(index),
              let vectorPath = document.layers[index].liveVectorPath,
              let asset = document.layers[index].asset,
              let image = PenBacking.image
        else { return }
        // Current path backings are already transparent 1×1 images, including ones just reopened from disk.
        guard vectorPath.image.width != 1 || vectorPath.image.height != 1,
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        self.document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        self.document?.layers[index].vectorPath?.image = image
    }

    private func replaceActivePenPath(with proposed: LayerVectorPathStyle) {
        guard let id = activeLayerID,
              let document,
              let index = document.layers.firstIndex(where: { $0.id == id }),
              document.layers.indices.contains(index),
              let currentPath = document.layers[index].liveVectorPath,
              let oldAsset = document.layers[index].asset
        else { return }
        let oldTransform = document.layers[index].transform
        let localNodes = proposed.nodes(in: oldTransform.size)
        let draft = PenDraft(
            mode: proposed.mode,
            color: PaletteColor(red: CGFloat(proposed.red), green: CGFloat(proposed.green), blue: CGFloat(proposed.blue)),
            lineWidth: proposed.lineWidth,
            nodes: localNodes,
            hoverPoint: nil
        )
        guard let committed = committedPenStyle(draft, closed: proposed.closed) else { return }
        let fullSize = committed.box.size

        let centerUnit = CGPoint(
            x: committed.box.midX / max(oldTransform.size.width, 1),
            y: committed.box.midY / max(oldTransform.size.height, 1)
        )
        let center = centerUnit.applying(oldTransform.unitToDocument)
        var transform = oldTransform
        transform.size = fullSize
        transform.origin = CGPoint(x: center.x - fullSize.width / 2, y: center.y - fullSize.height / 2)
        let image = currentPath.image.width == 1 && currentPath.image.height == 1
            ? currentPath.image : PenBacking.image
        guard let image else { return }
        if image !== currentPath.image {
            let thumbnail = (try? PixelInvert.thumbnail(of: image)) ?? oldAsset.thumbnail
            self.document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: oldAsset.name)
        }
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

    private func filledPenPath(_ path: CGPath, color: PaletteColor, canvas: CGSize, name: String) throws
        -> (asset: ImportedImage, transform: LayerTransform) {
        let canvas = CGRect(origin: .zero, size: canvas)
        let box = path.boundingBoxOfPath.insetBy(dx: -1, dy: -1).integral.intersection(canvas)
        guard !box.isNull, !box.isEmpty,
              box.width <= DocumentLimits.maxSideExtent,
              box.height <= DocumentLimits.maxSideExtent,
              box.width * box.height <= DocumentLimits.maxSurfaceExtent else { throw ProjectError.tooLarge }
        let used = document?.layers.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) } ?? 0
        guard used + Int(box.width * box.height) <= DocumentLimits.documentPixelBudget else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: Int(box.width), height: Int(box.height), mask: false)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.translateBy(x: -box.minX, y: -box.minY)
        let components = [color.red, color.green, color.blue, CGFloat(1)]
        guard let fillColor = context.colorSpace.flatMap({ CGColor(colorSpace: $0, components: components) })
        else { throw ExportError.render }
        context.setFillColor(fillColor)
        context.addPath(path)
        context.fillPath(using: .winding)
        guard let image = context.makeImage() else { throw ExportError.render }
        let asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: name)
        return (asset, LayerTransform(origin: box.origin, size: box.size))
    }

    /// A Pen result is deliberately a sibling pixel layer: the source remains a vector path and stays selected.
    private func installPenResult(_ asset: ImportedImage, transform: LayerTransform,
                                  name: String, editName: String) {
        let hadDraft = penDraft != nil
        finishOpacityEdit()
        beginEdit(editName)
        defer { endEdit() }
        if hadDraft, !finishPen() { return }
        guard let document,
              let sourceID = activeLayerID,
              let sourceIndex = document.layers.firstIndex(where: { $0.id == sourceID }),
              document.layers[sourceIndex].liveVectorPath != nil else { return }
        let result = ImageLayer(id: UUID(), asset: asset, name: name, isVisible: true,
                                transform: transform, parentID: document.layers[sourceIndex].parentID)
        // Older projects may contain the Pen path's former painted preview. Replace it with the transparent
        // backing before adding the explicit result, while keeping the vector source visible and editable.
        redrawVectorPath(at: sourceIndex)
        self.document?.layers.insert(result, at: sourceIndex + 1)
        activeLayerID = sourceID
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
        let padding: CGFloat = 1
        var box = CGRect(x: minX - padding, y: minY - padding,
                         width: max(maxX - minX + padding * 2, 1),
                         height: max(maxY - minY + padding * 2, 1)).integral
        box.size.width = max(box.size.width, 1)
        box.size.height = max(box.size.height, 1)
        guard box.width <= DocumentLimits.maxSideExtent,
              box.height <= DocumentLimits.maxSideExtent
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

    private func nextVectorPathName() -> String {
        nextPenResultName("Path")
    }

    private func nextPenResultName(_ base: String) -> String {
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
