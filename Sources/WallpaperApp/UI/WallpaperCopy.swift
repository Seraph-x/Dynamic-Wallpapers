import WallpaperCore

/// Shared functional copy. Page slogans stay in the library and favorites headers.
enum WallpaperCopy {
    static let entryAudioHelp = "仅影响当前播放列表中的此项及其预览，不影响其他播放列表。"
    static let directAudioHelp = "预览使用此设置；应用壁纸时保存到目标显示器，不影响播放列表中的声音设置。"
    static let displayAudioHelp = "立即更新此壁纸的声音；同步显示器共用设置，不影响播放列表。"
    static let transitionHelp = "画面与声音同步渐变。"
    static let sortingHelp = "拖动壁纸可调整顺序，选择壁纸可设置停留时长。"
    static let imageTimingHelp = "静态图片每次显示所设时长，循环模式下的总停留时长为所设时长 × 循环次数；视频和动图的完整播放与循环按自身单次时长计算。"
    static let pauseHelp = "自动暂停不受节能开关影响，所有暂停原因解除后恢复；手动暂停需手动恢复，暂停原因可在菜单栏查看。"
    static let storageExplanation = "新导入的文件会复制到应用的 Media 目录，网页会复制整个项目；移动或删除原文件不影响副本播放。"
    static let clearLibraryConfirmation = "先备份配置，再移除全部素材、收藏、播放列表和显示器绑定，并删除托管副本；保留设置、原文件和系统底图。配置备份不包含媒体文件。"
    static let supportedFormats = "视频：MP4、MOV、M4V、MKV、WebM、AVI\n图片与动图：JPEG/JPG、PNG、HEIC、HEIF、GIF、APNG"
    static let resetConfirmation = "壁纸记录、播放列表和设置将重置，现有配置会先备份，原文件不变。"
    static let quitTranscoding = "未完成的任务将被取消，清理临时文件后退出；已完成的文件会保留，取消的任务需重新开始。"
}

extension ContentFit {
    var title: String { self == .fill ? "填满" : "完整显示" }
    var helpText: String {
        self == .fill ? "保持画面比例，裁剪超出显示区域的部分。" : "显示完整画面，空余区域显示为黑色。"
    }
}
