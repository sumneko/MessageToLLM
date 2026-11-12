# MessageToLLM

为游戏 *MessageFromAliens* 提供屏幕观测与输入自动化工具。

> 名字对照：本项目叫 **MessageToLLM**，游戏叫 **MessageFromAliens**（进程名 `MessageFromAliens`）。

> 游戏操作期间，LLM 唯一允许读取的提示词是 [`docs/SOLVER-PROMPT.md`](docs/SOLVER-PROMPT.md)；不得读取或使用其他提示词。README 和其余项目文档仅供维护者使用，不得作为游戏线索。

## 两条通道，现在用哪条

| 通道                           | 做法                                                                     | 状态                                                |
| ------------------------------ | ------------------------------------------------------------------------ | --------------------------------------------------- |
| **后台界面接口**（现用） | BepInEx 插件 + 命令文件，进程内读屏、伪造鼠标点击                        | ✅ 可用，不需要前台、不抢鼠标                       |
| 前台截屏 + 点击（旧管线）      | `src/**` PowerShell 管线：截屏 → 切块 → 指纹 → `mouse_event` 点击 | ✅ 仍能跑，但**必须抢前台**；保留作对照与工具 |

游戏是 Unity（`UnityPlayer.dll`，Mono 后端）。实测窗口消息（`PostMessage`/`SendMessage`）注入鼠标**完全无效**（RawInput），所以后台操作只能走进程内钩子 —— 这就是插件存在的理由。

## 快速开始（后台接口）

按下面步骤准备后台接口：

```powershell
# 1) 装插件（BepInEx 5 x64 解压到游戏根目录后执行；-Uninstall 只删插件，-Purge 连 BepInEx 一起清）
pwsh -NoProfile -File .\tools\build-probe.ps1

# 2) 启动游戏
pwsh -NoProfile -File .\tools\game-control.ps1 start

# 3) 获取屏幕快照
pwsh -NoProfile -File .\tools\probe-cmd.ps1 screen

# 4) 发送点击命令（屏幕坐标，左上原点；L 左键 / R 右键）
pwsh -NoProfile -File .\tools\probe-cmd.ps1 "click 1040 400 L"

# 5) 按矩形坐标裁图
pwsh -NoProfile -File .\tools\shot.ps1 -Rect 1040,360,80,80 -Scale 4
```

`tools\shot.ps1` 不带 `-Rect` 时输出整帧到 `runs\shot\frame.png`。

## 游戏进程控制 API

| 命令                                                      | 说明                                                                            |
| --------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `pwsh -NoProfile -File .\tools\game-control.ps1 status` | 输出 `closed`、`running`、`minimized` 或 `not-foreground`               |
| `pwsh -NoProfile -File .\tools\game-control.ps1 start`  | 启动安装目录中的游戏 EXE；若 EXE 不存在则回退 Steam URI，进程已存在时不重复启动 |

命令返回 JSON；默认游戏目录为 `D:\steam\steamapps\common\Message From Aliens`，可用 `-GameDir` 覆盖；启动默认最多等待 150 秒，可用 `-TimeoutSec` 调整。

## 后台界面接口

| 命令                           | 说明                                                                                                  |
| ------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `screen`                     | 整屏快照：屏幕尺寸、共享网格参数、`blank`、`regions[]` 和与上次显式 `screen` 比较的 `changes` |
| `click <x> <y> [L\|R]`        | 在屏幕坐标点一下，交给游戏自己的点击逻辑                                                              |
| `translate <shapeId> <text>` | 对当前画面中匹配的符号提交译文                                                                        |
| `state`                      | 立刻重写 `runs\inject\state.json`（后台每 1s 自动写，内容同 `screen`）                            |

