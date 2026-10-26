import AppKit
import WallpaperCore
import WallpaperAudioSpectrum

@MainActor protocol EditorScenePreviewPage: AnyObject {
    var view: NSView { get }
    var origin: String { get }
    var onReady: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onDiagnostic: (([String: Any]) -> Void)? { get set }
    var onSceneScriptIssue: (([String: Any]) -> Void)? { get set }
    var onSceneScriptRawIssue: ((String) -> Void)? { get set }
    func start() throws
    func setSpectrum(_ value: AudioSpectrum) throws
    func setPlaying(_ value: Bool) async throws
    func setUserProperties(_ values: [String: Any]) async throws
    func setUserPropertyData(_ data: Data) async throws
    func close() async throws
}

/// Owns one immutable snapshot until every acquired native page has released.
@MainActor final class EditorScenePreviewSession {
    enum State: String { case idle, loading, playing, paused, failed, closing, closed }
    private let makePage: () throws -> any EditorScenePreviewPage
    let audio: EditorPreviewAudioController?
    private var readyRequested = false
    private let cleanup: () async throws -> Void
    private var page: (any EditorScenePreviewPage)?
    private var generation = UUID()
    private(set) var state: State = .idle
    private(set) var propertyInspection: Result<EditorPreviewProperties, Error>?
    var properties: EditorPreviewProperties? {
        if case .some(.success(let properties)) = propertyInspection { return properties }
        return nil
    }
    var propertyInspectionFailure: Error? {
        if case .some(.failure(let error)) = propertyInspection { return error }
        return nil
    }
    private(set) var propertyValues = EditorPreviewPropertyValues()
    private(set) var propertyFailure: Error?
    private(set) var busy = false
    private(set) var failure: Error?
    private(set) var diagnostic: [String: Any]?
    private(set) var scriptIssues: [EditorScriptDiagnostic] = []
    private(set) var consoleDiagnostics: [[String: Any]] = []
    private(set) var rawJSONReports: [String] = []
    private var rawJSONIdentities: Set<Data> = []
    var onChange: (() -> Void)?
    var view: NSView? { page?.view }
    var origin: String? { page?.origin }

    init(makePage: @escaping () throws -> any EditorScenePreviewPage,
         audio: EditorPreviewAudioController? = nil,
         properties: EditorPreviewProperties? = nil,
         cleanup: @escaping () async throws -> Void) {
        self.makePage = makePage; self.audio = audio; self.cleanup = cleanup
        propertyInspection = properties.map { .success($0) }; propertyValues = properties?.defaults ?? [:]
    }

    func start() throws {
        guard state == .idle else { throw WallpaperError("Preview has already started") }
        try mount()
    }

    private func mount() throws {
        generation = UUID(); readyRequested = false; let capturedGeneration = generation
        propertyValues = properties?.defaults ?? [:]; propertyFailure = nil
        failure = nil; diagnostic = nil; scriptIssues = []; consoleDiagnostics = []; rawJSONReports = []; rawJSONIdentities = []; state = .loading
        do {
            let acquired = try makePage(); page = acquired
            acquired.onReady = { [weak self, weak acquired] in
                guard let self, let acquired, self.generation == capturedGeneration, self.state == .loading, !self.readyRequested else { return }
                self.readyRequested = true
                Task { @MainActor [weak self] in
                    guard let self, self.generation == capturedGeneration, self.state == .loading else { return }
                    do {
                        try await acquired.setPlaying(true)
                        guard self.generation == capturedGeneration, self.state == .loading else { return }
                        self.state = .playing; self.subscribe(acquired, generation: capturedGeneration); self.onChange?()
                    } catch {
                        guard self.generation == capturedGeneration, self.state == .loading else { return }
                        self.fail(error)
                    }
                }
            }
            acquired.onError = { [weak self] error in
                guard let self, self.generation == capturedGeneration,
                      self.state != .closing, self.state != .closed else { return }
                self.fail(error)
            }
            acquired.onDiagnostic = { [weak self] diagnostic in
                guard let self, self.generation == capturedGeneration,
                      self.state != .closing, self.state != .closed else { return }
                self.diagnostic = diagnostic; self.consoleDiagnostics.append(diagnostic); self.onChange?()
            }
            acquired.onSceneScriptIssue = { [weak self] raw in
                guard let self, self.generation == capturedGeneration,
                      self.state != .closing, self.state != .closed else { return }
                do {
                    let issue = try EditorScriptDiagnostic(validated: raw)
                    if let index = self.scriptIssues.firstIndex(where: { $0.key == issue.key }) { self.scriptIssues[index] = issue }
                    else { self.scriptIssues.append(issue) }
                    self.onChange?()
                } catch { self.fail(error) }
            }
            acquired.onSceneScriptRawIssue = { [weak self] rawJSON in
                guard let self, self.generation == capturedGeneration,
                      self.state != .closing, self.state != .closed else { return }
                // The bridge validated the exact schema. Keep its original JSON
                // bytes because malformed UTF16 cannot be decoded losslessly.
                if self.rawJSONIdentities.insert(Data(rawJSON.utf8)).inserted {
                    self.rawJSONReports.append(rawJSON); self.onChange?()
                }
            }
            onChange?() // Attach the native view before starting its child browser.
            try acquired.start()
        } catch { fail(error); throw error }
    }

