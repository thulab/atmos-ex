# Python API 场景操作说明

## 1. 场景概览

`python_api.sh` 是持续轮询脚本，默认工作根 `/root/zk_test`。它监控本地 IoTDB `master` 代码更新，编译发行包和 Python client wheel，启动 `/root/apache-iotdb`，运行 `tools/python_api.py`，记录 `InsertRecord/InsertRecords/InsertTablet` 三项结果到 `QA_ATM.python_api`。

## 2. 运行前准备

设置 `ATMOS_DB_PASSWORD`，检查 `/root/zk_test/iotdb` 源码、Maven、Python3/pip、wheel 构建依赖及 root 工作目录权限。该脚本会卸载并安装系统/当前环境中的 `apache-iotdb` 包，必须使用隔离测试环境或虚拟环境。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /root/zk_test/atmos-ex
bash script/scenarios/python_api.sh 2>&1 | tee /root/zk_test/log_python_api_runner
```

## 4. 自动流程

脚本无限循环同步 IoTDB master；发现更新后编译 distribution，构建并安装 client-py wheel，重建/启动 IoTDB，执行 Python API 工具并等待 `All executions done!!`，最长 7200 秒。成功时从日志解析三项耗时入库；编译失败写 `-1`，测试超时写 `-3`。无更新时等待 300 秒。

## 5. 验收与排查

每个新 commit 预期一行，三项指标均应为非负且日志包含完成标志。重点检查 pip 实际安装版本、Python 解释器环境、IoTDB 启动日志和源码 HEAD；该脚本不受任务表 `retest` 控制，重跑需处理版本比较条件。
