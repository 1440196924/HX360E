# 维护者工具：从本地 XenDroid 工作树重新导出 harmony 补丁。
#
#   powershell -ExecutionPolicy Bypass -File scripts/export-patch.ps1 -Fork D:\Code\OpenSource\XenDroid
#
# 会把工作树的改动（含新增文件）导出到 patches/harmony/ 下的三个补丁。
# 注意：导出前会先 git add -N 新增文件，否则新文件不会进 diff。
#
# 说明：主补丁相对 upstream.json 里钉死的 commit 导出；子模块补丁（glslang /
# xbyak_aarch64）有各自独立的 git 历史，只能相对其当前 HEAD 导出，不能套用
# 主仓库的 commit。
[CmdletBinding()]
param(
    # 本地 XenDroid 工作树（含你的改动）
    [string]$Fork = '',
    # 主补丁相对哪个 commit 导出（缺省 = upstream.json 里的 commit）
    [string]$Base = ''
)

$ErrorActionPreference = 'Stop'

function Info([string]$m) { Write-Host "[export] $m" -ForegroundColor Cyan }
function Fail([string]$m) { Write-Host "[export] $m" -ForegroundColor Red; exit 1 }

$repoRoot = Split-Path -Parent $PSScriptRoot
# 必须显式 -Encoding UTF8：PowerShell 5.1 默认按 ANSI 读，中文变乱码会解析失败。
$cfg = Get-Content -LiteralPath (Join-Path $repoRoot 'patches/upstream.json') -Raw -Encoding UTF8 | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($Fork)) {
    if ($env:XE_XENDROID_ROOT) { $Fork = $env:XE_XENDROID_ROOT }
    else { $Fork = Join-Path $repoRoot 'third_party/XenDroid' }
}
if (-not (Test-Path -LiteralPath (Join-Path $Fork '.git'))) {
    Fail "不是 git 工作树：$Fork"
}
$Fork = (Resolve-Path -LiteralPath $Fork).Path
if ([string]::IsNullOrWhiteSpace($Base)) { $Base = $cfg.commit }

$outDir = Join-Path $repoRoot 'patches/harmony'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# 导出单个补丁。new_files = $true 时先 add -N，保证新增文件进 diff。
# 用 git diff --output=<file> 直接写文件：PowerShell 的 ">" 会写 UTF-8 BOM，git apply 会报错。
function Export-Patch {
    param([string]$SubDir, [string]$OutFile, [string]$DiffBase)
    $work = if ($SubDir -eq '.') { $Fork } else { Join-Path $Fork $SubDir }
    if (-not (Test-Path -LiteralPath $work)) {
        Write-Host "[export] 跳过（目录不存在，子模块没装？）：$SubDir" -ForegroundColor Yellow
        return
    }
    & git -C $work add -N . 2>&1 | Out-Null
    $out = Join-Path $outDir $OutFile
    $args = @('-C', $work, 'diff', '--binary', "--output=$out")
    if (-not [string]::IsNullOrWhiteSpace($DiffBase)) { $args += $DiffBase }
    Info "导出 $OutFile  <- $SubDir $(if ($DiffBase) { "(base $($DiffBase.Substring(0,8)))" } else { '(工作树 vs HEAD)' })"
    & git @args
    if ($LASTEXITCODE -ne 0) { Fail "git diff 失败：$OutFile" }
    $size = (Get-Item -LiteralPath $out).Length
    Info ("  -> {0:N1} KB" -f ($size / 1KB))
}

foreach ($p in $cfg.patches) {
    # 只有主补丁能套主仓库的 base commit。
    $diffBase = if ($p.subdir -eq '.') { $Base } else { '' }
    Export-Patch -SubDir $p.subdir `
        -OutFile ([System.IO.Path]::GetFileName($p.file)) -DiffBase $diffBase
}

Info ''
Info '完成。别忘了：'
Info '  1) 本地 fork 若有新 commit，更新 patches/upstream.json 的 commit 字段'
Info '  2) git add patches; git commit'
