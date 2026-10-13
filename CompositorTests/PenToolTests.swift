import AppKit
import Testing
@testable import Compositor

@MainActor
struct PenToolTests {
    private func makeSession(mode: PenMode = .line) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 120, height: 100, emptyLayer: true)
        session.selectTool(.pen)
        session.penMode = mode
        session.foregroundColor = PaletteColor(red: 0.1, green: 0.4, blue: 0.9)
        return session
    }

    private func add(_ point: CGPoint, to session: EditorSession, handle: CGPoint? = nil) {
        _ = session.beginPenAnchor(at: point, closeDistance: 2, constrain: false)
        if let handle { session.dragPenHandle(to: handle, constrain: false) }
    }

    private func documentAnchors(_ layer: ImageLayer) throws -> [CGPoint] {
        let vector = try #require(layer.liveVectorPath)
        return vector.style.nodes.map { node in node.anchor.applying(layer.transform.unitToDocument) }
    }

    private func pixel(_ layer: ImageLayer, at point: CGPoint) throws -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let image = try #require(layer.asset?.image)
        let mapping = BrushRaster.pixelToDocument(layer.transform, width: image.width, height: image.height)
        let local = point.applying(mapping.inverted())
        guard local.x >= 0, local.y >= 0, local.x < CGFloat(image.width), local.y < CGFloat(image.height) else {
            return (0, 0, 0, 0)
        }
        let context = try BrushRaster.copy(image)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = Int(local.y) * context.bytesPerRow + Int(local.x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
    }

    @Test func openLineCommitsAsOneEditableLayerAndUndoRemovesIt() throws {
        let session = makeSession()
        let undoCount = session.history.undoCount
        add(CGPoint(x: 10, y: 20), to: session)
        add(CGPoint(x: 40, y: 30), to: session, handle: CGPoint(x: 48, y: 10))
        add(CGPoint(x: 80, y: 60), to: session)
        #expect(session.finishPen())

        let layer = try #require(session.activeLayer)
        let vector = try #require(layer.liveVectorPath)
        #expect(layer.name == "Path 1")
        #expect(vector.style.mode == .line && !vector.style.closed)
        #expect(vector.style.nodes.count == 3)
        #expect(vector.style.nodes[1].inHandle != vector.style.nodes[1].anchor)
        #expect(session.history.undoCount == undoCount + 1)

        session.undo()
        #expect(session.document?.layers.map(\.name) == ["Layer 1"])
        session.redo()
        #expect(session.activeLayer?.liveVectorPath?.style == vector.style)
    }

    @Test func committedPenLayerIsAnEditablePathWithoutPaintedPixels() throws {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 15, y: 15), to: session)
        add(CGPoint(x: 90, y: 20), to: session)
        add(CGPoint(x: 50, y: 75), to: session)
        #expect(session.finishPen())

        let path = try #require(session.activeLayer)
        #expect(path.liveVectorPath != nil)
        #expect(try pixel(path, at: CGPoint(x: 50, y: 35)).alpha == 0)
    }

    @Test func foregroundFillCreatesPixelsButKeepsThePathEditable() throws {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 15, y: 15), to: session)
        add(CGPoint(x: 90, y: 15), to: session)
        add(CGPoint(x: 50, y: 75), to: session)
        #expect(session.finishPen())
        let pathID = try #require(session.activeLayerID)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        let undoCount = session.history.undoCount

        #expect(session.canFillPenPath)
        session.fillPenPathWithForeground()

        let document = try #require(session.document)
        let source = try #require(document.layers.first(where: { $0.id == pathID }))
        #expect(document.layers.count == 2)
        #expect(source.liveVectorPath?.style.fill != nil && source.isVisible)
        #expect(session.activeLayerID == pathID)
        #expect(session.history.undoCount == undoCount + 1)
        let color = try pixel(source, at: CGPoint(x: 50, y: 35))
        #expect(color.red > 240, "red: \(color)")
        #expect(color.green < 5, "green: \(color)")
        #expect(color.blue < 5, "blue: \(color)")
        #expect(color.alpha > 240, "alpha: \(color)")

        session.undo()
        #expect(session.document?.layers.count == 2)
        #expect(session.activeLayer?.liveVectorPath?.style.fill == nil)
        #expect(try pixel(try #require(session.activeLayer), at: CGPoint(x: 50, y: 35)).alpha == 0)
        #expect(session.activeLayer?.isVisible == true)
    }

    @Test func filledArtworkMovesAndItsPenNodesRemainEditable() throws {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 20, y: 20), to: session)
        add(CGPoint(x: 80, y: 20), to: session)
        add(CGPoint(x: 50, y: 70), to: session)
        #expect(session.finishPen())
        session.fillPenPathWithForeground()
        let id = try #require(session.activeLayerID)

        session.selectTool(.move)
        session.nudgeLayer(dx: 20, dy: 0)
        let moved = try #require(session.activeLayer)
        #expect(moved.id == id && moved.liveVectorPath?.style.fill != nil)
        #expect(try pixel(moved, at: CGPoint(x: 70, y: 35)).alpha > 240)

        let image = try #require(moved.asset?.image)
        session.selectTool(.pen)
        #expect(session.beginPenLineNodeGesture(at: CGPoint(x: 40, y: 20), tolerance: 2) == 0)
        session.dragPenLineNode(to: CGPoint(x: 45, y: 25))
        session.endPenLineNodeGesture()

        let edited = try #require(session.activeLayer)
        #expect(edited.id == id && edited.liveVectorPath?.style.fill != nil)
        #expect(edited.asset?.image !== image)
        #expect(hypot(try documentAnchors(edited)[0].x - 45,
                      try documentAnchors(edited)[0].y - 25) < 0.001)
    }

    @Test func brushStrokeUsesCurrentBrushAndPreservesTheOpenPath() throws {
        let session = makeSession()
        add(CGPoint(x: 20, y: 50), to: session)
        add(CGPoint(x: 100, y: 50), to: session)
        #expect(session.finishPen())
        let pathID = try #require(session.activeLayerID)
        session.foregroundColor = PaletteColor(red: 0, green: 1, blue: 0)
        session.brushSettings.diameter = 12
        session.brushSettings.hardness = 1
        session.brushSettings.opacity = 0.5

        #expect(session.canStrokePenPath)
        session.strokePenPathWithBrush()

        let document = try #require(session.document)
        let source = try #require(document.layers.first(where: { $0.id == pathID }))
        let center = try pixel(source, at: CGPoint(x: 60, y: 50))
        #expect(document.layers.count == 2)
        #expect(source.liveVectorPath?.style.brushStroke != nil && source.isVisible)
        #expect(session.activeLayerID == pathID)
        #expect(center.red < 5 && center.green > 110 && center.blue < 5)
        #expect((110...140).contains(center.alpha))
        #expect(try pixel(source, at: CGPoint(x: 60, y: 60)).alpha == 0)
    }

    @Test func fillingAnUnfinishedPathCommitsThePathAndResultAsOneUndoStep() throws {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 20, y: 15), to: session)
        add(CGPoint(x: 75, y: 15), to: session)
        add(CGPoint(x: 45, y: 65), to: session)
        let undoCount = session.history.undoCount

        session.fillPenPathWithForeground()

        #expect(session.penDraft == nil)
        #expect(session.document?.layers.map(\.name) == ["Layer 1", "Path 1"])
        #expect(session.activeLayer?.liveVectorPath?.style.fill != nil)
        #expect(session.history.undoCount == undoCount + 1)
        session.undo()
        #expect(session.document?.layers.map(\.name) == ["Layer 1"])
    }

    @Test func shapePathClosesAndKeepsItsFillColor() throws {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 15, y: 15), to: session)
        add(CGPoint(x: 90, y: 20), to: session)
        add(CGPoint(x: 50, y: 75), to: session)
        #expect(session.finishPen())
        let style = try #require(session.activeLayer?.liveVectorPath?.style)
        #expect(style.mode == .shape && style.closed)
        #expect(style.nodes.count == 3)
        #expect(abs(style.red - 0.1) < 0.001)
        #expect(abs(style.green - 0.4) < 0.001)
        #expect(abs(style.blue - 0.9) < 0.001)
    }

    @Test func closedShapeCanInsertMoveDeleteAndUndoPoints() throws {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 15, y: 15), to: session)
        add(CGPoint(x: 85, y: 15), to: session)
        add(CGPoint(x: 85, y: 75), to: session)
        add(CGPoint(x: 15, y: 75), to: session)
        #expect(session.finishPen())
        let original = try #require(session.activeLayer?.liveVectorPath?.style)

        // The final segment closes from the last point back to the first; it must be editable too.
        #expect(session.beginPenLineNodeGesture(at: CGPoint(x: 15, y: 45), tolerance: 2) == 4)
        session.dragPenLineNode(to: CGPoint(x: 5, y: 45))
        session.endPenLineNodeGesture()

        let editedLayer = try #require(session.activeLayer)
        let edited = try #require(editedLayer.liveVectorPath).style
        #expect(edited.mode == .shape && edited.closed && edited.nodes.count == 5)
        #expect(abs(try documentAnchors(editedLayer)[4].x - 5) < 0.001)
        #expect(session.removeSelectedPenNode())
        #expect(session.activeLayer?.liveVectorPath?.style.nodes.count == 4)
        session.undo()
        session.undo()
        #expect(session.activeLayer?.liveVectorPath?.style == original)
    }

    @Test func invalidModeClosureAndCoordinatesAreRejected() {
        let nodes = [VectorPathNode(anchor: CGPoint(x: 0, y: 0)),
                     VectorPathNode(anchor: CGPoint(x: 1, y: 1))]
        let openShape = LayerVectorPathStyle(mode: .shape, red: 0, green: 0, blue: 0,
                                             lineWidth: 4, nodes: nodes, closed: false)
        let outside = LayerVectorPathStyle(mode: .line, red: 0, green: 0, blue: 0,
                                           lineWidth: 4,
                                           nodes: [nodes[0], VectorPathNode(anchor: CGPoint(x: 2, y: 1))],
                                           closed: false)
        #expect(!openShape.isValid)
        #expect(!outside.isValid)
    }

    @Test func switchingModeCancelsAnUnfinishedPath() {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 10, y: 10), to: session)
        #expect(session.penDraft != nil)
        session.cyclePenMode()
        #expect(session.penMode == .line)
        #expect(session.penDraft == nil)
        #expect(session.document?.layers.count == 1)
    }

    @Test func commandUndoRemovesUnfinishedPointsBeforeDocumentHistory() {
        let session = makeSession()
        let historyCount = session.history.undoCount
        add(CGPoint(x: 10, y: 10), to: session)
        add(CGPoint(x: 40, y: 30), to: session)
        add(CGPoint(x: 70, y: 50), to: session)

        #expect(session.canUndo)
        session.undo()
        #expect(session.penDraft?.nodes.count == 2)
        #expect(session.history.undoCount == historyCount)
        session.undo()
        #expect(session.penDraft?.nodes.count == 1)
        session.undo()
        #expect(session.penDraft == nil)
        #expect(session.history.undoCount == historyCount)
    }

    @Test func linePointCanBeInsertedMovedDeletedAndUndone() throws {
        let session = makeSession()
        add(CGPoint(x: 10, y: 20), to: session)
        add(CGPoint(x: 50, y: 20), to: session)
        #expect(session.finishPen())
        let before = try #require(session.activeLayer?.liveVectorPath?.style)
        let count = session.history.undoCount

        #expect(session.beginPenLineNodeGesture(at: CGPoint(x: 30, y: 20), tolerance: 2) == 1)
        session.dragPenLineNode(to: CGPoint(x: 30, y: 45))
        session.endPenLineNodeGesture()
        let movedLayer = try #require(session.activeLayer)
        #expect(movedLayer.liveVectorPath?.style.nodes.count == 3)
        #expect(try documentAnchors(movedLayer)[1].y == 45)
        #expect(session.history.undoCount == count + 1)

        #expect(session.removeSelectedPenNode())
        #expect(session.activeLayer?.liveVectorPath?.style.nodes.count == 2)
        session.undo()
        #expect(session.activeLayer?.liveVectorPath?.style.nodes.count == 3)
        session.undo()
        #expect(session.activeLayer?.liveVectorPath?.style == before)
    }

    @Test func lineHandlesCanBeSelectedLinkedMovedBrokenAndUndone() throws {
        let session = makeSession()
        add(CGPoint(x: 10, y: 50), to: session)
        add(CGPoint(x: 60, y: 50), to: session, handle: CGPoint(x: 75, y: 35))
        #expect(session.finishPen())
        let original = try #require(session.activeLayer?.liveVectorPath?.style)

        #expect(session.beginPenLineNodeGesture(at: CGPoint(x: 45, y: 65), tolerance: 2) == 1)
        #expect(session.selectedPenHandle == .incoming)
        session.dragPenLineNode(to: CGPoint(x: 40, y: 80))
        session.endPenLineNodeGesture()

        let linkedLayer = try #require(session.activeLayer)
        let linked = try #require(linkedLayer.liveVectorPath).style.nodes[1]
        let linkedAnchor = linked.anchor.applying(linkedLayer.transform.unitToDocument)
        let linkedIn = linked.inHandle.applying(linkedLayer.transform.unitToDocument)
        let linkedOut = linked.outHandle.applying(linkedLayer.transform.unitToDocument)
        #expect(hypot(linkedIn.x - 40, linkedIn.y - 80) < 0.001)
        #expect(abs((linkedIn.x - linkedAnchor.x) * (linkedOut.y - linkedAnchor.y) -
                    (linkedIn.y - linkedAnchor.y) * (linkedOut.x - linkedAnchor.x)) < 0.001)

        #expect(session.beginPenLineNodeGesture(at: linkedOut, tolerance: 2) == 1)
        let incomingBeforeBreak = linkedIn
        session.dragPenLineNode(to: CGPoint(x: 85, y: 60), breakHandles: true)
        session.endPenLineNodeGesture()
        let brokenLayer = try #require(session.activeLayer)
        let broken = try #require(brokenLayer.liveVectorPath).style.nodes[1]
        let incomingAfterBreak = broken.inHandle.applying(brokenLayer.transform.unitToDocument)
        #expect(hypot(incomingAfterBreak.x - incomingBeforeBreak.x,
                      incomingAfterBreak.y - incomingBeforeBreak.y) < 0.001)

        session.undo()
        session.undo()
        #expect(session.activeLayer?.liveVectorPath?.style == original)
    }

    @Test func editablePathRoundTripsWithoutMovingAnchors() async throws {
        let session = makeSession()
        add(CGPoint(x: 12, y: 18), to: session)
        add(CGPoint(x: 86, y: 64), to: session)
        #expect(session.finishPen())
        let anchors = try documentAnchors(try #require(session.activeLayer))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorPenTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let url = folder.appendingPathComponent("Path.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.activeLayer?.liveVectorPath?.style == session.activeLayer?.liveVectorPath?.style)
        #expect(try documentAnchors(try #require(reopened.activeLayer)) == anchors)
    }

    @Test func saveSnapshotKeepsTheLivePathAppearanceFallback() throws {
        let session = makeSession()
        session.penMode = .shape
        add(CGPoint(x: 12, y: 18), to: session)
        add(CGPoint(x: 86, y: 18), to: session)
        add(CGPoint(x: 50, y: 64), to: session)
        #expect(session.finishPen())
        session.fillPenPathWithForeground()
        let id = try #require(session.activeLayerID)

        let snapshot = try #require(session.projectSnapshot())
        let backing = try #require(snapshot.images[id]?.image)
        #expect(snapshot.manifest.version == 16)
        #expect(snapshot.manifest.layers.first(where: { $0.id == id })?.vectorPath?.fill != nil)
        #expect(backing.width > 1 && backing.height > 1)
    }

    @Test func activeShapeLoadsAsASelectionInDocumentCoordinates() throws {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 15, y: 20), to: session)
        add(CGPoint(x: 80, y: 20), to: session)
        add(CGPoint(x: 80, y: 70), to: session)
        add(CGPoint(x: 15, y: 70), to: session)
        #expect(session.finishPen())

        let layerID = try #require(session.activeLayerID)
        let layerIndex = try #require(session.document?.layers.firstIndex(where: { $0.id == layerID }))
        session.document?.layers[layerIndex].transform.rotation = 90
        let center = try #require(session.activeLayer?.transform.center)

        #expect(session.canLoadPenPathSelection)
        session.loadPenPathSelection()

        let selection = try #require(session.selection)
        #expect(selection.path.contains(center, using: .winding))
        #expect(!selection.path.contains(CGPoint(x: 5, y: 5), using: .winding))
        #expect(session.activeLayer?.isVisible == true)
        #expect(session.activeLayer?.liveVectorPath != nil)
    }

    @Test func openPathClosesWhenLoadedAndCanAddToASelection() throws {
        let session = makeSession()
        add(CGPoint(x: 10, y: 10), to: session)
        add(CGPoint(x: 70, y: 10), to: session)
        add(CGPoint(x: 40, y: 60), to: session)
        #expect(session.finishPen())

        session.applySelection(CGPath(rect: CGRect(x: 90, y: 80, width: 10, height: 10), transform: nil),
                               mode: .replace, name: "Select")
        session.loadPenPathSelection(mode: .add)

        let selection = try #require(session.selection)
        #expect(selection.path.contains(CGPoint(x: 40, y: 25), using: .winding))
        #expect(selection.path.contains(CGPoint(x: 95, y: 85), using: .winding))
    }

    @Test func loadingAnUnfinishedPathCommitsAndPreservesIt() throws {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 20, y: 15), to: session)
        add(CGPoint(x: 75, y: 15), to: session)
        add(CGPoint(x: 45, y: 65), to: session)

        #expect(session.canLoadPenPathSelection)
        session.loadPenPathSelection()

        #expect(session.penDraft == nil)
        #expect(session.document?.layers.count == 2)
        #expect(session.activeLayer?.liveVectorPath != nil)
        #expect(try #require(session.selection).path.contains(CGPoint(x: 45, y: 30), using: .winding))
        session.undo()
        #expect(session.document?.layers.count == 1)
        #expect(session.selection == nil)
    }

    @Test func commandReturnLoadsTheDraftAndKeepsAnEditablePath() throws {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 20, y: 15), to: session)
        add(CGPoint(x: 75, y: 15), to: session)
        add(CGPoint(x: 45, y: 65), to: session)
        let canvas = CanvasView(session: session)
        let commandReturn = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))

        canvas.keyDown(with: commandReturn)

        #expect(session.penDraft == nil)
        #expect(session.document?.layers.count == 2)
        #expect(session.activeLayer?.liveVectorPath != nil)
        #expect(try #require(session.selection).path.contains(CGPoint(x: 45, y: 30), using: .winding))
    }

    @Test func editablePathCannotBeAccidentallyPaintedOver() throws {
        let session = makeSession()
        add(CGPoint(x: 10, y: 20), to: session)
        add(CGPoint(x: 90, y: 70), to: session)
        #expect(session.finishPen())

        session.selectTool(.brush)

        #expect(!session.canPaint)
        #expect(session.paintRefusal?.contains("editable path") == true)
        #expect(session.activeLayer?.liveVectorPath != nil)
    }

    @Test func draggingAPathPointReusesItsTransparentBacking() throws {
        let session = makeSession()
        add(CGPoint(x: 10, y: 20), to: session)
        add(CGPoint(x: 90, y: 70), to: session)
        #expect(session.finishPen())
        let image = try #require(session.activeLayer?.liveVectorPath?.image)

        #expect(session.beginPenLineNodeGesture(at: CGPoint(x: 10, y: 20), tolerance: 2) == 0)
        session.dragPenLineNode(to: CGPoint(x: 15, y: 25))
        session.dragPenLineNode(to: CGPoint(x: 20, y: 30))
        session.endPenLineNodeGesture()

        #expect(session.activeLayer?.liveVectorPath?.image === image)
    }

    @Test func generatedBrushStrokeRejectsUnboundedDabWork() throws {
        var settings = BrushSettings()
        settings.diameter = 1
        let layer = ImageLayer(name: "Stroke", blankSize: CGSize(width: 10, height: 10))
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings,
                                     canvas: CGSize(width: 10, height: 10), useGPU: false)

        #expect(throws: BrushStrokeError.self) {
            try stroke.appendPolyline([.zero, CGPoint(x: 1_000_000, y: 0)])
        }
        #expect(stroke.patches.isEmpty)
    }
}
