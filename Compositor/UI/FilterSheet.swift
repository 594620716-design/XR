import AppKit
import SwiftUI

/// The open filter's panel: its settings, Preview, and Cancel / OK.
struct FilterSheet: View {
    @Bindable var session: EditorSession
    private var edit: FilterEdit? { session.filterEdit }
    private var settings: FilterSettings { edit?.settings ?? FilterSettings() }
    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateFilter(value, preview: edit?.preview ?? true)
    }

    private var isCameraRaw: Bool { edit?.kind == .cameraRaw }
    /// The widest slider title in the panel, so every slider starts and ends in the same place.
    @State private var labelWidth: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch edit?.kind ?? .gaussianBlur {
            case .curves:
                CurvesControls(settings: Binding(get: { settings.curves }, set: { new in update { $0.curves = new } }))
            case .exposure:
                control("Exposure".localized, \.exposure.exposure, range: ExposureSettings.exposureRange, unit: "", decimals: 2, logarithmic: false)
                control("Offset".localized, \.exposure.offset, range: ExposureSettings.offsetRange, unit: "", decimals: 4, logarithmic: false)
                control("Gamma".localized, \.exposure.gamma, range: ExposureSettings.gammaRange, unit: "", decimals: 2, logarithmic: true)
            case .gradientMap:
                GradientMapControls(settings: Binding(get: { settings.gradientMap }, set: { new in update { $0.gradientMap = new } }),
                                    pick: { session.openGradientMapColorPicker(highlights: $0) })
            case .blackWhite:
                // Each slider says how bright that family of colors becomes, as Photoshop's do.
                control("Reds".localized, \.blackWhite.reds, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false, track: .luminance(0))
                control("Yellows".localized, \.blackWhite.yellows, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false, track: .luminance(60))
                control("Greens".localized, \.blackWhite.greens, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false, track: .luminance(120))
                control("Cyans".localized, \.blackWhite.cyans, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false, track: .luminance(180))
                control("Blues".localized, \.blackWhite.blues, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false, track: .luminance(240))
                control("Magentas".localized, \.blackWhite.magentas, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false, track: .luminance(300))
                Toggle("Tint".localized, isOn: flag(\.blackWhite.tint))
                    .help("Color the result while keeping its tones, for a sepia or a cyanotype".localized)
                if settings.blackWhite.tint {
                    control("Hue".localized, \.blackWhite.tintHue, range: 0...360, unit: "°", decimals: 0, logarithmic: false, track: .plain)
                    control("Saturation".localized, \.blackWhite.tintSaturation, range: 0...100, unit: "%", decimals: 0, logarithmic: false,
                            track: .saturation(settings.blackWhite.tintHue))
                }
            case .cameraRaw:
                CameraRawControls(session: session)
                    .frame(maxHeight: .infinity, alignment: .top)
            case .colorBalance:
                Text("Shadows").font(.headline)
                control("Cyan / Red".localized, \.colorBalance.shadowCyanRed, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false, track: Self.cyanRedTrack)
                control("Magenta / Green".localized, \.colorBalance.shadowMagentaGreen, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false, track: Self.magentaGreenTrack)
                control("Yellow / Blue".localized, \.colorBalance.shadowYellowBlue, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false, track: Self.yellowBlueTrack)
                Text("Midtones").font(.headline)
                control("Cyan / Red".localized, \.colorBalance.midCyanRed, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false, track: Self.cyanRedTrack)
                control("Magenta / Green".localized, \.colorBalance.midMagentaGreen, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false, track: Self.magentaGreenTrack)
                control("Yellow / Blue".localized, \.colorBalance.midYellowBlue, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false, track: Self.yellowBlueTrack)
                Text("Highlights").font(.headline)
                control("Cyan / Red".localized, \.colorBalance.highlightCyanRed, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false, track: Self.cyanRedTrack)
                control("Magenta / Green".localized, \.colorBalance.highlightMagentaGreen, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false, track: Self.magentaGreenTrack)
                control("Yellow / Blue".localized, \.colorBalance.highlightYellowBlue, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false, track: Self.yellowBlueTrack)
                Toggle("Preserve Luminosity".localized, isOn: flag(\.colorBalance.preserveLuminosity))
                    .help("Put each pixel's brightness back afterwards, so only the color moves".localized)
            case .grain:
                control("Amount".localized, \.grain.amount, range: GrainSettings.amountRange, unit: "", decimals: 0, logarithmic: false)
                control("Size".localized, \.grain.size, range: GrainSettings.sizeRange, unit: "px", decimals: 1, logarithmic: true)
                control("Roughness".localized, \.grain.roughness, range: GrainSettings.roughnessRange, unit: "", decimals: 0, logarithmic: false)
            case .removeBackground:
                Text("Hide the background behind a layer mask, keeping the foreground subjects. The pixels stay, so the background can be painted back at any time.")
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Quality".localized, selection: Binding(get: { settings.backgroundQuality },
                                                     set: { new in update { $0.backgroundQuality = new } })) {
                    ForEach(BackgroundQuality.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Basic is quick; Advanced refines the mask against the layer's own detail, for hair and fur".localized)
                if settings.backgroundQuality == .advanced {
                    control("Refine".localized, \.refineEdges, range: 0...40, unit: "px", decimals: 0, logarithmic: false)
                        .help("Pull the mask onto the image's own edges, which recovers hair and fur".localized)
                    control("Contrast".localized, \.matteContrast, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                        .help("Clear the haze that leaves background showing through thin areas".localized)
                    control("Shift Edge".localized, \.shiftEdge, range: -10...10, unit: "px", decimals: 0, logarithmic: false)
                        .help("Shrink the mask to drop the rim of background color around the subject, or grow it".localized)
                }
            case .contentAwareFill:
                Text("Fill the selection using surrounding pixels from this layer.")
                    .fixedSize(horizontal: false, vertical: true)
            case .gaussianBlur:
                control("Radius".localized, \.radius, range: 0.1...250, unit: "px", decimals: 1, logarithmic: true)
                Toggle("Preserve Transparency".localized, isOn: flag(\.preserveTransparency))
                    .help("Blur only the colors, keeping the layer's outline and transparency as they are".localized)
            case .progressiveBlur:
                Text("Click and drag two points on canvas")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("Shape")
                    Picker("Shape".localized, selection: flag(\.progressiveRadial)) {
                        Text("Linear").tag(false)
                        Text("Radial").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Linear blurs along the line; Radial keeps the start sharp and blurs outwards".localized)
                }
                control("From".localized, \.progressiveFrom, range: 0...250, unit: "px", decimals: 1, logarithmic: false)
                    .help("The blur where the line starts".localized)
                control("To".localized, \.progressiveTo, range: 0...250, unit: "px", decimals: 1, logarithmic: false)
                    .help("The blur where the line ends, and past it".localized)
                Toggle("Invert".localized, isOn: flag(\.progressiveInverted))
                    .help("Swap From and To: blur the start and sharpen toward the end".localized)
            case .rgbSplit:
                HStack(spacing: 10) {
                    Text("Shape")
                    Picker("Shape".localized, selection: flag(\.rgbSplitRadial)) {
                        Text("Linear").tag(false)
                        Text("Radial").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Linear splits along one direction; Radial splits outwards from a center, sharp there")
                }
                if settings.rgbSplitRadial {
                    Text("Click or drag on the canvas to move the center")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                control("Distance".localized, \.rgbSplitDistance, range: 0...200, unit: "px", decimals: 0, logarithmic: false)
                    .help("How far the colors spread apart, red one way and blue the other")
                control("Blur".localized, \.rgbSplitBlur, range: 0...400, unit: "px", decimals: 0, logarithmic: false)
                    .help("Smear the split into streaks along its direction")
                if !settings.rgbSplitRadial {
                    control("Angle".localized, \.rgbSplitAngle, range: -180...180, unit: "°", decimals: 0, logarithmic: false)
                        .help("Which way the colors spread")
                }
            case .lensEffects:
                lensEffectsControls
            case .motionBlur:
                control("Angle".localized, \.angle, range: -90...90, unit: "°", decimals: 0, logarithmic: false)
                control("Distance".localized, \.distance, range: 1...2000, unit: "px", decimals: 0, logarithmic: true)
            case .addNoise:
                control("Amount".localized, \.amount, range: 0.1...400, unit: "%", decimals: 1, logarithmic: true)
                HStack(spacing: 10) {
                    Text("Distribution")
                    Picker("Distribution".localized, selection: flag(\.gaussian)) {
                        Text("Uniform").tag(false)
                        Text("Gaussian").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                Toggle("Monochromatic".localized, isOn: flag(\.monochromatic))
            case .dither:
                ditherControls
            case .scanlines:
                scanlinesControls
            case .vignette:
                HStack(spacing: 8) {
                    Text("Color").frame(width: 95, alignment: .leading)
                    Button { session.openVignetteColorPicker() } label: {
                        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                        shape.fill(Color(.sRGB, red: settings.vignetteColor.red,
                                         green: settings.vignetteColor.green, blue: settings.vignetteColor.blue))
                            .overlay { shape.inset(by: 1).strokeBorder(.white, lineWidth: 1.5) }
                            .overlay { shape.strokeBorder(.black, lineWidth: 1) }
                            .frame(width: 24, height: 24)
                            .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                    .help("Choose the vignette color".localized)
                    Spacer()
                }
                control("Amount".localized, \.vignetteAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                    .help("Blend the chosen color into the edges while keeping the center unchanged".localized)
                control("Midpoint".localized, \.vignetteMidpoint, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                control("Roundness".localized, \.vignetteRoundness, range: -100...100, unit: "", decimals: 0, logarithmic: false)
                control("Feather".localized, \.vignetteFeather, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                control("Highlights".localized, \.vignetteHighlights, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                    .help("Protect bright areas near the edge".localized)
            case .bloomGlow:
                control("Amount".localized, \.bloomAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                control("Radius".localized, \.bloomRadius, range: 1...150, unit: "px", decimals: 0, logarithmic: true)
            case .tonalContrast:
                control("Amount".localized, \.tonalAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                control("Shadows".localized, \.tonalShadows, range: -100...100, unit: "%", decimals: 0, logarithmic: false)
                control("Midtones".localized, \.tonalMidtones, range: -100...100, unit: "%", decimals: 0, logarithmic: false)
                control("Highlights".localized, \.tonalHighlights, range: -100...100, unit: "%", decimals: 0, logarithmic: false)
                control("Radius".localized, \.tonalRadius, range: 1...100, unit: "px", decimals: 0, logarithmic: true)
            case .lensCorrection:
                control("Remove Distortion".localized, \.distortion, range: -100...100, unit: "", decimals: 0, logarithmic: false)
                Text("Positive straightens lines that bow outward (barrel); negative, lines that bow inward (pincushion).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Preview".localized, isOn: Binding(get: { edit?.preview ?? true },
                                            set: { session.updateFilter(settings, preview: $0) }))
            if let error = edit?.previewError {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if session.adjustmentOriginal == nil && session.selection != nil {
                Text("Limited to the selection").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Cancel".localized) { session.cancelFilter() }.configuredNativeShortcut(.escape)
                // The utility beside the effect: the layer's own channels, unshifted, as layers for Export As › Channel Pack.
                // Not on an RGB Split adjustment layer, which has no pixels of its own to split.
                if edit?.kind == .rgbSplit, session.adjustmentOriginal == nil {
                    Button("Split to Layers") {
                        session.cancelFilter()
                        session.splitChannels()
                    }
                    .help("Split the layer's original channels into four grayscale layers, Red, Green, Blue and Alpha, for Export As › Channel Pack. Color under fully transparent pixels can't be recovered")
                }
                Spacer()
                // While the preview is being worked out (Remove Background's mask, Content-Aware Fill) OK waits, so
                // the panel says what it is waiting for rather than showing a disabled button and nothing else.
                // Only the slow filters say so: a quick preview (Dither, a blur) toggling this at every slider step would
                // make the panel flicker as it grows and shrinks.
                if edit?.committing == true || (edit?.preparing == true && edit?.kind.isAutomatic == true) {
                    ProgressView().controlSize(.small)
                    Text(edit?.committing == true ? "Applying…" : "Working…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("OK".localized) { Task { await session.commitFilter() } }
                    .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
                    .disabled(edit?.kind.isAutomatic == true && (edit?.preparing == true || edit?.previewError != nil))
            }
        }
        .onPreferenceChange(LabelWidthKey.self) { labelWidth = max(60, $0) }
        .padding(24)
        .frame(width: isCameraRaw ? FloatingPanelController.dockedWidth : 380)
        .frame(maxHeight: isCameraRaw ? .infinity : nil, alignment: .top)
        .fixedSize(horizontal: false, vertical: !isCameraRaw)

        .disabled(edit?.committing == true)
        // Filter colors preview live while the app's color picker is open.
        .onChange(of: session.colorPicker?.color) { _, _ in
            session.previewGradientMapColor()
            session.previewVignetteColor()
            session.previewDitherColor()
        }
    }

    @ViewBuilder private var ditherControls: some View {
        let dither = settings.dither
        Picker("Style".localized, selection: Binding(get: { dither.style }, set: { new in update { $0.dither.style = new } })) {
            ForEach(DitherStyle.groups.indices, id: \.self) { group in
                if group > 0 { Divider() }
                ForEach(DitherStyle.groups[group], id: \.self) { Text($0.localizedName).tag($0) }
            }
        }
        if dither.style.usesPixelSize {
        control("Pixel Size".localized, \.dither.pixelSize, range: DitherSettings.pixelSizeRange, unit: "px", decimals: 0, logarithmic: false)
            .help("Make each dithered pixel this many pixels across, for a chunky old-screen look".localized)
        }
        if dither.style == .ascii {
            control("Text Size".localized, \.dither.textSize, range: DitherSettings.textSizeRange, unit: "px", decimals: 0, logarithmic: false)
                .help("The height of each line of characters".localized)
        }
        if dither.style.isHalftone {
            control("Cell Size".localized, \.dither.cellSize, range: DitherSettings.cellSizeRange, unit: "px", decimals: 0, logarithmic: false)
        }
        if dither.style.isHalftone {
            control("Angle".localized, \.dither.angle, range: -90...90, unit: "°", decimals: 0, logarithmic: false)
        }
        if dither.style == .ascii {
            HStack(spacing: 10) {
                Text("Characters")
                TextField("Characters", text: Binding(get: { dither.characters }, set: { new in update { $0.dither.characters = new } }))
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
            }
            .help("The characters to draw with, in any order: each spot gets the one whose ink best matches its tone".localized)
        }
        if dither.style.hasTones {
            control("Tones".localized, \.dither.levels, range: DitherSettings.levelsRange, unit: "", decimals: 0, logarithmic: false)
                .help("Tones per channel: 2 is pure black and white".localized)
        }
        if dither.style.diffuses {
            control("Diffusion".localized, \.dither.diffusion, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                .help("How much of each pixel's error spreads to its neighbors. Less gives flatter areas".localized)
        }
        control("Density".localized, \.dither.density, range: -100...100, unit: "", decimals: 0, logarithmic: false)
            .help("More ink (darker) or less before dithering".localized)
        control("Contrast".localized, \.dither.contrast, range: -100...100, unit: "", decimals: 0, logarithmic: false)
        // A menu, like Style: the three choices as segments are wider than the panel, which then flips between
        // squeezing the row and wrapping it, resizing itself at every slider step.
        Picker("Colors".localized, selection: Binding(get: { dither.colors }, set: { new in update { $0.dither.colors = new } })) {
            ForEach(DitherColors.allCases, id: \.self) { Text($0.localizedName).tag($0) }
        }
        .fixedSize()
        if dither.colors == .twoColors {
            HStack(spacing: 8) {
                Text("Dark")
                swatch(dither.dark, help: "Choose the dark color") { session.openDitherColorPicker(light: false) }
                Text("Light").padding(.leading, 10)
                swatch(dither.light, help: "Choose the light color") { session.openDitherColorPicker(light: true) }
                Spacer()
            }
        }
        if dither.pixelSize > 1, dither.style.usesPixelSize {
            Picker("Pixel Shape".localized, selection: Binding(get: { dither.pixelShape }, set: { new in update { $0.dither.pixelShape = new } })) {
                ForEach(DitherPixelShape.allCases, id: \.self) { Text($0.localizedName).tag($0) }
            }
            .fixedSize()
            .help("Draw each chunky pixel as a solid square, or as a round dot like a dot-matrix screen".localized)
        }
        if dither.style.drawsMarks {
            Toggle("Light on Dark".localized, isOn: flag(\.dither.lightOnDark))
                .help("Draw the marks for the light tones on the dark color, like a glowing screen".localized)
        }
    }

    @ViewBuilder private var scanlinesControls: some View {
        let lines = settings.scanlines
        control("Line Spacing".localized, \.scanlines.lineSpacing, range: ScanlinesSettings.lineSpacingRange, unit: "px", decimals: 0, logarithmic: false)
            .help("How far apart the screen's lines are".localized)
        control("Thickness".localized, \.scanlines.thickness, range: 5...100, unit: "%", decimals: 0, logarithmic: false)
            .help("How much of the gap a bright line fills; dimmer parts draw it thinner".localized)
        control("Glow".localized, \.scanlines.glow, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
            .help("Light blooming around the lines, like a CRT's phosphors".localized)
        control("Dots".localized, \.scanlines.dots, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
            .help("Break the lines into beads where the picture is darker than this, blending into solid lines where it's brighter".localized)
        control("Displace".localized, \.scanlines.displace, range: ScanlinesSettings.displaceRange, unit: "px", decimals: 0, logarithmic: false)
            .help("Lift the lines where the picture is bright, or lower them when negative, so they swell into its shapes".localized)
        control("Smoothness".localized, \.scanlines.smoothness, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
            .help("How far the brightness is smoothed before it displaces the lines, from sharp ridges to rounded hills".localized)
        control("Threshold".localized, \.scanlines.threshold, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
            .help("Draw no line where the picture is darker than this, leaving the screen dark".localized)
        control("Wobble".localized, \.scanlines.wobble, range: ScanlinesSettings.wobbleRange, unit: "px", decimals: 0, logarithmic: false)
            .help("Make the lines waver sideways down the screen, like a CRT losing sync".localized)
        control("Color Split".localized, \.scanlines.split, range: ScanlinesSettings.splitRange, unit: "px", decimals: 0, logarithmic: false)
            .help("Move the red and blue apart, for colored fringes on the lines".localized)
        control("Density".localized, \.scanlines.density, range: -100...100, unit: "", decimals: 0, logarithmic: false)
            .help("Darker or lighter before the lines are drawn".localized)
        control("Contrast".localized, \.scanlines.contrast, range: -100...100, unit: "", decimals: 0, logarithmic: false)
        control("Black Level".localized, \.scanlines.blackLevel, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
            .help("How bright the lines are where the picture is black, so they show even over black".localized)
        Picker("Colors".localized, selection: Binding(get: { lines.colors }, set: { new in update { $0.scanlines.colors = new } })) {
            ForEach(DitherColors.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
        if lines.colors == .twoColors {
            HStack(spacing: 8) {
                Text("Dark")
                swatch(lines.dark, help: "Choose the screen's color") { session.openDitherColorPicker(light: false) }
                Text("Light").padding(.leading, 10)
                swatch(lines.light, help: "Choose the lines' color") { session.openDitherColorPicker(light: true) }
                Spacer()
            }
        }
    }

    private func swatch(_ color: AdjustmentColor, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape.fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue))
                .overlay { shape.inset(by: 1).strokeBorder(.white, lineWidth: 1.5) }
                .overlay { shape.strokeBorder(.black, lineWidth: 1) }
                .frame(width: 24, height: 24)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Lens Effects: which effect, then its own settings.
    @ViewBuilder private var lensEffectsControls: some View {
        HStack(spacing: 10) {
            Text("Effect")
            Picker("Effect", selection: Binding(get: { settings.lens.effect }, set: { new in update { $0.lens.effect = new } })) {
                ForEach(LensEffect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
        switch settings.lens.effect {
        case .anamorphicFlare:
            control("Amount".localized, \.lens.flareAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
            control("Length", \.lens.flareLength, range: 1...100, unit: "%", decimals: 0, logarithmic: false)
                .help("How far the streaks reach across the picture")
            control("Threshold".localized, \.lens.threshold, range: 50...100, unit: "%", decimals: 0, logarithmic: false)
                .help("How bright a light has to be to flare; near 100, only the biggest, brightest spots")
            control("Blue".localized, \.lens.flareBlue, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                .help("How far the lens's coatings turn each streak blue along its length; none keeps the light's own color")
        case .starburst:
            control("Amount".localized, \.lens.starAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
            control("Length", \.lens.starLength, range: 2...40, unit: "%", decimals: 0, logarithmic: false)
                .help("How far the spikes reach")
            control("Threshold".localized, \.lens.threshold, range: 50...100, unit: "%", decimals: 0, logarithmic: false)
                .help("How bright a light has to be to sparkle; near 100, only the biggest, brightest spots")
            control("Angle".localized, \.lens.starAngle, range: -180...180, unit: "°", decimals: 0, logarithmic: false)
            HStack(spacing: 10) {
                Text("Points")
                Picker("Points", selection: Binding(get: { settings.lens.starPoints }, set: { new in update { $0.lens.starPoints = new } })) {
                    ForEach(LensEffectSettings.starPointChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("How many spikes each light has, as the lens's aperture blades make them")
            }
        case .mist:
            control("Strength".localized, \.lens.mistStrength, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                .help("How much light scatters: a soft halo around bright areas, and gently lifted shadows")
            control("Size".localized, \.lens.mistSize, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                .help("How far the light spreads")
        case .prism:
            control("Amount".localized, \.lens.prismAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
            control("Copies", \.lens.prismCopies, range: 1...8, unit: "", decimals: 0, logarithmic: false)
                .help("How many times the picture echoes, each fainter")
            control("Offset".localized, \.lens.prismOffset, range: 0...50, unit: "%", decimals: 0, logarithmic: false)
                .help("How far apart the copies are")
            control("Angle".localized, \.lens.prismAngle, range: -180...180, unit: "°", decimals: 0, logarithmic: false)
                .help("Which way the copies step")
            control("Blur".localized, \.lens.prismBlur, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                .help("Soften the copies, more the farther they're pushed")
            HStack(spacing: 10) {
                Text("Direction")
                Picker("Direction", selection: Binding(get: { settings.lens.prismBothWays }, set: { new in update { $0.lens.prismBothWays = new } })) {
                    Text("One Way").tag(false)
                    Text("Both Ways").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Copies to one side of the picture, or out to both")
            }
        case .bokeh:
            control("Size".localized, \.lens.bokehRadius, range: LensEffectSettings.bokehSizes, unit: "%", decimals: 1, logarithmic: false)
                .help("How far out of focus: the size of each disc")
            control("Brightness", \.lens.bokehBrightness, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                .help("How brightly lights open into discs")
            control("Ring", \.lens.bokehRing, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                .help("Light gathered at each disc's rim, as some lenses draw it")
            HStack(spacing: 10) {
                Text("Shape")
                Picker("Shape".localized, selection: Binding(get: { settings.lens.bokehShape }, set: { new in update { $0.lens.bokehShape = new } })) {
                    ForEach(BokehShape.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("The aperture's shape: round wide open, a hexagon of blades, an anamorphic oval, or a cat's eye toward the edges")
            }
        }
    }

    private func flag(_ key: WritableKeyPath<FilterSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }

    /// The setting put back to its filter's default, as a double-click on a colored slider does.
    static func resetting(_ key: WritableKeyPath<FilterSettings, Double>, in settings: FilterSettings) -> FilterSettings {
        var value = settings
        value[keyPath: key] = FilterSettings()[keyPath: key]
        return value
    }

    static let cyanRedTrack = CameraRawSliderTrack.opposing(NSColor(srgbRed: 0.10, green: 0.72, blue: 0.80, alpha: 1),
                                                            NSColor(srgbRed: 0.86, green: 0.18, blue: 0.20, alpha: 1))
    static let magentaGreenTrack = CameraRawSliderTrack.opposing(NSColor(srgbRed: 0.80, green: 0.22, blue: 0.70, alpha: 1),
                                                                 NSColor(srgbRed: 0.24, green: 0.70, blue: 0.30, alpha: 1))
    static let yellowBlueTrack = CameraRawSliderTrack.opposing(NSColor(srgbRed: 0.95, green: 0.82, blue: 0.18, alpha: 1),
                                                               NSColor(srgbRed: 0.22, green: 0.40, blue: 0.92, alpha: 1))

    /// A slider plus an exact field. Logarithmic sliders give the small values used most most of the travel.
    /// A colored track draws the slider as Camera Raw's, where a double-click on the title or knob resets it.
    private func control(_ title: String, _ key: WritableKeyPath<FilterSettings, Double>, range: ClosedRange<Double>,
                         unit: String, decimals: Int, logarithmic: Bool, track: CameraRawSliderTrack? = nil) -> some View {
        let step = pow(10, Double(decimals))
        let reset = { update { $0 = Self.resetting(key, in: $0) } }
        return HStack(spacing: 10) {
            Text(title).fixedSize()
                .background(GeometryReader { Color.clear.preference(key: LabelWidthKey.self, value: $0.size.width) })
                .frame(width: labelWidth, alignment: .leading)
                .onTapGesture(count: 2) { if track != nil { reset() } }
                .scrubbable(sensitivity: 1 / step,
                            value: Binding(get: { settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } }),
                            range: range)
            if let track {
                CameraRawSlider(value: settings[keyPath: key], range: range, track: track,
                                help: "\(title). Double-click to reset.",
                                onChange: { value in update { $0[keyPath: key] = (value * step).rounded() / step } },
                                onReset: reset)
            } else {
                Slider(value: Binding(get: { logarithmic ? log(settings[keyPath: key]) : settings[keyPath: key] },
                                      set: { value in update { $0[keyPath: key] = ((logarithmic ? exp(value) : value) * step).rounded() / step } }),
                       in: logarithmic ? log(range.lowerBound)...log(range.upperBound) : range)
            }
            TextField(title, value: Binding(get: { settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } }),
                      format: .number.precision(.fractionLength(0...decimals)))
                .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .unitSuffix(unit)
        }
    }
}

/// Gradient Map's two colors, the gradient they make, and Reverse. The colors are swatches like the
/// tool rail's, and open the app's own color picker.
struct GradientMapControls: View {
    @Binding var settings: GradientMapSettings
    /// Opens the color picker on an end: false for Shadows, true for Highlights.
    let pick: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let ends = settings.ends
            LinearGradient(colors: [color(ends.dark), color(ends.light)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.35)) }
                .accessibilityHidden(true)
            HStack(spacing: 20) {
                swatch("Shadows".localized, settings.shadows) { pick(false) }
                swatch("Highlights".localized, settings.highlights) { pick(true) }
                Spacer()
            }
            Toggle("Reverse".localized, isOn: $settings.reversed)
        }
    }

    private func color(_ value: AdjustmentColor) -> Color { Color(.sRGB, red: value.red, green: value.green, blue: value.blue) }

    private func swatch(_ title: String, _ value: AdjustmentColor, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return HStack(spacing: 8) {
            Button(action: action) {
                shape
                    .fill(color(value))
                    .overlay { shape.inset(by: 1).strokeBorder(.white, lineWidth: 1.5) }
                    .overlay { shape.strokeBorder(.black, lineWidth: 1) }
                    .frame(width: 24, height: 24)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .help("Choose the \(title.lowercased()) color")
            .accessibilityLabel("\(title) color")
            Text(title)
        }
    }
}

private struct LabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
