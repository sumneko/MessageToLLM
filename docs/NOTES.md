# 技术笔记：Message From Aliens 感知层

> 本文件是**技术留档**：感知层实现、踩过的坑、自制工具。
> 游戏机制与译文进度属于游戏进度笔记，见 `progress/PROGRESS.md`（已 gitignore）。

---

## 一、符号切格：纯网格公式（2026-11-11 定稿）

**结论：所有符号都对齐固定网格，中心点可以直接算，不需要任何墨迹推断。**

```
格中心 X = CellW/2 + n × CellW
格中心 Y = CellW/2 + m × RowPitch
裁剪框   = 中心 ± Half（所有符号同一尺寸）
```

| 参数 | 1080p 基准 | 4K（scale=2） |
|---|---|---|
| CellW（格宽） | 80 | 160 |
| RowPitch（行距） | 120 | 240 |
| Half（裁剪半边长） | 34 | 68（即 136×136 框） |
| 判定有符号 | 框内亮度 ≥ 30 的像素数 ≥ 框面积 × 0.5% | 同左 |

- 实现：`MtGV7.GridScan.Scan`（C# 热路径）+ `Get-BlockGrid`（`src/vision/layout.ps1`）
- **不要**再回到动态墨迹切分（`Get-CellMetrics` / `Merge-CellsByGrid` / `Get-RowLayout` 那套）：
  它对阈值极敏感 —— 阈值 90 会漏掉灰色条目（灰墨迹峰值仅 ~92），降到 30 又会让
  `又加` 这类上下结构的符号被抗锯齿像素切成两行。
- 灰色条目靠**低阈值 30** 就能看见（背景实际是 0，90 是历史遗留的过高值）。

## 二、已废弃的做法（历史记录，勿重蹈）

### 动态墨迹切分（已删除）

曾用「行投影找墨迹带 → 按高度比例过滤 → 列投影切符号 → 墨迹包围盒」的链路切格，
再由 `Get-CellMetrics` 反推格宽、`Merge-CellsByGrid` 合并同列笔画。

问题：
- 阈值敏感（见上），灰色条目与上下结构符号都容易出问题
- 包围盒导致格子大小不一（`|` 的格子 8px 宽、`丰` 的格子 136px 宽）
- 半句话就能说清的事，写了数百行推测逻辑

### RowMergeGap 吞掉译文行（2026-11-10）

- **现象**：某页 block4 只识别出 1 行 5 格，实际页面有 3 行
- **根因**：4K 下 `RowMergeGap = 8×Scale = 16px`，而译文距字形仅 13-14px，被合并成大带
- **仅影响**旧 `recognize.ps1` 基线

## 三、指纹与台账

- `data/glyphbook.json`（gitignore，运行时学习）：24×24 block-max 采样向量
- 匹配阈值：`high ≤ 0.060` / `low ≤ 0.072` / 否则 new
  - 实测同形距离 ≤ 0.014，异形最近对（加/减镜像）0.0775
  - 同一字形在不同渲染瞬间会漂移到 0.05~0.06，阈值过紧会让同一符号分裂成两个 ID
- 采样前做**亮度归一化**（线性缩放到 max=255），让灰/白同形符号得到同一指纹；色调另由 `Tone` 字段表达
- 固定裁剪后所有符号同尺寸，宽高比恒等，`Aspect` 传 0 表示不参与判同

## 四、自制工具

