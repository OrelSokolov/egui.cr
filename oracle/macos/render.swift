// macOS widget oracle renderer — headless AppKit → PNG.
//
// One flat sheet per widget (see plans/macos-oracle-gallery.md):
// 480×160 @1×, light aqua appearance, no window chrome, no focus
// rings, no hover. Controls are hosted in an offscreen borderless
// window (needed for accurate rendering of view-based controls),
// then captured with cacheDisplay into a bitmap.
//
//   cd oracle/macos && make   # → png/<sheet>.png

import AppKit

let sheetSize = NSSize(width: 480, height: 160)

@main
struct RenderOracle {
    // Sheets whose control outgrows the standard 40pt gallery row
    // (textarea is a 56pt multiline box) get their own row height.
    static let galleryRowH: [String: CGFloat] = ["textarea": 64.0]

    static func main() {
        let app = NSApplication.shared
        // `gallery` argument: a live visible window with every sheet
        // stacked up (the egui.cr twin is examples/macos_gallery.cr).
        // Without it: headless PNG rendering into png/.
        let gallery = CommandLine.arguments.contains("gallery")
        // .accessory: no Dock icon, but the app CAN activate — key
        // windows render controls in their active state (a window
        // that was never key draws everything in the desaturated
        // inactive look, losing accent colors).
        app.setActivationPolicy(gallery ? .regular : .accessory)
        app.activate(ignoringOtherApps: true)

        // Always light aqua, independent of the user's system theme.
        let aqua = NSAppearance(named: .aqua)

        let outDir = URL(fileURLWithPath: "png")
        try? FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true)

        // name → controls factory, laid out on a plain flipped view
        let sheets: [(String, (HostView) -> Void)] = [
            ("button", addButtons),
            ("checkbox", addCheckboxes),
            ("radio", addRadios),
            ("switch", addSwitches),
            ("text_field", addTextFields),
            ("search_field", addSearchFields),
            ("slider", addSliders),
            ("segmented", addSegmented),
            ("popup", addPopup),
            ("progress", addProgress),
            ("stepper", addStepper),
            ("label", addLabels),
            // Tier 4: dialog extras (each needs an egui.cr twin —
            // scripts/make_macos_oracle_shots.cr).
            ("separator", addSeparator),
            ("link", addLink),
            ("secure_field", addSecureField),
            ("textarea", addTextarea),
            // Tier 5: disclosure (settings triangles), color well,
            // date/time pickers (compact stepper style, POSIX locale
            // so the text stays numeric/ASCII like the egui twins).
            ("disclosure", addDisclosure),
            ("color_well", addColorWells),
            ("date_picker", addDatePicker),
            ("time_picker", addTimePicker),
        ]

        if gallery {
            runGallery(app: app, aqua: aqua, sheets: sheets)
            app.run()
            return
        }

