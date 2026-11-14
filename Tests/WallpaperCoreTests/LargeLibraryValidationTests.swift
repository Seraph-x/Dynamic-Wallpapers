import XCTest
@testable import WallpaperCore

final class LargeLibraryValidationTests: XCTestCase {
    func testLargeLibraryValidationWorkload() throws {
        var library = Library.empty
        library.media = (0..<5000).map { MediaItem(url: URL(fileURLWithPath: "/tmp/item-\($0).png"),
            kind: .image, width: 640, height: 360) }
        library.playlists = (0..<100).map { list in
            Playlist(name: "List \(list)", entries: (0..<100).map {
                PlaylistEntry(mediaID: library.media[(list * 100 + $0) % library.media.count].id)
            })
        }
        library.displays = library.playlists.enumerated().map { index, list in
            DisplayBinding(id: "display-\(index)", playlistID: list.id, currentEntryID: list.entries.last!.id)
        }
        let clock = ContinuousClock()
        let start = clock.now
        try library.validate()
        print("LIBRARY_VALIDATION_WORKLOAD media=5000 entries=10000 displays=100 elapsed=\(start.duration(to: clock.now))")
    }

    func testDuplicateMediaFailsBeforeBuildingIndex() {
        var library = Library.empty
        let item = MediaItem(url: URL(fileURLWithPath: "/tmp/item.png"), kind: .image, width: 64, height: 64)
        library.media = [item, item]
        XCTAssertThrowsError(try library.validate()) { XCTAssertEqual($0.localizedDescription, "素材库包含重复标识。") }
    }

    func testCurrentEntryMustBelongToTheBoundPlaylist() {
        var library = Library.empty
        let item = MediaItem(url: URL(fileURLWithPath: "/tmp/item.png"), kind: .image, width: 64, height: 64)
        library.media = [item]
        let first = PlaylistEntry(mediaID: item.id), second = PlaylistEntry(mediaID: item.id)
        library.playlists = [Playlist(name: "First", entries: [first]), Playlist(name: "Second", entries: [second])]
        library.displays = [DisplayBinding(id: "display", playlistID: library.playlists[0].id, currentEntryID: second.id)]
        XCTAssertThrowsError(try library.validate()) {
            XCTAssertEqual($0.localizedDescription, "显示器绑定引用了不存在的播放列表或条目。")
        }
    }
}
