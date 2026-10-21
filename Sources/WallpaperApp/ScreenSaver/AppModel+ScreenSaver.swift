import Foundation
import ScreenSaverCore
import WallpaperCore

extension AppModel {
    var canClearPublishedScreenSaver: Bool {
        guard let screenSaver else { return false }
        return screenSaver.settings.source != nil || screenSaver.state.published?.generationID != nil
    }

    @discardableResult
    func bindScreenSaver(_ source: ScreenSaverSource) -> Task<ScreenSaverCurrentPointer?, Error> {
        guard !isShuttingDown else {
            return Task { throw ScreenSaverFailure(code: .applicationClosing(.configuration)) }
        }
        guard let screenSaver, !loadFailed else {
            return Task { throw ScreenSaverFailure(code: .settingsUnavailable) }
        }
        section = .screenSaver
        return screenSaver.update(screenSaver.settings.selecting(source))
    }

    @discardableResult
    func bindScreenSaver(_ displayed: ScreenSaverProjection) -> Task<ScreenSaverCurrentPointer?, Error> {
        guard !isShuttingDown else {
            return Task { throw ScreenSaverFailure(code: .applicationClosing(.configuration)) }
        }
        guard let screenSaver, !loadFailed else {
            return Task { throw ScreenSaverFailure(code: .settingsUnavailable) }
        }
        do {
            let current = try ScreenSaverProjection(library: library, source: displayed.source)
            guard current == displayed else { throw ScreenSaverFailure(code: .invalidProjection) }
            var settings = screenSaver.settings.selecting(displayed.source)
            if !displayed.exclusions.isEmpty {
                settings = try settings.confirming(ScreenSaverConsent(acknowledging: displayed))
            }
            section = .screenSaver
            return screenSaver.update(settings)
        } catch { return Task { throw error } }
    }

    @discardableResult
    func clearPublishedScreenSaver() -> Task<ScreenSaverCurrentPointer?, Error> {
        guard !isShuttingDown else {
            return Task { throw ScreenSaverFailure(code: .applicationClosing(.configuration)) }
        }
        guard let screenSaver, !loadFailed else {
            return Task { throw ScreenSaverFailure(code: .settingsUnavailable) }
        }
        discardScreenSaverImportChoices()
        return screenSaver.update(screenSaver.settings.selecting(nil))
    }
}