        // Run inside the real event loop: activation only lands while
        // NSApp.run is turning (probe-verified — without it the app
        // never activates and every control renders in the
        // desaturated inactive look, losing accent colors).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            app.activate(ignoringOtherApps: true)
            captureAll(sheets: sheets, outDir: outDir, aqua: aqua)
            app.terminate(nil)
        }
        app.run()
    }

    private static func captureAll(sheets: [(String, (HostView) -> Void)],
                                   outDir: URL, aqua: NSAppearance?) {
        for (name, populate) in sheets {
            let window = offscreenWindow(aqua: aqua)
            let host = window.contentView! as! HostView
            populate(host)
            window.layoutIfNeededIfNeeded()
            // Park the window far off-screen and make it key: active
            // control state, nothing visible flashing on the display.
            window.setFrameOrigin(NSPoint(x: -32000, y: -32000))
            window.makeKeyAndOrderFront(nil)
            window.layoutIfNeededIfNeeded()
            let png = host.capture()
            try? png.write(to: outDir.appendingPathComponent("\(name).png"))
            print("png/\(name).png \(sheetSize.width)x\(sheetSize.height)" +
                  " key=\(window.isKeyWindow)")
            window.orderOut(nil)
            window.isReleasedWhenClosed = false
            window.close()
        }
    }

    // --- live gallery -----------------------------------------------------

    // One visible window with every sheet stacked as a row plus a
    // small caption — run side by side with examples/macos_gallery.cr.
    private static func runGallery(app: NSApplication,
                                   aqua: NSAppearance?,
                                   sheets: [(String, (HostView) -> Void)]) {
        let margin: CGFloat = 16.0
        let rowHs = sheets.map { galleryRowH[$0.0] ?? 40.0 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520,
                                height: margin * 2 + rowHs.reduce(0, +)),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = aqua
        window.title = "macOS Widget Gallery (native oracle)"
        window.contentView = HostView(frame: NSRect(
            x: 0, y: 0, width: 520,
            height: margin * 2 + rowHs.reduce(0, +)))
        let host = window.contentView! as! HostView
        var y = margin
        for (i, (name, populate)) in sheets.enumerated() {
            let rowH = rowHs[i]
            let caption = NSTextField(labelWithString: name)
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            caption.sizeToFit()
            caption.frame.origin = NSPoint(x: 12, y: y + 6)
            host.addSubview(caption)

            let row = HostView(frame: NSRect(
                x: 100, y: y, width: 400, height: rowH))
            populate(row)
            host.addSubview(row)
            y += rowH
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // --- host infrastructure -------------------------------------------

    static func offscreenWindow(aqua: NSAppearance?) -> NSWindow {
        // A titled window (probe-verified: borderless ones are never
        // made key here, and an app that isn't active renders every
        // control desaturated). The title bar sits ABOVE the content
        // view and the capture is of the content view only, so the
        // sheets stay chrome-free.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: sheetSize.width,
                                             height: sheetSize.height + 28)),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = aqua
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let host = HostView(frame: NSRect(origin: .zero, size: sheetSize))
        window.contentView = host
        // The window autoresizes its content view to fill under the
        // title bar — pin the sheet rect back and freeze it, or the
        // capture squeezes a 480x188 host into the 480x160 bitmap.
        host.setFrameOrigin(.zero)
        host.setFrameSize(sheetSize)
        host.autoresizingMask = []
        host.translatesAutoresizingMaskIntoConstraints = true
        return window
    }

    // Plain flipped container: top-left origin, dialog-gray fill,
    // manually framed children.
    final class HostView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            // Explicit sRGB #ECECEC — windowBackgroundColor renders
            // white through the deviceRGB bitmap context, and the
            // egui twin fills 236,236,236: identical backgrounds make
            // the diff isolate the widgets.
            NSColor(srgbRed: 236.0 / 255.0, green: 236.0 / 255.0,
                    blue: 236.0 / 255.0, alpha: 1.0).setFill()
            bounds.fill()
        }

        func capture() -> Data {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(sheetSize.width),
                pixelsHigh: Int(sheetSize.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false,
                colorSpaceName: NSColorSpaceName.deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = sheetSize
            cacheDisplay(in: NSRect(origin: .zero, size: sheetSize), to: rep)
            return rep.representation(using: .png, properties: [:])!
        }
    }

    // Place a control at x, vertically centered in the HOST's bounds
    // (sheets use 160pt hosts, gallery rows 40pt). NSControl children
    // get sizeToFit(); others (progress indicators) set their own
    // frame size beforehand.
    @discardableResult
    static func place(_ c: NSView, in host: HostView,
                      x: CGFloat, w: CGFloat? = nil) -> NSView {
        (c as? NSControl)?.sizeToFit()
        var f = c.frame
        if let w { f.size.width = w }
        f.origin = NSPoint(x: x,
                           y: (host.bounds.height - f.height) / 2)
        c.frame = f
        host.addSubview(c)
        return c
    }
}

extension NSWindow {
    // Borderless windows don't run the normal layout pass; drive the
    // content view's subtree manually before capturing.
    func layoutIfNeededIfNeeded() {
        contentView?.layoutSubtreeIfNeeded()
        contentView?.displayIfNeeded()
    }
}

// --- sheets -----------------------------------------------------------

func addButtons(_ host: RenderOracle.HostView) {
    let plain = NSButton(title: "Button", target: nil, action: nil)
    plain.bezelStyle = .rounded
    RenderOracle.place(plain, in: host, x: 24)

    let def = NSButton(title: "OK", target: nil, action: nil)
    def.bezelStyle = .rounded
    def.keyEquivalent = "\r" // default (accent-filled) button look
    RenderOracle.place(def, in: host, x: 250)
    host.window?.defaultButtonCell = def.cell as? NSButtonCell
    host.window?.layoutIfNeededIfNeeded()
}

