# 本機資料與發佈

- Bundle ID 為 `com.LlS.iina-ani`，版本為 `0.10.1`；Core Data 仍使用 `Application Support/IINA+`。其他 Application Support 資料、UserDefaults 與帳號 Keychain service 隨 Bundle ID 改變，尚未自動遷移；修改前核對[資料儲存](../architecture/PROJECT.md#資料模型與儲存)。
- 啟動驗證前留意既有 IINA+ 資料及本機埠衝突；不要同時啟動上游與 fork，也不要觸發上游更新。
- 未經要求不清除使用者 Application Support、Cookies、書籤或偏好。
- 日誌及回報不得包含 Cookie、token、授權 header 或完整簽名串流 URL。
- Bangumi OAuth 應用憑證僅放被忽略的 `Config/Local.xcconfig`，不得硬編碼、輸出值或納入 Git；公開範本保持空值。建置設定會寫進 App bundle，不是分發端保密機制；缺失配置須明確報錯。
- 已移除 Sparkle 與上游 feed／公鑰；未配置獨立更新服務。正式發佈前須完成資料遷移／隔離、簽署與公證驗證，不以 Bundle ID 更名視為完成。
- Git origin 目前為 `https://github.com/Vianssr/iina-ani.git`；發佈地址與簽署資訊須以實際配置為準。
