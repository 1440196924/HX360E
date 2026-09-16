# HX360E 依赖准备：拉取指定版本的上游 XenDroid 并打上 harmony 补丁。
#
# 用法（在仓库根目录）：
#   powershell -ExecutionPolicy Bypass -File scripts/setup-upstream.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/setup-upstream.ps1 -Dest D:\src\XenDroid
#   powershell -ExecutionPolicy Bypass -File scripts/setup-upstream.ps1 -SkipSubmodules   # 跳过子模块（很快，但编译会缺文件）
#
# 幂等：重复执行只会 fetch + checkout + 尽力打补丁，已打过的补丁会跳过。
[CmdletBinding()]
param(
    # XenDroid 克隆目录；缺省为 <仓库>/third_party/XenDroid
    [string]$Dest = '',
    # 跳过子模块初始化（子模块很大，第一次必装）
    [switch]$SkipSubmodules,
    # 本地已有改动也强行 checkout（默认遇到本地改动会先提示）
    [switch]$Force,
    # 只检查环境与补丁状态，不做修改
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Info([string]$m) { Write-Host "[setup] $m" -ForegroundColor Cyan }
function Warn([string]$m) { Write-Host "[setup] $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "[setup] $m" -ForegroundColor Red; exit 1 }

function Invoke-Git {
    param([string[]]$GitArgs, [string]$WorkDir)
    Push-Location $WorkDir
    try {
        & git @GitArgs
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') 失败（exit=$LASTEXITCODE）" }
    } finally {
        Pop-Location
    }
}

# ---- 0. 前置检查 -----------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail '找不到 git，请先安装 Git 并加入 PATH'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$cfgPath = Join-Path $repoRoot 'patches/upstream.json'
if (-not (Test-Path -LiteralPath $cfgPath)) { Fail "缺少 $cfgPath" }
# 必须显式 -Encoding UTF8：PowerShell 5.1 默认按 ANSI 读，中文会变乱码导致 JSON 解析失败。
$cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($Dest)) {
    $Dest = Join-Path $repoRoot 'third_party/XenDroid'
}
$Dest = [System.IO.Path]::GetFullPath($Dest)

Info "上游仓库 : $($cfg.repo)"
Info "固定版本 : $($cfg.commit)  ($($cfg.commitSubject))"
Info "克隆目录 : $Dest"

# ---- 1. 克隆 / 更新 --------------------------------------------------------
$isRepo = Test-Path -LiteralPath (Join-Path $Dest '.git')
if ($DryRun) {
    Info ($(if ($isRepo) { '已存在克隆，将执行 fetch + checkout' } else { '将执行 clone' }))
} elseif ($isRepo) {
    $dirty = & git -C $Dest status --porcelain
    if ($dirty -and -not $Force) {
        Fail "克隆目录里有未提交改动，先处理它们，或加 -Force 覆盖：`n$dirty"
    }
    Info 'fetch 上游…'
    Invoke-Git -WorkDir $Dest -GitArgs @('fetch', '--tags', 'origin')
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
    Info 'clone 上游（--filter=blob:none 省流量）…'
    Invoke-Git -WorkDir (Split-Path -Parent $Dest) -GitArgs @(
        'clone', '--filter=blob:none', '--branch', $cfg.branch, $cfg.repo, $Dest)
}

if (-not $DryRun) {
    Info "checkout $($cfg.commit)…"
    Invoke-Git -WorkDir $Dest -GitArgs @('checkout', '--detach', $cfg.commit)
    if ($Force) {
        Invoke-Git -WorkDir $Dest -GitArgs @('reset', '--hard', $cfg.commit)
    }
}

# ---- 2. 子模块 -------------------------------------------------------------
if ($cfg.submodules -and -not $SkipSubmodules) {
    if ($DryRun) {
        Info '将执行 git submodule update --init --recursive（较慢）'
    } else {
        Info '初始化子模块（第一次很慢，几百 MB~数 GB）…'
        Invoke-Git -WorkDir $Dest -GitArgs @('submodule', 'update', '--init', '--recursive')
    }
} elseif ($cfg.submodules) {
    Warn '按参数跳过子模块初始化：编译前必须补跑 git submodule update --init --recursive'
}

# ---- 3. 打补丁 -------------------------------------------------------------
foreach ($p in $cfg.patches) {
    $patchFile = Join-Path $repoRoot $p.file
    if (-not (Test-Path -LiteralPath $patchFile)) {
        Fail "补丁不存在：$($p.file)"
    }
    $target = if ($p.subdir -eq '.') { $Dest } else { Join-Path $Dest $p.subdir }
    if (-not (Test-Path -LiteralPath $target)) {
        Warn "跳过 $($p.file)：目标目录不存在（子模块没装？）$target"
        continue
    }

    # 先看能不能正向应用；不能再看是不是已经打过了。
    Push-Location $target
    try {
        & git apply --check --whitespace=nowarn $patchFile 2>$null
        $canApply = ($LASTEXITCODE -eq 0)
        if ($canApply) {
            if ($DryRun) {
                Info "将应用 $($p.file) -> $target"
            } else {
                Info "应用 $($p.file) -> $target"
                & git apply --whitespace=nowarn $patchFile
                if ($LASTEXITCODE -ne 0) { throw "应用失败：$($p.file)" }
            }
        } else {
            & git apply --reverse --check --whitespace=nowarn $patchFile 2>$null
            if ($LASTEXITCODE -eq 0) {
                Info "已打过，跳过：$($p.file)"
            } else {
                Warn "既不能应用也不是已应用状态，请人工检查：$($p.file) -> $target"
            }
        }
    } finally {
        Pop-Location
    }
}

# ---- 4. 收尾 --------------------------------------------------------------
$sourceRoot = Join-Path $Dest $cfg.sourceRoot
Info ''
Info '完成。DevEco/CMake 需要知道上游源码树位置：'
Info "  方式一（推荐）：把克隆放到默认位置 $Dest ，CMake 会自动找到"
Info "  方式二：构建时传 -DXE_XENDROID_ROOT=$sourceRoot"
Info "  方式三：设置环境变量 XE_XENDROID_ROOT=$sourceRoot"
