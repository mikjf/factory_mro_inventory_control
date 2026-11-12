# Export slides of a .pptx to PNG with PowerPoint (read-only, no window).
#   powershell -File deck\render.ps1 <pptx> <out folder> [slide numbers, e.g. 13,14,15]
param([string]$Pptx, [string]$Out, [string]$Slides = "")
$ErrorActionPreference = "Stop"
$Pptx = (Resolve-Path $Pptx).Path
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$app = New-Object -ComObject PowerPoint.Application
try {
    $pres = $app.Presentations.Open($Pptx, $true, $false, $false)  # read-only, untitled, no window
    $numbers = if ($Slides) { $Slides.Split(",") | ForEach-Object { [int]$_ } } else { 1..$pres.Slides.Count }
    foreach ($n in $numbers) {
        $pres.Slides.Item($n).Export((Join-Path $Out ("slide{0:D2}.png" -f $n)), "PNG", 1600, 900)
    }
    $pres.Close()
} finally {
    $app.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) | Out-Null
}
