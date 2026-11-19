//
//  ZaloScreenshotAnnotator.swift
//  boringNotch
//
//  Zalo-style Screenshot & Quick Annotation (Note / Arrow / Box / Mosaic / Step / Pin / Shelf)
//

import AppKit
import CoreImage
import Defaults
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models

enum ZaloAnnotationTool: String, CaseIterable, Identifiable {
    case select
    case rectangle
    case ellipse
    case arrow
    case pen
    case highlighter
    case mosaic
    case step
    case text

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .mosaic: return "checkerboard.rectangle"
        case .step: return "1.circle"
        case .text: return "textformat"
        }
    }

    var tooltip: String {
        switch self {
        case .select: return "Di chuyển vùng chọn"
        case .rectangle: return "Khung chữ nhật"
        case .ellipse: return "Khung tròn / Elip"
        case .arrow: return "Mũi tên"
        case .pen: return "Bút vẽ tự do"
        case .highlighter: return "Bút dạ quang"
        case .mosaic: return "Làm mờ / Che nhạy cảm"
        case .step: return "Đánh số thứ tự ①②③"
        case .text: return "Ghi chú văn bản (Note)"
        }
    }
}

struct ZaloAnnotationColor: Identifiable, Equatable {
    let id: String
    let name: String
    let nsColor: NSColor

    var swiftUIColor: Color { Color(nsColor: nsColor) }

    static let presets: [ZaloAnnotationColor] = [
        ZaloAnnotationColor(id: "red", name: "Đỏ", nsColor: NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)),
        ZaloAnnotationColor(id: "yellow", name: "Vàng", nsColor: NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)),
        ZaloAnnotationColor(id: "blue", name: "Xanh Zalo", nsColor: NSColor(calibratedRed: 0.0, green: 0.41, blue: 1.0, alpha: 1)),
        ZaloAnnotationColor(id: "green", name: "Xanh lá", nsColor: NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
        ZaloAnnotationColor(id: "white", name: "Trắng", nsColor: .white),
        ZaloAnnotationColor(id: "black", name: "Đen", nsColor: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
    ]
}

struct ZaloAnnotationItem: Identifiable {
    let id = UUID()
    let tool: ZaloAnnotationTool
    var points: [CGPoint] // Screen-overlay local coordinates (top-left origin)
    var color: NSColor
    var lineWidth: CGFloat
    var text: String = ""
    var stepNumber: Int = 1

    var boundingRect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
    }
}

// MARK: - Overlay & Pinned Windows

final class ZaloOverlayWindow: NSWindow {
    var onKeyEvent: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let handler = onKeyEvent, handler(event) {
            return
        }
        super.keyDown(with: event)
    }
}

final class ZaloPinnedWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - State

@MainActor
final class ZaloCaptureSession: ObservableObject {
    let fullCGImage: CGImage
    let nsImage: NSImage
    let screenSize: CGSize
    let scaleFactor: CGFloat

    @Published var selectionRect: CGRect = .zero
    @Published var hasSelection: Bool = false
    @Published var activeTool: ZaloAnnotationTool = .arrow
    @Published var selectedColor: ZaloAnnotationColor = ZaloAnnotationColor.presets[0]
    @Published var strokeWidth: CGFloat = 3.5

    @Published var items: [ZaloAnnotationItem] = []
    @Published var redoStack: [ZaloAnnotationItem] = []
    @Published var activeDraftItem: ZaloAnnotationItem?

    // Inline text note entry
    @Published var pendingTextPoint: CGPoint?
    @Published var pendingTextContent: String = ""

    var nextStepNumber: Int {
        (items.filter { $0.tool == .step }.map(\.stepNumber).max() ?? 0) + 1
    }

    init(cgImage: CGImage, screenSize: CGSize, scaleFactor: CGFloat) {
        self.fullCGImage = cgImage
        self.screenSize = screenSize
        self.scaleFactor = scaleFactor
        self.nsImage = NSImage(cgImage: cgImage, size: screenSize)
    }

    func commitItem(_ item: ZaloAnnotationItem) {
        items.append(item)
        redoStack.removeAll()
    }

    func commitPendingText() {
        guard let point = pendingTextPoint else { return }
        let trimmed = pendingTextContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let item = ZaloAnnotationItem(
                tool: .text,
                points: [point],
                color: selectedColor.nsColor,
                lineWidth: strokeWidth,
                text: trimmed
            )
            commitItem(item)
        }
        pendingTextPoint = nil
        pendingTextContent = ""
    }

    func cancelPendingText() {
        pendingTextPoint = nil
        pendingTextContent = ""
    }

    func undo() {
        if pendingTextPoint != nil {
            cancelPendingText()
            return
        }
        guard let last = items.popLast() else { return }
        redoStack.append(last)
    }

    func redo() {
        guard let item = redoStack.popLast() else { return }
        items.append(item)
    }

    func clearAnnotations() {
        cancelPendingText()
        items.removeAll()
        redoStack.removeAll()
    }
}

