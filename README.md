# IPA 工坊

在 iPhone 或 iPad 上匯入已解密的 IPA，選擇補丁並重新封裝成 IPA。封裝與編輯在裝置本機完成。

## 下載與安裝

從 GitHub Releases 下載 `IPAWorkshop-unsigned.ipa`。使用自己的 Apple 開發簽名安裝。修改後匯出的 IPA 也需要重新簽名。

## 使用方式

1. 開啟 IPA 工坊，點「選擇 IPA」，從「檔案」選擇你有權修改的已解密 IPA。
2. 確認 App 名稱、套件識別碼及版本。可輸入新顯示名稱，或選擇既有 PNG 路徑並從「檔案」指定替換圖片。
3. 匯入原始套件識別碼的 YouTube IPA 時，可另外挑選 YouTube 補丁。
4. 點「封裝 IPA」，再用「分享或儲存 IPA」將檔案存到「檔案」。

通用補丁支援顯示名稱與獨立 PNG 資源。YouTube 補丁提供減少廣告、背景播放、隱藏 Shorts 分頁、清理系統分享連結及 SponsorBlock 贊助片段跳過。YouTube 補丁為實驗性功能，取決於 App 版本和內部介面。未加入 YouTube Music、Reddit、Return YouTube Dislike、播放器手勢或 Assets.car 編輯。

使用原始套件識別碼、已解密的單一 arm64 YouTube IPA。匯出後要以自己的簽名重新簽署主程式及內嵌動態函式庫。主程式標頭沒有可用空間時會顯示錯誤。

只有勾選 SponsorBlock 時，修改版 YouTube 才會向 SponsorBlock 服務查詢，送出影片 ID 的 SHA-256 雜湊前四碼。網站與 App 均不會上傳原始 IPA。

iOS 介面參考 [YTLite](https://github.com/dayanch96/YTLite) 和 [YTKACE](https://github.com/m0re11/ytkace)，贊助片段使用 [SponsorBlock API](https://wiki.sponsor.ajay.app/w/API_Docs)。

## 編譯

專案以 SwiftUI 開發，支援 iOS 16.0 以上版本。GitHub Actions 使用 macOS 建置環境、XcodeGen 和 ZIPFoundation 0.9.20。推送到 main 時會編譯 arm64 的 IPA，驗證封裝並上傳到 Releases。

在 Mac 上可以先執行 `bash build-youtube-patch.sh`以產生 `YouTubePatch.bin`，再執行 `brew install xcodegen`、`xcodegen generate`，並以 Xcode 開啟 `IPAWorkshop.xcodeproj`。
