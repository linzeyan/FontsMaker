# FontsMaker

把開源字型改成適合自己閱讀的版本：在 Kobo 上太細就加粗、閱讀器不支援直排就做偽直排、簡體書想看繁體字形就簡轉繁。調好的設定存成一份「配方」，用命令列可以重建出位元組相同的字型。

支援 macOS 與 iPhone／iPad。

## 功能

- **三步完成**：① 挑字型 → ② 調整 → ③ 匯出並安裝。
- **字型來源**
  - 內建目錄：中文 12 套、English 15 套，都是核對過授權的 OFL 字型。
  - 從網址加入：GitHub release 或檔案網址都可以，zip 會自動解開。
  - 自己的字型檔：`.ttf`、`.otf`、`.ttc`、可變字型。
- **效果**
  - 加粗：會列出加粗後筆畫可能黏在一起的字，可以逐字決定接受、不加粗、改用較小的粗細，或改用另一套字型的字。
  - 直排閱讀（偽直排）：給不支援直排的閱讀器用，把書轉 90° 讀就是直排。
  - 簡體書顯示繁體：可選台灣字形，並依詞彙選字，例如「里程碑」不會變成「裡程碑」。
  - 英文排版：字寬跟著加寬、字距、行高，也可以把中文字型附的英文字母換成另一套英文字型。
  - 逐字修改造型：Mac 與 iPad 可以編輯，iPhone 只能檢視。
- **預覽**：電子紙模擬頁面，橫排、直排都看得到。匯出後會用實際的字型檔再排一次版，確認系統讀得出來。
- **匯出**：先選要放到哪裡讀，完成後顯示該裝置的安裝步驟。可選這台 Mac（僅 macOS，App 直接安裝，也能從 App 移除）、Kobo、Kindle、KOReader、只存檔案。
  - 一起存下的檔案：字型 `.ttf`、配方 `.json`，以及來源字型的授權全文。
  - 英文字型可以一次匯出 Regular／Italic／Bold／Bold Italic 四種樣式。
- **授權與命名**：修改受限的字型會被拒絕處理。新字型名稱不能包含原字型名稱；匯出前會提醒，原作者保留的名稱（RFN）要自己再確認一次。



## 安裝

### macOS App

1. 到 [Releases](https://github.com/linzeyan/FontsMaker/releases) 下載 `FontsMaker-<版本>-macos-universal.zip`。需要 macOS 14 以上，Apple Silicon 與 Intel 都可以用。
2. 解壓縮，把 FontsMaker.app 拖進「應用程式」。
3. App 沒有經過 Apple 公證，第一次開啟會被擋下：到「系統設定 › 隱私權與安全性」按「強制打開」，之後就能正常開啟。

### iPhone／iPad

還沒有上架。iOS App 無法從下載的檔案安裝，要從原始碼建置（見下方）。

### 命令列工具 `fontsmaker`

給要批次產生字型、或把配方放進自動化流程的人。

1. 到 [Releases](https://github.com/linzeyan/FontsMaker/releases) 下載 `FontsMaker-CLI-<版本>-macos-universal.zip`，然後解壓縮。
2. 資料夾裡的 `fontsmaker` 和 `FontsMaker_FontsMakerKit.bundle` 要放在同一個資料夾，簡轉繁、直排用到的資料在 bundle 裡。
3. 執行檔沒有經過公證，先解除隔離：

   ```sh
   xattr -dr com.apple.quarantine FontsMaker-CLI-<版本>
   ```

4. 要在任何目錄都能執行，可以在 `PATH` 裡放一個指向它的 symlink：

   ```sh
   ln -s "$PWD/FontsMaker-CLI-<版本>/fontsmaker" /usr/local/bin/fontsmaker
   ```

用法：

```sh
fontsmaker inspect MyFont.ttf                  # 名稱、字數、外框格式、授權狀態、檔內宣告的保留名稱
fontsmaker build recipe.json --out-dir out     # 依配方產生字型；有加粗的配方會另外輸出風險報表
```

配方裡的來源字型路徑是相對於配方檔的位置，並用 sha256 鎖定來源檔。只要來源字型、配方和 FontsMaker 版本都相同，產出的檔案就逐位元組相同。範例在 [recipes/examples/](recipes/examples/)，App 匯出的 `.json` 也是同一種格式。

## 從原始碼建置

需要 Xcode（Swift 6）。開發動作都從 `make` 進去，`make help` 會列出所有指令。

```sh
make setup      # 安裝 xcodegen，下載測試用的參考字型，產生 Xcode 專案
make test       # 引擎與 CLI 的測試，以及 macOS、iOS 模擬器上的 App 測試
make run-mac    # 建置並啟動 macOS App
make run        # 建置並在 iOS 模擬器啟動
make cli        # 建置 CLI：.build/release/fontsmaker
```

`App/FontsMaker.xcodeproj` 由 `App/project.yml` 產生，不進版控。要改專案設定請改 `project.yml`，再執行 `make generate`。

## 發版

1. 把 `App/project.yml` 的 `MARKETING_VERSION` 改成新版號。
2. 推送同名 tag，一次推一個：

   ```sh
   git tag v0.1.0 && git push origin refs/tags/v0.1.0
   ```

GitHub Actions 會建出 macOS App 與 CLI 的 zip，放上 Release。tag 和 `MARKETING_VERSION` 不一致時，會直接失敗。
