# common.ps1 —— 图形切格 / 裁剪 / 最近邻放大 公共函数
# 由 zoom.ps1 / dedupe.ps1 点源引入：   . "$PSScriptRoot\common.ps1"
# 依赖：Windows + .NET System.Drawing（PowerShell 自带，无需安装任何包）

$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    Add-Type -AssemblyName System.Drawing.Common -ErrorAction Stop
}

# ---------------------------------------------------------------- 热路径的 C# 实现
#
# 逐像素扫描在 PowerShell 里是解释执行的：4K 全屏（830 万像素）一次亮度表就要 900ms，
# 行/列投影、剥分隔线再各接近 1s。这些全是机械运算、没有语义，下沉到 C# 后降到毫秒级。
# 注意：Add-Type 的类型不能在同一会话重复定义，改了定义要换命名空间。
if (-not ([System.Management.Automation.PSTypeName]'MtGV7.GridScan').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace MtGV7 {
    public class GridScan {
        // 固定网格扫描：格子中心 = (cellW/2 + n*cellW, cellW/2 + m*rowPitch)
        // 每格取 (half*2) x (half*2) 的固定裁剪框；框内墨迹数不足 minInk 则跳过。
        // 返回每 7 个一组：gridRow, gridCol, x0, y0, w, h, inkCount
        public static int[] Scan(byte[] lum, int w, int h,
                                 int cellW, int rowPitch, int half,
                                 int threshold, int bx, int by, int bw, int bh, int minInk) {
            List<int> res = new List<int>();
            int mFrom = (int)Math.Floor((by - cellW / 2.0) / rowPitch);
            int mTo = (int)Math.Ceiling((by + bh - cellW / 2.0) / rowPitch);
            int nFrom = (int)Math.Floor((bx - cellW / 2.0) / cellW);
            int nTo = (int)Math.Ceiling((bx + bw - cellW / 2.0) / cellW);
            for (int m = mFrom; m <= mTo; m++) {
                int cy = (int)Math.Round(cellW / 2.0 + m * (double)rowPitch);
                if (cy < by || cy >= by + bh) continue;
                for (int n = nFrom; n <= nTo; n++) {
                    int cx = (int)Math.Round(cellW / 2.0 + n * (double)cellW);
                    if (cx < bx || cx >= bx + bw) continue;
                    int x0 = cx - half, y0 = cy - half;
                    int cw = half * 2, ch = half * 2;
                    if (x0 < 0 || y0 < 0 || x0 + cw > w || y0 + ch > h) continue;
                    int ink = 0;
                    for (int y = y0; y < y0 + ch; y++) {
                        int off = y * w;
                        for (int x = x0; x < x0 + cw; x++) { if (lum[off + x] >= threshold) ink++; }
                    }
                    if (ink < minInk) continue;
                    res.Add(m); res.Add(n); res.Add(x0); res.Add(y0); res.Add(cw); res.Add(ch); res.Add(ink);
                }
            }
            return res.ToArray();
        }
    }
}
'@
}

