#!/bin/bash

# 默认参数值
REPLICAS_NUMS=4
CLIENT_NUMS=4
BLOCK_SIZE=400
DELTA=0.05
LOGDIR='./logs'
RESULT='./results'
KEYS='./configs'
BINDIR='../bin'
CPU_IDLE_THRD=10
CMD_NUM=200000
MAX_ASYNC=4000
LEADER_FAULT=false
FAULTY_SIZE=0
FAULTY_LIST=""
FORCE_TIMEOUT=false

timeout_seconds=30

# 使用说明函数
function print_usage {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -r, --replicas NUM    指定副本数量 (默认: 3)"
    echo "  -c, --clients NUM     指定客户端数量 (默认: 3)"
    echo "  -b, --block-size SIZE 指定区块大小 (默认: 400)"
    echo "  -d, --delta VALUE     指定 delta 值 (默认: 0.05)"
    echo "  -l, --log-dir DIR     指定日志目录 (默认: ./bench/logs)"
    echo "  -n, --cmd-num NUM     指定命令数量 (默认: 200000，-1表示无限)"
    echo "  -a, --max-async NUM   指定最大异步数量 (默认: 4000)"
    echo "  -f, --leader-fault    启用领导者故障模式"
    echo "  -x, --faulty-size NUM 指定崩溃节点数量 (默认: 0)"
    echo "  -t, --force-timeout   强制启用超时模式"
    echo "  -h, --help            显示此帮助信息"
    exit 1
}

# 优雅停止进程的通用函数
function graceful_stop {
    local process_pattern=$1
    local pids=$(pgrep -f "$process_pattern")
    local process_cnt=$(echo "$pids" | wc -w)
    
    if [ -z "$pids" ]; then
        echo "未找到${process_pattern}进程"
        return 0
    fi
    
    echo "检测到${process_pattern}进程: $pids，开始优雅停止..."
    
    # 向所有进程同时发送SIGINT信号
    for pid in $pids; do
        if ps -p $pid > /dev/null; then
            echo "向${process_pattern}进程 $pid 发送中断信号(SIGINT)"
            kill -SIGINT $pid
        fi
    done
    
    # 等待所有进程退出
    local wait_time=$((10 * (process_cnt + 1)))
    echo "等待${wait_time}秒钟，直到所有${process_pattern}进程完成退出..."
    for pid in $pids; do
        wait_count=0
        while ps -p $pid > /dev/null && [ $wait_count -lt ${wait_time} ]; do
            echo "等待${process_pattern}-${pid}进程完成退出..."
            sleep 1
            wait_count=$((wait_count + 1))
        done
        
        # 如果进程仍在运行，发送SIGTERM
        if ps -p $pid > /dev/null; then
            echo "${process_pattern}进程 $pid 未响应中断信号，发送终止信号(SIGTERM)"
            sleep 2
            kill -SIGTERM $pid
            
            # 如果进程仍在运行，发送SIGKILL
            if ps -p $pid > /dev/null; then
                echo "${process_pattern}进程 $pid 仍未退出，强制终止(SIGKILL)"
                sleep 0.5
                kill -9 $pid
            fi
        fi
    done
    
    # 检查是否有未终止的进程
    remaining=$(pgrep -f "$process_pattern")
    if [ ! -z "$remaining" ]; then
        echo "仍有${process_pattern}进程未终止，强制终止这些进程..."
        for pid in $remaining; do
            if ps -p $pid > /dev/null; then
                echo "强制终止${process_pattern}进程 $pid"
                sleep 0.5
                kill -9 $pid
            fi
        done
    fi
    
    echo "所有${process_pattern}进程已完全退出"
}

