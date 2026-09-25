#!/usr/bin/env bash
# 一键更新线上机器人（在 VPS 上执行）
#
#   用法：  bash ~/newbot_pg1/deploy.sh
#
#   等价于手敲这两条：
#     cd ~/newbot_pg1 && git pull && bash deploy/update.sh
#     docker logs --tail 3 newbot_pg1_container
#
# 部署位置固定是 ~/newbot_pg1（用 APP_DIR 可覆盖），容器名 newbot_pg1_container。
# 构建镜像 / 删旧容器 / 重新 docker run 的逻辑都在部署目录自己的 deploy/update.sh 里，
# 本脚本只负责把它跑起来，再把最近的日志打出来给你确认。
# 数据卷挂在部署目录的 data/ 下，重建容器不会丢账本。
#
# 可调环境变量：APP_DIR / BRANCH / CONTAINER / LOG_LINES / DRY_RUN

set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/newbot_pg1}"
BRANCH="${BRANCH:-main}"
CONTAINER="${CONTAINER:-newbot_pg1_container}"
LOG_LINES="${LOG_LINES:-3}"
DRY_RUN="${DRY_RUN:-0}"

if [ ! -d "$APP_DIR/.git" ]; then
  echo "!!  部署目录不对：$APP_DIR 不是 git 仓库。" >&2
  echo "    换目录：APP_DIR=/别的/路径 bash $0" >&2
  exit 1
fi

echo "▶ 部署目录：$APP_DIR"

if [ "$DRY_RUN" = "1" ]; then
  echo "▶ DRY_RUN=1：只做检查，不动线上"
  echo "  将要执行：git -C $APP_DIR pull --ff-only origin $BRANCH"
  echo "           bash $APP_DIR/deploy/update.sh"
  echo "           docker logs --tail $LOG_LINES $CONTAINER"
  exit 0
fi

echo "▶ 1/3 拉取最新代码"
git -C "$APP_DIR" pull --ff-only origin "$BRANCH"
echo "    当前版本：$(git -C "$APP_DIR" log --oneline -1)"

if [ ! -f "$APP_DIR/deploy/update.sh" ]; then
  echo "!!  $APP_DIR 里没有 deploy/update.sh，没法重建容器（clone 错仓库了？）" >&2
  exit 1
fi

echo "▶ 2/3 构建镜像并重建容器"
bash "$APP_DIR/deploy/update.sh"

echo "▶ 3/3 最近 $LOG_LINES 条日志"
docker ps --filter "name=^${CONTAINER}$" --format '    容器：{{.Status}}  {{.Image}}'
docker logs --tail "$LOG_LINES" "$CONTAINER"

echo
echo "完成。实时日志： docker logs -f ${CONTAINER}"