if (-not ([System.Management.Automation.PSTypeName]'MtGV5.QuickOps').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace MtGV5 {
    public class QuickOps {
        // 32bpp BGRA 缓冲 → 亮度表
        public static byte[] Lum(byte[] buf, int w, int h, int stride) {
            byte[] lum = new byte[w * h];
            for (int y = 0; y < h; y++) {
                int rowOff = y * stride;
                int lumOff = y * w;
                for (int x = 0; x < w; x++) {
                    int i = rowOff + x * 4;
                    lum[lumOff + x] = (byte)(0.114 * buf[i] + 0.587 * buf[i + 1] + 0.299 * buf[i + 2]);
                }
            }
            return lum;
        }

        public static int[] RowProfile(byte[] lum, int w, int h, int threshold) {
            int[] prof = new int[h];
            for (int y = 0; y < h; y++) {
                int off = y * w;
                int c = 0;
                for (int x = 0; x < w; x++) { if (lum[off + x] >= threshold) c++; }
                prof[y] = c;
            }
            return prof;
        }

        // 区域内每列墨迹数（长度 w，索引为相对 x0 的偏移）
        public static int[] ColProfile(byte[] lum, int imgW, int x0, int y0, int w, int h, int threshold) {
            int[] prof = new int[w];
            for (int y = y0; y < y0 + h; y++) {
                int off = y * imgW;
                for (int x = x0; x < x0 + w; x++) { if (lum[off + x] >= threshold) prof[x - x0]++; }
            }
            return prof;
        }

        // 裁出子亮度表（矩形裁剪，用于分块）
        public static byte[] CropLum(byte[] lum, int imgW, int imgH, int x0, int y0, int w, int h) {
            if (x0 < 0) { w += x0; x0 = 0; }
            if (y0 < 0) { h += y0; y0 = 0; }
            if (x0 + w > imgW) { w = imgW - x0; }
            if (y0 + h > imgH) { h = imgH - y0; }
            if (w <= 0) { w = 1; }
            if (h <= 0) { h = 1; }
            byte[] dst = new byte[w * h];
            for (int y = 0; y < h; y++) {
                int srcOff = (y0 + y) * imgW + x0;
                int dstOff = y * w;
                for (int x = 0; x < w; x++) { dst[dstOff + x] = lum[srcOff + x]; }
            }
            return dst;
        }

        // 剥隔离线，返回 [已剥行数, 已剥列数]
        public static int[] RemoveSeparators(byte[] lum, int w, int h, int threshold, double coverage, int maxThickness) {
            int killedRows = 0, killedCols = 0;

            double[] rowCov = new double[h];
            for (int y = 0; y < h; y++) {
                int off = y * w;
                int c = 0;
                for (int x = 0; x < w; x++) { if (lum[off + x] >= threshold) c++; }
                rowCov[y] = (double)c / w;
            }
            int yy = 0;
            while (yy < h) {
                if (rowCov[yy] >= coverage) {
                    int y0 = yy;
                    while (yy < h && rowCov[yy] >= coverage) yy++;
                    int y1 = yy - 1;
                    bool okAbove = (y0 == 0) || (rowCov[y0 - 1] < 0.5);
                    bool okBelow = (y1 == h - 1) || (rowCov[y1 + 1] < 0.5);
                    if ((yy - y0) <= maxThickness && okAbove && okBelow) {
                        for (int y2 = y0; y2 <= y1; y2++) {
                            int off = y2 * w;
                            for (int x = 0; x < w; x++) { lum[off + x] = 0; }
                        }
                        killedRows += (y1 - y0 + 1);
                    }
                } else { yy++; }
            }

            double[] colCov = new double[w];
            for (int x = 0; x < w; x++) {
                int c = 0;
                for (int y = 0; y < h; y++) { if (lum[y * w + x] >= threshold) c++; }
                colCov[x] = (double)c / h;
            }
            int xx = 0;
            while (xx < w) {
                if (colCov[xx] >= coverage) {
                    int x0 = xx;
                    while (xx < w && colCov[xx] >= coverage) xx++;
                    int x1 = xx - 1;
                    bool okLeft = (x0 == 0) || (colCov[x0 - 1] < 0.5);
                    bool okRight = (x1 == w - 1) || (colCov[x1 + 1] < 0.5);
                    if ((xx - x0) <= maxThickness && okLeft && okRight) {
                        for (int x2 = x0; x2 <= x1; x2++) {
                            for (int y = 0; y < h; y++) { lum[y * w + x2] = 0; }
                        }
                        killedCols += (x1 - x0 + 1);
                    }
                } else { xx++; }
            }

            return new int[] { killedRows, killedCols };
        }

        // 存活判定统计，返回 [亮像素数, 颜色桶数]
        public static int[] InkStats(byte[] buf, int w, int h, int stride, int step, int lumThreshold) {
            int ink = 0;
            System.Collections.Generic.HashSet<int> colors = new System.Collections.Generic.HashSet<int>();
            for (int y = 0; y < h; y += step) {
                int rowOff = y * stride;
                for (int x = 0; x < w; x += step) {
                    int i = rowOff + x * 4;
                    int b = buf[i], g = buf[i + 1], r = buf[i + 2];
                    if ((0.114 * b + 0.587 * g + 0.299 * r) >= lumThreshold) ink++;
                    colors.Add(((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4));
                }
            }
            return new int[] { ink, colors.Count };
        }

        // 区块归一化采样：把 (x,y,bw,bh) 缩成 n×n，块内取最大值（细线不会被漏掉）
        public static byte[] SampleVec(byte[] lum, int w, int h, int x, int y, int bw, int bh, int n) {
            byte[] v = new byte[n * n];
            if (bw <= 0) { bw = 1; }
            if (bh <= 0) { bh = 1; }
            for (int j = 0; j < n; j++) {
                int by0 = y + (int)((long)j * bh / n);
                int by1 = y + (int)((long)(j + 1) * bh / n) - 1;
                if (by1 < by0) { by1 = by0; }
                if (by0 < 0) { by0 = 0; }
                if (by1 >= h) { by1 = h - 1; }
                for (int i = 0; i < n; i++) {
                    int bx0 = x + (int)((long)i * bw / n);
                    int bx1 = x + (int)((long)(i + 1) * bw / n) - 1;
                    if (bx1 < bx0) { bx1 = bx0; }
                    if (bx0 < 0) { bx0 = 0; }
                    if (bx1 >= w) { bx1 = w - 1; }
                    int mx = 0;
                    for (int yy = by0; yy <= by1; yy++) {
                        int off = yy * w;
                        for (int xx = bx0; xx <= bx1; xx++) {
                            int val = lum[off + xx];
                            if (val > mx) { mx = val; }
                        }
                    }
                    v[j * n + i] = (byte)mx;
                }
            }
            return v;
        }

        // 找槽位方框：先找横/竖「线段带」，再配对成闭合矩形。
        // 返回平铺的 [x0,y0,x1,y1] 四元组（外框）。
        public static int[] FindFrames(byte[] lum, int w, int h, int threshold, int minLen, int maxThick, int tol) {
            List<int[]> hBands = FindBands(lum, w, h, threshold, minLen, true, maxThick, tol);
            List<int[]> vBands = FindBands(lum, w, h, threshold, minLen, false, maxThick, tol);
            List<int> outv = new List<int>();

            for (int i = 0; i < hBands.Count; i++) {
                for (int j = i + 1; j < hBands.Count; j++) {
                    int[] a = hBands[i];   // [y0,y1,x0,x1]
                    int[] b = hBands[j];
                    if (Math.Abs(a[2] - b[2]) > tol || Math.Abs(a[3] - b[3]) > tol) { continue; }
                    int topY = Math.Min(a[1], b[1]);
                    int botY = Math.Max(a[0], b[0]);
                    if (botY - topY < minLen) { continue; }
                    int lx = Math.Min(a[2], b[2]);
                    int rx = Math.Max(a[3], b[3]);
                    // 找左右两条竖线
                    int leftX = -1, rightX = -1;
                    for (int k = 0; k < vBands.Count; k++) {
                        int[] v = vBands[k];   // [x0,x1,y0,y1]
                        if (Math.Abs(v[2] - topY) > tol * 2 || Math.Abs(v[3] - botY) > tol * 2) { continue; }
                        if (Math.Abs(v[0] - lx) <= tol * 2 && Math.Abs(v[1] - lx) <= tol * 2) { leftX = v[0]; }
                        if (Math.Abs(v[0] - rx) <= tol * 2 && Math.Abs(v[1] - rx) <= tol * 2) { rightX = v[0]; }
                    }
                    if (leftX >= 0 && rightX >= 0 && rightX > leftX) {
                        outv.Add(lx); outv.Add(topY); outv.Add(rx); outv.Add(botY);
                    }
                }
            }
            return outv.ToArray();
        }

        // 线段带：horizontal=true 时返回 [y0,y1,x0,x1]，否则 [x0,x1,y0,y1]
        static List<int[]> FindBands(byte[] lum, int w, int h, int threshold, int minLen,
            bool horizontal, int maxThick, int tol) {
            List<int[]> runs = new List<int[]>();
            if (horizontal) {
                for (int y = 0; y < h; y++) {
                    int x = 0;
                    while (x < w) {
                        if (lum[y * w + x] >= threshold) {
                            int s = x;
                            while (x < w && lum[y * w + x] >= threshold) { x++; }
                            if (x - s >= minLen) { runs.Add(new int[] { y, s, x - 1 }); }
                        }
                        else { x++; }
                    }
                }
            }
            else {
                for (int x = 0; x < w; x++) {
                    int y = 0;
                    while (y < h) {
                        if (lum[y * w + x] >= threshold) {
                            int s = y;
                            while (y < h && lum[y * w + x] >= threshold) { y++; }
                            if (y - s >= minLen) { runs.Add(new int[] { x, s, y - 1 }); }
                        }
                        else { y++; }
                    }
                }
            }

            List<int[]> bands = new List<int[]>();
            // 按固定坐标排序后合并相邻行/列（x 范围相近）
            runs.Sort(delegate (int[] p, int[] q) {
                if (p[0] != q[0]) { return p[0].CompareTo(q[0]); }
                return p[1].CompareTo(q[1]);
            });
            foreach (int[] r in runs) {
                bool merged = false;
                for (int i = bands.Count - 1; i >= 0; i--) {
                    int[] b = bands[i];
                    if (r[0] - b[1] > 2) { continue; }
                    if (Math.Abs(b[2] - r[1]) <= tol && Math.Abs(b[3] - r[2]) <= tol) {
                        b[1] = Math.Max(b[1], r[0]);
                        merged = true;
                        break;
                    }
                }
                if (!merged) { bands.Add(new int[] { r[0], r[0], r[1], r[2] }); }
            }

            List<int[]> keeper = new List<int[]>();
            foreach (int[] b in bands) {
                if (b[1] - b[0] + 1 <= maxThick) { keeper.Add(b); }
            }
            return keeper;
        }

        // 台账：在平铺的向量库里找最近邻
        // lib = count*dim 的字节数组，返回 [bestIndex, bestDist, secondDist]（dist 为 0-255 尺度的 RMS）
        public static double[] Nearest(byte[] lib, int count, int dim, byte[] vec) {
            double best = double.MaxValue, second = double.MaxValue;
            int bestIdx = -1;
            for (int c = 0; c < count; c++) {
                int off = c * dim;
                double sum = 0.0;
                for (int i = 0; i < dim; i++) {
                    double d = lib[off + i] - vec[i];
                    sum += d * d;
                }
                double dist = Math.Sqrt(sum / dim);
                if (dist < best) { second = best; best = dist; bestIdx = c; }
                else if (dist < second) { second = dist; }
            }
            return new double[] { bestIdx, best, second };
        }

        // 帧差统计，返回 [变化像素数, 采样总数]
        public static long[] DiffStats(byte[] a, byte[] b, int w, int h, int stride, int step, int tolerance) {
            long diff = 0, total = 0;
            for (int y = 0; y < h; y += step) {
                int rowOff = y * stride;
                for (int x = 0; x < w; x += step) {
                    int i = rowOff + x * 4;
                    total++;
                    int d = Math.Abs(a[i] - b[i]) + Math.Abs(a[i + 1] - b[i + 1]) + Math.Abs(a[i + 2] - b[i + 2]);
                    if (d > tolerance) diff++;
                }
            }
            return new long[] { diff, total };
        }
    }
}
'@ -ErrorAction Stop
}

# 墨迹色调统计（白 / 灰判定）。新类型必须换命名空间：Add-Type 不能在同会话重复定义。
if (-not ([System.Management.Automation.PSTypeName]'MtGV6.InkTone').Type) {
    Add-Type -TypeDefinition @'
using System;
namespace MtGV6 {
    public class InkTone {
        // 区域内墨迹统计：返回 [inkCount, meanLum]（lum >= threshold 的像素）
        public static double[] CellStats(byte[] lum, int w, int h, int x, int y, int bw, int bh, int threshold) {
            long n = 0; double sum = 0;
            int y0 = Math.Max(0, y), y1 = Math.Min(h - 1, y + bh - 1);
            int x0 = Math.Max(0, x), x1 = Math.Min(w - 1, x + bw - 1);
            for (int yy = y0; yy <= y1; yy++) {
                int off = yy * w;
                for (int xx = x0; xx <= x1; xx++) {
                    int v = lum[off + xx];
                    if (v >= threshold) { n++; sum += v; }
                }
            }
            return new double[] { n, n > 0 ? sum / n : 0 };
        }
    }
}
'@ -ErrorAction Stop
}

# ---------------------------------------------------------------- 读图

function Open-ImagePlain {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ms = [System.IO.MemoryStream]::new($bytes)
    $src = [System.Drawing.Bitmap]::FromStream($ms)
    $bmp = [System.Drawing.Bitmap]::new($src.Width, $src.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawImage($src, 0, 0, $src.Width, $src.Height)
    $g.Dispose()
    $src.Dispose()
    $ms.Dispose()
    return $bmp
}

# ---------------------------------------------------------------- 像素缓冲

function Get-PixelBuffer {
    param([System.Drawing.Bitmap]$Bmp)
    $rect = [System.Drawing.Rectangle]::new(0, 0, $Bmp.Width, $Bmp.Height)
    $data = $Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $len = $data.Stride * $Bmp.Height
    $buf = [byte[]]::new($len)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $len)
    $stride = $data.Stride
    $Bmp.UnlockBits($data)
    return [pscustomobject]@{ Buf = $buf; Stride = $stride; Width = $Bmp.Width; Height = $Bmp.Height }
}

# 预计算亮度表（0-255），后面所有判定都基于它
function Get-LumBuffer {
    param($PB)
    $lum = [MtGV5.QuickOps]::Lum($PB.Buf, $PB.Width, $PB.Height, $PB.Stride)
    return [pscustomobject]@{ Lum = $lum; Width = $PB.Width; Height = $PB.Height }
}

# ---------------------------------------------------------------- 墨迹包围盒

# 墨迹包围盒。MinCount = 该行/列至少要有几个墨迹像素才算数（滤掉孤点噪点）。
# 阈值要低到能盖住灰色条目的抗锯齿边：灰墨迹峰值只有 ~92，用 90 会把边缘裁掉。
function Get-InkBounds {
    param($LumBuf, [int]$X0, [int]$Y0, [int]$W, [int]$H, [int]$Threshold = 90, [int]$MinCount = 1)
    $imgW = $LumBuf.Width
    $imgH = $LumBuf.Height
    $x0 = [Math]::Max(0, $X0)
    $y0 = [Math]::Max(0, $Y0)
    $xEnd = [Math]::Min($X0 + $W, $imgW)
    $yEnd = [Math]::Min($Y0 + $H, $imgH)
    $rows = @{}
    $cols = @{}
    for ($y = $y0; $y -lt $yEnd; $y++) {
        $rowOff = $y * $imgW
        for ($x = $x0; $x -lt $xEnd; $x++) {
            if ($LumBuf.Lum[$rowOff + $x] -ge $Threshold) {
                $rows[$y] = 1 + $(if ($rows.ContainsKey($y)) { $rows[$y] } else { 0 })
                $cols[$x] = 1 + $(if ($cols.ContainsKey($x)) { $cols[$x] } else { 0 })
            }
        }
    }
    if ($rows.Count -eq 0) { return $null }
    $minX = [int]::MaxValue; $maxX = -1; $minY = [int]::MaxValue; $maxY = -1
    foreach ($k in $rows.Keys) {
        if ($rows[$k] -lt $MinCount) { continue }
        if ($k -lt $minY) { $minY = $k }
        if ($k -gt $maxY) { $maxY = $k }
    }
    foreach ($k in $cols.Keys) {
        if ($cols[$k] -lt $MinCount) { continue }
        if ($k -lt $minX) { $minX = $k }
        if ($k -gt $maxX) { $maxX = $k }
    }
    if ($maxX -lt 0 -or $maxY -lt 0) { return $null }
    return [pscustomobject]@{ X = $minX; Y = $minY; W = ($maxX - $minX + 1); H = ($maxY - $minY + 1) }
}

# ---------------------------------------------------------------- 按列投影切分字符

function Get-InkColumnRuns {
    param($LumBuf, [int]$X0, [int]$Y0, [int]$W, [int]$H,
        [int]$Threshold = 90, [int]$MinGap = 3, [int]$MinRun = 6)
    $imgW = $LumBuf.Width
    $imgH = $LumBuf.Height
    $yEnd = [Math]::Min($Y0 + $H, $imgH)
    $xEnd = [Math]::Min($X0 + $W, $imgW)
    $x0 = [Math]::Max(0, $X0)
    $y0 = [Math]::Max(0, $Y0)
    $prof = [MtGV5.QuickOps]::ColProfile($LumBuf.Lum, $imgW, $x0, $y0, ($xEnd - $x0), ($yEnd - $y0), $Threshold)
    $runs = New-Object System.Collections.Generic.List[object]
    $inRun = $false; $start = 0; $lastInk = -1
    for ($x = 0; $x -lt $prof.Length; $x++) {
        if ($prof[$x] -gt 0) {
            if (-not $inRun) { $inRun = $true; $start = $x }
            $lastInk = $x
        } elseif ($inRun) {
            if (($x - $lastInk) -ge $MinGap) {
                $inRun = $false
                $rw = $lastInk - $start + 1
                if ($rw -ge $MinRun) { $runs.Add([pscustomobject]@{ X = $x0 + $start; W = $rw }) }
            }
        }
    }
    if ($inRun) {
        $rw = $lastInk - $start + 1
        if ($rw -ge $MinRun) { $runs.Add([pscustomobject]@{ X = $x0 + $start; W = $rw }) }
    }
    return $runs
}

# ---------------------------------------------------------------- 按行投影切分行带（图形行/文字行）

function Get-InkRowBands {
    param($LumBuf, [int]$Threshold = 90, [int]$MinGap = 2, [int]$MinBand = 4)
    $w = $LumBuf.Width
    $h = $LumBuf.Height
    $prof = [MtGV5.QuickOps]::RowProfile($LumBuf.Lum, $w, $h, $Threshold)
    $bands = New-Object System.Collections.Generic.List[object]
    $inBand = $false; $start = 0; $lastInk = -1
    for ($y = 0; $y -lt $h; $y++) {
        if ($prof[$y] -gt 0) {
            if (-not $inBand) { $inBand = $true; $start = $y }
            $lastInk = $y
        } elseif ($inBand) {
            if (($y - $lastInk) -ge $MinGap) {
                $inBand = $false
                if (($lastInk - $start + 1) -ge $MinBand) {
                    $bands.Add([pscustomobject]@{ Y0 = $start; Y1 = $lastInk })
                }
            }
        }
    }
    if ($inBand -and (($lastInk - $start + 1) -ge $MinBand)) {
        $bands.Add([pscustomobject]@{ Y0 = $start; Y1 = $lastInk })
    }
    return $bands
}

# 识别"图形行"：字形主体很高，文字行很矮，贴在图上的小横线更矮。
# 步骤：1) 切所有墨迹带；2) 间距很小的带先合并（把贴着的横线并进字形行）；
#      3) 只保留高度≥最高的 HeightRatio 倍的带（= 图形行，排除文字行）；
#      4) 再按 PadRatio 略微外扩，但不越过相邻墨迹带。
# 注意：RowMergeGap 必须小 —— 译文行与字形的间隙只有 ~13px(4K)，阈值过大会把译文吞进符号行。
function Get-GlyphRowBands {
    param($LumBuf, [int]$Threshold = 90, [int]$MinGap = 2, [int]$RowMergeGap = 4,
        [double]$HeightRatio = 0.55, [double]$PadRatio = 0.10)
    $raw = @(Get-InkRowBands -LumBuf $LumBuf -Threshold $Threshold -MinGap $MinGap -MinBand 1)
    if ($raw.Count -eq 0) { return @() }

    # ---- 合并挨得很近的带（横线 + 字形）
    $merged = New-Object System.Collections.Generic.List[object]
    foreach ($b in $raw) {
        if ($merged.Count -gt 0) {
            $last = $merged[$merged.Count - 1]
            $gap = $b.Y0 - $last.Y1 - 1
            if ($gap -le $RowMergeGap) {
                $merged[$merged.Count - 1] = [pscustomobject]@{ Y0 = $last.Y0; Y1 = $b.Y1 }
                continue
            }
        }
        $merged.Add([pscustomobject]@{ Y0 = $b.Y0; Y1 = $b.Y1 })
    }

    $maxH = 0
    foreach ($b in $merged) {
        $h = $b.Y1 - $b.Y0 + 1
        if ($h -gt $maxH) { $maxH = $h }
    }

    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $merged.Count; $i++) {
        $b = $merged[$i]
        $h = $b.Y1 - $b.Y0 + 1
        if ($h -lt ($maxH * $HeightRatio)) { continue }

        $pad = [int][Math]::Round($h * $PadRatio)
        $y0 = [Math]::Max(0, $b.Y0 - $pad)
        $y1 = [Math]::Min($LumBuf.Height - 1, $b.Y1 + $pad)
        if ($i -gt 0 -and ($merged[$i - 1].Y1 + 2) -gt $y0) { $y0 = [Math]::Max($b.Y0, $merged[$i - 1].Y1 + 2) }
        if ($i -lt ($merged.Count - 1) -and ($merged[$i + 1].Y0 - 2) -lt $y1) { $y1 = [Math]::Min($b.Y1, $merged[$i + 1].Y0 - 2) }
        if ($y1 -lt $b.Y1) { $y1 = $b.Y1 }
        $out.Add([pscustomobject]@{ Y0 = $y0; Y1 = $y1; Body0 = $b.Y0; Body1 = $b.Y1 })
    }
    return $out
}

