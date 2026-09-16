#!/usr/bin/env bash
# HX360E 依赖准备（Linux / macOS / WSL / Git Bash）
#
#   bash scripts/setup-upstream.sh
#   bash scripts/setup-upstream.sh --dest /opt/src/XenDroid
#   bash scripts/setup-upstream.sh --skip-submodules
#   bash scripts/setup-upstream.sh --dry-run
#
# 幂等：重复执行只会 fetch + checkout + 尽力打补丁，已打过的补丁会跳过。
set -euo pipefail

DEST=""
SKIP_SUBMODULES=0
FORCE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --skip-submodules) SKIP_SUBMODULES=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

info() { printf '\033[36m[setup] %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[setup] %s\033[0m\n' "$*"; }
fail() { printf '\033[31m[setup] %s\033[0m\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || fail '找不到 git，请先安装 Git'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$REPO_ROOT/patches/upstream.json"
[ -f "$CFG" ] || fail "缺少 $CFG"

# 极简 JSON 取值：避免依赖 jq。
json_get() {
  python3 - "$CFG" "$1" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1],encoding='utf-8'))
node=cfg
for key in sys.argv[2].split('.'):
    node=node[key]
print(node)
PY
}

command -v python3 >/dev/null 2>&1 || fail '需要 python3 解析 patches/upstream.json'

UPSTREAM_REPO="$(json_get repo)"
UPSTREAM_COMMIT="$(json_get commit)"
UPSTREAM_BRANCH="$(json_get branch)"
SOURCE_ROOT="$(json_get sourceRoot)"

if [ -z "$DEST" ]; then
  DEST="$REPO_ROOT/third_party/XenDroid"
fi
mkdir -p "$(dirname "$DEST")"
DEST="$(cd "$(dirname "$DEST")" && pwd)/$(basename "$DEST")"

info "上游仓库 : $UPSTREAM_REPO"
info "固定版本 : $UPSTREAM_COMMIT"
info "克隆目录 : $DEST"

if [ -d "$DEST/.git" ]; then
  if [ "$FORCE" -eq 0 ] && [ -n "$(git -C "$DEST" status --porcelain)" ]; then
    fail '克隆目录里有未提交改动，先处理它们，或加 --force 覆盖'
  fi
  [ "$DRY_RUN" -eq 1 ] || info 'fetch 上游…'
  [ "$DRY_RUN" -eq 1 ] || git -C "$DEST" fetch --tags origin
else
  if [ "$DRY_RUN" -eq 1 ]; then
    info '将执行 clone'
  else
    info 'clone 上游（--filter=blob:none 省流量）…'
    git clone --filter=blob:none --branch "$UPSTREAM_BRANCH" "$UPSTREAM_REPO" "$DEST"
  fi
fi

if [ "$DRY_RUN" -eq 0 ]; then
  info "checkout $UPSTREAM_COMMIT…"
  git -C "$DEST" checkout --detach "$UPSTREAM_COMMIT"
  [ "$FORCE" -eq 1 ] && git -C "$DEST" reset --hard "$UPSTREAM_COMMIT"
fi

if [ "$SKIP_SUBMODULES" -eq 1 ]; then
  warn '按参数跳过子模块初始化：编译前必须补跑 git submodule update --init --recursive'
elif [ "$DRY_RUN" -eq 1 ]; then
  info '将执行 git submodule update --init --recursive（较慢）'
else
  info '初始化子模块（第一次很慢，几百 MB~数 GB）…'
  git -C "$DEST" submodule update --init --recursive
fi

# 补丁清单：file|subdir，来自 upstream.json。
PATCHES="$(python3 - "$CFG" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1],encoding='utf-8'))
for p in cfg['patches']:
    print(p['file']+'|'+p['subdir'])
PY
)"

while IFS='|' read -r FILE SUBDIR; do
  [ -n "$FILE" ] || continue
  PATCH_FILE="$REPO_ROOT/$FILE"
  [ -f "$PATCH_FILE" ] || fail "补丁不存在：$FILE"
  if [ "$SUBDIR" = "." ]; then TARGET="$DEST"; else TARGET="$DEST/$SUBDIR"; fi
  if [ ! -d "$TARGET" ]; then
    warn "跳过 $FILE：目标目录不存在（子模块没装？）$TARGET"
    continue
  fi
  if git -C "$TARGET" apply --check --whitespace=nowarn "$PATCH_FILE" 2>/dev/null; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "将应用 $FILE -> $TARGET"
    else
      info "应用 $FILE -> $TARGET"
      git -C "$TARGET" apply --whitespace=nowarn "$PATCH_FILE"
    fi
  elif git -C "$TARGET" apply --reverse --check --whitespace=nowarn "$PATCH_FILE" 2>/dev/null; then
    info "已打过，跳过：$FILE"
  else
    warn "既不能应用也不是已应用状态，请人工检查：$FILE -> $TARGET"
  fi
done <<< "$PATCHES"

info ''
info '完成。DevEco/CMake 需要知道上游源码树位置：'
info "  方式一（推荐）：克隆放在默认位置 $DEST ，CMake 自动找到"
info "  方式二：构建时传 -DXE_XENDROID_ROOT=$DEST/$SOURCE_ROOT"
info "  方式三：export XE_XENDROID_ROOT=$DEST/$SOURCE_ROOT"