func addCheckboxes(_ host: RenderOracle.HostView) {
    let off = NSButton(checkboxWithTitle: "Check", target: nil, action: nil)
    RenderOracle.place(off, in: host, x: 24)

    let on = NSButton(checkboxWithTitle: "Selected", target: nil,
                      action: nil)
    on.state = .on
    RenderOracle.place(on, in: host, x: 250)
}

func addRadios(_ host: RenderOracle.HostView) {
    let a = NSButton(radioButtonWithTitle: "First", target: nil, action: nil)
    a.state = .on
    RenderOracle.place(a, in: host, x: 24)

    let b = NSButton(radioButtonWithTitle: "Second", target: nil,
                     action: nil)
    RenderOracle.place(b, in: host, x: 250)
}

func addSwitches(_ host: RenderOracle.HostView) {
    let off = NSSwitch()
    off.state = .off
    RenderOracle.place(off, in: host, x: 24)

    let on = NSSwitch()
    on.state = .on
    RenderOracle.place(on, in: host, x: 250)
}

func addTextFields(_ host: RenderOracle.HostView) {
    let field = NSTextField()
    field.stringValue = "Placeholder"
    field.bezelStyle = .roundedBezel
    field.placeholderString = "Type here"
    RenderOracle.place(field, in: host, x: 24, w: 200)
}

func addSearchFields(_ host: RenderOracle.HostView) {
    let search = NSSearchField()
    search.placeholderString = "Search"
    RenderOracle.place(search, in: host, x: 24, w: 220)
}

func addSliders(_ host: RenderOracle.HostView) {
    let slider = NSSlider(value: 0.6, minValue: 0, maxValue: 1,
                          target: nil, action: nil)
    slider.isContinuous = true
    RenderOracle.place(slider, in: host, x: 24, w: 220)
}

func addSegmented(_ host: RenderOracle.HostView) {
    let seg = NSSegmentedControl(
        labels: ["One", "Two", "Three"], trackingMode: .selectOne,
        target: nil, action: nil)
    seg.selectedSegment = 1
    RenderOracle.place(seg, in: host, x: 24, w: 220)
}

func addPopup(_ host: RenderOracle.HostView) {
    let popup = NSPopUpButton()
    popup.addItems(withTitles: ["First", "Second", "Third"])
    popup.selectItem(at: 0)
    RenderOracle.place(popup, in: host, x: 24, w: 200)
}

func addProgress(_ host: RenderOracle.HostView) {
    let bar = NSProgressIndicator()
    bar.style = .bar
    bar.isIndeterminate = false
    bar.minValue = 0
    bar.maxValue = 1
    bar.doubleValue = 0.45
    bar.frame = NSRect(x: 0, y: 0, width: 200, height: 4)
    RenderOracle.place(bar, in: host, x: 24, w: 200)

    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.isIndeterminate = true
    spinner.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
    RenderOracle.place(spinner, in: host, x: 280)
}

func addStepper(_ host: RenderOracle.HostView) {
    let value = NSTextField(labelWithString: "42")
    value.font = .systemFont(ofSize: 13)
    RenderOracle.place(value, in: host, x: 24)

    let stepper = NSStepper()
    stepper.minValue = 0
    stepper.maxValue = 100
    stepper.intValue = 42
    RenderOracle.place(stepper, in: host, x: 80)
}

func addLabels(_ host: RenderOracle.HostView) {
    let primary = NSTextField(labelWithString: "Label")
    primary.font = .systemFont(ofSize: 13)
    RenderOracle.place(primary, in: host, x: 24)

    let secondary = NSTextField(labelWithString: "Secondary label")
    secondary.font = .systemFont(ofSize: 13)
    secondary.textColor = .secondaryLabelColor
    RenderOracle.place(secondary, in: host, x: 250)
}

func addSeparator(_ host: RenderOracle.HostView) {
    let one = NSTextField(labelWithString: "One")
    one.font = .systemFont(ofSize: 13)
    RenderOracle.place(one, in: host, x: 24)

    // Vertical hairline between the labels (NSBox separator picks its
    // axis from the frame aspect).
    let sep = NSBox()
    sep.boxType = .separator
    sep.frame = NSRect(x: 0, y: 0, width: 1, height: 20)
    RenderOracle.place(sep, in: host, x: 64)

    let two = NSTextField(labelWithString: "Two")
    two.font = .systemFont(ofSize: 13)
    RenderOracle.place(two, in: host, x: 80)
}

