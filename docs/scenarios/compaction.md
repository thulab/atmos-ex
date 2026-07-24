# Compaction 场景操作说明

本文说明如何准备、启动、观察和验收 `script/scenarios/compaction.sh`。该脚本用于对指定 IoTDB 提交依次执行顺序空间合并、乱序空间合并和跨空间合并测试，并将结果写入 MySQL。

> 警告：脚本会停止本机已有的 `DataNode`、`ConfigNode` 和 `IoTDB` Java 进程，删除 `/data/atmos/apache-iotdb` 下原有数据，并在测试结束后移动整个 IoTDB 目录。只能在专用测试机 `11.101.17.114` 上运行，不要在保存有效数据或运行其他 IoTDB 实例的机器上执行。

## 1. 场景概览

脚本当前使用固定测试矩阵：

| 项目 | 固定值 |
| --- | --- |
| 测试机 | `11.101.17.114` |
| 场景名 | `compaction` |
| 协议编号 | `211` |
| ConfigNode 共识协议 | RatisConsensus |
| SchemaRegion 共识协议 | SimpleConsensus |
| DataRegion 共识协议 | SimpleConsensus |
| 时间序列类型 | `common`、`aligned` |
| 单种序列的测试顺序 | `seq_space` → `unseq_space` → `cross_space` |
| 单轮合并等待上限 | 7200 秒 |

一次任务共执行 `1 个协议 × 2 种序列类型 × 3 种合并类型 = 6` 轮测试。脚本不接收命令行参数；待测提交来自 MySQL 任务表，测试矩阵和路径由脚本顶部常量控制。

## 2. 目录和外部服务

### 2.1 固定目录

| 路径 | 用途 | 运行中的处理 |
| --- | --- | --- |
| `/data/atmos/zk_test/atmos-ex` | 本仓库部署目录 | 从这里执行场景脚本 |
| `/nasdata/repository/master/<commit_id>/apache-iotdb` | 待测提交的 IoTDB 安装包 | 每种序列测试开始前复制到测试目录 |
| `/data/atmos/DataSet/211/common/data` | 普通序列预置数据 | 复制到 IoTDB 目录 |
| `/data/atmos/DataSet/211/aligned/data` | 对齐序列预置数据 | 复制到 IoTDB 目录 |
| `/data/atmos/apache-iotdb` | 本轮临时 IoTDB 实例 | 会被删除、重建并最终移动 |
| `/nasdata/repository/compaction/<ts_type>` | 结果归档根目录 | 保存测试后的完整 IoTDB 目录 |
| `/data/atmos/zk_test/test_type_file` | 调度状态文件 | 运行时写为 `ontesting`，退出时恢复为 `compaction` |

归档目录名称为：

```text
/nasdata/repository/compaction/<common|aligned>/<commit_date_time>_<commit_id>_211/
```

若同名归档已经存在，脚本会先将其递归删除。

### 2.2 外部服务

- MySQL：`111.200.37.158:13306`，数据库 `QA_ATM`。
- Prometheus：`111.200.37.158:19090`。
- 待测机的 DataNode 指标地址：`11.101.17.114:9091`；ConfigNode 指标端口为 `9081`。
- 结果表：普通提交写入 `ex_compaction`；作者为 `Timecho` 时写入 `ex_compaction_T`。
- 任务表：`ex_commit_history`，使用其中的 `compaction` 字段维护任务状态。

## 3. 运行前准备

### 步骤 1：确认在专用测试机上

```bash
hostname -I
```

确认当前机器是测试机 `11.101.17.114`，并确认机器上没有需要保留的 IoTDB 进程和 `/data/atmos/apache-iotdb` 数据。

### 步骤 2：确认系统命令齐全

脚本会检查以下命令：

```text
awk bc cat cp curl cut date du find findmnt grep hostname jps jq kill
lsof lsblk mkdir mv mysql ps readlink rm scp sed sleep ssh sudo tail
touch tr wc
```

可重点检查容易缺失的工具：

```bash
command -v bc curl jq jps lsof mysql sudo
```

同时确认当前用户可免交互执行脚本涉及的 `sudo mkdir`、`sudo mv` 和 `sudo rm`，否则后台运行会停在密码输入处。

### 步骤 3：准备数据库密码

