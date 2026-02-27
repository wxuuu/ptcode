#!/bin/bash
set -e  # 遇到错误立即退出

# 初始化变量
FTP_USER=""
FTP_PASS=""
FTP_PORT="5000"
# 新增：指定 FTP 默认根目录
FTP_ROOT="/home/waterxu/qbittorrent/Downloads/"
VSFTPD_CONF="/etc/vsftpd.conf"
BACKUP_CONF="/etc/vsftpd.conf.bak"

# 函数：显示帮助信息
show_help() {
    echo "用法：$0 [选项]"
    echo "自动安装并配置Ubuntu FTP服务器（端口5000）"
    echo
    echo "选项："
    echo "  -u, --user      指定FTP用户名（必填，若使用参数模式）"
    echo "  -p, --password  指定FTP密码（必填，若使用参数模式）"
    echo "  -h, --help      显示此帮助信息"
    echo
    echo "示例："
    echo "  $0 -u user -p 11111111"
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user) FTP_USER="$2"; shift 2 ;;
        -p|--password) FTP_PASS="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "错误：未知参数 $1" >&2; show_help; exit 1 ;;
    esac
done

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用root权限运行此脚本（sudo）" >&2
    exit 1
fi

echo "===== 第一步：更新软件源并安装vsftpd ====="
apt update -y > /dev/null
apt install -y vsftpd > /dev/null

echo "===== 第二步：备份原始配置文件 ====="
if [ ! -f "$BACKUP_CONF" ]; then
    cp "$VSFTPD_CONF" "$BACKUP_CONF"
    echo "已备份原始配置到 $BACKUP_CONF"
else
    echo "配置备份文件已存在，跳过备份"
fi

echo "===== 第三步：配置vsftpd（端口：$FTP_PORT） ====="
# 确保安全目录存在
mkdir -p /var/run/vsftpd/empty

cat > "$VSFTPD_CONF" << EOF
# 核心配置
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=NO
chroot_local_user=YES
allow_writeable_chroot=YES

# 新增：指定本地用户登录后的默认目录
local_root=$FTP_ROOT

# 端口配置
listen_port=$FTP_PORT
pasv_enable=YES
pasv_min_port=5001
pasv_max_port=5010

# 安全配置
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
userlist_enable=NO
tcp_wrappers=YES
EOF

echo "===== 第四步：配置防火墙 ====="
if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw active; then
    ufw allow $FTP_PORT/tcp > /dev/null
    ufw allow 5001:5010/tcp > /dev/null
    ufw reload > /dev/null
    echo "UFW防火墙规则已更新"
else
    echo "提示：UFW未安装或未启用，跳过防火墙配置"
fi

echo "===== 第五步：处理FTP账户与目录权限 ====="
if ! grep -q "/usr/sbin/nologin" /etc/shells; then
    echo "/usr/sbin/nologin" >> /etc/shells
fi

create_or_update_user() {
    local u="$1"
    local p="$2"
    if id "$u" > /dev/null 2>&1; then
        echo "警告：账户 $u 已存在，将更新密码"
    else
        useradd -m -s /usr/sbin/nologin "$u" > /dev/null
        echo "已创建账户 $u"
    fi
    echo "$u:$p" | chpasswd
    echo "已成功设置账户密码"
    
    # 新增：创建指定的默认文件夹并赋予该 FTP 用户所有权
    echo "正在配置默认FTP目录：$FTP_ROOT"
    mkdir -p "$FTP_ROOT"
    # 这里只改变该目录的所有权，以确保FTP用户有权限上传文件
    chown "$u:$u" "$FTP_ROOT"
}

if [ -n "$FTP_USER" ] && [ -n "$FTP_PASS" ]; then
    echo "（参数模式）正在配置账户..."
    create_or_update_user "$FTP_USER" "$FTP_PASS"
elif [ -n "$FTP_USER" ] || [ -n "$FTP_PASS" ]; then
    echo "错误：-u/--user 和 -p/--password 必须同时指定" >&2
    exit 1
else
    echo "（交互式模式）"
    read -p "是否需要创建FTP专用账户？(y/n，默认n)：" CREATE_USER
    if [[ "$CREATE_USER" =~ ^[Yy]$ ]]; then
        read -p "请输入FTP账户名：" FTP_USER
        read -s -p "请输入FTP账户密码：" FTP_PASS
        echo
        read -s -p "请再次输入密码确认：" FTP_PASS_CONFIRM
        echo
        if [ "$FTP_PASS" = "$FTP_PASS_CONFIRM" ]; then
            create_or_update_user "$FTP_USER" "$FTP_PASS"
        else
            echo "错误：两次输入的密码不一致" >&2
            exit 1
        fi
    fi
fi

echo "===== 第六步：启动vsftpd服务 ====="
systemctl restart vsftpd
systemctl enable vsftpd > /dev/null

if systemctl is-active --quiet vsftpd; then
    echo -e "\n===== 安装完成 ====="
    echo "FTP服务器端口：$FTP_PORT"
    if [ -n "$FTP_USER" ]; then
        echo "FTP账户：$FTP_USER"
        echo "FTP默认目录：$FTP_ROOT"
    fi
    echo "注意：被动模式端口范围为 5001-5010，请确保已开放"
else
    echo -e "\n错误：vsftpd服务启动失败，请使用 'systemctl status vsftpd' 检查日志" >&2
    exit 1
fi