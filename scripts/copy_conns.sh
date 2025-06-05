#!/bin/bash

# 设置工作目录为脚本所在目录
cd "$(dirname "$0")"

# 检查配置文件是否存在
if [ ! -f "replicas.txt" ]; then
    echo "错误：replicas.txt 文件不存在"
    exit 1
fi

if [ ! -f "clients.txt" ]; then
    echo "错误：clients.txt 文件不存在"
    exit 1
fi

echo "开始复制配置文件到测试用例文件夹并执行生成脚本..."

# 记录当前目录
current_dir=$(pwd)

# 查找并复制到所有以 testcase_ 开头的子文件夹，然后执行gen_all.sh
count=0
for dir in $(find . -type d -name "testcase_*"); do
    cp replicas.txt "$dir/"
    cp clients.txt "$dir/"
    echo "已复制配置文件到: $dir"
    
    # 进入测试用例文件夹
    cd "$dir"
    echo "进入目录 $dir 执行 gen_all.sh..."
    
    # 检查gen_all.sh是否存在并可执行
    if [ -x "./gen_all.sh" ]; then
        ./gen_all.sh
        echo "已在 $dir 中执行 gen_all.sh"
    else
        echo "警告：$dir 中的 gen_all.sh 不存在或不可执行"
    fi
    
    # 返回原始目录
    cd "$current_dir"
    
    count=$((count+1))
done

if [ $count -eq 0 ]; then
    echo "警告：未找到以 testcase_ 开头的文件夹"
else
    echo "完成！已复制配置文件到 $count 个测试用例文件夹"
fi