MySQL 密码不应写入脚本或文档，运行前通过环境变量提供：

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
```

若使用 `nohup`、cron 或 systemd 启动，应在同一个运行环境中设置该变量。变量为空时脚本会立即退出并提示 `ATMOS_DB_PASSWORD is required`。

可先验证数据库连通性和账号权限：

```bash
MYSQL_PWD="$ATMOS_DB_PASSWORD" mysql -N -B \
  -h111.200.37.158 -P13306 -uiotdbatm QA_ATM \
  -e "select 1;"
```

该账号至少需要读取 `ex_commit_history`，更新其 `compaction` 字段，并向 `ex_compaction`、`ex_compaction_T` 插入记录。

### 步骤 4：准备待测任务和安装包

脚本按以下优先级领取一条任务：

1. `compaction = 'retest'` 的最新提交；
2. 若没有重测任务，则选择 `compaction is null` 的最新提交。

确认待测任务的 `commit_id`、`author` 和 `commit_date_time` 已写入 `QA_ATM.ex_commit_history`。然后确认编译产物存在：

```bash
test -d /nasdata/repository/master/<commit_id>/apache-iotdb
test -f /nasdata/repository/master/<commit_id>/apache-iotdb/conf/iotdb-system.properties
test -f /nasdata/repository/master/<commit_id>/apache-iotdb/conf/datanode-env.sh
```

安装包还必须包含可执行的 `sbin/start-confignode.sh`、`sbin/start-datanode.sh`、停止脚本以及 CLI 工具。

### 步骤 5：准备测试数据

确认两种序列数据均存在：

```bash
test -d /data/atmos/DataSet/211/common/data
test -d /data/atmos/DataSet/211/aligned/data
find /data/atmos/DataSet/211/common/data -name '*.tsfile' | head
find /data/atmos/DataSet/211/aligned/data -name '*.tsfile' | head
```

预置数据会直接复制到 `/data/atmos/apache-iotdb/data`。数据目录结构需要与当前 IoTDB 版本兼容，并同时具备各轮测试所需的顺序和乱序 TsFile。

### 步骤 6：确认许可证和监控

确认仓库内存在场景许可证：

```bash
test -f /data/atmos/zk_test/atmos-ex/conf/compaction/license
```

脚本会将其复制到 IoTDB 的 `activation/` 目录。再检查 Prometheus 可访问且能够查询测试机指标：

```bash
curl -fsS 'http://111.200.37.158:19090/-/ready'
curl -G -fsS 'http://111.200.37.158:19090/api/v1/query' \
  --data-urlencode 'query=sys_cpu_load{instance="11.101.17.114:9091"}'
```

脚本会根据 `dn_data_dirs`、`dn_wal_dirs` 和挂载设备自动确定磁盘 ID；解析失败时回退到 `sdb`。

### 步骤 7：确认磁盘空间和进程状态

```bash
df -h /data/atmos /nasdata/repository/compaction
jps
```

空间至少应能同时容纳源数据、临时 IoTDB 目录和归档结果。若 `jps` 中已有 `DataNode`、`ConfigNode` 或 `IoTDB`，必须先确认它们可以被脚本终止。

## 4. 启动步骤

### 方式 A：直接运行，推荐用于首次验证

```bash
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/compaction.sh 2>&1 | tee /data/atmos/zk_test/log_compaction
```

前台运行便于及时发现权限、路径或依赖问题。不要使用 `sh script/scenarios/compaction.sh`；脚本要求 Bash。

### 方式 B：后台运行

```bash
cd /data/atmos/zk_test/atmos-ex
nohup bash script/scenarios/compaction.sh \
  >> /data/atmos/zk_test/log_compaction 2>&1 &
