#!/bin/bash

HOST="root@192.168.125.2"
PASSWORD="root"
SOURCE_COMMAND="source /app/script/env.sh"

# 设置窗口的初始位置（单位是像素）
X_OFFSET=100  # 水平方向的起始位置
Y_OFFSET=100  # 垂直方向的起始位置
WIDTH=100     # 窗口宽度
HEIGHT=30     # 窗口高度

# 记录所有gnome-terminal窗口的PID
PIDS=()

# 函数：关闭本地窗口进程
terminate_local_processes() {
    for PID in "${PIDS[@]}"; do
        kill -9 "$PID"
    done
}

# 函数：杀死机器狗上的进程
terminate_remote_processes() {
    echo "正在杀死机器狗上的进程..."
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$HOST" "
        set -e

        # 优先用 systemd 停服务（比 grep/kill 更可靠）
        systemctl stop vita_slam 2>/dev/null || true

        # 兜底：按命令行匹配强杀（避免把 grep 自己也匹配进去）
        pkill -9 -f 'pct_path_publisher_0_to_7m.py' 2>/dev/null || true
        pkill -9 -f 'dog_planner_node' 2>/dev/null || true
        pkill -9 -f 'foxglove_bridge' 2>/dev/null || true
        pkill -9 -f 'vbot_path_follower.py' 2>/dev/null || true
    " || true
}

wait_remote_processes_gone() {
    local timeout_s="${1:-30}"
    local interval_s="${2:-1}"
    local start_ts
    start_ts="$(date +%s)"

    echo "等待机器狗上的进程真正退出（超时 ${timeout_s}s）..."
    while true; do
        if sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$HOST" "
            set -e
            active_slam=0
            systemctl is-active --quiet vita_slam && active_slam=1 || true

            any_proc=0
            pgrep -f 'pct_path_publisher_0_to_7m.py' >/dev/null 2>&1 && any_proc=1 || true
            pgrep -f 'dog_planner_node' >/dev/null 2>&1 && any_proc=1 || true
            pgrep -f 'foxglove_bridge' >/dev/null 2>&1 && any_proc=1 || true
            pgrep -f 'vbot_path_follower.py' >/dev/null 2>&1 && any_proc=1 || true

            # 都不在了：返回 0；否则返回 1
            if [ \"\$active_slam\" -eq 0 ] && [ \"\$any_proc\" -eq 0 ]; then
                exit 0
            fi
            exit 1
        "; then
            echo "机器狗上的相关进程已全部退出。"
            return 0
        fi

        local now_ts elapsed_s
        now_ts="$(date +%s)"
        elapsed_s=$((now_ts - start_ts))
        if (( elapsed_s >= timeout_s )); then
            echo "等待超时：仍检测到机器狗上有相关进程/服务存活。"
            return 1
        fi
        sleep "$interval_s"
    done
}

# 捕获终止信号，确保关闭进程
trap "terminate_local_processes; HOST=\"$HOST\" PASSWORD=\"$PASSWORD\" bash \"$(dirname \"$0\")/kill_test14.sh\" || true; echo '所有窗口和进程已终止。'" EXIT

# 窗口 1: 重启机器狗slam
gnome-terminal --title="Restart SLAM" --geometry="${WIDTH}x${HEIGHT}+${X_OFFSET}+${Y_OFFSET}" -- bash -c "
sshpass -p $PASSWORD ssh -t -o StrictHostKeyChecking=no $HOST '$SOURCE_COMMAND && systemctl restart vita_slam'
exec bash
" &
PIDS+=($!)

# 更新X坐标，向右移动（增加水平间隔）
X_OFFSET=$((X_OFFSET + WIDTH + 50))

# 窗口 2: 发布路径
gnome-terminal --title="Path Publisher" --geometry="${WIDTH}x${HEIGHT}+${X_OFFSET}+${Y_OFFSET}" -- bash -c "
sshpass -p $PASSWORD ssh -t -o StrictHostKeyChecking=no $HOST '$SOURCE_COMMAND && python3 /app/egoplanner_heng_dog/pct_path_7m/pct_path_publisher_0_to_7m.py'
exec bash
" &
PIDS+=($!)

# 更新X坐标，向右移动（增加水平间隔）
X_OFFSET=$((X_OFFSET + WIDTH + 50))

# 窗口 3: 启动局部路径规划算法
gnome-terminal --title="Path Planner" --geometry="${WIDTH}x${HEIGHT}+${X_OFFSET}+${Y_OFFSET}" -- bash -c "
sshpass -p $PASSWORD ssh -t -o StrictHostKeyChecking=no $HOST '$SOURCE_COMMAND && source /app/egoplanner_heng_dog/install4/setup.bash && chmod 777 /app/egoplanner_heng_dog/install4/dog_ego_planner/lib/dog_ego_planner/dog_planner_node && ros2 launch dog_ego_planner robot_launch.py'
exec bash
" &
PIDS+=($!)

# 更新X坐标，向右移动（增加水平间隔）
X_OFFSET=$((X_OFFSET + WIDTH + 50))

# 窗口 4: 启动 foxglove_bridge
gnome-terminal --title="Foxglove Bridge" --geometry="${WIDTH}x${HEIGHT}+${X_OFFSET}+${Y_OFFSET}" -- bash -c "
sshpass -p $PASSWORD ssh -t -o StrictHostKeyChecking=no $HOST '$SOURCE_COMMAND && ros2 run foxglove_bridge foxglove_bridge && echo '已经启动foxglove_bridge''
exec bash
" &
PIDS+=($!)

# 更新X坐标，向右移动（增加水平间隔）
X_OFFSET=$((X_OFFSET + WIDTH + 50))

# 窗口 5: 启动控制器
gnome-terminal --title="Path Follower" --geometry="${WIDTH}x${HEIGHT}+${X_OFFSET}+${Y_OFFSET}" -- bash -c "
sshpass -p $PASSWORD ssh -t -o StrictHostKeyChecking=no $HOST '$SOURCE_COMMAND && python3 /app/egoplanner_heng_dog/0.0dogmove/vbot_path_follower.py'
exec bash
" &
PIDS+=($!)

# 等待用户按空格键
echo "请把焦点切回【运行 test14.sh 的这个终端】再按空格结束。"
while true; do
    IFS= read -rsn1 -p "按空格结束..." key
    echo
    [[ "$key" == " " ]] && break
done

# 按下空格后杀死所有进程
terminate_local_processes
HOST="$HOST" PASSWORD="$PASSWORD" bash "$(dirname "$0")/kill_test14.sh" || true
echo "所有窗口和进程已终止。"