func addLink(_ host: RenderOracle.HostView) {
    // Attributed .link labels: selectable, so the cell renders them in
    // linkColor (AppKit text links are NOT underlined by default —
    // the egui twin drops the underline for parity).
    let guide = NSTextField(labelWithAttributedString: NSAttributedString(
        string: "Open the guide",
        attributes: [.link: URL(string: "https://example.com")!]))
    guide.isSelectable = true
    RenderOracle.place(guide, in: host, x: 24)

    let more = NSTextField(labelWithAttributedString: NSAttributedString(
        string: "More…",
        attributes: [.link: URL(string: "https://example.com/more")!]))
    more.isSelectable = true
    RenderOracle.place(more, in: host, x: 250)
}

func addSecureField(_ host: RenderOracle.HostView) {
    let secure = NSSecureTextField()
    secure.stringValue = "Placeholder"
    secure.bezelStyle = .roundedBezel
    RenderOracle.place(secure, in: host, x: 24, w: 200)
}

func addTextarea(_ host: RenderOracle.HostView) {
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 56))
    text.string = "Line one\nLine two"
    text.font = .systemFont(ofSize: 13)
    text.drawsBackground = true
    text.backgroundColor = .textBackgroundColor
    RenderOracle.place(text, in: host, x: 24, w: 200)
}

func addDisclosure(_ host: RenderOracle.HostView) {
    // Bare disclosure triangles with a label next to each, like a
    // settings row: roundedDisclosure points right when off, down
    // when on.
    let closed = NSButton(title: "", target: nil, action: nil)
    closed.bezelStyle = .roundedDisclosure
    closed.state = .off
    RenderOracle.place(closed, in: host, x: 24)
    let closedLabel = NSTextField(labelWithString: "Advanced")
    closedLabel.font = .systemFont(ofSize: 13)
    RenderOracle.place(closedLabel, in: host, x: 48)

    let open = NSButton(title: "", target: nil, action: nil)
    open.bezelStyle = .roundedDisclosure
    open.state = .on
    RenderOracle.place(open, in: host, x: 250)
    let openLabel = NSTextField(labelWithString: "Advanced")
    openLabel.font = .systemFont(ofSize: 13)
    RenderOracle.place(openLabel, in: host, x: 274)
}

func addColorWells(_ host: RenderOracle.HostView) {
    // Fixed sRGB colors — the egui twins paint the exact same values.
    let blue = NSColorWell()
    blue.color = NSColor(srgbRed: 0, green: 122.0 / 255.0, blue: 1.0,
                         alpha: 1.0)
    RenderOracle.place(blue, in: host, x: 24)

    let red = NSColorWell()
    red.color = NSColor(srgbRed: 1.0, green: 59.0 / 255.0,
                        blue: 48.0 / 255.0, alpha: 1.0)
    RenderOracle.place(red, in: host, x: 250)
}

private func makeDatePicker(elements: NSDatePicker.ElementFlags,
                            components: DateComponents) -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerStyle = .textFieldAndStepper
    picker.datePickerElements = elements
    picker.calendar = Calendar(identifier: .gregorian)
    // POSIX locale keeps the rendered text numeric ("11/07/2026",
    // "14:30:05") — ASCII and deterministic like the egui twins'
    // format strings, so the diff measures the control, not the locale.
    picker.locale = Locale(identifier: "en_US_POSIX")
    picker.timeZone = TimeZone(identifier: "UTC")
    var comp = components
    comp.calendar = picker.calendar
    comp.timeZone = picker.timeZone
    picker.dateValue = picker.calendar!.date(from: comp)!
    return picker
}

func addDatePicker(_ host: RenderOracle.HostView) {
    var comp = DateComponents()
    comp.year = 2026
    comp.month = 11
    comp.day = 7
    RenderOracle.place(makeDatePicker(elements: [.yearMonthDay],
                                      components: comp),
                       in: host, x: 24)
}

func addTimePicker(_ host: RenderOracle.HostView) {
    var comp = DateComponents()
    comp.hour = 14
    comp.minute = 30
    comp.second = 5
    RenderOracle.place(makeDatePicker(elements: [.hourMinuteSecond],
                                      components: comp),
                       in: host, x: 24)
}
