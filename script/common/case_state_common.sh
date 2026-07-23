#!/usr/bin/env bash

# 功能：初始化标准 Benchmark 指标
init_benchmark_metrics() {
    okPoint=0; okOperation=0; failPoint=0; failOperation=0
    throughput=0; Latency=0; MIN=0; P10=0; P25=0; MEDIAN=0
    P75=0; P90=0; P95=0; P99=0; P999=0; MAX=0
}

# 功能：初始化标准监控指标
init_monitor_metrics() {
    numOfSe0Level=0; numOfUnse0Level=0; dataFileSize=0; walFileSize=0
    maxNumofOpenFiles=0; maxNumofThread=0; errorLogSize=0
    maxCPULoad=0; avgCPULoad=0
    maxDiskIOOpsRead=0; maxDiskIOOpsWrite=0
    maxDiskIOSizeRead=0; maxDiskIOSizeWrite=0
}

# 功能：初始化单轮测试时间状态
init_case_timestamps() {
    start_time=""; end_time=""; cost_time=0; m_start_time=0; m_end_time=0
}

# 功能：初始化公共状态并调用场景扩展 hook
init_case_state() {
    init_benchmark_metrics
    init_monitor_metrics
    init_case_timestamps
    declare -F init_scenario_state >/dev/null 2>&1 && init_scenario_state
}