# ---------------------------------------------------------------- 自适应分块

# 按「列方向低密度带」把整页切成若干块（左栏 / 右栏 / 侧边按钮区）。
# 竖线剥完常有抗锯齿残点，所以判据不是「零墨迹」，而是「该列亮像素占比 ≤ MaxDensity」。
# MinGap 必须按画面缩放传入：1920 下约 40px，4K 下 80px，才不会被符号间隙误切。
function Get-LumBlocks {
    param($LumBuf, [int]$MinGap = 40, [double]$MaxDensity = 0.02, [int]$Threshold = 90)
    $w = $LumBuf.Width
    $h = $LumBuf.Height
    if ($w -le 0 -or $h -le 0) { return @() }
    $counts = [MtGV5.QuickOps]::ColProfile($LumBuf.Lum, $w, 0, 0, $w, $h, $Threshold)
    $limit = [Math]::Max(1, [int]($h * $MaxDensity))

    $blocks = New-Object System.Collections.Generic.List[object]
    $cur = 0
    $x = 0
    while ($x -lt $w) {
        if ($counts[$x] -le $limit) {
            $gapStart = $x
            while ($x -lt $w -and $counts[$x] -le $limit) { $x++ }
            if (($x - $gapStart) -ge $MinGap -and $gapStart -gt $cur) {
                $blocks.Add([pscustomobject]@{ X0 = $cur; W = ($gapStart - $cur) })
                $cur = $x
            }
        }
        else { $x++ }
    }
    if ($cur -lt $w) { $blocks.Add([pscustomobject]@{ X0 = $cur; W = ($w - $cur) }) }

    # 收紧到实际墨迹列，避免块尾空白把最后一格的包围盒撑大
    $tight = New-Object System.Collections.Generic.List[object]
    foreach ($b in $blocks) {
        $x0 = $b.X0
        $x1 = $b.X0 + $b.W - 1
        while ($x0 -le $x1 -and $counts[$x0] -le $limit) { $x0++ }
        while ($x1 -ge $x0 -and $counts[$x1] -le $limit) { $x1-- }
        if ($x1 -ge $x0) { $tight.Add([pscustomobject]@{ X0 = $x0; W = ($x1 - $x0 + 1) }) }
    }
    return $tight
}

