# MessageToLLM

让 LLM **自己破解**游戏 *MessageFromAliens* 里的外星符号系统，并通过点击自动完成游戏内的填空题。

> 名字对照：本项目叫 **MessageToLLM**，游戏叫 **MessageFromAliens**（进程名 `MessageFromAliens`）。
> 协作规则见 `docs/RULES.md`（提问先答复、大改先获批、禁止擅自展开）。

## 两条通道，现在用哪条

| 通道 | 做法 | 状态 |
|---|---|---|
| **后台界面接口**（现用） | BepInEx 插件 + 命令文件，进程内读屏、伪造鼠标点击 | ✅ 可用，不需要前台、不抢鼠标 |
| 前台截屏 + 点击（旧管线） | `src/**` PowerShell 管线：截屏 → 切块 → 指纹 → `mouse_event` 点击 | ✅ 仍能跑，但**必须抢前台**；保留作对照与工具 |

游戏是 Unity（`UnityPlayer.dll`，Mono 后端）。实测窗口消息（`PostMessage`/`SendMessage`）注入鼠标**完全无效**（RawInput），所以后台操作只能走进程内钩子 —— 这就是插件存在的理由。

## 快速开始（后台接口）

```powershell
# 1) 装插件（BepInEx 5 x64 解压到游戏根目录后执行；-Uninstall 只删插件，-Purge 连 BepInEx 一起清）
pwsh -NoProfile -File .\tools\build-probe.ps1

# 2) 启动游戏
pwsh -NoProfile -Command ". .\src\api\game-api.ps1; `$null=Initialize-GameApi -Root (Get-Location).Path; Start-Game"

# 3) 看屏幕：几个区域、各区域位置、区域内符号
pwsh -NoProfile -File .\tools\probe-cmd.ps1 screen

# 4) 点一下（屏幕坐标，左上原点；L 左键 / R 右键）
pwsh -NoProfile -File .\tools\probe-cmd.ps1 "click 1040 400 L"

# 5) 看某个符号长什么样（坐标取 screen 里的 sp）
pwsh -NoProfile -File .\tools\shot.ps1 -Rect 1040,360,80,80 -Scale 4
```

`tools\shot.ps1` 不带 `-Rect` 时输出整帧到 `runs\shot\frame.png`。

## 接口（只做「手和眼」）

| 命令 | 说明 |
|---|---|
| `screen` | 整屏快照：`screen`（尺寸）、`blank`（本次判定的空白色）、`regions[]` |
| `click <x> <y> [L\|R]` | 在屏幕坐标点一下，交给游戏自己的点击逻辑 |
| `state` | 立刻重写 `runs\inject\state.json`（后台每 1s 自动写，内容同 `screen`） |

`regions[]` 每项：`id`（不透明序号 `r0/r1/...`）、`cells`、`box`（区域框）、`items[]`。
`items[]` 每项：`x` `y`（网格号）、`shapeId`（形状指纹，同形同 ID、不含词义）、`edge`、`sp`（格子矩形）。

**接口不给语义**：没有页面名、没有题型标记、没有分区名 —— 区域是标题 / 题面 / 候选 / 菜单，要 LLM 自己从符号和位置推。细节（区域怎么来、空格怎么判、坐标规则）见 `docs/INTERNALS.md`。

维护命令（**不属于** solver 接口）：`savedata`（看当前 profile 存档规模）、`resetprofile <n>`（重置某号 profile）。

### 已知的交互协议（实测）

- 点符号 = 左栏变成该符号的笔记（`click <sp 中心> R` 同样效果）
- 填空 = **先点候选格中心 → 再点答案框中心**，复核答案框 `shapeId` 变成候选的 `shapeId`
- 坐标必须是格子中心（`sp[0]+sp[2]/2, sp[1]+sp[3]/2`），点边缘/空格无效

## 给求解器

`docs/SOLVER-PROMPT.md` 是给「玩游戏的 LLM」的 system prompt：接口用法、坐标规则、标准循环、失败判定、工具故障停手协议、玩法铁律。

旧的前台管线接口（`Invoke-GameClickAt` / `Get-GameObservation` 等，见 `src/api/game-api.ps1`）仍保留，用于离线识别与对照，不再作为主通道。

```powershell
# 旧管线：识别一张截图 / 抓当前画面识别
.\src\main.ps1 -Image data\samples\p1.png
.\src\main.ps1 -Live

# 环境自检（运行时 / 符号库 / 识图回归 / 缩放回归 / 实时截屏）
.\tools\selftest.ps1
.\tools\diagnose-display.ps1   # 分辨率 / DPI / 客户区几何诊断
```

## 目录

```
tools/
  build-probe.ps1        编译并安装只读/界面插件（-Uninstall / -Purge）
  probe-cmd.ps1          发一条界面命令并打印结果（screen / click / state）
  shot.ps1               后台截图 + 按 sp 矩形裁图（可放大）
  dump-asm.ps1           反射枚举游戏托管程序集（类型/方法清单）
  probe-bg-input.ps1     窗口消息注入可行性探针（结论：不可行）
  probe-inject/Plugin.cs 插件源码（快照 + 命令通道 + Harmony 输入重定向）
  selftest.ps1 / diagnose-display.ps1 / ocr-winrt.ps1 / page-dump.ps1 / preview-crops.ps1 / render-observation.ps1
