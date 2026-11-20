# IPA 工坊

在 iPhone 或 iPad 上匯入已解密的 IPA，修改 App 顯示名稱、替換獨立 PNG 資源，再重新封裝成 IPA。所有編輯均在裝置本機執行。

## 下載與安裝

從 GitHub Releases 下載 `IPAWorkshop-unsigned.ipa`。使用自己的 Apple 開發簽名安裝。修改後匯出的 IPA 也需要重新簽名。

## 使用方式

1. 開啟 IPA 工坊，點「選擇 IPA」，從「檔案」選擇你有權修改的已解密 IPA。
2. 確認 App 名稱、套件識別碼及版本。可輸入新顯示名稱，或選擇既有 PNG 路徑並從「檔案」指定替換圖片。
3. 點「封裝 IPA」，再用「分享或儲存 IPA」將檔案存到「檔案」。

目前的修改項目是顯示名稱與獨立 PNG 資源。編譯進 Assets.car 的圖片、去廣告、SponsorBlock、背景播放及 Android 補丁均未實作。

## 編譯

專案以 SwiftUI 開發，支援 iOS 16.0 以上版本。GitHub Actions 使用 macOS 建置環境、XcodeGen 和 ZIPFoundation 0.9.20。推送到 main 時會編譯 arm64 的 IPA，驗證封裝並上傳到 Releases。

在 Mac 上也可以執行 `brew install xcodegen`、`xcodegen generate`，再以 Xcode 開啟 `IPAWorkshop.xcodeproj`。