echo $!
```

### 方式 C：由总调度脚本启动

将调度状态设为 `compaction` 后运行 `atmos.sh`：

```bash
printf 'compaction\n' > /data/atmos/zk_test/test_type_file
cd /data/atmos/zk_test/atmos-ex
bash atmos.sh
```

`atmos.sh` 会更新仓库，并以后台方式调用 `script/scenarios/compaction.sh`。注意当前调度脚本包含 `git reset --hard origin/main`，本机未提交修改会丢失，因此部署机上不要保留工作中改动。

## 5. 脚本自动执行流程

### 5.1 领取任务

1. 检查命令依赖和 `ATMOS_DB_PASSWORD`。
2. 把 `test_type_file` 写为 `ontesting`。
3. 从任务表领取重测任务或最新待测任务；若没有任务，等待 60 秒后退出。
4. 将该提交的 `compaction` 状态更新为 `ontesting`。

### 5.2 执行单种序列类型

脚本先执行 `common`，再执行 `aligned`。每种类型都会：

1. 终止残留的 IoTDB Java 进程。
2. 删除旧的 `/data/atmos/apache-iotdb`，从 `/nasdata/repository/master/<commit_id>/apache-iotdb` 复制全新的安装包。
3. 复制场景许可证。
4. 将 DataNode 堆内存改为 `20G`，并写入基础配置：
   - `series_slot_num=10000`
   - 初始关闭顺序、乱序和跨空间合并
   - `cluster_name=compaction`
   - ConfigNode/DataNode 开启全部级别指标和性能统计
   - Prometheus 端口分别设为 `9081`、`9091`
5. 按协议编号 `211` 写入三类共识协议。
6. 把对应预置 `data` 目录复制进 IoTDB。
7. 依次执行三轮合并测试。

### 5.3 三轮合并参数

| 轮次 | `comp_type` | 顺序合并 | 乱序合并 | 跨空间合并 | 目标文件大小 | 启动就绪检查 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `seq_space` | 开启 | 关闭 | 关闭 | 1 GiB | 10 次，每次间隔 5 秒 |
| 2 | `unseq_space` | 关闭 | 开启 | 关闭 | 1 GiB | 20 次，每次间隔 30 秒 |
| 3 | `cross_space` | 关闭 | 关闭 | 开启 | 2 GiB | 20 次，每次间隔 30 秒 |

每轮测试的实际动作是：

1. 修改合并开关和目标文件大小。
2. 记录合并前数据目录大小及 sequence/unsequence 的 0 层 TsFile 数量。
3. 启动 ConfigNode，等待 10 秒，再启动 DataNode。
4. 等待 10 秒后执行 `show cluster` 就绪检查。
5. 就绪后再等待 30 秒，让对应合并任务启动。
6. 轮询 `data/datanode/data` 下的 `*compaction.log`。未发现活动日志时再等待 70 秒复核；活动日志消失且 `logs/log_datanode_compaction.log` 存在即认为该轮结束。
7. 最长等待 7200 秒。超时会向合并日志写入耗时为 `-1` 的占位记录，然后继续收集结果。
8. 停止 IoTDB，等待 30 秒并清理残留进程。
9. 收集合并后数据、进程峰值、错误日志标志和 Prometheus 指标。
10. 向结果表插入一行，并将本轮 `conf`、`logs` 移到 IoTDB 目录下以 `comp_type` 命名的归档目录。

三轮完成后，脚本删除测试目录中的 `data`，再把整个 `/data/atmos/apache-iotdb` 移到该序列类型的最终归档目录。

## 6. 运行中观察

### 6.1 查看场景日志

```bash
tail -f /data/atmos/zk_test/log_compaction
```

### 6.2 查看进程和合并状态

```bash
jps
find /data/atmos/apache-iotdb/data/datanode/data \
  -name '*compaction.log' 2>/dev/null
tail -f /data/atmos/apache-iotdb/logs/log_datanode_compaction.log
```

某些阶段 `logs` 已被移动到 `seq_space/`、`unseq_space/` 或 `cross_space/`，此时应到相应归档子目录查看。

### 6.3 查看任务状态

```bash
MYSQL_PWD="$ATMOS_DB_PASSWORD" mysql -N -B \
  -h111.200.37.158 -P13306 -uiotdbatm QA_ATM \
  -e "select commit_id,author,commit_date_time,compaction from ex_commit_history order by commit_date_time desc limit 10;"
```

状态含义：

| 状态 | 含义 |
| --- | --- |
| `NULL` | 尚未测试 |
| `retest` | 指定重测，领取优先级最高 |
| `ontesting` | 正在测试 |
| `done` | 六轮全部完成 |
| `RError` | 至少一轮启动或执行失败 |
| `skip` | 已有更新提交完成，较旧的普通提交被跳过 |

## 7. 完成验收

按以下顺序检查：

1. 场景日志出现本轮测试结束信息，脚本进程已退出。
2. `ex_commit_history.compaction` 为 `done`；若为 `RError`，按失败排查处理。
3. 普通提交应在 `ex_compaction` 中新增 6 行；作者为 `Timecho` 时应在 `ex_compaction_T` 中新增 6 行。
4. 每行对应一个 `ts_type + comp_type` 组合，即 `common/aligned × seq_space/unseq_space/cross_space`。
5. `cost_time` 正常情况下应为非负值。`-1` 表示没有提取到耗时或合并等待超时，`-3` 表示 IoTDB 启动失败。
6. `errorLogSize=0` 表示 ConfigNode 和 DataNode 错误日志均为空；值为 `1` 时需要检查错误日志。
7. 两个最终归档目录均存在，并包含三个合并类型的配置和日志归档。

可用以下 SQL 核对结果数量和关键字段：

```sql
select ts_type, comp_type, cost_time, errorLogSize,
       numOfSe0Level_before, numOfSe0Level_after,
       numOfUnse0Level_before, numOfUnse0Level_after,
       dataFileSize_before, dataFileSize_after,
       maxNumofOpenFiles, maxNumofThread, avgCPULoad, maxCPULoad
