# TsFile API Test 场景操作说明

## 1. 场景概览

`tsfile_api_test.sh` 监控 `/data/atmos/zk_test/tsfile` 的 `develop` 分支；检测到新提交后分别运行 Java、C++、Python TsFile API 测试，结果写入 `QA_ATM.tsfile_api_test`。它不启动 IoTDB，也不使用 `ex_commit_history`。

## 2. 运行前准备

检查 TsFile 源码及 `java/cpp/python-tsfile-api-test` 三个工具仓库，准备 Maven、CMake/C++、Python/pip、代理（默认 `172.20.31.76:7890`）和 Git 凭据。确认 `/data/qa` 测试目录和统一归档根可写，并设置 `ATMOS_DB_PASSWORD`。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/tsfile_api_test.sh 2>&1 | tee /data/atmos/zk_test/log_tsfile_api_test
```

## 4. 自动流程

脚本同步 TsFile develop 和三套测试工具，仅在 HEAD 变化时执行：Java 生成 Surefire HTML，C++ 生成 JSON，Python 生成 reports；分别解析用例总数、错误、失败、跳过、成功率和耗时入库，失败现场按语言写入统一 case 归档。执行后等待 300 秒并把调度类型恢复为 `native_api_test`。

## 5. 验收与排查

新提交预期 JAVA/CPP/PYTHON 三类记录。`-2` 一般表示语言工具编译失败，超时或报告缺失也会写负值；逐项检查 HTML/JSON/Python 报告与数据库统计一致。无源码更新时只等待并切回调度，不应误判为漏测。
