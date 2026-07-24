# Native API Test 场景操作说明

## 1. 场景概览

`native_api_test.sh` 不从 `ex_commit_history` 领取任务，而是监控 `/data/atmos/zk_test/iotdb` 的 `master` 分支。检测到新提交后编译 IoTDB，在 `/data/qa/apache-iotdb` 启动实例，并运行 Java、C++、C、Python 四套 Native API 测试。结果写入 `QA_ATM.native_api_test`。

完成后脚本会自动把调度类型切到 `tsfile_api_test` 并后台启动该脚本；这是链式外部状态变更。

## 2. 运行前准备

1. 设置 `ATMOS_DB_PASSWORD`，确认网络代理（默认 `172.20.31.15:7890`）符合当前环境。
2. 检查 IoTDB 源码仓库，以及 `java/cpp/c/python-native-api-testcase` 四个工具仓库；脚本当前只显式更新 Java、C++、Python 仓库，C 工具也必须预先存在。
3. 准备 Maven、C/C++ 编译链、Python/pip、Git 凭据和最长 7200 秒的编译窗口。
4. 确认 `/data/qa` 可被递归清理，`native_api_test_report` 仓库允许 commit/push。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/native_api_test.sh 2>&1 | tee /data/atmos/zk_test/log_native_api_test
```

## 4. 自动流程

脚本同步 IoTDB master 和测试工具；仅在 IoTDB HEAD 变化时最多重试编译，复制发行包、调整内存并启动单机。随后依次执行四种语言测试，解析各自报告的用例数、错误、失败、跳过、成功率和耗时入库；失败报告复制到备份目录，汇总报告仓库会 commit/push。最后停止 IoTDB并触发 TsFile API 场景。

## 5. 验收与排查

新提交预期至少有 JAVA/CPP/C/PYTHON 四类记录；编译失败使用负值。检查各语言报告、`failures_num/errors_num`、报告仓库推送和后继 `tsfile_api_test` 是否启动。没有代码更新时不运行测试是设计行为。
