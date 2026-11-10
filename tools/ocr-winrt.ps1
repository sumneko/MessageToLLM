# tools/ocr-winrt.ps1 -- Windows.Media.Ocr wrapper (ASCII only; must run on PowerShell 5.1
# because .NET Framework is required for the WinRT projection).
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\ocr-winrt.ps1 -Image <png> [-Out <json>] [-Scale 2] [-Region x,y,w,h]
#
# Output: JSON { Image, Lang, Width, Height, Lines: [ { Text, X, Y, W, H, Words:[{T,X,Y,W,H}] } ] }
# Coordinates are in the *scaled* image space; divide by Scale to get source pixels.

param(
    [Parameter(Mandatory)][string]$Image,
    [string]$Out,
    [double]$Scale = 1.0,
    [string]$Region = '',      # x,y,w,h in source pixels; empty = whole image
    [string]$Lang = '',        # e.g. zh-Hans-CN; empty = user profile languages
    [switch]$Invert,           # game renders white text on black; OCR prefers the opposite
    [double]$Contrast = 1.0    # >1 boosts contrast (grayscale around midpoint)
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

# --- prepare image (optionally crop + upscale) -------------------------------
$src = [System.Drawing.Bitmap]::FromFile($Image)
$rect = New-Object System.Drawing.Rectangle 0, 0, $src.Width, $src.Height
if ($Region) {
    $p = $Region.Split(',')
    $rx = [int]$p[0]; $ry = [int]$p[1]; $rw = [int]$p[2]; $rh = [int]$p[3]
    if ($rx -lt 0) { $rw += $rx; $rx = 0 }
    if ($ry -lt 0) { $rh += $ry; $ry = 0 }
    if (($rx + $rw) -gt $src.Width) { $rw = $src.Width - $rx }
    if (($ry + $rh) -gt $src.Height) { $rh = $src.Height - $ry }
    if ($rw -lt 1 -or $rh -lt 1) { throw "region outside image: $Region" }
    $rect = New-Object System.Drawing.Rectangle $rx, $ry, $rw, $rh
}

$workW = [int][Math]::Round($rect.Width * $Scale)
$workH = [int][Math]::Round($rect.Height * $Scale)
$work = New-Object System.Drawing.Bitmap $workW, $workH, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($work)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $workW, $workH), $rect, [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$src.Dispose()

# Optional post-processing: contrast boost and/or inversion (white-on-black -> black-on-white).
if ($Contrast -ne 1.0 -or $Invert) {
    $post = New-Object System.Drawing.Bitmap $workW, $workH, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g2 = [System.Drawing.Graphics]::FromImage($post)
    $attr = New-Object System.Drawing.Imaging.ImageAttributes
    $cm = New-Object System.Drawing.Imaging.ColorMatrix
    $c = [double]$Contrast
    $t = 0.5 - 0.5 * $c                     # keep midpoint stable
    $sig = if ($Invert) { -1.0 } else { 1.0 }
    $off = if ($Invert) { 1.0 } else { 0.0 }
    $cm.Matrix00 = $sig * $c
    $cm.Matrix11 = $sig * $c
    $cm.Matrix22 = $sig * $c
    $cm.Matrix40 = if ($Invert) { $off + $t } else { $t }
    $cm.Matrix41 = if ($Invert) { $off + $t } else { $t }
    $cm.Matrix42 = if ($Invert) { $off + $t } else { $t }
    $attr.SetColorMatrix($cm)
    $destRect = New-Object System.Drawing.Rectangle 0, 0, $workW, $workH
    $g2.DrawImage($work, $destRect, 0, 0, $workW, $workH, [System.Drawing.GraphicsUnit]::Pixel, $attr)
    $g2.Dispose()
    $attr.Dispose()
    $work.Dispose()
    $work = $post
}

$tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), ('ocr-' + [Guid]::NewGuid().ToString('N') + '.png'))
$work.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
$work.Dispose()

try {
    # --- run OCR ------------------------------------------------------------
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

    $engine = $null
    if ($Lang) {
        $language = New-Object Windows.Globalization.Language $Lang
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
    }
    if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    if (-not $engine) { throw 'no OCR engine available' }

    $result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

    $lines = @()
    foreach ($line in $result.Lines) {
        $words = @()
        $minX = [double]::MaxValue; $minY = [double]::MaxValue; $maxX = 0; $maxY = 0
        foreach ($w in $line.Words) {
            $br = $w.BoundingRect
            $words += [pscustomobject]@{
                T = $w.Text
                X = [int][Math]::Round($br.X / $Scale) + $rect.X
                Y = [int][Math]::Round($br.Y / $Scale) + $rect.Y
                W = [int][Math]::Round($br.Width / $Scale)
                H = [int][Math]::Round($br.Height / $Scale)
            }
            if ($br.X -lt $minX) { $minX = $br.X }
            if ($br.Y -lt $minY) { $minY = $br.Y }
            if (($br.X + $br.Width) -gt $maxX) { $maxX = $br.X + $br.Width }
            if (($br.Y + $br.Height) -gt $maxY) { $maxY = $br.Y + $br.Height }
        }
        $lines += [pscustomobject]@{
            Text  = $line.Text
            X     = [int][Math]::Round($minX / $Scale) + $rect.X
            Y     = [int][Math]::Round($minY / $Scale) + $rect.Y
            W     = [int][Math]::Round(($maxX - $minX) / $Scale)
            H     = [int][Math]::Round(($maxY - $minY) / $Scale)
            Words = $words
        }
    }

    $obj = [pscustomobject]@{
        Image  = $Image
        Lang   = $engine.RecognizerLanguage.LanguageTag
        Region = ('{0},{1},{2},{3}' -f $rect.X, $rect.Y, $rect.Width, $rect.Height)
        Scale  = $Scale
        Lines  = $lines
    }

    $json = $obj | ConvertTo-Json -Depth 8
    if ($Out) { [IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding $false)) }
    Write-Output $json
}
finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
