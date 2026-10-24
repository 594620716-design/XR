import SwiftUI
import UniformTypeIdentifiers
import Sparkle

@main
struct CompositorApp: App {
    @NSApplicationDelegateAdaptor(CompositorApplicationDelegate.self) private var applicationDelegate
    @AppStorage("navigator.visible") private var showsNavigator = false
    private var session: EditorSession { applicationDelegate.session }
    private func filterMenuItem(_ kind: FilterKind) -> some View {
        Button(kind.localizedName + "…") { session.beginFilter(kind) }
            .disabled(!(kind == .vignette ? session.canVignette : session.canAdjustColors) || session.hueSaturation != nil)
    }
    var body: some Scene {
        Window("Compositor", id: "editor") {
            ProjectWorkspaceView(applicationDelegate: applicationDelegate).roundedControls()
        }
            .defaultSize(width: 1180, height: 780)
            // Files opened from Finder or dropped on the Dock icon go to the app delegate, which imports them into
            // the open window. Left to SwiftUI, each one builds a throwaway window and fades the editor out and back.
            .handlesExternalEvents(matching: [])
            // A first launch fills the screen (without going full screen); after that macOS reopens the window at the
            // size it was left.
            .defaultWindowPlacement { _, context in
                WindowPlacement(size: context.defaultDisplay.visibleRect.size)
            }
            // The project's name is already on its tab, so the toolbar doesn't repeat it as a window title.
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .commands {
                CommandGroup(replacing: .undoRedo) {
                    // Dialog text fields keep native text undo; document history
                    // is unavailable while an import or modal edit is active.
                    if session.textDraft != nil || session.levels != nil || session.isProjectBusy || session.showsNewDocument || session.showsImporter || session.renamingLayerID != nil || session.transformEdit?.persistent == true {
                        Button("Undo".localized) {
                            if NSApp.isEditingText {
                                NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil)
                            }
                        }
                            .configuredKeyboardShortcut("z")
                        Button("Redo".localized) {
                            if NSApp.isEditingText {
                                NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil)
                            }
                        }
                            .configuredKeyboardShortcut("z", modifiers: [.command, .shift])
                    } else {
                        // A Save or Open panel's name field undoes its own typing (see `isEditingText`).
                        Button(session.penDraft != nil ? "Undo Add Path Point" : session.canUndoPenClosure ? "Undo Close Path" : session.history.canUndo ? "Undo \(session.history.undoName)" : "Undo") {
                            if NSApp.keyWindow is NSSavePanel { NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil) }
                            else { session.undo() }
                        }
                            .configuredKeyboardShortcut("z").disabled(!session.canUndo)
                        Button(session.history.canRedo ? "Redo \(session.history.redoName)" : "Redo") {
                            if NSApp.keyWindow is NSSavePanel { NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil) }
                            else { session.redo() }
                        }
                            .configuredKeyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
                    }
                }
                CommandGroup(replacing: .newItem) {
                    Button("New Canvas…".localized) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.newCanvas() }
                    }.configuredKeyboardShortcut("n")
                        .disabled(!applicationDelegate.projects.canStart)
                    Button("Open Project…".localized) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.open() }
                    }
                        .configuredKeyboardShortcut("o").disabled(!applicationDelegate.projects.canStart)
                    Menu("Open Recent".localized) {
                        ForEach(RecentProjects.shared.urls, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                applicationDelegate.showEditor?()
                                Task { await applicationDelegate.projects.open(url) }
                            }
                        }
                        Divider()
                        Button("Clear Menu".localized) { RecentProjects.shared.clear() }
                            .disabled(RecentProjects.shared.urls.isEmpty)
                    }
                        .disabled(!applicationDelegate.projects.canStart)
                    Button("Import…".localized) { session.showsImporter = true }
                        .disabled(session.levels != nil || session.showsBusy || session.isImporting || session.showsNewDocument)
                }
                CommandGroup(replacing: .saveItem) {
                    Button("Save".localized) { Task { await applicationDelegate.projects.save() } }
                        .configuredKeyboardShortcut("s").disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button("Save As…".localized) { Task { await applicationDelegate.projects.save(asNew: true) } }
                        .configuredKeyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Divider()
                    // Export As on JPEG.
                    Button("Export JPEG…".localized) { Task { await applicationDelegate.projects.exportAs(start: .jpeg) } }
                        .configuredKeyboardShortcut("s", modifiers: [.command, .option, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button("Export PNG…".localized) { Task { await applicationDelegate.projects.exportPNG() } }
                        .configuredKeyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    // Still images or GIF timelines, sized and previewed; ⌥⇧⌘W, as Photoshop's Export As.
                    Button("Export As…".localized) { Task { await applicationDelegate.projects.exportAs() } }
                        .configuredKeyboardShortcut("w", modifiers: [.command, .option, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Divider()
                    Button("Close Project".localized) {
                        if let window = applicationDelegate.projects.window {
                            Task { await applicationDelegate.projects.close(window) }
                        }
                    }.configuredKeyboardShortcut("w").disabled(!applicationDelegate.projects.canStart)
                }
                // Grouped: a commands builder takes at most ten items.
                Group {
                    CommandGroup(after: .appInfo) {
                        Button("Check for Updates…".localized) { applicationDelegate.updater.checkForUpdates() }
                    }
                    CommandGroup(after: .toolbar) {
                        Button("Search Commands…".localized) {
                            CommandPaletteController.shared.toggle(session: session, over: applicationDelegate.projects.window)
                        }
                        .configuredKeyboardShortcut("f", modifiers: [.command])
                        // A plain F, shown as menus show keys; the app hands an F meant for a text field to the field
                        // first (see CompositorApplicationDelegate).
                        Toggle("Toggle Fullscreen".localized, isOn: Binding(get: { session.canvasOnly },
                                                            set: { _ in applicationDelegate.toggleCanvasOnly() }))
                            .keyboardShortcut("f", modifiers: [])
                            .disabled(!session.canToggleCanvasOnly)
                        Divider()
                        // With a dialog's preview open (Export As), these zoom that preview rather than the canvas.
                        Button("Fit Canvas".localized) {
                            if let preview = session.previewZoom { preview(.fit) } else { session.fit() }
                        }.configuredKeyboardShortcut("0").disabled(session.document == nil)
                        Button("Actual Pixels".localized) {
                            if let preview = session.previewZoom { preview(.actual) } else { session.zoom(to: 1) }
                        }.configuredKeyboardShortcut("1").disabled(session.document == nil)
                        Button("Zoom In".localized) {
                            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                            if let preview = session.previewZoom { preview(.zoomIn) } else { session.zoomKeyboard(by: 1) }
                        }
                            .configuredKeyboardShortcut("=").disabled(session.document == nil)
                        Button("Zoom Out".localized) {
                            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                            if let preview = session.previewZoom { preview(.zoomOut) } else { session.zoomKeyboard(by: -1) }
                        }
                            .configuredKeyboardShortcut("-").disabled(session.document == nil)
                        Toggle("Navigator (300% and above)".localized, isOn: $showsNavigator)
                        Toggle("Pixel Grid (800% and above)".localized, isOn: Binding(get: { session.showsPixelGrid },
                                                                              set: { session.showsPixelGrid = $0 }))
                        Toggle("Show Transform Controls".localized, isOn: Binding(get: { session.showsTransformControls },
                                                                          set: { session.showsTransformControls = $0 }))
                            .configuredKeyboardShortcut("h").disabled(session.tool != .move || session.document == nil)
                        Divider()
                        // Print: the canvas as the chosen CMYK profile will print it, tucked in a submenu as few need it. No
                        // shortcuts (Photoshop's ⌘Y sits by ⌘U and would be hit by mistake); Search Commands finds them.
                        Menu("CMYK".localized) {
                            Toggle("Proof Colors".localized, isOn: Binding(get: { session.proofsColors }, set: { session.proofsColors = $0 }))
                                .assignableShortcut("CMYK Proof Colors")
                                .disabled(session.document == nil)
                            Toggle("Gamut Warning".localized, isOn: Binding(get: { session.showsGamutWarning },
                                                                  set: { session.showsGamutWarning = $0 }))
                                .assignableShortcut("CMYK Gamut Warning")
                                .disabled(session.document == nil)
                            Divider()
                            Menu("Profile".localized) {
                                let current = session.proofProfile ?? CMYK.chosen
                                ForEach(CMYK.installed()) { profile in
                                    Toggle(profile.name, isOn: Binding(get: { current?.name == profile.name },
                                                                       set: { if $0 { session.proofProfile = profile } }))
                                }
                                Divider()
                                Button("Load Profile…".localized) { loadCMYKProfile() }
                            }
                        }
                        Group {
                            Divider()
                            Menu("Show".localized) {
                                Toggle("Grid".localized, isOn: Binding(get: { session.showsGrid }, set: { session.showsGrid = $0 }))
                                    .configuredKeyboardShortcut("'").disabled(session.document == nil)
                                Toggle("Guides".localized, isOn: Binding(get: { session.showsGuides }, set: { session.showsGuides = $0 }))
                                    .configuredKeyboardShortcut(";").disabled(session.document == nil)
                            }
                            Button("Grid Settings…".localized) { Task { await applicationDelegate.projects.gridSettings() } }
                                .disabled(session.document == nil)
                            Toggle("Rulers".localized, isOn: Binding(get: { session.showsRulers }, set: { session.showsRulers = $0 }))
                                .configuredKeyboardShortcut("r").disabled(session.document == nil)
                            Divider()
                            Toggle("Snap".localized, isOn: Binding(get: { session.snapEnabled }, set: { session.snapEnabled = $0 }))
                                .configuredKeyboardShortcut(";", modifiers: [.command, .shift]).disabled(session.document == nil)
                            Menu("Snap To".localized) {
                                Toggle("Guides".localized, isOn: Binding(get: { session.snapToGuides }, set: { session.snapToGuides = $0 }))
                                    .disabled(session.document == nil)
                                Toggle("Grid".localized, isOn: Binding(get: { session.snapToGrid }, set: { session.snapToGrid = $0 }))
                                    .disabled(session.document == nil)
                                Toggle("Layers".localized, isOn: Binding(get: { session.snapToLayers }, set: { session.snapToLayers = $0 }))
                                    .disabled(session.document == nil)
                                Toggle("Document Bounds".localized, isOn: Binding(get: { session.snapToDocumentBounds },
                                                                        set: { session.snapToDocumentBounds = $0 }))
                                    .disabled(session.document == nil)
                            }
                            Divider()
                            Toggle("Lock Guides".localized, isOn: Binding(get: { session.locksGuides }, set: { session.locksGuides = $0 }))
                                .configuredKeyboardShortcut(";", modifiers: [.command, .option]).disabled(session.document == nil)
                            Button("Clear Guides".localized) { session.clearGuides() }
                                .disabled(!session.canClearGuides)
                        }
                    }
                    // ⌘H toggles the Move tool's transform controls instead of hiding the app, so Hide keeps its
                    // place in the app menu without the shortcut.
                    CommandGroup(replacing: .appVisibility) {
                        Button("Hide Compositor".localized) { NSApp.hide(nil) }
                        Button("Hide Others".localized) { NSApp.hideOtherApplications(nil) }
                            .configuredKeyboardShortcut("h", modifiers: [.command, .option])
                        Button("Show All".localized) { NSApp.unhideAllApplications(nil) }
                    }
                }
                CommandGroup(replacing: .pasteboard) {
                    // Canvas pixels when the canvas has focus; text fields keep their own editing.
                    // Cut, Copy and Paste check when chosen rather than through .disabled: what they depend on
                    // (the pasteboard, the copied pixels, the busy flag) isn't observed, so a disabled state could
                    // go stale — the first Paste after a Copy used to beep until something else refreshed the menu.
                    Button("Cut".localized) {
                        if NSApp.isEditingText { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                        else if session.selection != nil, session.canCopyPixels { Task { await session.cutSelection() } }
                        else { NSSound.beep() }
                    }
                        .configuredKeyboardShortcut("x")
                    Button("Copy".localized) {
                        if NSApp.isEditingText { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                        else if session.canCopyPixels || session.canCopyLayer { session.copySelection() }
                        else { NSSound.beep() }
                    }
                        .configuredKeyboardShortcut("c")
                    Button("Copy Merged".localized) { session.copyMergedSelection() }
                        .configuredKeyboardShortcut("c", modifiers: [.command, .shift]).disabled(!session.canCopyMerged)
                    Button("Paste".localized) {
                        // On the New canvas screen an image on the clipboard makes the canvas, even with a size field
                        // being typed in; a size copied as text still goes into the field.
                        if session.canPasteImageAsNewCanvas { Task { await session.pasteImageAsNewCanvas() } }
                        else if NSApp.isEditingText { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                        else if applicationDelegate.workspace.pasteCopiedLayer() { }
                        else if session.canPaste { session.paste() }
                        else { NSSound.beep() }
                    }
                        .configuredKeyboardShortcut("v")
                }
                CommandGroup(after: .pasteboard) {
                    Divider()
                    Button("Keyboard Shortcuts…".localized) { ShortcutSettings.shared.show() }
                    // Photoshop's fill shortcuts; in a text field they keep their text meaning.
                    Button("Fill with Foreground Color".localized) {
                        if NSApp.isEditingText {
                            NSApp.sendAction(#selector(NSResponder.deleteWordBackward(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .foreground) } }
                    }
                        .configuredKeyboardShortcut(.delete, modifiers: .option).disabled(!session.canEditPixels)
                    Button("Fill with Background Color".localized) {
                        if NSApp.isEditingText {
                            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .background) } }
                    }
                        .configuredKeyboardShortcut(.delete, modifiers: .command).disabled(!session.canEditPixels)
                    Button("Clear Selection Pixels".localized) { Task { await session.clearSelectedPixels() } }
                        .disabled(session.selection == nil || !session.canEditPixels)
                    Button("Content-Aware Fill…".localized) { session.beginFilter(.contentAwareFill) }
                        .configuredKeyboardShortcut(.delete, modifiers: .shift).disabled(!session.canContentAwareFill)
                }
                CommandMenu("Select".localized) {
                    // A field being edited keeps its own Select All: offer it to the responder chain
                    // first, which covers every kind of text control rather than NSTextView alone,
                    // and select the canvas only when nothing there wanted it.
                    Button("All".localized) {
                        if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) { return }
                        guard session.document != nil else { return }
                        session.selectAll()
                    }
                        // Never disabled: on macOS this menu item is what binds Cmd-A to selectAll:, so
                        // switching it off takes Select All away from every text field too. With no
                        // document and nothing being edited the action simply does nothing.
                        .configuredKeyboardShortcut("a")
                    Button("Deselect".localized) { session.deselect() }
                        .configuredKeyboardShortcut("d").disabled(session.selection == nil || !session.canEditSelection)
                    Button("Inverse".localized) { session.invertSelection() }
                        .configuredKeyboardShortcut("i", modifiers: [.command, .shift])
                        .disabled(session.selection == nil || !session.canEditSelection)
                    Button("Layer's Pixels".localized) {
                        if let id = session.activeLayerID { session.loadLayerSelection(layerID: id) }
                    }
                        .disabled(session.activeLayer?.asset == nil || !session.canEditSelection)
                    Button("Subject".localized) { Task { await session.selectSubject() } }
                        .configuredKeyboardShortcut("a", modifiers: [.command, .option])
                        .disabled(!session.canSelectSubject)
                    Button("Color Range…".localized) { session.beginColorRange() }
                        .disabled(!session.canSelectColorRange)
                    Button("Mask's Black Areas".localized) {
                        if let id = session.activeLayerID { session.loadMaskSelection(layerID: id) }
                    }
                        .disabled(session.activeLayer.flatMap { session.selectedMask(for: $0) } == nil || !session.canEditSelection)
                    Divider()
                    Button("Expand…".localized) { session.promptSelectionAmount(.expand) }
                        .disabled(!session.canModifySelection)
                    Button("Contract…".localized) { session.promptSelectionAmount(.contract) }
                        .disabled(!session.canModifySelection)
                    Button("Feather…".localized) { session.promptSelectionAmount(.feather) }
                        .disabled(!session.canModifySelection)
                }
                CommandMenu("Image".localized) {
                    Button("Curves…".localized) { session.beginFilter(.curves) }
                        .configuredKeyboardShortcut("m").disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button("Levels…".localized) { session.beginLevels() }
                        .configuredKeyboardShortcut("l").disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button("Hue/Saturation…".localized) { session.beginHueSaturation() }
                        .configuredKeyboardShortcut("u").disabled(!session.canAdjustColors)
                    ForEach([FilterKind.blackWhite, .colorBalance, .exposure, .gradientMap, .grain], id: \.self) { kind in
                        Button(kind.localizedName + "…") { session.beginFilter(kind) }
                            .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    }
                    Button(session.isMaskSelected ? "Invert Mask".localized : "Invert".localized) { Task { await session.invertPixels() } }
                        .configuredKeyboardShortcut("i")
                        .disabled(!session.canInvert)
                    Divider()
                    Button("Canvas Size…".localized) { Task { await applicationDelegate.projects.canvasSize() } }
                        .configuredKeyboardShortcut("c", modifiers: [.command, .option])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button("Image Size…".localized) { Task { await applicationDelegate.projects.imageSize() } }
                        .configuredKeyboardShortcut("i", modifiers: [.command, .option])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button("Trim…".localized) { Task { await applicationDelegate.projects.trim() } }
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Group {
                        Divider()
                        Button("Rotate Canvas 90° Clockwise".localized) { session.rotateCanvas(clockwise: true) }
                            .disabled(!session.canEditLayers)
                        Button("Rotate Canvas 90° Counterclockwise".localized) { session.rotateCanvas(clockwise: false) }
                            .disabled(!session.canEditLayers)
                        Button("Flip Canvas Horizontal".localized) { session.flipCanvas(horizontally: true) }
                            .disabled(!session.canEditLayers)
                        Button("Flip Canvas Vertical".localized) { session.flipCanvas(horizontally: false) }
                            .disabled(!session.canEditLayers)
                    }
                }
                CommandMenu("Filter".localized) {
                    Button(session.lastFilter.map { String.localizedStringWithFormat(NSLocalizedString("Last Filter: %@", comment: ""), $0.localizedName) } ?? "Last Filter".localized) {
                        Task { await session.repeatLastFilter() }
                    }
                        // ⌃⌘F, as in Photoshop; ⌘F is the command palette.
                        .configuredKeyboardShortcut("f", modifiers: [.command, .control]).disabled(!session.canRepeatLastFilter)
                    Divider()
                    // Those that can also be adjustment layers, in that menu's order, then the rest.
                    let layered = AdjustmentKind.filters.compactMap(\.filterKind)
                    let others = FilterKind.allCases.filter { $0 != .contentAwareFill && !$0.isImageAdjustment && !layered.contains($0) }
                    ForEach(layered, id: \.self) { filterMenuItem($0) }
                    Divider()
                    ForEach(others, id: \.self) { filterMenuItem($0) }
                }
                CommandMenu("Layer".localized) {
                    Menu("New Adjustment Layer".localized) {
                        // The Image menu's adjustments, then the Filter menu's filters.
                        ForEach(AdjustmentKind.imageAdjustments, id: \.self) { kind in
                            Button(kind.localizedName + (kind.isEditable ? "…" : "")) { session.addAdjustment(kind) }
                        }
                        Divider()
                        ForEach(AdjustmentKind.filters, id: \.self) { kind in
                            Button(kind.rawValue + "…") { session.addAdjustment(kind) }
                        }
                    }.disabled(!session.canEditLayers || session.document == nil)
                    Button("Edit Adjustment…".localized) {
                        session.adjustmentEditingID = session.activeLayerID
                    }.disabled(!session.canEditLayers || session.activeLayer?.adjustment == nil)
                    Divider()
                    Button(session.canTransformSelection ? "Transform Selection".localized : "Transform Layer".localized) { session.transformCommand() }
                        .configuredKeyboardShortcut("t").disabled(!session.canTransform && !session.canTransformSelection)
                    Button(session.selection == nil ? "Duplicate Layer".localized : "Layer via Copy".localized) { session.layerViaCopy() }
                        .configuredKeyboardShortcut("j").disabled(!session.canCopyPixels && !(session.selection == nil && session.canEditLayers && session.activeLayer != nil))
                    Divider()
                    Button(session.activeLayer?.maskSourceID == nil ? "Create Clipping Mask".localized : "Release Clipping Mask".localized) {
                        if let id = session.activeLayerID { session.toggleClippingMask(id) }
                    }
                    .configuredKeyboardShortcut("g", modifiers: [.command, .option])
                    .disabled(session.activeLayerID.map { !session.canToggleClippingMask($0) } ?? true)
                    Divider()
                    Button("Group Selected Layers".localized) { session.groupSelectedLayers() }
                        .configuredKeyboardShortcut("g").disabled(!session.canEditLayers)
                    Button("Ungroup Layers".localized) { session.ungroupLayers() }
                        .configuredKeyboardShortcut("g", modifiers: [.command, .shift]).disabled(!session.canUngroupLayers)
                    Button("Move Out of Folder".localized) { session.moveActiveLayerOutOfGroup() }
                        .disabled(!session.canEditLayers || session.activeLayer?.parentID == nil)
                    Button("New Blank Layer".localized) { session.addBlankLayer() }
                        .configuredKeyboardShortcut("n", modifiers: [.command, .shift]).disabled(!session.canEditLayers)
                    Button("Rename Layer…".localized) { session.renamingLayerID = session.activeLayerID }
                        .disabled(!session.canEditLayers || session.activeLayer == nil)
                    Button(session.activeLayer?.isVisible == false ? "Show Layer".localized : "Hide Layer".localized) {
                        if let id = session.activeLayerID { session.toggleLayerVisibility(id) }
                    }.disabled(!session.canEditLayers || session.activeLayer == nil)
                    Divider()
                    Button("Move Layer Up".localized) { session.moveActiveLayer(by: 1) }
                        .configuredKeyboardShortcut("]").disabled(!session.canMoveActiveLayer(by: 1))
                    Button("Move Layer Down".localized) { session.moveActiveLayer(by: -1) }
                        .configuredKeyboardShortcut("[").disabled(!session.canMoveActiveLayer(by: -1))
                    Group {
                        Button(session.mergeTitle) { session.mergeLayers() }
                            .configuredKeyboardShortcut("e").disabled(!session.canMergeLayers)
                        Divider()
                        Button("Flip Layer Horizontal".localized) { session.flipLayers(horizontally: true) }
                            .disabled(!session.canTransform)
                        Button("Flip Layer Vertical".localized) { session.flipLayers(horizontally: false) }
                            .disabled(!session.canTransform)
                    }
                    Divider()
                    Button(session.selectedEffect != nil ? "Delete " + session.selectedEffect!.kind.rawValue : session.isMaskSelected && session.activeLayer.flatMap({ session.selectedMask(for: $0) }) != nil ? "Delete Layer Mask" : session.selectedLayerIDs.count > 1 ? "Delete Layers" : "Delete Layer") {
                        session.deleteLayerOrMask()
                    }
                        .disabled(!session.canEditLayers || session.activeLayer == nil)
                }
            }
    }

    /// View › CMYK › Profile › Load Profile: a CMYK ICC profile picked from anywhere, kept and chosen.
    private func loadCMYKProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
        panel.message = "Choose a CMYK ICC profile, such as the one your printer gave you".localized
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { session.proofProfile = try CMYK.load(url) }
        catch { session.importError = error.localizedDescription }
    }
}

extension NSApplication {
    /// Whether the keyboard is in a text field, so Cut, Copy, Paste, Undo and the fill shortcuts act on its text rather
    /// than the canvas. A Save or Open panel counts: the sandbox runs it in another process, so its file name field
    /// isn't a text view of ours, and copying or pasting a name there reached the canvas instead.
    var isEditingText: Bool { keyWindow?.firstResponder is NSTextView || keyWindow is NSSavePanel }
}