from ex_compaction
where commit_id = '<commit_id>'
order by ts_type, comp_type;
```

## 8. 常见失败与处理

### 缺少数据库密码

现象：日志提示 `ATMOS_DB_PASSWORD is required`。

处理：在实际启动脚本的 shell、cron 或服务环境中设置 `ATMOS_DB_PASSWORD`，然后将任务状态设为 `retest` 再执行。

### 找不到待测安装包

现象：日志提示 `missing tested IoTDB path`。

处理：确认任务的 `commit_id` 正确，并补齐 `/nasdata/repository/master/<commit_id>/apache-iotdb` 编译产物。

### 缺少预置数据

现象：日志提示缺少 `/data/atmos/DataSet/211/<ts_type>/data`。

处理：补齐对应 `common` 或 `aligned` 数据目录，检查挂载是否正常。

### IoTDB 启动失败

现象：任务最终为 `RError`，结果 `cost_time=-3`。

优先检查：

```bash
tail -n 100 /data/atmos/apache-iotdb/logs/log_confignode_error.log
tail -n 100 /data/atmos/apache-iotdb/logs/log_datanode_error.log
grep -E 'ON_HEAP_MEMORY|consensus_protocol|metric|compaction' \
  /data/atmos/apache-iotdb/conf/{datanode-env.sh,iotdb-system.properties}
```

若目录已经归档，则改到对应的 `/nasdata/repository/compaction/...` 目录检查。

### 合并超时或耗时为 `-1`

处理步骤：

1. 检查对应合并类型的 `log_datanode_compaction.log` 是否有成功完成记录。
2. 检查 `*compaction.log` 是否长期残留。
3. 检查磁盘空间、I/O、DataNode 错误日志和堆内存。
4. 确认预置数据确实能触发该类型合并。
5. 排除环境问题后，将任务的 `compaction` 状态改为 `retest` 重新执行。

### Prometheus 指标全部为 0

处理：确认 `9081/9091` 端口可访问、Prometheus 已抓取 `11.101.17.114`，并检查自动识别出的磁盘 ID。日志出现回退到 `sdb` 时，还需确认实际数据盘是否确为 `sdb`。

### 脚本异常退出后仍有进程

先查看现场日志，再停止专用测试实例：

```bash
cd /data/atmos/apache-iotdb
./sbin/stop-datanode.sh
./sbin/stop-confignode.sh
jps
```

确认没有其他业务实例后再处理残留进程。不要在未确认路径和归属时手工递归删除数据。

## 9. 重测操作

1. 保留首次失败的场景日志和归档目录，先完成原因分析。
2. 修复安装包、数据、权限、监控或环境问题。
3. 将目标提交在 `ex_commit_history` 中的 `compaction` 字段更新为 `retest`。
4. 重新运行脚本。
5. 重测会优先于所有 `compaction is null` 的新任务，并会覆盖同名最终归档目录；如需保留旧归档，应事先另行备份。

## 10. 当前实现注意事项

- 场景参数、IP、路径和协议均为脚本常量，不能通过命令行覆盖。
- 三轮测试使用同一份逐步变化的数据；不是每轮都重新恢复原始数据。
- 是否完成主要依据活动 `*compaction.log` 消失且合并主日志存在，不会进一步校验合并结果语义。
- 超时被记录为 `cost_time=-1` 后流程仍可继续，任务也可能最终标记为 `done`；验收时必须检查结果值，不能只看任务状态。
- `ts_dataSize`、`ts_numOfPoints` 和 `compaction_rate` 当前实现固定写入 `0`。
- `errorLogSize` 当前是错误日志是否非空的标志值 `0/1`，不是实际文件字节数。
- 脚本退出时会把 `test_type_file` 恢复为 `compaction`，这表示调度场景类型，不表示任务仍在执行。
