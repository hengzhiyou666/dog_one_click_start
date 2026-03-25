#!/bin/bash
set -euo pipefail

# 用法：
#   bash kill_test14_processes.sh
#   HOST=root@192.168.125.2 PASSWORD=root bash kill_test14_processes.sh
#   bash kill_test14_processes.sh --host root@192.168.125.2 --password root --timeout 60 --interval 1

HOST_DEFAULT="root@192.168.125.2"
PASSWORD_DEFAULT="root"
TIMEOUT_S_DEFAULT="60"
INTERVAL_S_DEFAULT="1"

HOST="${HOST:-$HOST_DEFAULT}"
PASSWORD="${PASSWORD:-$PASSWORD_DEFAULT}"
TIMEOUT_S="${TIMEOUT_S_DEFAULT}"
INTERVAL_S="${INTERVAL_S_DEFAULT}"

usage() {
  cat <<'EOF'
用法:
  bash kill_test14_processes.sh [--host root@ip] [--password xxx] [--timeout 60] [--interval 1]

也可用环境变量:
  HOST=root@192.168.125.2 PASSWORD=root bash kill_test14_processes.sh

说明:
  - 会停止 vita_slam 服务，并强杀以下进程（按命令行匹配）：
    pct_path_publisher_0_to_7m.py, dog_planner_node, foxglove_bridge, vbot_path_follower.py
  - 然后循环检测，直到它们确实都退出（或超时）。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="$2"; shift 2;;
    --password)
      PASSWORD="$2"; shift 2;;
    --timeout)
      TIMEOUT_S="$2"; shift 2;;
    --interval)
      INTERVAL_S="$2"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 2;;
  esac
done

remote() {
  # 统一的远端执行入口：不依赖本地 ssh key，直接用密码
  # -T: 不分配伪终端，避免远端 profile/clear 导致的 TERM 报错
  sshpass -p "$PASSWORD" ssh -T -o StrictHostKeyChecking=no -o LogLevel=ERROR "$HOST" "$@"
}

kill_remote_processes() {
  echo "正在杀死机器狗上的进程（$HOST）..."
  remote "env TERM=dumb SYSTEMD_PAGER=cat SYSTEMD_COLORS=0 bash -c '
    set -e
    systemctl stop vita_slam 2>/dev/null || true

    # 先温和终止，再强杀，给进程一点清理时间
    # 用 [x]xxx 的写法避免 pkill/pgrep 匹配到自身命令行
    pkill -f \"[p]ct_path_publisher_0_to_7m.py\" 2>/dev/null || true
    pkill -f \"[d]og_planner_node\" 2>/dev/null || true
    pkill -f \"[f]oxglove_bridge\" 2>/dev/null || true
    pkill -f \"[v]bot_path_follower.py\" 2>/dev/null || true

    # 有些进程其实是 ros2/launch 进程名，额外兜底匹配
    pkill -f \"[r]os2 launch dog_ego_planner\" 2>/dev/null || true
    pkill -f \"[r]obot_launch.py\" 2>/dev/null || true

    sleep 1

    pkill -9 -f \"[p]ct_path_publisher_0_to_7m.py\" 2>/dev/null || true
    pkill -9 -f \"[d]og_planner_node\" 2>/dev/null || true
    pkill -9 -f \"[f]oxglove_bridge\" 2>/dev/null || true
    pkill -9 -f \"[v]bot_path_follower.py\" 2>/dev/null || true
    pkill -9 -f \"[r]os2 launch dog_ego_planner\" 2>/dev/null || true
    pkill -9 -f \"[r]obot_launch.py\" 2>/dev/null || true
  '" || true
}

wait_remote_processes_gone() {
  echo "等待远端进程真正退出（超时 ${TIMEOUT_S}s, 间隔 ${INTERVAL_S}s）..."

  # 只建立一次 SSH，在远端循环检测并打印剩余项，避免每秒重新登录触发 profile 输出
  remote "env TERM=dumb SYSTEMD_PAGER=cat SYSTEMD_COLORS=0 bash -c '
    set -e
    start_ts=\$(date +%s)

    while true; do
      active_slam=0
      systemctl is-active --quiet vita_slam && active_slam=1 || true

      # 收集还活着的进程（输出 pid + cmdline 方便定位为什么杀不掉）
      remain=\"\"
      # 用 [x]xxx 的写法避免 pgrep 匹配到本检测脚本自身命令行
      for pat in \
        \"[p]ct_path_publisher_0_to_7m.py\" \
        \"[d]og_planner_node\" \
        \"[f]oxglove_bridge\" \
        \"[v]bot_path_follower.py\" \
        \"[r]os2 launch dog_ego_planner\" \
        \"[r]obot_launch.py\"
      do
        if pgrep -a -f \"\$pat\" >/dev/null 2>&1; then
          remain=\"\$remain\n[match] \$pat\"
          remain=\"\$remain\n\$(pgrep -a -f \"\$pat\" | head -n 20)\"
        fi
      done

      if [ \"\$active_slam\" -eq 0 ] && [ -z \"\$remain\" ]; then
        echo \"OK：相关服务/进程已全部退出。\"
        exit 0
      fi

      now_ts=\$(date +%s)
      elapsed_s=\$((now_ts - start_ts))
      echo \"仍存活：vita_slam_active=\$active_slam, 已等待 \${elapsed_s}s\"
      if [ -n \"\$remain\" ]; then
        printf \"%b\n\" \"\$remain\"
      fi

      if [ \"\$elapsed_s\" -ge \"${TIMEOUT_S}\" ]; then
        echo \"等待超时：仍检测到相关服务/进程存活。\" >&2
        exit 1
      fi

      sleep \"${INTERVAL_S}\"
    done
  '"
}

kill_remote_processes
wait_remote_processes_gone
