#!/bin/bash
rep=({0..3})
if [[ $# -gt 0 ]]; then
    rep=($@)
fi

# avoid stack overflow as in our simple demo the bootstrapping replica will
# potentially have a long chain of promise resolution
ulimit -s unlimited

for i in "${rep[@]}"; do
    echo "starting replica $i"
    #valgrind --leak-check=full ./bin/hotstuff-app --conf hotstuff-sec${i}.conf > log${i} 2>&1 &
    #gdb -ex r -ex bt -ex q --args ./bin/hotstuff-app --conf hotstuff-sec${i}.conf > log${i} 2>&1 &
    ./bin/hotstuff-app --conf ./configs/hotstuff-sec${i}.conf > log${i}.log 2>&1 &
done
wait