# 检测是否完成
function do_waiting {
  # 获取所有客户端进程的PID
  CLIENT_PIDS=$(pgrep -f "hotstuff-client")

  # 创建一个临时文件来存储CPU负载数据
  CPU_LOG_FILE="${LOGDIR}/cpu_usage.log"
  echo "时间戳,CPU使用率(%)" > ${CPU_LOG_FILE}
  
  # 设置超时逻辑
  timeout_mode=false
  if [ "$CMD_NUM" == "-1" ] || [ "$FORCE_TIMEOUT" = true ]; then
    echo "启用超时模式：$([ "$CMD_NUM" == "-1" ] && echo "CMD_NUM为-1" || echo "FORCE_TIMEOUT为true")，将执行10s压力测试，不进行CPU负载检测"
    timeout_mode=true
    start_time=$(date +%s)
  fi

  if [ -z "$CLIENT_PIDS" ]; then
      echo "警告: 未找到客户端进程，可能已经快速完成"
  else
      echo "检测到客户端进程: $CLIENT_PIDS"
      
      # 连续低CPU计数器
      low_cpu_count=0
      
      while true; do
         
          # 获取当前时间戳
          timestamp=$(date "+%Y-%m-%d %H:%M:%S")

          # 检查是否达到超时时间 (仅在超时模式下)
          if [ "$timeout_mode" = true ]; then
              current_time=$(date +%s)
              elapsed_time=$((current_time - start_time))
              
              if [ $elapsed_time -ge $timeout_seconds ]; then
                  echo "达到${timeout_seconds}秒超时限制，开始优雅终止进程..."
                  break
              fi
              
              # 显示剩余时间
              remaining=$((timeout_seconds - elapsed_time))
              echo "测试将在${remaining}秒后超时退出"
          fi
      
          # 获取系统总体CPU使用率
          # 使用top命令获取当前CPU占用率
          cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
          echo "当前系统CPU使用率: ${cpu_usage}%"

          # 记录CPU使用率到日志文件
          echo "${timestamp},${cpu_usage}" >> ${CPU_LOG_FILE}
          
          # 如果所有客户端进程都已不存在，则退出循环
          active_clients=0
          for pid in $CLIENT_PIDS; do
              if ps -p $pid > /dev/null; then
                  active_clients=$((active_clients + 1))
              fi
          done
          
          if [ $active_clients -eq 0 ]; then
              echo "所有客户端已退出!"
              break
          fi
          
          # 只在非超时模式下检查CPU使用率
          if [ "$timeout_mode" = false ] && (( $(echo "$cpu_usage < ${CPU_IDLE_THRD}" | bc -l) )); then
              low_cpu_count=$((low_cpu_count + 1))
              echo "检测到低系统CPU使用率 ($low_cpu_count/4)"
              
              # 如果连续4次检测（2秒）CPU使用率都低于阈值，认为客户端已完成
              if [ $low_cpu_count -ge 4 ]; then
                  echo "系统负载已恢复正常（连续2秒CPU使用率低于${CPU_IDLE_THRD}%），测试似乎已经完成"
                  break
              fi
          else
              # 只在非超时模式下重置计数器
              if [ "$timeout_mode" = false ]; then
                  low_cpu_count=0
              fi
          fi
          
          # 等待0.5秒再次检测
          sleep 0.5
      done
  fi

  # 先停止服务器进程，再停止客户端进程
  echo "正在停止服务器进程..."
  graceful_stop "hotstuff-app" 
  
  echo "正在停止客户端进程..."
  graceful_stop "hotstuff-client" 
}

