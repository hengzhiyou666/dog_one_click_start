#!/bin/bash

echo "========== 一键启动开始 =========="

PIDS=()

########################################
# Ctrl+C 统一退出
########################################
cleanup() {
    echo ""
    echo "========== 正在关闭所有进程 =========="

    for pid in "${PIDS[@]}"; do
        kill -SIGINT "$pid" 2>/dev/null
    done

    pkill -f foxglove_bridge
    pkill -f vbot_path_follower.py

    echo "========== 已全部关闭 =========="
    exit 0
}

trap cleanup SIGINT

########################################
# 1️⃣ 发布路径
########################################
echo "开始发布路径..."

(
    source /app/script/env.sh
    echo "开始发布路径"
    python3 /app/egoplanner_heng_dog/pct_path_7m/pct_path_publisher_0_to_7m.py
) > path_pub.log 2>&1 &

PIDS+=($!)

sleep 3

########################################
# 2️⃣ 重启 SLAM
########################################
echo "开始重启slam..."

source /app/script/env.sh
sudo systemctl restart vita_slam

echo "完成slam重启"

sleep 3

########################################
# 3️⃣ planner
########################################
echo "开始启动局部路径规划算法..."

(
    source /app/script/env.sh
    source /app/egoplanner_heng_dog/install4/setup.bash
    chmod 777 /app/egoplanner_heng_dog/install4/dog_ego_planner/lib/dog_ego_planner/dog_planner_node
    ros2 launch dog_ego_planner robot_launch.py
) > planner.log 2>&1 &

PIDS+=($!)

sleep 3

########################################
# 4️⃣ foxglove_bridge（自动重启）
########################################
echo "开始启动foxglove_bridge..."

monitor_foxglove() {
    while true; do
        (
            source /app/script/env.sh
            echo "启动 foxglove_bridge"
            ros2 run foxglove_bridge foxglove_bridge
        ) > foxglove.log 2>&1 &

        FOX_PID=$!
        echo "foxglove_bridge PID: $FOX_PID"

        # 监控错误（连续3秒检测 error）
        ERROR_COUNT=0

        while kill -0 $FOX_PID 2>/dev/null; do
            sleep 1

            if tail -n 20 foxglove.log | grep -i "error" >/dev/null; then
                ((ERROR_COUNT++))
            else
                ERROR_COUNT=0
            fi

            if [ $ERROR_COUNT -ge 3 ]; then
                echo "检测到foxglove_bridge连续报错，正在重启..."
                kill -9 $FOX_PID
                break
            fi
        done

        echo "foxglove_bridge 已退出，准备重启..."
        sleep 2
    done
}

monitor_foxglove &
PIDS+=($!)

########################################
# 5️⃣ 控制器（可交互）
########################################

controller_loop() {
    while true; do
        echo ""
        echo "机器狗控制器已启动，是否暂停？（按 Enter / 空格）"

        (
            source /app/script/env.sh
            python3 vbot_path_follower.py
        ) &

        CTRL_PID=$!

        # 等用户按键
        read -n 1 -s key
        kill -SIGINT $CTRL_PID

        echo ""
        echo "控制器已经暂停，是否需要再次启动控制器？（按 Enter / 空格）"

        read -n 1 -s key
    done
}

controller_loop &
PIDS+=($!)

########################################

echo "========== 所有进程已启动 =========="

# 保持主进程不退出
while true; do
    sleep 1
done
