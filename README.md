# MessageToLLM

让 LLM **自己破解**游戏 *MessageFromAliens* 里的外星符号系统，并通过点击自动完成游戏内的填空题。

> 名字对照：本项目叫 **MessageToLLM**，游戏叫 **MessageFromAliens**（进程名 `MessageFromAliens`）。

## 当前进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| **P0 只读感知** | 截屏 + 网格切分 + 符号分类 + 输出 ID 矩阵 | ✅ **已完成并自检通过** |
| **P0+ 分辨率自适应** | 1080p / 2K / 4K、125%~200% DPI 缩放下像素参数自动缩放 | ✅ **已完成并自检通过** |
| **P0++ 接口化** | 分隔线切块 + 块内网格 + 符号台账 + 点击/启游接口 | ✅ **已完成（观察 4K 单页 0.66s，二次观察 0.37s）** |
| P1 点击原语 | 真实点击 + 帧差验证 | ⏳ 待做 |
| P2 槽位与配对 | 测验页网格标定、空槽位检测、候选符号区定位 | ⏳ 待做 |
| P3 算式求解闭环 | 数字/加/减 已知 → 规则求解 → 填满 → 检测「正确」 | ⏳ 待做 |
| P4 LLM 求解 | 未知符号语义推断 + 动作规划 | ⏳ 待做 |

## 快速开始

```powershell
# 环境自检（运行时 / 符号库 / 识图回归 / 缩放回归 / 实时截屏 / 点击 dry-run）
.\tools\selftest.ps1

# 显示环境诊断（分辨率 / DPI / 窗口客户区 / 点缩放）——换电脑、换屏、点击偏位时先跑它
.\tools\diagnose-display.ps1

# 识别一张已有截图
.\src\main.ps1 -Image data\samples\p1.png

# 抓当前游戏画面并识别（前台用 GDI，后台用 PrintWindow）
.\src\main.ps1 -Live
```

自检全绿应输出：`全部通过 ✅`

## 游戏接口（给求解器用）

设计原则：**接口只做「手和眼」，不含任何「这是什么面板 / 这个按钮干什么」的判断**。

| 接口 | 说明 |
|---|---|
| `Get-GameObservation` | 截屏 → 分块；结构未变时直接返回 `Changed=$false` |
| `Get-GameBlock -BlockId` | 块内网格：行/列、符号 ID、置信度、相对位置、与前一个符号的间距；**含槽位（方框 + 框内符号）** |
| `Get-SymbolInfo -SymbolId` | 台账信息；首次出现时自动存裁剪图 |
| `Get-SymbolSamples -SymbolId` | 该符号本次出现的位置列表 |
| `Invoke-GameClickAt -BlockId -Row -Col` | 点某个格子（`-Button Left/Right`） |
| `Invoke-GameClickAtRel -BlockId -RelX -RelY` | 点块内相对位置（0-1），**空槽位用这个** |
| `Invoke-GameClickSymbol -SymbolId` | 点该符号最近一次出现的位置 |
| `Get-GameState` | `running / closed / minimized / not-foreground` |
| `Start-Game` | 通过 Steam 启动并等到窗口出现 |
| `Merge-GameSymbols / Split-GameSymbol` | 台账纠错：同形被拆开 / 一个 ID 混了两种形状 |

```powershell
. .\src\api\game-api.ps1
$api = Initialize-GameApi -Root (Get-Location).Path
$obs = Get-GameObservation
$obs.Blocks | Format-Table BlockId, RelX, RelY, RelW, RelH, Rows, Cols, CellCount
$null = Get-GameBlock -BlockId 3
```

判同形由工具用指纹完成（不消耗 LLM 的视觉预算）：

- **网格归并**：先推断格宽（同一行相邻符号中心差的众数 → 用 `画面宽/格宽` 取整修正），再把同一行内同一列的笔画合并成一个符号。
  不做这步的话 `III` 会被拆成 3 个 `I`。实测：4K 格宽 160（24 列）、1920 格宽 80、1600 宽窗口的裁剪图格宽 ≈66.7。
- **槽位检测**：细线方框（实测 4K 下 8px 线宽）由「横/竖线段带 + 闭合矩形配对」识别，
  框边不再当作符号，框内符号归入槽位的 `SymbolIds`。实测：边框剔除后 B4 r3 从 8 个符号降到 3 个。
- **宽高比**作为辅助身份特征（同形但长宽比例不同的符号需要区分）。
- LLM 只在 `Band=low/new` 时介入；`Merge/Split` 用于纠正。

## 目录