    func setPlaying(_ value: Bool) async throws {
        guard !busy, [.playing, .paused].contains(state), let page else {
            throw WallpaperError("Preview is not ready for playback commands")
        }
        let capturedGeneration = generation
        busy = true; onChange?(); defer { busy = false; onChange?() }
        do {
            if !value { audio?.removeSubscriber(id: capturedGeneration) }
            if let failure { throw failure }
            try await page.setPlaying(value)
            guard generation == capturedGeneration else { return }
            if let failure { throw failure }
            state = value ? .playing : .paused
            if value { subscribe(page, generation: capturedGeneration) }
        } catch { fail(error); throw error }
    }

    func configurePropertyInspection(_ inspection: Result<EditorPreviewProperties, Error>?) {
        precondition(state == .idle, "Captured property inspection cannot change after preview starts")
        propertyInspection = inspection; propertyValues = properties?.defaults ?? [:]; onChange?()
    }

    func setUserProperties(_ values: [String: Any]) async throws {
        if let propertyInspectionFailure { throw propertyInspectionFailure }
        guard let properties else { throw WallpaperError("Preview has no captured properties") }
        try await applyPropertyValues(properties.validate(values))
    }

    private func applyPropertyValues(_ validated: EditorPreviewPropertyValues) async throws {
        guard !busy, [.playing, .paused].contains(state), let page else {
            throw WallpaperError("Preview is not ready for property commands")
        }
        let data = try validated.encoded()
        let capturedGeneration = generation
        busy = true; propertyFailure = nil; onChange?(); defer { busy = false; onChange?() }
        do {
            if let failure { throw failure }
            // NSData avoids importing a dictionary through Swift String keys,
            // preserving exact Unicode names in one atomic native command.
            try await page.setUserPropertyData(data)
            guard generation == capturedGeneration, [.playing, .paused].contains(state) else {
                throw WallpaperError("Property acknowledgement belongs to a retired preview")
            }
            if let failure { throw failure }
            propertyValues = propertyValues.merging(validated)
        } catch {
            propertyFailure = error
            // Property rejection does not alter play state or system-audio subscription demand.
            throw error
        }
    }

    func resetUserProperties() async throws {
        if let propertyInspectionFailure { throw propertyInspectionFailure }
        guard let properties else { throw WallpaperError("Preview has no captured properties") }
        try await applyPropertyValues(properties.defaults)
    }

    func restart() async throws {
        guard !busy, state != .closed, state != .idle else {
            throw WallpaperError("Preview is busy or closed")
        }
        busy = true; onChange?(); defer { busy = false; onChange?() }
        do { try await releasePage(); try mount() }
        catch { fail(error); throw error }
    }

    func close() async throws {
        if state == .closed { return }
        guard !busy else { throw WallpaperError("Preview operation is still in progress") }
        busy = true; onChange?(); defer { busy = false; onChange?() }
        do {
            try await releasePage()
            try await cleanup()
            state = .closed; failure = nil; diagnostic = nil; scriptIssues = []; consoleDiagnostics = []; rawJSONReports = []; rawJSONIdentities = []
        } catch { fail(error); throw error }
    }

    private func releasePage() async throws {
        // Invalidate ready/error/diagnostic callbacks before the asynchronous close.
        let spectrumFailure = audio?.removeSubscriber(id: generation)
        generation = UUID(); state = .closing; onChange?()
        if let page {
            do { try await page.close(); self.page = nil; onChange?() }
            catch {
                if let spectrumFailure { throw WallpaperErrorGroup([spectrumFailure, error]) }
                throw error
            }
        }
        if let spectrumFailure { throw spectrumFailure }
    }

    private func subscribe(_ page: any EditorScenePreviewPage, generation capturedGeneration: UUID) {
        audio?.addSubscriber(id: capturedGeneration, deliver: { [weak self, weak page] value in
            guard let self, self.generation == capturedGeneration, self.state == .playing, let page else { return }
            try page.setSpectrum(value)
        }, onFailure: { [weak self] error in
            guard let self, self.generation == capturedGeneration else { return }
            self.fail(error)
        })
    }

    private func fail(_ error: Error) {
        failure = error
        if let spectrumFailure = audio?.removeSubscriber(id: generation) {
            failure = WallpaperErrorGroup([error, spectrumFailure])
        }
        state = .failed; onChange?()
    }
}
