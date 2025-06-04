#!/bin/bash

# 默认值设置
BUILD_TYPE="prod"
CLI_TYPE="manual"

# 参数处理
for arg in "$@"
do
    case $arg in
        dev)
        BUILD_TYPE="dev"
        ;;
        prod)
        BUILD_TYPE="prod"
        ;;
        auto)
        CLI_TYPE="auto"
        ;;
    esac
done

# 根据参数设置编译选项
if [ "$BUILD_TYPE" = "dev" ]; then
    PROTO_LOG="ON"
    DEBUG_LOG="ON"
else
    PROTO_LOG="OFF"
    DEBUG_LOG="OFF"
fi

if [ "$CLI_TYPE" = "auto" ]; then
    AUTOCLI="ON"
else
    AUTOCLI="OFF"
fi

# 执行cmake命令
cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED=ON -DHOTSTUFF_PROTO_LOG=$PROTO_LOG -DHOTSTUFF_DEBUG_LOG=$DEBUG_LOG -DHOTSTUFF_ENABLE_BENCHMARK=ON -DSYNCHS_AUTOCLI=$AUTOCLI
make