| 工具 | 用途 |
|---|---|
| `tools/page-dump.ps1` | **页面导出**：抓帧 → 每块渲染成 `sXXX[译文]` 紧凑文本 + 未知符号清单；`-Sync` 读游戏内译文（默认 `Crop` 裁剪比对，2 秒；`-Method Ocr` / `Clipboard` 备选）；`-Sync -OnlyNew` 只补未同步的；`-NoCapture` 用上次观察；`-ShowSlots` 附槽位；`-SaveText` 存盘。灰色条目后缀 `` ` `` |
| `tools/ocr-winrt.ps1` | **OCR 底层**：`Windows.Media.Ocr` 封装，输出 JSON（行/词 + bbox），支持 `-Scale` / `-Region` / `-Invert` / `-Contrast`。**必须用 `powershell.exe`（5.1）跑**，pwsh 7 无 WinRT 投影 |
| `tools/render-observation.ps1` | **标注图**：在截图上画裁剪框（粗线，按置信度着色）+ 网格格子（细线）+ ID 标签 + 槽位框 |
| `tools/preview-crops.ps1` | **裁剪对照图**：把每格的实际裁剪图拼成一张，肉眼核对是否贴边 |
| `Set-GameTranslation`（`game-api.ps1`） | 写/清游戏内译文（点译文栏 → 粘贴 → 回车），空文本 = 清除；同时更新本地台账 |
| `Get-GameTranslationsByCrop` / `Sync-GameTranslations -Method Crop`（`game-api.ps1`） | **默认的译文读取**：裁剪译文框 → 16×16 签名比对，判空 + 识别已知字符 |
| `Register-GameTranslationTemplate`（`game-api.ps1`） | 把「符号 → 单字」登记进字符模板库，供以后自动识别 |
| `Get-GameTranslationsByOcr`（`game-api.ps1`） | 整页 OCR 读译文（陌生中文用得上） |
| `Get-GameTranslationText`（`game-api.ps1`） | **读**单个符号当前的游戏内译文（剪贴板法） |

## 五、译文读取（2026-11-11）

- **译文栏位置**：每个符号**正下方**（非墨迹包围盒下方）。纵坐标 = 该行最高格底边 + `26 × scale`；矮符号用自身底边会点偏，必须取**整行最大底边**
- **默认占位符是半角 `?`**；读到 `?` / `？` 一律归为空（无译文）

### 主方案：译文框裁剪比对（默认，毫秒级）

`Sync-GameTranslations -Method Crop`。**不调 OCR、不碰鼠标、不抢焦点。**

- **译文框位置固定**：横向 = 格子宽度，纵向 = 该行最高格底边 + `15×scale`，高 `23×scale`
  - 4K 实测文字落在 `rowBottom+35..70`，参考空间即 `17.5..35`，该框上下都留了余量
  - **偏移必须按参考空间 × scale 换算**：写成 `28×scale` 会变成 4K 下 56px，直接裁偏（踩过）
- **签名**：框内墨迹取紧包围盒 → 重采样成 `16×16` 二值串（`MtGV8.TransBox.Sign`）
- **判空**：与占位符签名比对，距离 ≤ 0.1 即视为无译文
  - **实测同页所有 `?` 的签名距离 = 0**，而 `?` 与最近的非空字符（「是」）= 0.492 —— 区分极干净
- **字符识别**：与模板库（`data/translation-templates.json`，gitignore）比对
  - 模板库为空时自动把「出现次数最多的签名」当作占位符，并落盘
  - 新字符用 `Register-GameTranslationTemplate -Pairs @{ s097='1'; ... }` 登记（**只支持单字**，多字会串味）
- 认不出的符号返回 `$null`，**同步时不会覆盖台账**，page-dump 显示 `[未知]`
- **注意**：`?` 和真译文的亮度完全一样（都白色、峰值 232），颜色法没用，只能靠形状

### 备选一：整页 OCR（`-Method Ocr`）

- 引擎 `Windows.Media.Ocr`（`tools/ocr-winrt.ps1`），**只能由 PowerShell 5.1 调用** —— pwsh 7 没有 WinRT 投影
- 语言包 `zh-Hans-CN` 就绪，`MaxImageDimension = 10000`
- **实测边界**：
  - 对**成句中文**有效（旧存档一页能认出 50 行：`显 示 ？` / `full 窗 口` / `黑 色 ？ 红 色 棕 色…`）
  - 对**满屏占位符**几乎无输出（只认出 4~6 行外星符号乱码）
  - 对**孤立单字符**完全无效 —— 哪怕裁成单块放大 6 倍 + 反色 + 对比度 2.5，仍全部返回空
- 外星符号会被识别成汉字乱码（`丌 +DTT`、`山 目 田`），靠 y 带过滤

### 备选二：剪贴板（`-Method Clipboard`）

点译文栏 → `Ctrl+A` → `Ctrl+C` → 读剪贴板 → `Esc` 退出编辑。约 1 秒/符号。

- 优点：100% 精确（改写、生僻字、多字文本都不怕），也是给模板库"喂样本"的可靠来源
- 缺点：**占用鼠标、抢焦点、必须前台**
- `Tab` 在译文栏内会跨行跨块乱跳，无法用来批量读，别试

### 台账语义

`data/translations-s.json`（gitignore）是游戏内译文的**镜像**，不是真相源：

| 状态 | 含义 |
|---|---|
| 键有值 | 游戏内该符号有译文 |
| 键值为空串 | 已确认游戏内该符号译文栏为空 |
| 键缺失 | 从未同步过 |

- **游戏不在前台时译文不渲染**，整页都会读成空 —— 这是游戏特性，不是 OCR 的错
- **页面外的旧译文读不到**：只有当前画面渲染出来的符号才能读，想读得先导航过去
- `Set-GameTranslation` 写译文后会自动回写台账，保证两边一致

## 六、存档 profile（2026-11-11 踩坑）

**必须用最后一个 profile。** 设置页第一屏的 `? ? 1(1) 2(2) 3(3) 4(4) 5(5) 6(6) 7(7)` 那一行**就是 profile 选择器**，点 `7` 即切换。

- 存档文件：`%USERPROFILE%\AppData\LocalLow\Artless Games\MessageFromAliens\76561198086961046\alienmessage<N>.sav`
- **判定是否用错存档**：`alienmessage1.sav` ≈ 13 KB（别人做完了，到处都有现成译文）；`alienmessage7.sav` ≈ 2.3 KB（空档）
- 切换后游戏会把当前存档改写成目标文件（看 `LastWriteTime` 即可确认切换成功）
- 走错存档时的典型症状：所有符号都有译文，`page-dump` 显示大量中文词 —— **那不是「游戏内置文本」，是存档里的答案**

## 七、其他注意

- `Initialize-GameApi` 每次新建 OutDir；重复 Save 到已打开的文件会 GDI+ 报错（换目录即可）
- 截图时确保游戏在前台，否则译文不可见；观察工具内部会 `Set-GameForeground`
- `Add-Type` 不能在同一会话重复定义同名 C# 类型 —— 改 C# 定义必须换命名空间（当前用到 `MtL4` / `MtGV5` / `MtGV6` / `MtGV7`）