// MARK: - Coordinator

@MainActor
final class ZaloScreenshotCoordinator: ObservableObject {
    static let shared = ZaloScreenshotCoordinator()

    private var overlayWindow: ZaloOverlayWindow?
    private var pinnedWindows: [ZaloPinnedWindow] = []
    private var currentSession: ZaloCaptureSession?
    private var isCapturing: Bool = false

    private init() {}

    func startCapture() {
        if overlayWindow != nil {
            dismissOverlay()
            return
        }
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            defer { self.isCapturing = false }

            // Find screen under mouse cursor
            let mouseLoc = NSEvent.mouseLocation
            let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) })
                ?? NSScreen.main
                ?? NSScreen.screens.first

            guard let screen = targetScreen else { return }
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()

            do {
                let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scDisplay = shareable.displays.first(where: { $0.displayID == displayID }) ?? shareable.displays.first else {
                    showPermissionAlert()
                    return
                }

                let myBundleID = Bundle.main.bundleIdentifier
                let excludedApps = shareable.applications.filter { app in
                    myBundleID != nil && app.bundleIdentifier == myBundleID
                }

                let filter = SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                let scale = max(1.0, screen.backingScaleFactor)
                config.width = Int(round(screen.frame.width * scale))
                config.height = Int(round(screen.frame.height * scale))
                config.showsCursor = false
                config.capturesAudio = false
                config.scalesToFit = true

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                presentOverlay(with: cgImage, on: screen)
            } catch {
                showPermissionAlert()
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Cần quyền Ghi màn hình"
        alert.informativeText = "Vui lòng cấp quyền Ghi màn hình cho Boring Notch trong Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Ghi màn hình, sau đó thử chụp lại."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Mở Cài đặt hệ thống")
        alert.addButton(withTitle: "Đóng")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func presentOverlay(with cgImage: CGImage, on screen: NSScreen) {
        let session = ZaloCaptureSession(
            cgImage: cgImage,
            screenSize: screen.frame.size,
            scaleFactor: max(1.0, screen.backingScaleFactor)
        )
        self.currentSession = session

        let window = ZaloOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        window.onKeyEvent = { [weak self, weak session] event in
            guard let self, let session else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Let TextField handle normal typing when editing text note
            if session.pendingTextPoint != nil {
                if event.keyCode == 53 { // Escape
                    session.cancelPendingText()
                    return true
                }
                return false
            }

            // Escape -> cancel capture
            if event.keyCode == 53 {
                self.dismissOverlay()
                return true
            }

            // Return / Enter -> Copy to Clipboard when selection exists
            if (event.keyCode == 36 || event.keyCode == 76) && session.hasSelection {
                self.copyToClipboard(session: session)
                return true
            }

            if flags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "z":
                    if flags.contains(.shift) {
                        session.redo()
                    } else {
                        session.undo()
                    }
                    return true
                case "c":
                    if session.hasSelection {
                        self.copyToClipboard(session: session)
                        return true
                    }
                case "s":
                    if session.hasSelection {
                        self.saveToFile(session: session)
                        return true
                    }
                default:
                    break
                }
            }
            return false
        }

        let rootView = ZaloScreenshotOverlayView(
            session: session,
            onCopy: { [weak self] in self?.copyToClipboard(session: session) },
            onSave: { [weak self] in self?.saveToFile(session: session) },
            onSendToShelf: { [weak self] in self?.sendToShelf(session: session) },
            onPin: { [weak self] in self?.pinSelection(session: session) },
            onCancel: { [weak self] in self?.dismissOverlay() }
        )

        window.contentView = NSHostingView(rootView: rootView)
        window.setFrame(screen.frame, display: true)
        self.overlayWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSCursor.crosshair.set()
    }

    func dismissOverlay() {
        currentSession?.cancelPendingText()
        overlayWindow?.orderOut(nil)
        overlayWindow?.close()
        overlayWindow = nil
        currentSession = nil
        NSCursor.arrow.set()
    }

    // MARK: - Actions

    private func renderCurrentSelection(session: ZaloCaptureSession) -> (NSImage, Data)? {
        session.commitPendingText()
        guard session.hasSelection,
              session.selectionRect.width >= 4,
              session.selectionRect.height >= 4 else { return nil }
        return ZaloScreenshotRenderer.render(session: session)
    }

    private func copyToClipboard(session: ZaloCaptureSession) {
        guard let (nsImage, pngData) = renderCurrentSelection(session: session) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)
        if let tiff = nsImage.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        NSSound(named: NSSound.Name("Pop"))?.play()
        dismissOverlay()
    }

    private func saveToFile(session: ZaloCaptureSession) {
        guard let (_, pngData) = renderCurrentSelection(session: session) else { return }
        dismissOverlay()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let defaultName = "ChupManHinh_\(formatter.string(from: Date())).png"

        let panel = NSSavePanel()
        panel.title = "Lưu ảnh chụp màn hình"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? pngData.write(to: url, options: .atomic)
            NSSound(named: NSSound.Name("Pop"))?.play()
        }
    }

    private func sendToShelf(session: ZaloCaptureSession) {
        guard let (_, pngData) = renderCurrentSelection(session: session) else { return }
        dismissOverlay()

        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let fileName = "ChupManHinh_\(formatter.string(from: Date())).png"

        Task {
            if let tempURL = await TemporaryFileStorageService.shared.createTempFile(
                for: .data(pngData, suggestedName: fileName)
            ), let bookmark = (try? Bookmark(url: tempURL))?.data {
                await MainActor.run {
                    ShelfStateViewModel.shared.add([
                        ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
                    ])
                    BoringViewCoordinator.shared.currentView = .shelf
                    NSSound(named: NSSound.Name("Pop"))?.play()
                }
            }
        }
    }

    private func pinSelection(session: ZaloCaptureSession) {
        guard let (nsImage, pngData) = renderCurrentSelection(session: session) else { return }
        let displaySize = session.selectionRect.size
        let originOnScreen = overlayWindow?.frame.origin ?? .zero
        let targetOrigin = NSPoint(
            x: originOnScreen.x + session.selectionRect.minX,
            y: originOnScreen.y + (session.screenSize.height - session.selectionRect.maxY)
        )
        dismissOverlay()

        let pinnedWin = ZaloPinnedWindow(
            contentRect: NSRect(origin: targetOrigin, size: displaySize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        pinnedWin.level = .floating
        pinnedWin.isOpaque = false
        pinnedWin.backgroundColor = .clear
        pinnedWin.hasShadow = true
        pinnedWin.isMovableByWindowBackground = true
        pinnedWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pinnedWin.isReleasedWhenClosed = false

        let view = ZaloPinnedImageView(
            image: nsImage,
            pngData: pngData,
            onClose: { [weak self, weak pinnedWin] in
                guard let pinnedWin else { return }
                pinnedWin.orderOut(nil)
                pinnedWin.close()
                self?.pinnedWindows.removeAll { $0 === pinnedWin }
            }
        )
        pinnedWin.contentView = NSHostingView(rootView: view)
        pinnedWindows.append(pinnedWin)
        pinnedWin.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Pinned Floating Preview View

private struct ZaloPinnedImageView: View {
    let image: NSImage
    let pngData: Data
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                )

            if isHovering {
                HStack(spacing: 6) {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setData(pngData, forType: .png)
                        NSSound(named: NSSound.Name("Pop"))?.play()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.black.opacity(0.72), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Sao chép ảnh")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.red.opacity(0.85), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Đóng ảnh ghim")
                }
                .padding(8)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) {
            onClose()
        }
        .contextMenu {
            Button("Sao chép ảnh") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(pngData, forType: .png)
            }
            Button("Lưu thành tệp…") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "GhimManHinh.png"
                panel.allowedContentTypes = [.png]
                if panel.runModal() == .OK, let url = panel.url {
                    try? pngData.write(to: url, options: .atomic)
                }
            }
            Divider()
            Button("Đóng", role: .destructive) {
                onClose()
            }
        }
    }
}

