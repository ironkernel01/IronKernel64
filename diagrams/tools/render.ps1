# Render a built drawing set to PNG sheets for checking and for embedding in documents.
#   powershell -File diagrams\tools\render.ps1 diagrams\out\<set>.pptx
# Output: diagrams\out\png\<set>-<sheet>.png (110 dpi; a 13.33 x 7.5 in sheet is 1467 x 825)
# LibreOffice prints the .pptx to PDF and poppler's pdftoppm rasterizes each page.
# Install once: winget install TheDocumentFoundation.LibreOffice
#               winget install oschwartz10612.Poppler
param([Parameter(Mandatory = $true)][string]$Pptx)
$ErrorActionPreference = 'Stop'

$pptxPath = (Resolve-Path $Pptx).Path
$name = [IO.Path]::GetFileNameWithoutExtension($pptxPath)
$out = Split-Path -Parent $pptxPath
$pngDir = Join-Path $out 'png'

# A shell opened before an install still has the old PATH, so read it again from the registry.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
    [Environment]::GetEnvironmentVariable('Path', 'User')

# soffice.com waits for the conversion to finish; soffice.exe returns immediately.
$soffice = @((Join-Path $env:ProgramFiles 'LibreOffice\program\soffice.com'), 'soffice.com') |
    Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $soffice) { throw 'LibreOffice not found (soffice.com): winget install TheDocumentFoundation.LibreOffice' }
if (-not (Get-Command pdftoppm -ErrorAction SilentlyContinue)) { throw 'pdftoppm not found: winget install oschwartz10612.Poppler' }

New-Item -ItemType Directory -Force -Path $pngDir | Out-Null
Get-ChildItem -Path $pngDir -Filter "$name-*.png" | Remove-Item

& $soffice --headless --convert-to pdf --outdir $out $pptxPath | Out-Null
$pdf = Join-Path $out "$name.pdf"
if (-not (Test-Path $pdf)) { throw "LibreOffice did not produce $pdf" }
& pdftoppm -r 110 -png $pdf (Join-Path $pngDir $name)
Remove-Item $pdf
Get-ChildItem -Path $pngDir -Filter "$name-*.png" | ForEach-Object { $_.FullName }