# ---------------------------------------------------------------- 剥掉分隔线

# 截图边缘经常带进游戏的细长分隔线。它们会：
#   1) 把整行行的包围盒拉大  2) 让列投影处处有墨迹（切成 1 格）
# 判定标准：某一行（列）的墨迹覆盖率 ≥ Coverage，且连续厚度 ≤ MaxThickness → 视为分隔线，直接抹成背景。
# 字形不可能有 45% 以上的整行/整列覆盖，所以不会误伤。
function Remove-SeparatorLines {
    param($LumBuf, [int]$Thresh = 25, [double]$Coverage = 0.90, [int]$MaxThickness = 6)
    $r = [MtGV5.QuickOps]::RemoveSeparators($LumBuf.Lum, $LumBuf.Width, $LumBuf.Height, $Thresh, $Coverage, $MaxThickness)
    return [pscustomobject]@{ Rows = $r[0]; Cols = $r[1] }
}

# 行布局：把图形行和它下面那行文字配成对。游戏里两者都是对齐到同一网格的。
#
# 行带合并规则（自适应）：
#   - 小间隙（≤ RowMergeGap，如下划线紧贴文字）→ 合并；
#   - 字形内部间隙（如灰色小号「又」上下两笔，约 16px@4K ≈ 0.12×字高）→ 合并，
#     判据 = gap 不超过 maxRawH×GapRatio 且合并后总高度不超过 maxRawH×1.15；
#   - 字形与译文行之间（约 35px@4K ≈ 0.26×字高）→ 不合并。
function Get-RowLayout {
    param($LumBuf, [int]$Threshold = 90, [int]$MinGap = 2, [int]$RowMergeGap = 4,
        [double]$HeightRatio = 0.45, [double]$PadRatio = 0.10, [double]$MergeSpanRatio = 1.15,
        [double]$GapRatio = 0.15)
    $raw = @(Get-InkRowBands -LumBuf $LumBuf -Threshold $Threshold -MinGap $MinGap -MinBand 1)
    if ($raw.Count -eq 0) { return @() }

    # 全页最高墨迹高度（未合并前），作为「字形最大合理高度」的估计
    $maxRawH = 0
    foreach ($b in $raw) {
        $h = $b.Y1 - $b.Y0 + 1
        if ($h -gt $maxRawH) { $maxRawH = $h }
    }
    $mergeSpan = [int][Math]::Round($maxRawH * $MergeSpanRatio)
    $mergeGapCap = [int][Math]::Round($maxRawH * $GapRatio)

    $merged = New-Object System.Collections.Generic.List[object]
    foreach ($b in $raw) {
        if ($merged.Count -gt 0) {
            $last = $merged[$merged.Count - 1]
            $gap = $b.Y0 - $last.Y1 - 1
            $spanIfMerged = $b.Y1 - $last.Y0 + 1
            if ($gap -le $RowMergeGap -or ($gap -le $mergeGapCap -and $spanIfMerged -le $mergeSpan)) {
                $merged[$merged.Count - 1] = [pscustomobject]@{ Y0 = $last.Y0; Y1 = $b.Y1 }
                continue
            }
        }
        $merged.Add([pscustomobject]@{ Y0 = $b.Y0; Y1 = $b.Y1 })
    }

    $maxH = 0
    foreach ($b in $merged) {
        $h = $b.Y1 - $b.Y0 + 1
        if ($h -gt $maxH) { $maxH = $h }
    }

    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $merged.Count; $i++) {
        $b = $merged[$i]
        $h = $b.Y1 - $b.Y0 + 1
        $isGlyph = $h -ge ($maxH * $HeightRatio)

        # 紧随其后、更矮的那个带 = 这行字的翻译栏
        $textIdx = -1
        if ($isGlyph -and ($i + 1) -lt $merged.Count) {
            $nb = $merged[$i + 1]
            $nh = $nb.Y1 - $nb.Y0 + 1
            if ($nh -lt $h -and ($nb.Y0 - $b.Y1) -lt $h) { $textIdx = $i + 1 }
        }

        $pad = [int][Math]::Round($h * $PadRatio)
        $y0 = [Math]::Max(0, $b.Y0 - $pad)
        $y1 = [Math]::Min($LumBuf.Height - 1, $b.Y1 + $pad)
        if ($i -gt 0 -and ($merged[$i - 1].Y1 + 2) -gt $y0) { $y0 = [Math]::Max($b.Y0, $merged[$i - 1].Y1 + 2) }
        if (($i + 1) -lt $merged.Count -and ($merged[$i + 1].Y0 - 2) -lt $y1) { $y1 = [Math]::Min($b.Y1, $merged[$i + 1].Y0 - 2) }
        if ($y1 -lt $b.Y1) { $y1 = $b.Y1 }

        $out.Add([pscustomobject]@{
                Y0        = $y0
                Y1        = $y1
                Kind      = $(if ($isGlyph) { 'glyph' } else { 'text' })
                Body0     = $b.Y0
                Body1     = $b.Y1
                TextIndex = $textIdx
            })
    }
    return $out
}

