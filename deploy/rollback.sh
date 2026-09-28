#!/usr/bin/env bash
# ============================================================
#  回退到上一个（或指定）版本 —— 秒级，不重新 build、不动 git、不动 data/
#
#    bash deploy/rollback.sh            # 回退到上一个版本
#    bash deploy/rollback.sh --list     # 只列出版本清单，不动线上
#    bash deploy/rollback.sh <版本>     # 回退到指定版本（commit 短哈希，或 latest）
#
#  原理：update.sh 每次构建都打两个标签 —— :latest 和 :<commit短哈希>
#        （见 update.sh 的「版本标签」那行）。回退＝用旧标签重新 docker run，
#        参数（--env-file / 数据卷 / 端口映射）与 update.sh 完全一致，所以不会漏挂卷、漏端口。
#
#  回到最新版：bash deploy/update.sh（或 bash deploy/rollback.sh latest）
#
#  注意：
#   - 回退只换代码，data/ 里的账本数据原样不动。
#   - 账本数据不会回退；如果新版本写过新字段，旧版本会忽略它们，一般没问题。
#   - 回退到「1a04066 之前」的版本时注意：那时还没有 OCR_SCAN_ENABLED 开关。
# ============================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONTAINER="${CONTAINER:-newbot_pg1_container}"
IMAGE="${IMAGE:-newbot_pg1_image:latest}"
REPO="${IMAGE%%:*}"
DATA_DIR="$(pwd)/data"
CMD="${1:-}"

# 对外端口：命令行 PORT= 优先，其次 .env 的 WEB_CONSOLE_HOST_PORT
PORT="${PORT:-$(grep -E '^WEB_CONSOLE_HOST_PORT=' .env 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '[:space:]' || true)}"
CONSOLE_PORT="$(grep -E '^WEB_CONSOLE_PORT=' .env 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '[:space:]')"
CONSOLE_PORT="${CONSOLE_PORT:-8787}"

if ! command -v docker >/dev/null 2>&1; then
  echo "!!  找不到 docker 命令" >&2
  exit 1
fi

# 每个标签 + 创建时间 + 对应提交说明（版本清单）
list_versions() {
  docker images "$REPO" --format '{{.Tag}}|{{.CreatedAt}}|{{.ID}}' \
    | grep -v '^latest|' | sort -t'|' -k2 -r
}

print_versions() {
  echo "  可用版本（从新到旧）："
  local cur_id
  cur_id="$(docker inspect "$CONTAINER" --format '{{.Image}}' 2>/dev/null || true)"
  while IFS='|' read -r tag created id; do
    [ -z "$tag" ] && continue
    local mark="  " subject
    [ "$id" = "$cur_id" ] && mark="▶ "   # ▶ = 当前线上跑的这个
    subject="$(git log -1 --format=%s "$tag" 2>/dev/null | cut -c1-42 || true)"
    printf "%s%-12s %s  %s\n" "$mark" "$tag" "${created:0:19}" "$subject"
  done < <(list_versions)
  echo "  （▶ 是当前线上版本；bash deploy/update.sh 回到最新）"
}

case "$CMD" in
  --list|-l)
    print_versions
    exit 0
    ;;
esac

if [ ! -f .env ]; then
  echo "!!  缺少 .env，先按 DEPLOY.md 建好再回退" >&2
  exit 1
fi

# 选定目标版本
if [ -n "$CMD" ]; then
  TARGET="$CMD"
else
  # 默认「上一个」= 当前线上镜像之外的、最新的那个标签
  cur_id="$(docker inspect "$CONTAINER" --format '{{.Image}}' 2>/dev/null || true)"
  TARGET=""
  while IFS='|' read -r tag created id; do
    [ -z "$tag" ] && continue
    if [ "$id" != "$cur_id" ]; then TARGET="$tag"; break; fi
  done < <(list_versions)
  if [ -z "$TARGET" ]; then
    echo "!!  找不到上一个版本。可能只 build 过一次（update.sh 会给每个版本打 :<commit哈希> 标签）。" >&2
    echo "    当前可用版本：" >&2
    print_versions >&2
    exit 1
  fi
fi

if ! docker image inspect "${REPO}:${TARGET}" >/dev/null 2>&1; then
  echo "!!  本地没有版本 ${REPO}:${TARGET}" >&2
  print_versions >&2
  exit 1
fi

echo "▶ 目标版本：${REPO}:${TARGET}"
docker image inspect "${REPO}:${TARGET}" --format '  构建时间：{{.Created}}'
SUBJECT="$(git log -1 --format='%h %s' "$TARGET" 2>/dev/null || true)"
[ -n "$SUBJECT" ] && echo "  对应提交：${SUBJECT}"

echo "▶ 重建容器（用同样的参数：--env-file / 数据卷 / 端口映射）"
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  docker rm -f "${CONTAINER}" >/dev/null
  echo "    已移除旧容器（数据卷保留在 ${DATA_DIR}）"
fi

PORT_ARGS=()
if [ -n "${PORT}" ]; then
  PORT_ARGS=(-p "${PORT}:${CONSOLE_PORT}")
  echo "    映射端口 ${PORT}(宿主机) -> ${CONSOLE_PORT}(容器内网页)"
fi

mkdir -p "${DATA_DIR}"
docker run -d \
  --name "${CONTAINER}" \
  --restart unless-stopped \
  --env-file .env \
  -e BOT_DATA_DIR=/app/data \
  ${PORT_ARGS[@]+"${PORT_ARGS[@]}"} \
  -v "${DATA_DIR}:/app/data" \
  "${REPO}:${TARGET}" >/dev/null

echo "▶ 启动日志"
sleep 3
docker logs --tail 20 "${CONTAINER}"

echo
echo "完成，已回退到 ${TARGET}。回到最新版：bash deploy/update.sh"
