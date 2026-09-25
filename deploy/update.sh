#!/usr/bin/env bash
# ============================================================
#  更新并重启 bot 容器（幂等，可反复执行）
#
#  用法：bash deploy/update.sh
#       换 token：BOT_TOKEN=<BotFather 给的新token> bash deploy/update.sh
#       开网页：.env 里写 WEB_CONSOLE_HOST_PORT=<宿主机端口>（Cloudflare 回源到哪个端口）
#               临时改也可以用 PORT=<宿主机端口> bash deploy/update.sh
#               （容器里网页监听 WEB_CONSOLE_PORT，默认 8787，本脚本自动读 .env）
#
#  它做的事：git pull -> docker build -> 删旧容器 -> 用同样的参数重新 docker run
#  数据卷固定挂在仓库目录的 data/ 下，重建容器不会丢账本。
#  只操作自己的容器，不会碰机器上别的容器。
#
#  换了 BOT_TOKEN=... 时，会先把 .env 里那行换成新值（.env 不存在就从
#  .env.example 生成一份），其余行原样保留。token 只进 .env，不进 git。
# ============================================================
set -euo pipefail

# 切到仓库根目录，这样从任何位置调用都成立
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONTAINER="${CONTAINER:-newbot_pg1_container}"
IMAGE="${IMAGE:-newbot_pg1_image:latest}"
DATA_DIR="$(pwd)/data"
PORT="${PORT:-}"   # 对外端口；留空则不映射（不映射就打不开账单明细网页）

if ! command -v docker >/dev/null 2>&1; then
  echo "!!  找不到 docker 命令，请确认当前用户在 docker 组里" >&2
  exit 1
fi

echo "==> 1/5 拉取最新代码"
git pull --ff-only

# 换 token：BOT_TOKEN=xxx bash deploy/update.sh
# 平时没带参数就只读现有的 .env；带了参数才改那一行，其余行原样保留
if [ ! -f .env ]; then
  if [ -n "${BOT_TOKEN:-}" ]; then
    cp .env.example .env
    echo "    .env 不存在，已从 .env.example 生成"
  else
    echo "!!  缺少 .env。先执行：" >&2
    echo "     cp .env.example .env && nano .env   # 填入 BOT_TOKEN" >&2
    exit 1
  fi
fi

if [ -n "${BOT_TOKEN:-}" ]; then
  if grep -q '^BOT_TOKEN=' .env; then
    sed -i "s|^BOT_TOKEN=.*|BOT_TOKEN=${BOT_TOKEN}|" .env
  else
    printf 'BOT_TOKEN=%s\n' "${BOT_TOKEN}" >> .env
  fi
  chmod 600 .env
  echo "    已更新 .env 里的 BOT_TOKEN（bot id ${BOT_TOKEN%%:*}），旧 token 随之作废"
fi

# 对外(宿主机)端口：命令行 PORT= 优先，其次 .env 里的 WEB_CONSOLE_HOST_PORT，都没有就不映射
if [ -z "${PORT}" ]; then
  PORT="$(grep -E '^WEB_CONSOLE_HOST_PORT=' .env 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '[:space:]' || true)"
fi

# 容器里网页监听哪个端口：跟 .env 的 WEB_CONSOLE_PORT 保持一致（默认 8787）
CONSOLE_PORT="$(grep -E '^WEB_CONSOLE_PORT=' .env 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '[:space:]')"
CONSOLE_PORT="${CONSOLE_PORT:-8787}"

# 端口预检查：必须在删旧容器之前做，否则 run 失败会让 bot 直接掉线（线上教训）
if [ -n "${PORT}" ]; then
  taken="$(docker ps --filter "publish=${PORT}" --format '{{.Names}}' | grep -vx "${CONTAINER}" || true)"
  if [ -n "${taken}" ]; then
    echo "!!  宿主机端口 ${PORT} 已经被别的容器占用：$(echo "${taken}" | tr '\n' ' ')" >&2
    echo "    换一个对外端口重跑，例如： PORT=8989 bash deploy/update.sh" >&2
    echo "    （记得把 .env 里的 WEB_CONSOLE_HOST_PORT 和 WEB_CONSOLE_BASE_URL 一起改）" >&2
    exit 1
  fi
fi

echo "==> 2/5 准备数据目录 ${DATA_DIR}"
mkdir -p "${DATA_DIR}"

echo "==> 3/5 构建镜像 ${IMAGE}"
docker build -t "${IMAGE}" .

echo "==> 4/5 重建容器 ${CONTAINER}"
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  docker rm -f "${CONTAINER}" >/dev/null
  echo "    已移除旧容器（数据卷保留在 ${DATA_DIR}）"
fi

# ${PORT_ARGS[@]+...} 的写法是为了空数组也能通过 set -u（老 bash 也能跑）
PORT_ARGS=()
if [ -n "${PORT}" ]; then
  PORT_ARGS=(-p "${PORT}:${CONSOLE_PORT}")
  echo "    映射端口 ${PORT}(宿主机) -> ${CONSOLE_PORT}(容器内网页)"
fi

if ! docker run -d \
  --name "${CONTAINER}" \
  --restart unless-stopped \
  --env-file .env \
  -e BOT_DATA_DIR=/app/data \
  ${PORT_ARGS[@]+"${PORT_ARGS[@]}"} \
  -v "${DATA_DIR}:/app/data" \
  "${IMAGE}" >/dev/null
then
  echo "!!  新容器没起来（端口被占之类）。先用「不带端口映射」的方式让 bot 上线：" >&2
  echo "     cd $(pwd) && docker rm -f ${CONTAINER} && docker run -d --name ${CONTAINER} \\" >&2
  echo "       --restart unless-stopped --env-file .env -e BOT_DATA_DIR=/app/data \\" >&2
  echo "       -v \"$(pwd)/data:/app/data\" ${IMAGE}" >&2
  echo "     （这样 bot 正常，只是账单明细网页暂时从外面打不开）" >&2
  exit 1
fi

echo "==> 5/5 启动日志"
sleep 3
docker logs --tail 20 "${CONTAINER}"

echo
echo "完成。实时日志： docker logs -f ${CONTAINER}"
echo "看到「记账机器人已启动，正在监听消息...」且没有 Unauthorized 就是成功。"
