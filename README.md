# pg_bot

Telegram 群管机器人：群发广播、租户到期管理、记账账单。功能详见 [BOT核心功能.md](BOT核心功能.md)。

## 部署

1. 安装 Python 3.10+，然后在项目目录：

   ```
   python -m venv .venv
   .venv\Scripts\pip install "python-telegram-bot[job-queue]" openpyxl
   ```

   （Windows 下直接双击 `启动测试.bat` 会自动完成建环境、装依赖并启动。）

2. 配置 Token（二选一，`bot.py` 不会内置 Token）：

   - 在项目根目录创建 `token.txt`，内容为 Bot Token；
   - 或设置环境变量 `BOT_TOKEN`。

3. 启动：

   ```
   .venv\Scripts\python bot.py
   ```

## 数据

所有运行数据保存在 `data/` 目录（JSON 文件），首次运行自动生成，不随仓库分发。
