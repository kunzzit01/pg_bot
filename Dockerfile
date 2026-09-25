FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    TZ=Asia/Kuala_Lumpur \
    BOT_DATA_DIR=/app/data

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 代码是打进镜像的：改完必须重新 build（deploy/update.sh 会做），光 docker restart 不生效
COPY . .

RUN mkdir -p /app/data
VOLUME ["/app/data"]

CMD ["python", "bot.py"]