src/
  vision/                读图 / 行带 / 网格 / 指纹 / 分隔线剥离 / 分块
  state/glyphbook.ps1    符号台账（旧管线）
  api/game-api.ps1       旧管线对外接口
  capture/capture.ps1    截屏 + 客户区几何 + DPI 换算
  act/mouse.ps1          点击原语 + 帧差比较（前台）
  main.ps1               旧管线调试入口
  solver/ guard/         预留
docs/
  SOLVER-PROMPT.md       给 LLM 的系统提示词
  INTERNALS.md           游戏内部接口清单 + 插件交付方式 + 维护命令
  RULES.md               协作规则
  NOTES.md / HANDOFF.md  历史笔记与完整设计
  LEGACY-README.md       旧版说明
runs/                    运行时产物（截图、状态、日志、备份），已 gitignore
```

## 已实测的关键事实

| 项目 | 值 |
|---|---|
| 游戏引擎 | Unity **6000.6.8f1**，Mono 后端，CLR 4.0.30319 |
| 游戏窗口 | 无边框全屏 1920×1080，客户区在 (0,0) |
| 后台截屏 | ✅ `PrintWindow(PW_RENDERFULLCONTENT)` 可用（4K 也完整） |
| 后台点击 | ✅ 仅插件方案可行：Harmony 改写 `Unity Input` 的鼠标查询 |
| 窗口消息注入 | ❌ `PostMessage`/`SendMessage`/按住模式全零帧差（RawInput） |
| 后台 tick | ⚠️ 游戏默认 `runInBackground=false`，失焦即停 `Update`；插件已置 `true` |
| 屏幕格宽 | 80px（1920 参考空间），网格 24×9 |
| 形状身份 | `shapeId` = sprite 纹理 FNV-1a 哈希，连续两次快照零差异 |
| 存档位置 | `LocalLow\Artless Games\MessageFromAliens\76561198086961046\alienmessage<n>.sav`（Steam AutoCloud 目录） |
| 存档加密 | AES（`CryptoHelper`），`setting.sav` / `*.sav` 都是 base64 密文 |
| 数字系统 | 一元竖线计数：`|`=1、`|||`=3；0 的写法特殊 |
| 动画 | 无（同一页静止时帧差 0.0000%） |

## 已知的坑（别重复踩）

1. **改 `ScriptingAssemblies.json` 加载不了自己的程序集** —— Unity 6 真正的脚本程序集名单在 `globalgamemanagers.assets`（二进制）。必须用 BepInEx。
2. **`GetMouseButtonDown` 必须整帧语义** —— 只给第一个调用者返回 true 会被游戏多组件轮询吃掉，表现为点击只触发「看笔记」、填空无效。
3. **坐标必须用格子中心** —— 点边缘或空格毫无反应，容易被误判成「填不进去」。
4. **纹理不可直读** —— `Texture2D.GetPixels32()` 抛异常，要用 `Graphics.Blit` 拷到临时 RT 再读。
5. **`Object.GetInstanceID()` 在 Unity 6 已废弃（编译报错）** —— 缓存 key 换 `texture.name + textureRect`。
6. **删存档文件没用** —— Steam 云会把 `alienmessage<n>.sav` 同步回来；要么关云同步，要么用 `resetprofile` 写空档覆盖。
7. **不能用稀疏 `GetPixel` 判断黑屏** —— 笔画极细，隔 40px 采样全落在黑底。必须遍历像素缓冲。
8. **`Add-Type` 类型不能二次定义** —— 改 C# 定义要换命名空间，否则旧类型静默缺新方法。
9. **像素级阈值按分辨率缩放** —— `Scale = 客户区高度 / 1080`，写死会在 2K/4K 上把词切成多个标签。
10. **列切分要用文字标签当标尺** —— 符号内部有缝隙，按墨迹投影切会把一个符号切成两半。
11. **截图要 PNG 原图** —— JPG 噪点会让指纹抖动。
12. **PowerShell 逐像素太慢** —— 热路径已下沉到 `MtGV.QuickOps`，别改回托管循环。

## 下一步

1. 用 `docs/SOLVER-PROMPT.md` 实测一轮求解：读区域 → 推断 → 点候选 → 复核
2. 把旧的 `glyphbook` 台账与插件的 `shapeId` 对齐（同形同 ID 的跨会话稳定性）
3. 收集工具故障样本，按提示词里的协议反哺修复

## 设计原则（别偏离）

- **接口只做「手和眼」**：不返回页面语义、不返回分区名、不读译文/答案表。所有词义判断必须由 LLM 给出并留痕。
- **感知层"笨"，求解层"聪明"**：切格/指纹/哈希是机械工作，不夹带语义猜测。
- **同形必同义**（游戏保证）：同一 `shapeId` 出现两种译文、或两个 ID 被赋同一译文 → 立刻报警。
- **失败即停**：截不到 / 点不动 / 字段异常 → 停下来反馈，不重试、不盲点（见提示词第 6 节）。
