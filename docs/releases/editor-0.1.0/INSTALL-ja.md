# Dynamic Wallpaper Editor 0.1.0 — 日本語

Apple Silicon (arm64) · macOS 14.0+ · Build 1

Editor の ZIP を別途ダウンロードし、付属の `SHA256SUMS.txt` と SHA-256 を照合します。
展開して **Dynamic Wallpaper Editor.app** をアプリケーションへ移動します。
このリリースはアドホック署名で、公証されていません。信頼できるダウンロードを
開くには「システム設定 → プライバシーとセキュリティ」で許可が必要な場合があります。
自動インストールは行いません。壁紙のメニューバー **Editor** は、インストール済みなら
直接起動し、未導入ならダウンロードとキャンセルのみを表示します。ダウンロードは
公式リリースページを開きます。インストールは手動です。

「ファイル → Dynamic Wallpaper で開く」で保存済みシーンをライブラリへ取り込み、
壁紙側で適用します。それぞれ独立して終了できます。削除は Editor を終了し `.app`
だけを削除します。工程は `~/Library/Application Support/DynamicWallpaperEditor/Projects/`
に残ります。通常の壁紙再生には影響せず、双方とも単独で動作します。
