# glyphs —— 外星文字破解工作台

专门用来做「符号 ↔ 译文」的核对。核心思路：**不再靠肉眼判断"这两个图形像不像"**，
而是把每个格子裁出来、归一化成指纹、按指纹聚类，自动给出全局唯一 ID（`g001`、`g002` …）。
游戏保证「同形必同义」，所以：

- 两个格子进了同一个 ID → 它们必是同一符号，译文必须一致
- 两个格子进了不同 ID → 它们必是不同符号（横线在上 / 在下能稳定区分）

## 目录

```
glyphs\
  in\                  ← 放截图（PNG 原图，别用 JPG/压缩过的）
  out\cells\           ← 每格原尺寸 + 放大图
  out\lines\           ← 每个图形行整行放大条（看整句用）
  out\clusters\        ← 每个 ID 一张代表图（放大）
  out\clusters.json    ← 聚类状态（ID 跨次运行保持稳定）
  out\report.csv       ← image,row,col,id,distance
  out\glyphs.auto.md   ← 自动生成的字形对照表
  common.ps1           ← 公共函数（读图/切格/放大/指纹）
  dedupe.ps1           ← 批量切格 + 聚类（主工具）
  zoom.ps1             ← 单张图局部放大（临时核对用）
  selftest.ps1         ← 自检，验证脚本是否正常
  glyphs.md            ← 人工维护的「ID ↔ 记号 ↔ 译文」台账
```

## 快速开始

```powershell
# 1) 把截图丢进 in\
cd d:\github\test\glyphs

# 2) 跑聚类（行是按高度自动识别的，列是按投影自动切的）
.\dedupe.ps1

# 3) 看结果
#    out\clusters\g001.png ... 每个符号一张放大图
#    out\lines\               每行整句
```

## 常用参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Merge` | 0.12 | 聚类阈值（RMS）。**调小 = 更严格**（宁可多分不可错并）；横线差异约 0.2，同形状抖动约 0.05 |
| `-RowMergeGap` | 8 | 墨迹带间距 ≤ 此值视为同一行。用于把贴在图上的横线并进图形行 |
| `-HeightRatio` | 0.55 | 高度 ≥ 最高带的比例才算图形行（排除文字行） |
| `-InkThreshold` | 90 | 亮度阈值，0-255。识别不到东西时调小 |
| `-RowSkip` | 0 | 跳过前 N 个图形行（截图顶部有多余元素时用） |
| `-RowCols` | 空 | 强制指定每行格数，如 `5,5,5,6,7`；不给则自动按列投影切 |
| `-Scale` | 8 | 放大倍数（最近邻，不会糊掉细线） |

## zoom.ps1

```powershell
# 全部图形行逐格放大
.\zoom.ps1 -Image .\in\p1.png

# 只要第 2 行第 3 格
.\zoom.ps1 -Image .\in\p1.png -Row 2 -Col 3

# 手动给像素矩形
.\zoom.ps1 -Image .\in\p1.png -Rect 120,40,90,90
```

## 自检

```powershell
.\selftest.ps1     # 应输出 SELFTEST PASS
```

## 注意

- 放大一律用 **最近邻**。双线性/双三次会把 1–2px 的横线糊掉，正是我们要判别的信息。
- 截图请存 **PNG 原图**。JPG 压缩噪点会让指纹抖动，影响聚类。
- 若某行被并成一行（例如两个图形挨太近），用 `-RowMergeGap` 调小；若文字行被误当成图形行，调大 `-HeightRatio`。
- `clusters.json` 会保留历史 ID，**删掉它 ID 会重新编号**。
