# 指引整理記錄

2026-10-24：以使用者確認的新 Bundle ID `com.LlS.iina-ani`、版本 `0.10.1` 與 `.aniskin` 為準；移除要求保留舊 Bundle ID 的指引。舊 `.iinaskin` 不再提供入口。

已移除或改寫的內容：

- 「未配置 Git 遠端」：已過時，實際已有 origin。
- 指向已刪除規劃文件、架構 §2.1 或已移除發佈章節的引用：改為目前可用指引。
- 「不是只有規劃文檔的空目錄」「不是 Animeko App」：對目前任務沒有操作價值，根文件已說明專案定位。
- 2026-10-10／11 驗收政策切換歷史：只保留目前驗收要求，歷史成果留在工作記錄。
- 重複保密提醒：保留根文件通用要求及資料／發佈文件中的具體憑證規則。

未發現需要保留的「寫乾淨程式碼」類空泛口號；不為縮短文件而刪除契約、資源引用、真實 App 驗收及資料保護要求。

文件結構：

```text
AGENTS.md                    # 最小入口
 docs/
  USER_GUIDE.md
  SKIN_GUIDE.md
  architecture/PROJECT.md
  development/
    changes.md
    validation.md
    data-and-release.md
    workflow.md
    documentation-lookup.md
    instruction-audit.md
  history/WORK_LOG.md
```

根指引目前受既有 `.gitignore` 忽略；本次保留此設定，未自行改變其版本控制政策。
