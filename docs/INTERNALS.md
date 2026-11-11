# 游戏内部接口清单（只读枚举结果）

来源：`D:\steam\steamapps\common\Message From Aliens\MessageFromAliens_Data\Managed\Assembly-CSharp.dll`
工具：`tools/dump-asm.ps1`（反射枚举，不加载到 Unity、不注入）
原始 dump：`runs/asm/csharp.txt`（gitignored）

> 方法体**未反编译**（本机无 dotnet/ILSpy）。下表语义由名称 + 字段推断，标 ✅ 的是靠字段/命名几乎确定的，其余为推测，注入前需实际验证。

## 程序集事实

| 项 | 值 |
|---|---|
| 后端 | Mono（`MonoBleedingEdge\EmbedRuntime\mono-2.0-bdwgc.dll`），**非 IL2CPP** |
| 托管代码 | `Assembly-CSharp.dll`，65 个 TypeDef / 446 MethodDef / 524 FieldDef —— 体量很小 |
| 混淆 | 无，类名/方法名/字段名全可读 |
| 输入方式 | Unity 旧版 Input：`Shapes2D.InputUtils.WasMouseDown(int button)` → `Input.GetMouseButtonDown`，靠 `BoxCollider` + 场景射线。**只能前台拿焦点才有输入**（与实测一致） |
| 逻辑分布 | 无 UI 组件类，全部逻辑集中在 `Draw`（渲染+翻页+作答）与 `Global`（数据+存档）两个类里；部分内容可能跑在 Unity Visual Scripting 图上 |
| 资源加密 | `Encrypted : ScriptableObject` + `CryptoHelper.key/iv` + `Decrypt/Encrypt`（AES）—— 数据文件是加密的，离线读表要先过这层 |

## 类型全景

| 类型 | 作用 |
|---|---|
| `Draw : MonoBehaviour` | 全局管理器：画字、翻页、排版、对话框、槽位编辑、成就显示（约 60 方法） |
| `Global`（static） | 全局数据：外星字表、词源、分类、测验答案、存档、7 进制换算、成就/flags |
| `AlienCharacter : MonoBehaviour` | 单个外星字符/槽位：输入框、高亮、显示译文 |
| `AdvGameState` | 剧情状态机：`CurrentScene`、`Inventory`、`Move(scene)`、`ShowText` |
| `Scene`（abstract）/ `StartAdv` / `Village` / `Capital` | 对话场景，各有 `title/GetDescription/GetOptions` |
| `Understand`（static） | **测验**：`NewTest(lv)`、`Example(lv)`、`Solution(lv)`、`UnderstandCheck(list, lv)` |
| `Clue`（abstract）+ `IsHonest` / `IsLiar` / `Has1Liar` / `Most1` / `IsSame` / `IsDiffer` / `SelfIsHonest` / `Least1` / `Has2Liar` | 逻辑推理题，统一 `Check(bool[] honest)` |
| `AlienInfo` / `Item` / `Option` / `RespondInfo` / `Liar` | 数据类 |
| `TxtLoader : MonoBehaviour` | 按 `path` / `resourceFolder` 加载文本 |
| `HyperLink` / `HardwareCursor` / `Focus`(无) / `Test` | 杂项 |
| `Shapes2D.*` | 第三方矢量图形插件（Shape/Path/PolyMap/InputUtils） |
| `MV` / `PixelPerUnit` / `Shapes2DPrefs` | 常量与配置 |

## 自动化可用接口（按用途）

### 视觉/状态（读）
| 接口 | 说明 |
|---|---|
| `Draw.current_page` / `currentleftpage` / `currentrightpage` / `prev_page` | ✅ 当前页字符串 |
| `Draw.CurrentPageIsRiddle()` / `IsMenu()` / `IsMessage()` / `IsBook()` | ✅ 页面类型判定，比截图猜版面可靠 |
| `Draw.isQuiz` / `understand_lv` / `understand_test` / `understand_testcase` | ✅ 是否在测验、难度、用例 |
| `Draw.alien_slots` (`AlienCharacter[,]`) | ✅ 当前屏所有字符/槽位对象数组 |
| `AlienCharacter.alien_txt` / `line` / `line_x` / `line_y` / `slot_index` / `sector` / `page` | ✅ 字符内容与版面坐标（无需再靠 OCR/切格） |
| `Draw.txt_slots` (`TMP_InputField[,]`) | ✅ 答案输入框矩阵 |
| `Global.GetWin(s)` / `GetFlag` / `GetDFlag` / `GetIntFlag` | ✅ 进度与标记 |