function do_cleanup {
  rm -r ./node.txt > /dev/null 2>&1
  rm -r hotstuff.conf > /dev/null 2>&1
  
  pkill -f hotstuff-app || true
  pkill -f hotstuff-client || true
  
  rm -f ${KEYS}/*
  rm -f ${LOGDIR}/*
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -r|--replicas)
            REPLICAS_NUMS="$2"
            shift 2
            ;;
        -c|--clients)
            CLIENT_NUMS="$2"
            shift 2
            ;;
        -b|--block-size)
            BLOCK_SIZE="$2"
            shift 2
            ;;
        -d|--delta)
            DELTA="$2"
            shift 2
            ;;
        -l|--log-dir)
            LOGDIR="$2"
            shift 2
            ;;
        -n|--cmd-num)
            CMD_NUM="$2"
            shift 2
            ;;
        -a|--max-async)
            MAX_ASYNC="$2"
            shift 2
            ;;
        -f|--leader-fault)
            LEADER_FAULT=true
            shift
            ;;
        -t|--force-timeout)
            FORCE_TIMEOUT=true
            shift
            ;;
        -x|--faulty-size)
            FAULTY_SIZE="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            ;;
        *)
            echo "错误: 未知参数 '$key'"
            print_usage
            ;;
    esac
done

# 创建日志目录
mkdir -p ${LOGDIR}
mkdir -p ${RESULT}
mkdir -p ${KEYS}

# 根据FAULTY_SIZE生成FAULTY_LIST
if [ "$FAULTY_SIZE" -gt 0 ]; then
    FAULTY_LIST=""
    for ((i=0; i<FAULTY_SIZE; i++)); do
        faulty_node=$((i*2))
        if [ -z "$FAULTY_LIST" ]; then
            FAULTY_LIST="$faulty_node"
        else
            FAULTY_LIST="${FAULTY_LIST},$faulty_node"
        fi
    done
    echo "生成的故障节点列表: $FAULTY_LIST"
fi

echo "============================================================="
echo "启动稳定性基准测试..."
echo "参数配置:"
echo "  副本数量: ${REPLICAS_NUMS}"
echo "  客户端数量: ${CLIENT_NUMS}"
echo "  区块大小: ${BLOCK_SIZE}"
echo "  Delta值: ${DELTA}"
echo "  日志目录: ${LOGDIR}"
echo "  命令数量: ${CMD_NUM}"
echo "  最大异步: ${MAX_ASYNC}"
echo "  强制超时模式: ${FORCE_TIMEOUT}"
if [ "$FAULTY_SIZE" -gt 0 ]; then
    echo "  故障节点数量: ${FAULTY_SIZE}"
    echo "  故障节点列表: ${FAULTY_LIST}"
fi
echo "============================================================="

echo "=> 步骤 0. 清理先前工作"

do_cleanup
sleep 0.5

echo "=> 步骤 1. 生成配置套件"

# 构建 Python 脚本的基本参数
PYTHON_ARGS="--prefix ${KEYS}/hotstuff \
    --keygen ../bin/hotstuff-keygen \
    --tls-keygen ../bin/hotstuff-tls-keygen \
    --block-size ${BLOCK_SIZE} \
    --delta ${DELTA} \
    --iter ${REPLICAS_NUMS} \
    --pace-maker rr"


if [ ! -z "$FAULTY_LIST" ]; then
    PYTHON_ARGS="${PYTHON_ARGS} --faulty-list ${FAULTY_LIST}"
fi

python3 ../scripts/gen_conf.py ${PYTHON_ARGS}

sleep 0.5

echo "=> 步骤 2. 启动 ${REPLICAS_NUMS} 个副本"

# 创建副本序列
rep=($(seq 0 $((REPLICAS_NUMS-1))))

for i in "${rep[@]}"; do
    echo "启动副本 $i"
    REPLICA_ARGS="--conf ${KEYS}/hotstuff-sec${i}.conf "
    if [ "$LEADER_FAULT" = true ]; then
        REPLICA_ARGS="${REPLICA_ARGS} --leader-fault --leader-tenure 2.2"
    fi
    ${BINDIR}/hotstuff-app ${REPLICA_ARGS}  > ${LOGDIR}/log${i}.log 2>&1 &
    # gdb -ex r -ex bt -ex q --args ${BINDIR}/hotstuff-app ${REPLICA_ARGS}  > ${LOGDIR}/log${i}.log 2>&1 &
done

echo "等待 4 秒钟让副本进入稳定状态..."
sleep 4

echo "=> 步骤 3. 启动 ${CLIENT_NUMS} 个客户端"

for i in $(seq 0 $((CLIENT_NUMS-1))); do
    echo "启动客户端 $i"
    CLIENT_ARGS="--cid ${i} --iter ${CMD_NUM} --max-async ${MAX_ASYNC} "
    ${BINDIR}/hotstuff-client ${CLIENT_ARGS} > ${LOGDIR}/log_client_${i}.log 2>&1 &
done

echo "=> 步骤 4. 正在执行自适应测试..."

echo "等待2秒后开始监控客户端状态..."

sleep 2

do_waiting

echo "=> 步骤 5. 处理测试结果..."

sleep 1

# 从LOGDIR中读取所有客户端日志文件并传给Python脚本
RESULT_PNG=./results/chstf-${REPLICAS_NUMS}-${CLIENT_NUMS}-${BLOCK_SIZE}-${DELTA}-${CMD_NUM}-${MAX_ASYNC}
if [ "$LEADER_FAULT" = true ]; then
    RESULT_PNG="${RESULT_PNG}-lf"
fi
if [ "$FAULTY_SIZE" -gt 0 ]; then
    RESULT_PNG="${RESULT_PNG}-fs${FAULTY_SIZE}"
fi
RESULT_PNG="${RESULT_PNG}.png"
RESULT_TXT=${RESULT_PNG%.png}.txt

cat ${LOGDIR}/log_client_* | python3 ../scripts/thr_hist.py \
        --plot --interval=${DELTA} \
        --output=${RESULT_PNG}  | tee  ${RESULT_TXT}
        # 将CPU使用率数据追加到结果文件中

echo "" >> ${RESULT_TXT}
echo "============= CPU 使用率记录 =============" >> ${RESULT_TXT}
cat ${LOGDIR}/cpu_usage.log >> ${RESULT_TXT}
        
echo "测试结果已保存到: ${RESULT_PNG} 和 ${RESULT_TXT}"

echo "============================================================="
echo "基准测试完成！"
echo "日志文件已保存在: ${LOGDIR}"
echo "============================================================="