# Venera 多端数据同步格式规范 v1

本文档定义 APP（iOS/Android/Win/macOS/Linux）与 Web 端之间 WebDAV 同步的数据格式、内容和规则。
所有平台实现必须遵守本规范，以确保多端数据互通。

---

## 1. 备份文件命名

格式: `{daysSinceEpoch}-{dataVersion}.{platform}.venera`

- `daysSinceEpoch`: `Date.now() / 86400000` 取整
- `dataVersion`: 递增整数，每次上传 +1
- `platform`: `ios` | `android` | `win` | `macos` | `linux` | `web`
- 兼容旧格式: `{daysSinceEpoch}-{version}.venera`（无平台标识，视为 legacy 组）

特殊文件: `latest.venera` — 最新备份的副本，不参与清理

---

## 2. 备份 ZIP 结构（必须包含的文件）

```
backup.venera (ZIP, compression=stored)
├── appdata.json          # 应用设置 + 搜索历史
├── history.db            # 阅读历史 SQLite
├── local_favorite.db     # 收藏夹 SQLite
├── data/venera.db        # 域数据库 SQLite（可选，不存在则跳过）
├── read_later.db         # 稍后阅读 SQLite（可选，不存在则跳过）
├── cookie.db             # Cookie SQLite（可选）
└── comic_source/         # 漫画源文件
    ├── xxx.js
    └── xxx.data
```

**硬性规定:**
- 所有平台导出时必须包含上述所有存在的文件
- 导入时缺失的文件跳过，不报错
- 漫画源目录统一使用 `comic_source/` 前缀

---

## 3. appdata.json 格式

```json
{
  "settings": { ... },
  "searchHistory": [...],
  "implicitData": { ... }
}
```

### 3.1 settings 同步规则

**不同步的设备特定字段 (_disableSync):**
```
proxy, authorizationRequired, customImageProcessing,
webdav, disableSyncFields, deviceId, followUpdatesFolder,
updateRepoOwner, updateRepoName, updateUsePrivateRepo, updateRepoToken
```

- 上述字段在导入时跳过，保留本机值
- 用户可通过 `disableSyncFields` 自定义额外不同步字段（逗号分隔）
- 新增设备特定字段时，必须同时加入 APP 和 Web 的 _disableSync 列表

### 3.2 implicitData 同步规则

**同步的 implicitData keys:**
```
follow_update_task_history
```

- 仅上述 key 参与跨设备同步
- `sync_logs`, `webdavAutoSync`, `webServerDbImportSha256` 等为设备特定数据，不同步
- 新增需要同步的 implicitData key 时，必须加入 `syncImplicitDataKeys` 列表

### 3.3 searchHistory 同步规则

- 完整替换，以最新上传方为准

### 3.4 追更（Follow Updates）同步规则

**设计原则:** 各端可独立选择不同的追更文件夹，但追更检查产生的数据全端共享。

**同步项:**
- `local_favorite.db` 中所有文件夹表的追更相关列（`has_new_update`, `last_update_time`, `last_check_time`）→ 随数据库整体同步
- `follow_update_task_history`（implicitData）→ 同步

**不同步项:**
- `followUpdatesFolder` 设置 → 在 `_disableSync` 中，各端独立

**行为规范:**
1. 设备 A 选文件夹 "X" 做追更，检查出更新后写入 `local_favorite.db` 的 "X" 表
2. 同步后，设备 B 的 `local_favorite.db` 包含完整的 "X" 表数据（含追更状态）
3. 设备 B 选择文件夹 "X" 时，追更页面自动从 DB 加载已有数据（更新、未读、完结）
4. 各端追更检查结果互相累积，不会因为切换设备而丢失

**上传安全保护:**
- 上传前检查当前设备配置的追更文件夹表是否为空（`_isFollowFolderEmpty`）
- 如果配了追更文件夹但表内 0 条漫画，拦截上传，防止空数据覆盖远端

---

## 4. 数据库 Schema 规范

### 4.1 history.db

```sql
CREATE TABLE history (
  id TEXT,
  title TEXT,
  subtitle TEXT,
  cover TEXT,
  time INT,
  type INT,
  ep INT,
  page INT,
  readEpisode TEXT,
  max_page INT,
  chapter_group INT,
  PRIMARY KEY (id, type)
);
```

### 4.2 local_favorite.db

每个收藏夹文件夹对应一张表，表名为文件夹 ID。

**文件夹表列定义:**
```sql
id TEXT, name TEXT, author TEXT, type INT, tags TEXT,
cover_path TEXT, time TEXT, display_order INT,
translated_tags TEXT, source_key TEXT,
last_update_time TEXT, has_new_update INT, last_check_time INT
```

**folders 表:**
```sql
CREATE TABLE folders (
  folder_id TEXT PRIMARY KEY,
  folder_name TEXT,
  sort_order INT
);
```

### 4.3 read_later.db

```sql
CREATE TABLE read_later (
  id TEXT PRIMARY KEY,
  title TEXT,
  cover TEXT,
  type INT,
  source_key TEXT,
  time INT
);
```

### 4.4 cookie.db

```sql
CREATE TABLE cookies (
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  domain TEXT NOT NULL,
  path TEXT,
  expires INTEGER,
  secure INTEGER,
  httpOnly INTEGER,
  PRIMARY KEY (name, domain, path)
);
```

**硬性规定:**
- 导入时如果目标数据库缺少列，必须先 ALTER TABLE 添加列
- 新增列时默认值为 NULL
- 不得删除已有列

---

## 5. 版本控制与冲突处理

### 5.1 dataVersion

- 每次上传前 `dataVersion++`
- 下载时比较远程 version 与本地 version
- 如果远程 version <= 本地 lastSyncTime，跳过下载（除非 force）

### 5.2 冲突规则

- 最后上传者胜出（last-write-wins）
- 不支持合并，完整覆盖
- 设备特定字段不受覆盖影响

---

## 6. 备份数量限制

- 每个平台最多保留 **10** 个备份文件
- 无平台标识的旧格式文件单独一组，也限 10 个
- 清理时按 daysSinceEpoch 降序排列，保留最新的 10 个
- `latest.venera` 不参与计数和清理

---

## 7. 各平台实现检查清单

| 检查项 | APP Native | APP Web | Web Server |
|--------|-----------|---------|------------|
| 导出 read_later.db | ✓ | N/A | ✓ |
| 导出 comic_source/ 前缀 | ✓ | ✓ | ✓ |
| appdata.json 含 implicitData | ✓ | ✓ | ✓ |
| 文件名含平台标识 | ✓ | ✓ | ✓ |
| 导入时 ALTER TABLE 补列 | ✓ | N/A | ✓ |
| _disableSync 列表一致 | ✓ | ✓ | ✓ |
