import Foundation
import WallpaperCore

/// Capture the source as well as the control's ID so a late edit cannot change a replacement wallpaper.
struct AudioEditTarget: Hashable {
    let id: CurrentWallpaperAudioTarget.ID
    let mediaID: UUID

    func audio(in library: Library) throws -> AudioSettings {
        switch id {
        case .playlist(let playlistID, let entryID):
            if let entry = library.playlists.first(where: { $0.id == playlistID })?.entries.first(where: {
                $0.id == entryID && $0.mediaID == mediaID
            }) { return entry.audio }
        case .direct(let groupID):
            if let binding = library.displays.first(where: { $0.groupID == groupID }),
               case .media(let currentID, let audio) = binding.source, currentID == mediaID { return audio }
        }
        throw WallpaperError("声音设置的目标已更换或移除，无法保存。")
    }

    func write(_ audio: AudioSettings, to library: inout Library) throws {
        _ = try self.audio(in: library)
        switch id {
        case .playlist(let playlistID, let entryID):
            let list = library.playlists.firstIndex { $0.id == playlistID }!
            let entry = library.playlists[list].entries.firstIndex { $0.id == entryID }!
            library.playlists[list].entries[entry].audio = audio
        case .direct(let groupID):
            for index in library.displays.indices where library.displays[index].groupID == groupID {
                library.displays[index].source = .media(mediaID, audio: audio)
            }
        }
    }
}

@MainActor
final class AudioEditSession {
    private struct Draft { let target: AudioEditTarget; let audio: AudioSettings }
    private var draft: Draft?
    private let apply: (AudioEditTarget, AudioSettings) throws -> Void
    private let commit: (AudioEditTarget, AudioSettings) throws -> Void
    private(set) var isCommitting = false
    var onChange: (() -> Void)?

    init(apply: @escaping (AudioEditTarget, AudioSettings) throws -> Void,
         commit: @escaping (AudioEditTarget, AudioSettings) throws -> Void) {
        self.apply = apply; self.commit = commit
    }

    func value(for target: AudioEditTarget, persisted: AudioSettings) -> AudioSettings {
        draft?.target == target ? draft!.audio : persisted
    }

    func update(_ audio: AudioSettings, target: AudioEditTarget) throws {
        try audio.validate()
        if let draft, draft.target != target { try finish() }
        try apply(target, audio)
        onChange?()
        draft = Draft(target: target, audio: audio)
    }

    /// A failed commit keeps the draft available for retry, including when quitting.
    func finish() throws {
        guard let draft, !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }
        try commit(draft.target, draft.audio)
        onChange?()
        self.draft = nil
    }
}
