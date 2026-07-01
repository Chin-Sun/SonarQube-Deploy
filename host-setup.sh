#!/usr/bin/env bash
# 在 ECS 主机上以 root 运行一次：设置 SonarQube 内嵌 Elasticsearch 所需内核参数。
# 不设置 vm.max_map_count，SonarQube 会因 ES 启动失败而无法运行。
set -euo pipefail

echo ">> 写入内核参数 /etc/sysctl.d/99-sonarqube.conf"
cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF

sysctl --system

echo ">> 当前值："
sysctl vm.max_map_count fs.file-max

cat <<'NOTE'

下一步：
  1) 安装 Docker 与 compose 插件（若未安装）。
  2) cp .env.example .env 并填好 RDS 等信息。
  3) docker compose up -d
  4) docker compose logs -f sonarqube   # 看到 "SonarQube is operational" 即就绪
NOTE
