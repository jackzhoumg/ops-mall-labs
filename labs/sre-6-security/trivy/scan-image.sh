#!/usr/bin/env bash
# scan-image.sh：用 Trivy 扫描镜像，发现可修复的高危 / 严重漏洞就以非 0 退出，给 CI 当“闸门”用。
# 对应教程：SRE-6 集群安全加固
#
# 用法（在 lab-dev 或 CI 构建机上执行，需要已安装 trivy，写作时版本 0.76.2）：
#   bash scan-image.sh harbor.lab.local/mall/mall-api:v1.0.0
#   SEVERITY=CRITICAL bash scan-image.sh harbor.lab.local/mall/mall-web:v1.0.0
#   IGNORE_UNFIXED=false bash scan-image.sh <镜像>      # 连没有修复版本的漏洞也算
#
# 输出：终端表格 + 当前目录下 trivy-<镜像名>.json（留档，CI 里作为制品保存）
# 退出码：0 = 通过；1 = 有需要修的漏洞；2 = 用法错误
set -euo pipefail

image="${1:-}"
[[ -n "$image" ]] || {
  echo "用法：$0 <镜像>" >&2
  exit 2
}

SEVERITY="${SEVERITY:-HIGH,CRITICAL}"
IGNORE_UNFIXED="${IGNORE_UNFIXED:-true}"
IGNORE_FILE="${IGNORE_FILE:-$(dirname "$0")/.trivyignore}"

command -v trivy >/dev/null || {
  echo "没找到 trivy，安装方法见教程 5.1" >&2
  exit 2
}

args=(image --scanners vuln --severity "$SEVERITY" --exit-code 1)
[[ "$IGNORE_UNFIXED" == "true" ]] && args+=(--ignore-unfixed)
[[ -f "$IGNORE_FILE" ]] && args+=(--ignorefile "$IGNORE_FILE")

report="trivy-$(echo "$image" | tr '/:@' '___').json"

# 先出一份完整 JSON 报告留档（不设 exit-code，不影响结果）
trivy image --scanners vuln --format json --output "$report" "$image" >/dev/null

echo "扫描 ${image}（级别：${SEVERITY}，忽略无修复版本：${IGNORE_UNFIXED}）"
if trivy "${args[@]}" "$image"; then
  echo "[通过] 没有需要处理的 ${SEVERITY} 漏洞。完整报告：$report"
else
  echo "[阻断] 发现 ${SEVERITY} 漏洞，升级基础镜像或依赖后重新构建。完整报告：$report" >&2
  exit 1
fi