# 用「标签中心点」反推网格：相邻中心连线取中点当格边界，首尾各向外扩半格。
function Get-GridRects {
    param([double[]]$Centers, [int]$Width)
    $rects = New-Object System.Collections.Generic.List[object]
    $n = $Centers.Count
    if ($n -eq 0) { return $rects }
    for ($i = 0; $i -lt $n; $i++) {
        if ($n -eq 1) {
            $left = 0.0; $right = [double]$Width
        } else {
            if ($i -eq 0) { $left = $Centers[0] - ($Centers[1] - $Centers[0]) / 2 }
            else { $left = ($Centers[$i - 1] + $Centers[$i]) / 2 }
            if ($i -eq $n - 1) { $right = $Centers[$i] + ($Centers[$i] - $Centers[$i - 1]) / 2 }
            else { $right = ($Centers[$i] + $Centers[$i + 1]) / 2 }
        }
        $x0 = [int][Math]::Max(0, [Math]::Round($left))
        $x1 = [int][Math]::Min($Width, [Math]::Round($right))
        if ($x1 -le $x0) { $x1 = [Math]::Min($Width, $x0 + 1) }
        $rects.Add([pscustomobject]@{ X = $x0; W = ($x1 - $x0) })
    }
    return $rects
}

# ---------------------------------------------------------------- 网格坐标

