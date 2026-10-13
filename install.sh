#!/bin/bash
# jobmon 安装脚本：装脚本、生成配置模板、渲染 LaunchAgent
set -euo pipefail

cd "$(dirname "$0")"

BIN_DIR="${BIN_DIR:-$HOME/bin}"
CONFIG_DIR="$HOME/.config/jobmon"
STATE_DIR="$HOME/.local/state/jobmon"
LABEL="cn.ojlab.jobmon"

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$STATE_DIR" "$HOME/Library/LaunchAgents"

install -m 755 jobmon "$BIN_DIR/jobmon"
echo "已安装 $BIN_DIR/jobmon"

if [ -e "$CONFIG_DIR/config.sh" ]; then
  echo "保留已有配置 $CONFIG_DIR/config.sh（未覆盖）"
else
  install -m 600 config.sh.example "$CONFIG_DIR/config.sh"
  echo "已生成配置模板 $CONFIG_DIR/config.sh  ← 请填写 SSH_HOST / CLUSTER_USER / 钉钉 webhook"
fi

sed -e "s|__HOME__|$HOME|g" -e "s|__BIN_DIR__|$BIN_DIR|g" plist.template.xml \
  > "$HOME/Library/LaunchAgents/$LABEL.plist"
plutil -lint "$HOME/Library/LaunchAgents/$LABEL.plist" >/dev/null
echo "已渲染 $HOME/Library/LaunchAgents/$LABEL.plist（按需加载，安装后不会自动运行）"

echo
echo "下一步："
echo "  1. 编辑 $CONFIG_DIR/config.sh"
echo "  2. $BIN_DIR/jobmon test     # 验证钉钉能收到消息"
echo "  3. $BIN_DIR/jobmon on       # 提交作业后唤醒监测"
echo
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "提示：$BIN_DIR 不在 PATH 里，可在 ~/.zshrc 加一行"
     echo "  export PATH=\"\$HOME/bin:\$PATH\"" ;;
esac
