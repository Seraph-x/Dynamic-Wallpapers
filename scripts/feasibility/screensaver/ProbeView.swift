import ScreenSaver
import OSLog

@objc(DWNativeScreenSaverProbeView)
final class DWNativeScreenSaverProbeView: ScreenSaverView {
    @objc private(set) dynamic var diagnosticState = "idle"
    @objc private(set) dynamic var diagnosticMessage = ""
    private var directoryAccess: ProbeDirectoryAccess?
    private var playback: ProbePlayback?
    private var completedCounts: [String: Int] = [:]
    @objc var diagnosticFrameCounts: NSDictionary { (playback?.frameCounts ?? completedCounts) as NSDictionary }
    private let status = NSTextField(wrappingLabelWithString: "屏保宿主验证原型：尚未配置")
    private let logger = Logger(subsystem: "local.dynamicwallpaper.screensaver.probe", category: "lifecycle")
    private lazy var configuration = ProbeConfiguration { [weak self] directory in
        guard let self else { throw ProbeAccessError.closed }
        try self.makeAccess().authorize(directory)
        self.record("configured", message: "测试目录授权已保存；重新启动原型以验证读取。")
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0 / 30
        status.textColor = .white
        status.frame = bounds.insetBy(dx: 12, dy: 12)
        status.autoresizingMask = [.width, .height]
        addSubview(status)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var hasConfigureSheet: Bool { true }
    override var configureSheet: NSWindow? { configuration.window }

    override func startAnimation() {
        super.startAnimation()
        do {
            try releasePlayback()
            let access = try makeAccess().acquire()
            directoryAccess = access
            let playback = ProbePlayback(view: self) { [weak self] file, count in
                self?.record("playing", message: "已解码 \(file)：\(count) 种不同的实际像素。")
            }
            self.playback = playback
            completedCounts = [:]
            try playback.start(directory: access.url)
            record("loading", message: "正在验证授权目录中的真实媒体。")
        } catch ProbeAccessError.authorizationRequired {
            record("authorizationRequired", message: ProbeAccessError.authorizationRequired.localizedDescription)
        } catch {
            fail(error)
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        do {
            try releasePlayback()
            record("stopped", message: "原型已停止，目录访问已释放。")
        } catch { record("failed", message: error.localizedDescription) }
    }

    override func animateOneFrame() {
        do { try playback?.tick() }
        catch { fail(error) }
    }

    private func releasePlayback() throws {
        completedCounts = playback?.frameCounts ?? completedCounts
        playback?.stop()
        playback = nil
        try directoryAccess?.close()
        directoryAccess = nil
    }

    private func fail(_ error: Error) {
        super.stopAnimation()
        var message = error.localizedDescription
        do { try releasePlayback() }
        catch { message += "; release: \(error.localizedDescription)" }
        record("failed", message: message)
    }

    private func makeAccess() throws -> ProbeAccess {
        guard let identifier = Bundle(for: Self.self).bundleIdentifier,
              let defaults = ScreenSaverDefaults(forModuleWithName: identifier) else {
            throw ProbeAccessError.defaultsUnavailable
        }
        return ProbeAccess(defaults: defaults)
    }

    private func record(_ state: String, message: String) {
        diagnosticState = state
        diagnosticMessage = message
        status.stringValue = message
        logger.notice("state=\(state, privacy: .public) pid=\(ProcessInfo.processInfo.processIdentifier) preview=\(self.isPreview) message=\(message, privacy: .public)")
    }
}