function Get-CellRect {
    param([int]$ImgW, [int]$ImgH, [int]$Rows, [int]$Cols, [int]$Row, [int]$Col, [double]$Inset = 0.02)
    $cellW = $ImgW / $Cols
    $cellH = $ImgH / $Rows
    $x0 = [int][Math]::Round($Col * $cellW + $cellW * $Inset)
    $y0 = [int][Math]::Round($Row * $cellH + $cellH * $Inset)
    $x1 = [int][Math]::Round(($Col + 1) * $cellW - $cellW * $Inset)
    $y1 = [int][Math]::Round(($Row + 1) * $cellH - $cellH * $Inset)
    return [pscustomobject]@{ X = $x0; Y = $y0; W = [Math]::Max(1, $x1 - $x0); H = [Math]::Max(1, $y1 - $y0) }
}

# ---------------------------------------------------------------- 采样向量（用于形状聚类）

function Get-SampleVector {
    param($LumBuf, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$N = 24)
    $imgW = $LumBuf.Width
    $imgH = $LumBuf.Height
    $v = [double[]]::new($N * $N)
    for ($j = 0; $j -lt $N; $j++) {
        $by0 = $Y + [int][Math]::Floor($j * $H / $N)
        $by1 = $Y + [int][Math]::Floor(($j + 1) * $H / $N) - 1
        if ($by1 -lt $by0) { $by1 = $by0 }
        if ($by1 -ge $imgH) { $by1 = $imgH - 1 }
        for ($i = 0; $i -lt $N; $i++) {
            $bx0 = $X + [int][Math]::Floor($i * $W / $N)
            $bx1 = $X + [int][Math]::Floor(($i + 1) * $W / $N) - 1
            if ($bx1 -lt $bx0) { $bx1 = $bx0 }
            if ($bx1 -ge $imgW) { $bx1 = $imgW - 1 }
            # 块内取最大值：细线不会被点采样漏掉
            $mx = 0
            for ($yy = $by0; $yy -le $by1; $yy++) {
                $rowOff = $yy * $imgW
                for ($xx = $bx0; $xx -le $bx1; $xx++) {
                    $val = $LumBuf.Lum[$rowOff + $xx]
                    if ($val -gt $mx) { $mx = $val }
                }
            }
            $v[$j * $N + $i] = $mx / 255.0
        }
    }
    return , $v
}

