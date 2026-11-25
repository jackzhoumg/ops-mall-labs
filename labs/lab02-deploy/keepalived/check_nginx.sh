#!/usr/bin/env bash
# Keepalived 健康检查：Nginx 进程在、而且能正常响应，才算健康
# 放在 /etc/keepalived/check_nginx.sh，属主 root、权限 755
#   enable_script_security 要求脚本和它所在的每一级目录都不能被非 root 用户写，否则 Keepalived 拒绝执行
#   （RHEL 系习惯放 /usr/libexec/keepalived/，那是为了 SELinux 标签；Ubuntu 没有这个目录，也没有对应的 AppArmor 限制）
#
# 退出码 0 = 健康；非 0 = 不健康，Keepalived 把本机优先级降 20，VIP 漂到另一台
# 故意不在这里自动重启 Nginx：重启掩盖了故障，而且配置写错时会反复重启、VIP 来回漂
# 对应教程：Lab 02 商城上线 5.15 节
set -u

systemctl is-active --quiet nginx || exit 1

# 进程在不代表能服务（worker 卡死、证书文件丢失等），再真实请求一次健康检查地址，2 秒超时
curl -fsk -m 2 -o /dev/null https://127.0.0.1/nginx-health || exit 1

exit 0