// MARK: - Selection & Annotation Overlay View

private enum SelectionDragMode {
    case none
    case creating(origin: CGPoint)
    case moving(startRect: CGRect, startPoint: CGPoint)
    case resizing(handle: ResizeHandle, startRect: CGRect)
    case annotating
}

private enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

private struct ZaloScreenshotOverlayView: View {
    @ObservedObject var session: ZaloCaptureSession
    let onCopy: () -> Void
    let onSave: () -> Void
    let onSendToShelf: () -> Void
    let onPin: () -> Void
    let onCancel: () -> Void

    @State private var dragMode: SelectionDragMode = .none
    @FocusState private var textFieldFocused: Bool

    private let zaloBlue = Color(red: 0.0, green: 0.41, blue: 1.0)

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. Frozen screenshot background
            Image(nsImage: session.nsImage)
                .resizable()
                .frame(width: session.screenSize.width, height: session.screenSize.height)

            // 2. Dim mask with transparent cutout for selection
            Canvas { ctx, size in
                var outer = Path(CGRect(origin: .zero, size: size))
                if session.hasSelection {
                    outer.addRect(session.selectionRect)
                }
                ctx.fill(outer, with: .color(.black.opacity(0.42)), style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)

            // 3. Hint pill before selection starts
            if !session.hasSelection {
                VStack {
                    Text("Kéo chuột chọn vùng chụp • Nhấn Esc để hủy")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.76), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                        .padding(.top, 52)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }

            // 4. Rendered annotations clipped to selection
            if session.hasSelection {
                Canvas { ctx, _ in
                    for item in session.items {
                        drawCanvasItem(item, in: &ctx)
                    }
                    if let draft = session.activeDraftItem {
                        drawCanvasItem(draft, in: &ctx)
                    }
                }
                .clipShape(Rectangle().path(in: session.selectionRect))
                .allowsHitTesting(false)

                // 5. Selection border, handles & size badge
                selectionChrome
                    .allowsHitTesting(false)
            }

            // 6. Full-screen gesture capture layer (under toolbar & text editor)
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handleDragChanged(value)
                        }
                        .onEnded { value in
                            handleDragEnded(value)
                        }
                )

            // 7. Inline Vietnamese text note box
            if let textPt = session.pendingTextPoint {
                inlineTextBox(at: textPt)
            }

            // 8. Zalo-style Floating Toolbar
            if session.hasSelection && session.selectionRect.width >= 10 && session.selectionRect.height >= 10 {
                floatingToolbar
                    .position(toolbarCenterPosition())
            }
        }
        .frame(width: session.screenSize.width, height: session.screenSize.height)
    }

    // MARK: - Selection Border & Handles

    @ViewBuilder
    private var selectionChrome: some View {
        let r = session.selectionRect
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(zaloBlue, lineWidth: 1.75)
                .frame(width: max(0, r.width), height: max(0, r.height))
                .position(x: r.midX, y: r.midY)

            // 8 white handles
            ForEach(ResizeHandle.allCases, id: \.self) { handle in
                let pt = handlePoint(handle, in: r)
                Circle()
                    .fill(.white)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(zaloBlue, lineWidth: 1.5))
                    .position(pt)
            }

            // Pixel dimension badge (top-left of selection)
            let wPx = Int(round(r.width * session.scaleFactor))
            let hPx = Int(round(r.height * session.scaleFactor))
            Text("\(wPx) × \(hPx)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
                .position(
                    x: min(max(r.minX + 44, 46), session.screenSize.width - 46),
                    y: r.minY > 28 ? r.minY - 14 : r.minY + 14
                )
        }
    }

    private func handlePoint(_ handle: ResizeHandle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func hitResizeHandle(at point: CGPoint, in r: CGRect) -> ResizeHandle? {
        for handle in ResizeHandle.allCases {
            let hp = handlePoint(handle, in: r)
            if hypot(point.x - hp.x, point.y - hp.y) <= 10 {
                return handle
            }
        }
        return nil
    }

    // MARK: - Inline Vietnamese Text Box

    private func inlineTextBox(at point: CGPoint) -> some View {
        let fontSize: CGFloat = max(14, session.strokeWidth * 4.2)
        let textColor: Color = session.selectedColor.swiftUIColor
        let minX: CGFloat = session.selectionRect.minX + 75
        let maxX: CGFloat = max(minX, session.selectionRect.maxX - 75)
        let posX: CGFloat = min(max(point.x + 70, minX), maxX)
        let minY: CGFloat = session.selectionRect.minY + 18
        let maxY: CGFloat = max(minY, session.selectionRect.maxY - 18)
        let posY: CGFloat = min(max(point.y, minY), maxY)

        return HStack(spacing: 4) {
            TextField("Nhập ghi chú…", text: $session.pendingTextContent)
                .onSubmit {
                    session.commitPendingText()
                }
                .textFieldStyle(.plain)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(textColor)
                .focused($textFieldFocused)
                .frame(minWidth: 120, maxWidth: 320)

            Button {
                session.commitPendingText()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(zaloBlue)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(textColor.opacity(0.85), lineWidth: 1.2)
        )
        .position(x: posX, y: posY)
        .onAppear {
            DispatchQueue.main.async {
                textFieldFocused = true
            }
        }
    }

    // MARK: - Zalo-Style Floating Toolbar

    private var toolbarEstimatedWidth: CGFloat { 650 }
    private var toolbarEstimatedHeight: CGFloat { 76 }

    private func toolbarCenterPosition() -> CGPoint {
        let r = session.selectionRect
        let halfW = toolbarEstimatedWidth / 2
        let clampedX = min(max(r.midX, halfW + 12), session.screenSize.width - halfW - 12)

        let belowY = r.maxY + 10 + toolbarEstimatedHeight / 2
        if belowY + toolbarEstimatedHeight / 2 < session.screenSize.height - 12 {
            return CGPoint(x: clampedX, y: belowY)
        }
        let aboveY = r.minY - 10 - toolbarEstimatedHeight / 2
        if aboveY - toolbarEstimatedHeight / 2 > 12 {
            return CGPoint(x: clampedX, y: aboveY)
        }
        return CGPoint(x: clampedX, y: min(r.maxY - toolbarEstimatedHeight / 2 - 12, session.screenSize.height - toolbarEstimatedHeight / 2 - 12))
    }

    private var floatingToolbar: some View {
        VStack(spacing: 6) {
            // Row 1: Tools + Undo/Redo + Actions
            HStack(spacing: 4) {
                ForEach(ZaloAnnotationTool.allCases) { tool in
                    Button {
                        session.commitPendingText()
                        session.activeTool = tool
                    } label: {
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(session.activeTool == tool ? .white : Color.white.opacity(0.78))
                            .frame(width: 28, height: 28)
                            .background(
                                session.activeTool == tool ? zaloBlue : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tool.tooltip)
                }

                Divider()
                    .frame(height: 18)
                    .overlay(Color.white.opacity(0.2))
                    .padding(.horizontal, 2)

                Button { session.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.items.isEmpty ? Color.white.opacity(0.3) : .white)
                        .frame(width: 26, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(session.items.isEmpty && session.pendingTextPoint == nil)
                .help("Hoàn tác (⌘Z)")

                Button { session.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.redoStack.isEmpty ? Color.white.opacity(0.3) : .white)
                        .frame(width: 26, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(session.redoStack.isEmpty)
                .help("Làm lại (⇧⌘Z)")

                Divider()
                    .frame(height: 18)
                    .overlay(Color.white.opacity(0.2))
                    .padding(.horizontal, 2)

                Button(action: onPin) {
                    Image(systemName: "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Ghim ảnh nổi trên màn hình")

                Button(action: onSendToShelf) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Đưa lên Khay tệp Tai thỏ")

                Button(action: onSave) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Lưu thành PNG (⌘S)")

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Hủy (Esc)")

                Button(action: onCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                        Text("Sao chép")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(zaloBlue, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Sao chép vào Clipboard (⌘C / Enter)")
            }

            // Row 2: Stroke thickness + Color swatches
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach([CGFloat(2.5), CGFloat(4.0), CGFloat(7.0)], id: \.self) { size in
                        Button {
                            session.strokeWidth = size
                        } label: {
                            Circle()
                                .fill(session.strokeWidth == size ? Color.white : Color.white.opacity(0.45))
                                .frame(width: size + 4, height: size + 4)
                                .frame(width: 20, height: 20)
                                .background(
                                    session.strokeWidth == size ? Color.white.opacity(0.18) : Color.clear,
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .frame(height: 14)
                    .overlay(Color.white.opacity(0.2))

                HStack(spacing: 7) {
                    ForEach(ZaloAnnotationColor.presets) { preset in
                        Button {
                            session.selectedColor = preset
                        } label: {
                            Circle()
                                .fill(preset.swiftUIColor)
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Circle()
                                        .stroke(
                                            session.selectedColor == preset ? Color.white : Color.white.opacity(0.25),
                                            lineWidth: session.selectedColor == preset ? 2 : 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }

                Spacer(minLength: 8)

                if !session.items.isEmpty {
                    Button {
                        session.clearAnnotations()
                    } label: {
                        Text("Xóa nét")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.94), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }

    // MARK: - Gesture Handling

    private func handleDragChanged(_ value: DragGesture.Value) {
        let start = value.startLocation
        let current = value.location

        if case .none = dragMode {
            if !session.hasSelection {
                dragMode = .creating(origin: start)
            } else if let handle = hitResizeHandle(at: start, in: session.selectionRect) {
                dragMode = .resizing(handle: handle, startRect: session.selectionRect)
            } else if session.selectionRect.contains(start) {
                if session.activeTool == .select {
                    dragMode = .moving(startRect: session.selectionRect, startPoint: start)
                } else if session.activeTool == .text {
                    session.commitPendingText()
                    session.pendingTextPoint = start
                    dragMode = .none
                    return
                } else if session.activeTool == .step {
                    let badge = ZaloAnnotationItem(
                        tool: .step,
                        points: [start],
                        color: session.selectedColor.nsColor,
                        lineWidth: session.strokeWidth,
                        stepNumber: session.nextStepNumber
                    )
                    session.commitItem(badge)
                    dragMode = .none
                    return
                } else {
                    session.commitPendingText()
                    dragMode = .annotating
                    session.activeDraftItem = ZaloAnnotationItem(
                        tool: session.activeTool,
                        points: [start, current],
                        color: session.selectedColor.nsColor,
                        lineWidth: session.strokeWidth
                    )
                    return
                }
            } else {
                // Drag outside existing selection starts a new selection if no annotations yet
                if session.items.isEmpty {
                    dragMode = .creating(origin: start)
                } else {
                    return
                }
            }
        }

        switch dragMode {
        case .creating(let origin):
            let rect = CGRect(
                x: min(origin.x, current.x),
                y: min(origin.y, current.y),
                width: abs(current.x - origin.x),
                height: abs(current.y - origin.y)
            ).intersection(CGRect(origin: .zero, size: session.screenSize))
            session.selectionRect = rect
            session.hasSelection = rect.width >= 4 && rect.height >= 4

        case .moving(let startRect, let startPoint):
            let dx = current.x - startPoint.x
            let dy = current.y - startPoint.y
            let clampedX = min(max(0, startRect.origin.x + dx), session.screenSize.width - startRect.width)
            let clampedY = min(max(0, startRect.origin.y + dy), session.screenSize.height - startRect.height)
            session.selectionRect = CGRect(x: clampedX, y: clampedY, width: startRect.width, height: startRect.height)

        case .resizing(let handle, let startRect):
            session.selectionRect = resizedRect(startRect, handle: handle, to: current)

        case .annotating:
            guard var draft = session.activeDraftItem else { return }
            if draft.tool == .pen || draft.tool == .highlighter {
                draft.points.append(current)
            } else {
                draft.points = [start, current]
            }
            session.activeDraftItem = draft

        case .none:
            break
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        if case .annotating = dragMode, let draft = session.activeDraftItem {
            if draft.tool == .pen || draft.tool == .highlighter {
                if draft.points.count >= 2 {
                    session.commitItem(draft)
                }
            } else if draft.boundingRect.width >= 3 || draft.boundingRect.height >= 3 {
                session.commitItem(draft)
            }
            session.activeDraftItem = nil
        }
        dragMode = .none
    }

    private func resizedRect(_ r: CGRect, handle: ResizeHandle, to pt: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        let clampedX = min(max(0, pt.x), session.screenSize.width)
        let clampedY = min(max(0, pt.y), session.screenSize.height)

        switch handle {
        case .topLeft: minX = clampedX; minY = clampedY
        case .top: minY = clampedY
        case .topRight: maxX = clampedX; minY = clampedY
        case .right: maxX = clampedX
        case .bottomRight: maxX = clampedX; maxY = clampedY
        case .bottom: maxY = clampedY
        case .bottomLeft: minX = clampedX; maxY = clampedY
        case .left: minX = clampedX
        }
        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: max(20, abs(maxX - minX)),
            height: max(20, abs(maxY - minY))
        )
    }

    // MARK: - Live Canvas Drawing

    private func drawCanvasItem(_ item: ZaloAnnotationItem, in ctx: inout GraphicsContext) {
        let color = Color(nsColor: item.color)
        switch item.tool {
        case .select:
            break
        case .rectangle:
            let path = Path(roundedRect: item.boundingRect, cornerRadius: 3)
            ctx.stroke(path, with: .color(color), lineWidth: item.lineWidth)
        case .ellipse:
            let path = Path(ellipseIn: item.boundingRect)
            ctx.stroke(path, with: .color(color), lineWidth: item.lineWidth)
        case .arrow:
            guard let start = item.points.first, let end = item.points.last else { return }
            let path = ZaloScreenshotRenderer.arrowPath(from: start, to: end, headLength: max(14, item.lineWidth * 4.2))
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: item.lineWidth, lineCap: .round, lineJoin: .round))
            let head = ZaloScreenshotRenderer.arrowHeadPath(from: start, to: end, headLength: max(14, item.lineWidth * 4.2))
            ctx.fill(head, with: .color(color))
        case .pen:
            guard item.points.count >= 2 else { return }
            var path = Path()
            path.move(to: item.points[0])
            for p in item.points.dropFirst() { path.addLine(to: p) }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: item.lineWidth, lineCap: .round, lineJoin: .round))
        case .highlighter:
            guard item.points.count >= 2 else { return }
            var path = Path()
            path.move(to: item.points[0])
            for p in item.points.dropFirst() { path.addLine(to: p) }
            ctx.stroke(path, with: .color(color.opacity(0.38)), style: StrokeStyle(lineWidth: item.lineWidth * 4.2, lineCap: .round, lineJoin: .round))
        case .mosaic:
            let rect = item.boundingRect
            guard rect.width >= 2, rect.height >= 2 else { return }
            // Checkerboard live preview (actual CoreImage CIPixellate mosaic is baked on export)
            let cell: CGFloat = 9
            let cols = Int(ceil(rect.width / cell))
            let rows = Int(ceil(rect.height / cell))
            for row in 0..<rows {
                for col in 0..<cols {
                    let tile = CGRect(
                        x: rect.minX + CGFloat(col) * cell,
                        y: rect.minY + CGFloat(row) * cell,
                        width: min(cell, rect.maxX - (rect.minX + CGFloat(col) * cell)),
                        height: min(cell, rect.maxY - (rect.minY + CGFloat(row) * cell))
                    )
                    let shade = ((row + col) % 2 == 0) ? Color.black.opacity(0.62) : Color.gray.opacity(0.58)
                    ctx.fill(Path(tile), with: .color(shade))
                }
            }
            ctx.stroke(Path(rect), with: .color(.white.opacity(0.45)), lineWidth: 1)
        case .step:
            guard let center = item.points.first else { return }
            let radius: CGFloat = max(12, item.lineWidth * 3.2)
            let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: circleRect), with: .color(color))
            ctx.stroke(Path(ellipseIn: circleRect), with: .color(.white), lineWidth: 1.5)
            let label = Text("\(item.stepNumber)")
                .font(.system(size: radius * 1.15, weight: .bold))
                .foregroundColor(item.color == .white ? .black : .white)
            ctx.draw(label, at: center, anchor: .center)
        case .text:
            guard let pt = item.points.first, !item.text.isEmpty else { return }
            let fontSize = max(14, item.lineWidth * 4.2)
            let resolved = ctx.resolve(
                Text(item.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(color)
            )
            let measured = resolved.measure(in: CGSize(width: 600, height: 300))
            let bgRect = CGRect(x: pt.x - 4, y: pt.y - 2, width: measured.width + 8, height: measured.height + 4)
            ctx.fill(Path(roundedRect: bgRect, cornerRadius: 4), with: .color(.black.opacity(0.45)))
            ctx.draw(resolved, at: pt, anchor: .topLeading)
        }
    }
}

// MARK: - Full-Resolution Retina Export Renderer

enum ZaloScreenshotRenderer {
    static func arrowPath(from start: CGPoint, to end: CGPoint, headLength: CGFloat) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * (headLength * 0.65),
            y: end.y - sin(angle) * (headLength * 0.65)
        )
        var path = Path()
        path.move(to: start)
        path.addLine(to: shaftEnd)
        return path
    }

    static func arrowHeadPath(from start: CGPoint, to end: CGPoint, headLength: CGFloat) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let spread: CGFloat = .pi / 6.5
        let p1 = CGPoint(x: end.x - headLength * cos(angle - spread), y: end.y - headLength * sin(angle - spread))
        let p2 = CGPoint(x: end.x - headLength * cos(angle + spread), y: end.y - headLength * sin(angle + spread))
        var path = Path()
        path.move(to: end)
        path.addLine(to: p1)
        path.addLine(to: p2)
        path.closeSubpath()
        return path
    }

    @MainActor
    static func render(session: ZaloCaptureSession) -> (NSImage, Data)? {
        let sel = session.selectionRect
        let scale = session.scaleFactor
        let imgW = CGFloat(session.fullCGImage.width)
        let imgH = CGFloat(session.fullCGImage.height)

        let cropPx = CGRect(
            x: max(0, round(sel.minX * scale)),
            y: max(0, round(sel.minY * scale)),
            width: min(imgW, round(sel.width * scale)),
            height: min(imgH, round(sel.height * scale))
        ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        guard cropPx.width >= 2, cropPx.height >= 2,
              let croppedCG = session.fullCGImage.cropping(to: cropPx) else {
            return nil
        }

        let pxW = croppedCG.width
        let pxH = croppedCG.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let cg = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        cg.interpolationQuality = .high
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)

        // 1. Draw base cropped image (bottom-left CoreGraphics coords)
        cg.draw(croppedCG, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))

        // 2. Bake real CoreImage CIPixellate mosaic blocks first
        let ciContext = CIContext(options: nil)
        for item in session.items where item.tool == .mosaic {
            let localRect = item.boundingRect.offsetBy(dx: -sel.minX, dy: -sel.minY)
            let mPx = CGRect(
                x: round(localRect.minX * scale),
                y: round(localRect.minY * scale),
                width: round(localRect.width * scale),
                height: round(localRect.height * scale)
            ).intersection(CGRect(x: 0, y: 0, width: CGFloat(pxW), height: CGFloat(pxH)))
            guard mPx.width >= 2, mPx.height >= 2,
                  let patch = croppedCG.cropping(to: mPx) else { continue }
            let ciInput = CIImage(cgImage: patch)
            if let filter = CIFilter(name: "CIPixellate") {
                filter.setValue(ciInput, forKey: kCIInputImageKey)
                filter.setValue(max(12.0, 9.0 * scale), forKey: kCIInputScaleKey)
                if let output = filter.outputImage?.cropped(to: ciInput.extent),
                   let pixCG = ciContext.createCGImage(output, from: ciInput.extent) {
                    let cgDrawRect = CGRect(
                        x: mPx.minX,
                        y: CGFloat(pxH) - mPx.maxY,
                        width: mPx.width,
                        height: mPx.height
                    )
                    cg.draw(pixCG, in: cgDrawRect)
                }
            }
        }

        // 3. Draw vector & text annotations in top-left flipped point coordinates (1:1 with SwiftUI!)
        cg.saveGState()
        cg.translateBy(x: 0, y: CGFloat(pxH))
        cg.scaleBy(x: scale, y: -scale)

        let flippedContext = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flippedContext

        for item in session.items where item.tool != .mosaic && item.tool != .select {
            let shiftedPoints = item.points.map { CGPoint(x: $0.x - sel.minX, y: $0.y - sel.minY) }
            drawCGItem(item, points: shiftedPoints, in: cg)
        }

        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()

        guard let outCG = cg.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: outCG)
        rep.size = sel.size
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        let outImage = NSImage(cgImage: outCG, size: sel.size)
        return (outImage, pngData)
    }

    private static func drawCGItem(_ item: ZaloAnnotationItem, points: [CGPoint], in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }

        let cgColor = item.color.cgColor
        cg.setStrokeColor(cgColor)
        cg.setFillColor(cgColor)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        switch item.tool {
        case .select, .mosaic:
            break
        case .rectangle:
            guard let a = points.first, let b = points.last else { return }
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            cg.setLineWidth(item.lineWidth)
            let path = CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)
            cg.addPath(path)
            cg.strokePath()
        case .ellipse:
            guard let a = points.first, let b = points.last else { return }
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            cg.setLineWidth(item.lineWidth)
            cg.strokeEllipse(in: r)
        case .arrow:
            guard let start = points.first, let end = points.last else { return }
            let headLen = max(14, item.lineWidth * 4.2)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let shaftEnd = CGPoint(x: end.x - cos(angle) * (headLen * 0.65), y: end.y - sin(angle) * (headLen * 0.65))
            cg.setLineWidth(item.lineWidth)
            cg.move(to: start)
            cg.addLine(to: shaftEnd)
            cg.strokePath()

            let spread: CGFloat = .pi / 6.5
            let p1 = CGPoint(x: end.x - headLen * cos(angle - spread), y: end.y - headLen * sin(angle - spread))
            let p2 = CGPoint(x: end.x - headLen * cos(angle + spread), y: end.y - headLen * sin(angle + spread))
            cg.move(to: end)
            cg.addLine(to: p1)
            cg.addLine(to: p2)
            cg.closePath()
            cg.fillPath()
        case .pen:
            guard points.count >= 2 else { return }
            cg.setLineWidth(item.lineWidth)
            cg.move(to: points[0])
            for p in points.dropFirst() { cg.addLine(to: p) }
            cg.strokePath()
        case .highlighter:
            guard points.count >= 2 else { return }
            cg.setStrokeColor(item.color.withAlphaComponent(0.38).cgColor)
            cg.setLineWidth(item.lineWidth * 4.2)
            cg.move(to: points[0])
            for p in points.dropFirst() { cg.addLine(to: p) }
            cg.strokePath()
        case .step:
            guard let center = points.first else { return }
            let radius = max(12, item.lineWidth * 3.2)
            let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            cg.fillEllipse(in: circleRect)
            cg.setStrokeColor(NSColor.white.cgColor)
            cg.setLineWidth(1.5)
            cg.strokeEllipse(in: circleRect)

            let textColor: NSColor = item.color == .white ? .black : .white
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
                .foregroundColor: textColor
            ]
            let str = NSString(string: "\(item.stepNumber)")
            let size = str.size(withAttributes: attrs)
            str.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
        case .text:
            guard let pt = points.first, !item.text.isEmpty else { return }
            let fontSize = max(14, item.lineWidth * 4.2)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: item.color
            ]
            let str = NSString(string: item.text)
            let size = str.size(withAttributes: attrs)
            let bgRect = CGRect(x: pt.x - 4, y: pt.y - 2, width: size.width + 8, height: size.height + 4)
            cg.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            cg.addPath(bgPath)
            cg.fillPath()
            str.draw(at: pt, withAttributes: attrs)
        }
    }
}
