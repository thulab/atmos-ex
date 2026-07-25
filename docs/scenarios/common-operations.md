# 场景脚本通用操作说明

## 1. 适用范围

本文说明所有场景共有的任务领取、环境检查、启动、观察、验收和重测步骤。场景文档只补充差异项；若场景文档与本文冲突，以场景脚本当前实现和场景文档为准。

> 警告：大多数 Linux 场景会终止本机 `DataNode`、`ConfigNode`、`IoTDB` 和 Benchmark 进程，并删除、重建测试目录。集群、Pipe 和 Windows 场景还会通过 SSH 清理远端目录和进程。仅可在对应专用测试环境运行。

## 2. 通用依赖

1. 仓库部署在场景指定的 `ATMOS_PATH`，通常为 `/data/atmos/zk_test/atmos-ex`。
2. 待测安装包位于 `/nasdata/repository/master/<commit_id>/apache-iotdb`。
3. IoT-Benchmark 仓库通常位于 `/nasdata/repository/iot-benchmark`，运行目录通常为 `/data/atmos/zk_test/iot-benchmark`。
4. MySQL 默认为 `111.200.37.158:13306/QA_ATM`，账号 `iotdbatm`。
5. Prometheus 默认为 `111.200.37.158:19090`。
6. 本地及远端账号必须具备脚本所需的免交互 `sudo`、SSH/SCP 和目录权限。

通用命令依赖包括 `awk`、`bc`、`curl`、`date`、`find`、`findmnt`、`git`、`jps`、`jq`、`lsof`、`lsblk`、`mysql`、`ps`、`sed`、`ssh`、`scp` 和 `sudo`；Windows 场景还要求可调用远端 PowerShell 任务。

## 3. 运行前步骤

1. 确认当前主机、远端节点和场景文档中的 IP 完全一致。
2. 检查待测目录和归档盘空间：`df -h /data /nasdata`。
3. 执行 `jps`，确认现有 Java 进程都属于可清理的测试实例。
4. 设置数据库密码：`export ATMOS_DB_PASSWORD='<数据库密码>'`。
5. 用 `MYSQL_PWD="$ATMOS_DB_PASSWORD" mysql -h111.200.37.158 -P13306 -uiotdbatm QA_ATM -e 'select 1'` 验证数据库。
6. 确认任务表存在目标提交，场景字段为 `NULL` 或 `retest`。
7. 确认 `/nasdata/repository/master/<commit_id>/apache-iotdb` 包含 `conf`、`sbin` 和 CLI。
8. 检查场景文档列出的 `conf/<scene>`、数据集、许可证、Benchmark 或 API 仓库。
9. 验证 Prometheus ready 接口和测试机 `9081/9091` 指标。
10. 对远端场景执行 SSH 连通性、免密登录、磁盘空间和进程检查。

## 4. 启动方式

首次验证建议前台运行：

```bash
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/<scene>.sh 2>&1 | tee /data/atmos/zk_test/log_<scene>
```

稳定后可后台运行：

```bash
nohup bash script/scenarios/<scene>.sh \
  >> /data/atmos/zk_test/log_<scene> 2>&1 &
```

使用总调度器时，将 `/data/atmos/zk_test/test_type_file` 写为场景名后运行 `atmos.sh`。调度器会执行 `git reset --hard origin/main`，部署目录中的未提交修改会丢失。

## 5. 通用任务生命周期

1. 校验依赖和 `ATMOS_DB_PASSWORD`，同步所需 Benchmark 版本。
2. 将 `test_type_file` 写为 `ontesting`。
3. 优先领取场景字段为 `retest` 的最新提交，否则领取字段为 `NULL` 的最新提交。
4. 将任务状态更新为 `ontesting`。
5. 作者为 `Timecho` 时写入 `<result_table>_T`，否则写入普通结果表。
6. 按场景测试矩阵逐项准备全新安装包、配置、数据和工具，启动测试并采集结果。
7. 成功时标记 `done`；普通提交还会把更早的未测提交标为 `skip`。失败通常标记 `RError`。
8. 退出时将 `test_type_file` 恢复为场景名。

## 6. 通用结果约定

Benchmark 场景通常写入成功/失败点数、吞吐、延迟分位数、文件数、数据量、线程数、打开文件数、错误日志大小、WAL、CPU 和磁盘 I/O。常见哨兵值：`-2` 表示结果缺失或解析失败，`-3` 表示 IoTDB 启动失败，`-4` 表示密码修改失败，`-1` 常用于超时占位。

验收不能只看任务为 `done`：还应核对预期结果行数、测试矩阵是否完整、吞吐/延迟是否有效、失败点是否为 0、错误日志是否为空，以及归档目录是否完整。

所有场景统一归档到：

```text
${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/
```

每轮运行和每个 case 都包含 `manifest.env`，case 还包含 `artifacts.tsv`。归档先写入 `.partial` 目录，完成后原子提交；已有 case 不会被覆盖。默认 `BACKUP_LEVEL=minimal`，失败诊断可使用 `diagnostic`，需要完整数据现场的场景使用 `full`。详细契约参见[统一备份公共脚本](../common/backup_common.md)。

## 7. 运行观察

```bash
tail -f /data/atmos/zk_test/log_<scene>
jps
find /data/atmos/zk_test/iot-benchmark/data/csvOutput -type f 2>/dev/null
```

远端场景还应同步查看节点进程、IoTDB 错误日志和网络连接。远端产物统一位于 case 目录的 `nodes/<host>/` 下。

## 8. 失败与重测

1. 先保留现场日志、CSV、配置和归档，确认失败发生在哪个测试组合。
2. 启动失败检查 `log_confignode_error.log`、`log_datanode_error.log`、端口、内存和许可证。
3. Benchmark 超时检查进程、配置、CSV、数据量和数据库连接。
4. 指标为 0 时检查 Prometheus target、测试机 IP 和自动解析的磁盘 ID。
5. 远端失败检查 SSH、SCP、账号权限、Windows 任务名或节点目录。
6. 修复后将目标提交的场景字段设为 `retest`，重新运行。
7. 重测会生成新的 `run_id`，不会覆盖已有归档；残留 `.partial` 表示归档未正常完成。
