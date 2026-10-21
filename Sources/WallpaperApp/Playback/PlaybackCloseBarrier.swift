import WallpaperCore

enum PlaybackCloseBarrier {
    /// One failed release must not short-circuit other resources still shutting down.
    static func wait(for tasks: [Task<Void, Error>]) async throws {
        var errors: [Error] = []
        for task in tasks {
            if case .failure(let error) = await task.result { errors.append(error) }
        }
        if errors.count == 1 { throw errors[0] }
        if !errors.isEmpty { throw WallpaperErrorGroup(errors) }
    }
}