```
src/
  vision/common.ps1      读图 / 亮度表 / 行带 / 网格 / 指纹 / 分隔线剥离 / 列空白带分块
  vision/layout.ps1      版面切分：分隔线 → 块 → 块内网格（行内列号 + 间距）
  vision/classify.ps1    指纹 → 已知符号 ID 的最近邻分类（旧回归用）
  vision/recognize.ps1   旧版「整页 → 标签反推网格」识别（保留作回归基线）
  state/glyphbook.ps1    符号台账：ID 分配、同形维护、merge / split
  api/game-api.ps1       **对外游戏接口**（只给「手和眼」，不含任何版面/玩法假设）
  capture/capture.ps1    截屏 + 客户区几何 + DPI 换算
  act/mouse.ps1          点击原语（左/右键）+ 帧差比较
  main.ps1               调试入口（旧管线）
  solver/ guard/         预留（P1+ 填充）
data/
  clusters.json          43 个符号的 24×24 指纹库（**仅供旧回归测试**）
  translations.csv       43 条符号译文（**人工 ground truth，不得进 solver 上下文**）
  glyphbook.json         运行时自动学习的符号台账（gitignore）
  samples/               样张
docs/
  HANDOFF.md             完整设计与方案
  LEXICON.md             符号台账（人工，**仅供回归验证**）
tools/selftest.ps1       自检 + 识图回归 + 缩放回归
tools/diagnose-display.ps1  显示器 / DPI / 客户区几何诊断
runs/                    运行时产物（截图、ID 矩阵、台账、日志），已 gitignore
```

## 已实测的关键事实（可直接依赖）

| 项目 | 值 |
|---|---|
| 游戏窗口 | 无边框全屏，客户区一般在 (0,0)；代码一律用**客户区**几何，有边框窗口也能用 |
| 参考空间 | **1920×1080**（所有像素级阈值以它为准） |
| 实测可用分辨率 | 1920×1080 / 2560×1440 / 3840×2160 |
| 分辨率自适应 | `Scale = 客户区高度 / 1080`，字缝、线厚、采样步长按同比例缩放；指纹本身是 24×24 归一化的，不需要重建库 |
| DPI | `点缩放 = GetDpiForWindow / GetDpiForSystem`：1 = 截图坐标即物理像素；≠1（如 4K@150% 的 unaware 进程 = 1.5）则 `SetCursorPos` 需乘该系数（`ConvertFrom-ReferencePoint` 已处理） |
| 双屏 | 游戏在哪个屏都行，`CopyFromScreen` 支持副屏坐标 |
| 后台截屏 | ✅ `PrintWindow(PW_RENDERFULLCONTENT)` 实测可用（4K 下也返回完整帧） |
| 点击 | ⚠️ 必须前台（`mouse_event` 走桌面输入队列） |
| 动画 | 无 |
| 数字系统 | 一元竖线计数：`|`=1、`|||`=3、0 是方框内四点 |
| 分类阈值 | `dist ≤ 0.08` 高置信；`0.08–0.11` 存疑；`> 0.11` 库外新符号 |

## 已知的坑（别重复踩）

1. **不能用稀疏 `GetPixel` 采样判断黑屏** —— 本游戏笔画极细，隔 40px 采样全落在黑底上，正常画面会被误判为黑屏。必须遍历像素缓冲统计亮像素数。
2. **`Add-Type` 类型不能二次定义** —— 改了 C# 定义后要换命名空间，否则同一会话报"类型已存在"，而且旧类型会**静默缺少新方法**。当前：采集层 `MtL4.Native`、像素热路径 `MtGV.QuickOps`、诊断 `MtLD.Display`。
3. **聚类阈值区间很窄** —— 同一符号在不同位置抖动 0.088–0.093，真正不同的符号（菱形上/下横线）距离 0.135–0.208。阈值只能落在 0.11 附近，别随手调。
4. **列切分必须用文字标签当标尺** —— 符号内部有缝隙（`E̷`/`丰` 这类），按墨迹投影切会把一个符号切成两半。笔记页用标签中心反推网格（4 张图 100% 命中）。
5. **截图要 PNG 原图** —— JPG 压缩噪点会让指纹抖动。
6. **像素级阈值不能写死** —— 字间缝隙随分辨率等比变大，`MinGap=8` 在 2K 下会把一个词切成多个标签、网格标尺随之错乱。必须按 `画面高/1080` 等比缩放（`Get-PanelMatrix -Scale`）。
7. **裁剪过的截图推不出缩放** —— 只有整屏图（≥1280×720）才自动推算 Scale，裁剪样张按 1:1；实时帧由 `-Live` 显式传入。想把裁剪图当 4K 图识别，手动传 `-Scale`。
8. **逐像素在 PowerShell 里太慢** —— 4K 全屏一次亮度表就要 900ms。热路径已下沉到 `MtGV.QuickOps`，整个识别约 180ms，别改回托管循环。

## 下一步要做的事

1. **P1**：真实点击一个固定按钮 → 帧差验证 → 失败即熔断。点击坐标走 `ConvertFrom-ReferencePoint`（已处理分辨率与 DPI 换算）
2. **P2**：测验页没有文字标签，需要**固定网格标定**（一次人工标定 + 锚点校验）；空槽位按描边色 RGB 检测（**不用颜色名，避免色觉差异影响**）
3. 补录符号：`加`、`减`、`=`、`正确`、`测验`、`order?` 等（目前 43 个库里没有）
4. 待解符号：`g003` / `g009` / `g013`（全在 p1）

## 设计原则（别偏离）

- **感知层"笨"，求解层"聪明"**：切格/指纹/查表是机械工作，不允许夹带语义猜测；所有词义判断必须由 LLM 给出并留痕，否则测的就不是模型能力了。
- **同形必同义**（游戏保证）：同一 ID 出现两种译文、或两个 ID 被赋同一译文 → 立刻报警。这是最便宜的地面真值。
- **失败即停**：截不到图 / 不在前台 / 动作无效 → 停下来通知用户，不重试、不盲点。