function Get-VecDistance {
    param([double[]]$A, [double[]]$B, [double]$FastPath = 0.05)
    # RMS（均方根）距离：结构性差异（多/少一条横线）会被放大，抗锯齿噪声影响小。
    # 另做 ±1 格的平移容差搜索，吸收不同截图的缩放/相位差异。
    $n = [int][Math]::Round([Math]::Sqrt($A.Length))
    $sum = 0.0
    for ($k = 0; $k -lt $A.Length; $k++) {
        $d = $A[$k] - $B[$k]
        $sum += $d * $d
    }
    $base = [Math]::Sqrt($sum / $A.Length)
    if ($base -le $FastPath) { return $base }   # 已经足够像，不必搜平移

    $best = $base
    foreach ($dy in -1, 0, 1) {
        foreach ($dx in -1, 0, 1) {
            if ($dx -eq 0 -and $dy -eq 0) { continue }
            $s = 0.0; $c = 0
            for ($j = 0; $j -lt $n; $j++) {
                $jj = $j + $dy
                if ($jj -lt 0 -or $jj -ge $n) { continue }
                $rowA = $jj * $n
                $rowB = $j * $n
                for ($i = 0; $i -lt $n; $i++) {
                    $ii = $i + $dx
                    if ($ii -lt 0 -or $ii -ge $n) { continue }
                    $d = $A[$rowA + $ii] - $B[$rowB + $i]
                    $s += $d * $d; $c++
                }
            }
            if ($c -gt 0) {
                $r = [Math]::Sqrt($s / $c)
                if ($r -lt $best) { $best = $r }
            }
        }
    }
    return $best
}

# ---------------------------------------------------------------- 输出图片

function Save-CropScaled {
    param(
        [System.Drawing.Bitmap]$Bmp,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [int]$Scale = 1,
        [Parameter(Mandatory)][string]$Path
    )
    if ($W -lt 1) { $W = 1 }
    if ($H -lt 1) { $H = 1 }
    $dw = $W * $Scale
    $dh = $H * $Scale
    $dst = [System.Drawing.Bitmap]::new($dw, $dh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    # 关键：最近邻。双线性/双三次会把 1-2px 的横线糊掉
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $dstRect = [System.Drawing.Rectangle]::new(0, 0, $dw, $dh)
    $srcRect = [System.Drawing.Rectangle]::new($X, $Y, $W, $H)
    $g.DrawImage($Bmp, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $dst.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $dst.Dispose()
}