`grid` 提供行列数、左上格中心、横纵格距和统一符号尺寸。行列从左上角起、从 1 编号；`R3C5` 中心坐标按 `firstCenter + [(列-1)*横向步长, (行-1)*纵向步长]` 计算。
`regions[]` 每项包含区域编号、格数及 `items[]`。`items[]` 按 `shapeId` 去重，每项含该形状在区域内出现的 `positions`（如 `R1C2`）；当前闭合方框的位置由顶层 `selection.framedPositions` 返回，`selection.frames` 附像素矩形。有已填译文时附 `translation`，空白或单独 `?` 不返回。同一形状在同一区域出现多次时只发送一次指纹。
`selection.highlights` 是符号背景高亮：`[{shapeId, positions}]`，只列该实例背景 Renderer 真正可绘制的格（启用、激活、可见、非全透明），不依赖焦点，也不假定同形全部高亮；无高亮时为空数组。高亮不是闭合框，两者字段互不混算。
`selection.underlinedPositions` / `selection.underlines` 是字符下划线：前者是行优先的 `RrCc` 列表，后者给 `{position, points: [[x,y],[x,y]]}` 端点。来源是 `Draw.selected` 里的开放水平短线（长度≈单格宽、落在符号下方），检测不看颜色，也不假定同形全部带下划线；框、背景高亮、下划线三者字段互不混算，下划线位置同样参与区域差异签名。
`selection.dimmed` 是置灰字符：`[{shapeId, positions}]`，与 `highlights` 完全同构（数组按 `shapeId` 聚合，没命中的形状不出现）。判定是把该实例 `sp.color` 和游戏自己的 `Draw.DefaultColor(3)`（front/back 混合色）比，容差 0.01，不写死 RGB 阈值，也不假定同形全灰；置灰位置同样参与区域差异签名。框、背景高亮、下划线、置灰四类字段互不混算。
`changes` 报告新增、变化、消失的区域；第一次 `screen` 只建立基线。后台 `state.json` 快照不会推进基线。
`translate <shapeId> <text>` 在游戏主线程调用当前画面匹配符号的 `EndEdit(string)`；返回 `submitted` 仅表示提交方法已调用，需通过截图确认译文显示。

维护命令（**不属于** solver 接口）：`savedata`（看当前 profile 存档规模）、`resetprofile <n>`（重置某号 profile）。

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
  game-control.ps1       检查游戏进程状态或启动游戏
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

## 已知的坑（别重复踩）

1. **改 `ScriptingAssemblies.json` 加载不了自己的程序集** —— Unity 6 真正的脚本程序集名单在 `globalgamemanagers.assets`（二进制）。必须用 BepInEx。
2. **`GetMouseButtonDown` 必须整帧语义** —— 只给第一个调用者返回 true 会被游戏多组件轮询吃掉。
3. **纹理不可直读** —— `Texture2D.GetPixels32()` 抛异常，要用 `Graphics.Blit` 拷到临时 RT 再读。
4. **`Object.GetInstanceID()` 在 Unity 6 已废弃（编译报错）** —— 缓存 key 换 `texture.name + textureRect`。
5. **删存档文件没用** —— Steam 云会把 `alienmessage<n>.sav` 同步回来；要么关云同步，要么用 `resetprofile` 写空档覆盖。
6. **不能用稀疏 `GetPixel` 判断黑屏** —— 笔画极细，隔 40px 采样全落在黑底。必须遍历像素缓冲。
7. **`Add-Type` 类型不能二次定义** —— 改 C# 定义要换命名空间，否则旧类型静默缺新方法。
8. **像素级阈值按分辨率缩放** —— `Scale = 客户区高度 / 1080`，写死会在 2K/4K 上把词切成多个标签。
9. **列切分要用文字标签当标尺** —— 符号内部有缝隙，按墨迹投影切会把一个符号切成两半。
10. **截图要 PNG 原图** —— JPG 噪点会让指纹抖动。
11. **PowerShell 逐像素太慢** —— 热路径已下沉到 `MtGV.QuickOps`，别改回托管循环。
12. **后台接口超时** —— 使用 `tools\game-control.ps1` 检查进程状态，并按 `docs/SOLVER-PROMPT.md` 的流程恢复。
