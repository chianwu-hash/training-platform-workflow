# 磨課師與公務園研習操作工具

把兩個平台的實際操作經驗整理成可移植的 SOP 與工具，供使用者和 AI 助手在另一台 Windows 電腦接續工作。

- 平台：edu磨課師、e等公務園+；公務園下的機關學習網以衛生福利e學園實作驗證。
- 功能：固定分頁觀察、起點播放、計時檢查、自然播完核對、下一影片切換、完成狀態保存。
- SOP：選課、登入核對、閒置處置、一般問卷、使用者測驗、原始證書、學校回傳。
- 測驗與本人出席聲明由使用者完成。CLI 不會代填問卷、登入或自動點閒置確認；這些依 SOP 由使用者或已獲授權的 AI 處理。

## 在另一台電腦安裝

需要 Windows、Chrome、Node.js 22.12 以上、Git、PowerShell 7.6.1 以上，以及能讀取這個私人 repo 的 GitHub 帳號。Node 套件由鎖定檔安裝，不會下載另一套 Chrome。

```powershell
git clone https://github.com/chianwu-hash/training-platform-workflow.git
cd training-platform-workflow
npm ci
npm run check
npm test
```

已有 `ai-browser-launch` 的電腦沿用原設定，跳過以下安裝。沒有啟動器時，先安裝同一套底層 CDP 工具，再安裝本 repo 內的共享占用啟動器：

```powershell
npm install -g github:chianwu-hash/cdp-tools
pwsh -NoProfile -File scripts/install-browser.ps1
```

關閉後重新開啟終端機及 AI 助手，確認 `Get-Command ai-browser-launch`。安裝器使用 `%LOCALAPPDATA%/AIWorkBrowser`，建立註冊 main、01、02 實例，各自獨立 profile；不搬移原電腦登入資料，也不覆寫既有啟動器。若公司政策禁止全域 npm 或修改使用者 PATH，請由管理者安裝共享工具。

第一次到新電腦，**自行登入平台**。不要複製 Chrome profile、Cookie、密碼或 session。看完 [新電腦設定](docs/新電腦設定.md)，再填課程設定。

## 開啟並綁定精確分頁

從 PowerShell 7 執行，以自己的穩定任務識別取代範例 Owner：

```powershell
$opened = ai-browser-launch -Acquire -Instance 01 -Owner training-task-01 https://moocs.moe.edu.tw/moocs/ -Json | ConvertFrom-Json
$opened | Select-Object Instance, TargetId, CdpUrl
ai-browser-launch -Release -Owner training-task-01 -LeaseId $opened.LeaseId -Json
```

這裡只為首次開頁與取得分頁 ID。自行登入、選課並進入影片，保持同一分頁。之後工具不會另開、刷新或改用其他分頁。

複製範本到 `local/`；此資料夾不會提交 Git：

```powershell
New-Item -ItemType Directory local -Force
Copy-Item config/moocs.example.json local/course.json
# 公務園改用 config/elearn.example.json
```

編輯 `local/course.json`：完整課程 URL、課名、精確 targetId、帳號標示、實際影片章節順序、最晚停止時間。`chapterIndex` 從 0 起算。首次設定前核對畫面上的選中章節；工具第一次觀察會將目前來源綁到此章節。`accountMarker` 只作後續一致性檢查，首次必須先從個人資料或框架核對完整身分，不能只憑遮罩姓名推定。

## 操作指令

```powershell
npm run training -- observe local/course.json
npm run training -- start local/course.json
npm run training -- watch local/course.json
npm run training -- advance local/course.json
```

| 指令 | 行為 |
|---|---|
| observe | 取得占用，核對分頁／課程／帳號與影片，保存觀察與下次檢查時間 |
| start | 僅啟動剛載入且停在 0–1 秒的暫停影片，再核對進度前進 |
| watch | 未到檢查點只讀本地狀態；到點每 5–8 秒觀察，直到下一檢查點、自然播完或停止條件 |
| advance | 重新取得現場自然結束證據，切下一影片並核對新來源；最後一部寫入 completed |

`watch` 不會自己切章，回傳 `ready_to_advance` 後才執行 `advance`。使用 AI 定時監看時，讓 AI 每分鐘呼叫 watch；取得現場證據後呼叫 advance，再繼續排程。工具不替你建立 Codex 排程，完整交接提示見 [AI 接續提示](docs/AI接續提示.md)。取消／期限到／出錯時停止排程。

播放器選擇器是**曾實際使用的範本**，不是所有課程的保證。公務園的 chapterSelector 需依可見導覽確認；同名影片與測驗無法唯一辨識時工具會停止。新版面先由 AI 讀取可見控制並調整設定，不能盲按。

## 安全與狀態

- 估算只能安排檢查；完成依 `ended=true` 且到片尾，或同來源的被動 ended 證據。
- 遇到帳號／來源不符、提示、登入失效、進度回退或已播放影片暫停，停止並釋放占用。
- 不改速、不快轉、不製造活躍事件、不代做測驗；不擷取登入憑證。
- runtime 只存影片來源雜湊、進度與完成紀錄；設定和證書留在本機。不要用 Git 強制加入被忽略檔案。
- 工具 completed 只表示設定清單的影片完成，課程通過、證書取得、時數傳報、學校回傳與審核是不同狀態。
- `stopped` 不自動恢復。使用者處理後重新核對畫面，建立新狀態檔；已完成紀錄作為交接線索，不取代新現場證據。

詳見 [雙平台 SOP](docs/SOP.md)、[驗證範圍](docs/驗證紀錄.md)與 [資料保護](docs/資料保護.md)。