### 作答/驱动（写）
| 接口 | 说明 |
|---|---|
| `Draw.ToPage(string)` / `ToParentPage()` | ✅ 翻页 |
| `Draw.DrawACToSlot(int x, int y, string s)` | ✅ 往槽位放字符 —— 填空题的核心，替代点击候选区 |
| `AlienCharacter.StartEdit(string)` / `EndEdit(string)` | ✅ 单个槽位的编辑提交 |
| `AlienCharacter.Highlight(bool)` / `ShowText(bool)` | 高亮 / 显示该字译文 |
| `Draw.UpdateText(tag)` / `UpdateText1()` / `UpdateRenderOnDemand()` | ✅ 触发重绘（改完状态必须调，否则画面不变） |
| `Draw.CompleteAmount()` | 推测：结算/完成判定 |
| `Understand.NewTest(lv)` / `UnderstandCheck(list, lv)` | ✅ 生成与判定测验 |

### 译文表（ground truth，可离线拿）
| 接口 | 说明 |
|---|---|
| `Global.alien_text` / `alien_message` / `link_message` / `message_source` | ✅ 外星字/短语 → 译文映射 |
| `Global.word_source` / `word_source_dict` / `word_source_dict_category` | ✅ 词源（含词性、部首、结构 `PosRelation`） |
| `Global.quiz_answer` / `quiz_supply` | ✅ 测验答案 |
| `Global.GetSolution(page, category)` / `SetSolution(...)` | ✅ 每页每分类的存解 |
| `Global.StringToCharacter(s, init)` / `GetInfo(category, s)` / `ToBase7*` / `HumanUnitToAlienUnit` | 字形分解、词条查询、**7 进制**数字换算 |

> ⚠️ 这一块等于直接读答案。项目原则是「LLM 自己破解」，用 `alien_slots`/坐标/槽位这类**结构性**接口没问题，用 `alien_text`/`quiz_answer` 就把题做没了。

### 存档
`Global.SaveGame()` / `SaveSetting()` / `LoadGame(bool)` / `Init()` / `InitData(filename, decode)` / `InitWordSource(bool)`

## 注入调用约束

1. **必须进程内**：`mono_runtime_invoke` 在宿主进程里才有效，PowerShell 外部调不到
2. **必须主线程**：Unity API 跨线程会崩。插件挂 `MonoBehaviour.Update`（或 hook 任一同名方法）做调度
3. **线程 attach**：自己起的线程要先 `mono_thread_attach(mono_get_root_domain())`
4. 导出已验证存在：`mono_domain_assembly_open` / `mono_runtime_invoke` / `mono_thread_attach` / `mono_class_from_name` / `mono_method_desc_new` / `mono_assembly_get_image`
5. 加载自分发 DLL 后：`mono_domain_assembly_open` → `mono_assembly_get_image` → `mono_class_from_name` → `mono_method_desc_new`（带签名，天然处理重载）→ `mono_runtime_invoke`

## 已实测的交付方式（2026-11-11）

环境：Unity **6000.6.8f1**（Unity 6），Mono 后端，CLR 4.0.30319。

| 方式 | 结果 |
|---|---|
| 改 `MessageFromAliens_Data\ScriptingAssemblies.json` + `[RuntimeInitializeOnLoadMethod]` | ❌ **无效**。Unity 6 真正的脚本程序集名单在 `globalgamemanagers.assets`（二进制），JSON 只是旁挂信息，改了不加载 |
| 自写 native injector | ❌ 本机没有 cl/clang/gcc/MSBuild |
| **BepInEx 5.4.23.5 x64 + csc 编译插件** | ✅ **可用**。`winhttp.dll` + `doorstop_config.ini` + `BepInEx\` 放游戏根目录，插件放 `BepInEx\plugins\` |

落地工具（都在本仓库）：

| 文件 | 作用 |
|---|---|
| `tools/build-probe.ps1` | 用 `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe` 编译插件并安装；`-Uninstall` 删插件，`-Purge` 连 BepInEx 删干净 |
| `tools/probe-inject/Plugin.cs` | 只读探针 payload：1Hz 把 `Draw` 状态写成 JSON（全反射，游戏字段是 private） |
| `runs/inject/state.json` | 实时快照：`page` / `slotsDim` / `alien_slots` 明细 / 各表 Count / `version` |
| `runs/inject/probe.log` | 插件自身日志（AWAKE / Draw found / 异常） |

csc 编译插件需要这几个引用（少一个就 CS0012）：

`BepInEx\core\BepInEx.dll`、`Managed\UnityEngine.dll`、`Managed\UnityEngine.CoreModule.dll`、`Managed\netstandard.dll`、`Managed\Assembly-CSharp.dll`

实测首帧状态：`page="home"`、`slotsDim=[24,9]`、`alien_text=1419`、`word_source=1099`、`quiz_answer=55`、`textfiles=19`、`version="0.99"`。

### 关键坑：后台不 tick

游戏 `Application.runInBackground` 默认 **false** —— 窗口一失去焦点 Unity 就停止调用 `Update`：插件全部停摆、画面冻结、`state.json` 时间戳卡住。实测：启动 3.5s 后失焦即停；用 Alt 键伪造把窗口切回前台后立刻恢复。

解决：插件在 `Awake` 里 `Application.runInBackground = true;`（只改运行时开关，不落盘）。此后后台可正常 tick、`PrintWindow` 也能拿到新鲜画面。

## 界面接口（唯一对外能力）

命令通道：插件每 0.25s 轮询 `runs\inject\cmd.txt`，执行后删文件、回写 `runs\inject\result.json`。

**边界：只暴露画面观察、鼠标点击和单一译文提交命令；不给语义、不给答案、不给跳页捷径，也不暴露通用反射调用。**

```powershell
pwsh -NoProfile -File .\tools\probe-cmd.ps1 screen
pwsh -NoProfile -File .\tools\probe-cmd.ps1 screen
pwsh -NoProfile -File .\tools\probe-cmd.ps1 'click 40 160 R'
pwsh -NoProfile -File .\tools\probe-cmd.ps1 'translate s12345678 hello'
```

### 读（眼）

| 命令 | 返回 |
|---|---|
| `screen` | `screen`（画面尺寸）、`grid`、`blank`、按 shapeId 聚合的 `regions[]`、与上次显式 screen 的 `changes` |
| `state` | 立刻重写一次 `state.json`（1Hz 自动刷新，内容与 `screen` 相同） |
| `translate <shapeId> <text>` | 主线程定位当前画面的符号，调用其 `AlienCharacter.EndEdit(string)` 提交译文 |

`grid` 提供 `rows`、`cols`、左上格中心、步长和统一符号尺寸。`regions[]` 每项包含 `id`、`cells` 和 `items[]`；`items[]` 按 `shapeId` 去重，每项包含该符号出现位置的 `RrCc` 列表，有译文时附 `translation`（空白和单独 `?` 不返回）。
`changes` 仅由显式 `screen` 更新基线；`state` 和 1Hz 快照不会推进基线。`translate` 返回 `submitted` 只表示调用已执行，不保证 UI 已显示；需截图复核。

**不给语义**：没有页面名、没有 `isRiddle/isMenu/...` 这类判定、没有 `sector` 名。区域是什么（标题栏 / 题面 / 候选区 / 菜单）**必须由 LLM 自己从符号和位置推**。

- **区域怎么来**：直接用游戏自己的分区字段（`AlienCharacter.sector`：`lefttitle / lefttext / leftmenu / righttitle / righttextdown / righttextup / rightmenu`），但**只输出不透明序号**，分区名不外泄。
- **空格怎么判**：出现次数最多的 `shapeId` 且占比 ≥ 40% 视为空白底，不参与分区；这次判成谁写在 `blank` 字段里。实测首页 `blank=sdd4ceb52`，分成 5 个区域。
- **`shapeId`**：sprite 自身纹理区域的 FNV-1a 哈希（`s` + 8 位十六进制）。同形同 ID、异形异 ID、不含词义；连续两次 `screen` 结果零差异（216 格实测）。
- **`grid`**：提供 R/C 到截图坐标的原点与步长，`symbolSize` 提供统一符号宽高；看形状时按位置算中心，再用该尺寸调用 `tools/shot.ps1 -Rect`。

### 写（手）

鼠标输入只有一条：`click <x> <y> [L|R]` —— 屏幕坐标（左上原点），效果等同玩家在该点点了一下鼠标。译文提交通过受限的 `translate <shapeId> <text>` 调用当前符号的 `EndEdit(string)`。

实现：Harmony 前缀临时改写 `UnityEngine.Input.get_mousePosition` / `GetMouseButton` / `GetMouseButtonDown` / `GetMouseButtonUp`（外加 `Shapes2D.InputUtils` 的同名入口），按住 3 帧再松开，随后立即解除。**不移动真实鼠标、不需要前台**，游戏自己的点击逻辑照跑。

实测：

| 用例 | 结果 |
|---|---|
| `click 40 160 R`（右键某符号格） | 帧差 **1.09%**，左栏立刻变成该符号的笔记 —— 与物理右键同效果 |
| `click 1794 36 L`（左键「笔记」页签） | 帧差 **1.09%**，`leftPage` 从 `["0"]` 变 `["0","0","0"]`（页面栈推进） |
| `screen` / `state` | 均正常 |

**填空闭环（算式题页，实测通过）**：先点候选数字格，再点答案框。

```
候选 3 = 格 (14,7)，中心 (1160,160)
答案框 = 格 (13,5)，中心 (1080,400)
click 1160 160 L  →  click 1080 400 L
(13,5).shapeId: s2cd185fc → sf0fcc14c   （变成候选 3 的 shapeId）
```

所以填一格的完整协议是：`screen` 读格子 → 用 `grid` 的原点和步长换算候选/答案框中心 → `click` 候选 → `click` 答案框 → 再检查目标格 `shapeId` 是否变成候选的 `shapeId`。

两个坑（都踩过）：
1. 坐标必须是**格子中心**，从 `RrCc` 用 `grid.firstCenter` 与 `grid.step` 换算。我第一次把候选算到空格上，点下去毫无反应，误判成「填不进去」。
2. `GetMouseButtonDown` 必须**整帧语义**：同一帧所有调用者都返回 true。最初实现成「第一个调用者消费掉」，游戏多组件轮询时就丢了按键，表现为点击只有「看笔记」生效、填空无效。

### 明确不提供

| 东西 | 为什么 |
|---|---|
| `alien_txt` / `line_str` / `line_x` / `line_y` | 实测就是**英文译文**（`mankind` / `welcome` / `terran`），给了等于泄题 |
| sprite / texture 名字 | 同理按词命名（`mankind`），不是形状标识 |
| `goto <page>` / `parent` | 按内部页名跳页，玩家界面上没有这个动作 |
| 任意 `put` / `clear` / `edit` / `highlight` | 不暴露通用内部方法调用。唯一例外是受限的 `translate <shapeId> <text>`，只对当前画面匹配的 `AlienCharacter` 调用 `EndEdit(string)` 提交译文，不接受任意方法名 |
| `Global.alien_text` / `word_source` / `quiz_answer` 等表 | 直接读答案 |
| 任意字段反射读取（`field <name>`） | 通用后门，无法界定边界 |

### 实测结论

导航、看笔记与填空走 `click`，译文提交仅走受限 `translate`。填空流程 = `screen` 读格子与形状 → 决策 → `click` 点候选/槽位 → `screen` 与截图复核，全程后台。

## 维护命令（不属于 solver 界面接口）

这两条**只给维护用**，玩游戏的 LLM 不得使用。

| 命令 | 作用 |
|---|---|
| `savedata` | 只读：当前 profile 的 `slot` + 七张表规模（`dict/flags/dflags/win/solution/bookmark/notebook2`），不读内容 |
| `resetprofile <n>` | 把第 n 号 profile 重置为空档：备份原档 → `globalData.slot = n` → `Global.LoadGame(true)` → 清空 `Global.savedata` 七张表 → `Global.SaveGame()` |

实测（profile 7）：`alienmessage7.sav` 19136 → **152 字节**；重置后 `savedata` 为 `slot=7, dict=13, 其余全 0`（`dict=13` 是游戏启动时自灌的菜单词条，不是进度）。备份落在 `runs/inject/backup/`。

坑：

- 存档实际写入 **`persistentDataPath\76561198086961046\alienmessage<n>.sav`**（Steam AutoCloud 目录），不是 `persistentDataPath` 根目录 —— 根目录那几个 `.sav` 是旧的，删它们没用。
- 只删文件没用：Steam 云会把它同步回来。要么在 Steam 关掉该游戏云同步，要么像 `resetprofile` 这样写一份空档覆盖，让云同步上传空档。
- `Global.LoadGame` 之后内存里就是目标 profile，会影响当前这一局显示；恢复游玩前先确认 `savedata` 的 `slot` 对不对。

## 风险

- 调错方法直接崩游戏（无存档），顺序必须是：只读打印 → 只读驱动 → 再写入
- 游戏更新后成员名/流程变化，需重跑 `tools/dump-asm.ps1` 对表
- BepInEx 会往游戏目录写文件（`winhttp.dll` 等），Steam 更新/校验可能清掉；`build-probe.ps1 -Purge` 可完全还原
