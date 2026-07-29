# Atmos EX

Atmos EX 是面向 Apache IoTDB / TimechoDB 的自动化测试与性能回归编排仓库。它以 MySQL 任务表为任务队列，从制品仓库部署指定提交的 IoTDB，调用 IoT-Benchmark、CLI、SQL/API 测试工具或远端节点执行测试，采集结果与系统指标，最后将数据写回结果表并归档运行现场。

仓库当前包含 29 个场景脚本和 20 个公共脚本，覆盖写入、查询、合并、集群、Pipe、重启恢复、删除、长稳、SQL 覆盖、Windows 和多语言 API 等测试。

> 重要：本仓库不是通用的本地单元测试套件。多数场景绑定专用测试机、共享数据库、Prometheus、NAS 数据集和制品目录，并会停止进程、删除测试目录、移动数据或清理远端主机。运行任何场景前必须阅读对应场景文档，并确认当前环境是可清理的专用测试环境。

## 核心能力

- 以 `QA_ATM.ex_commit_history` 管理待测、重测、执行中、完成和跳过状态。
- 按提交号从制品仓库部署全新的 IoTDB 安装目录。
- 统一编排 IoTDB、IoT-Benchmark、CLI、SQL 工具和多语言 API 测试。
- 支持单机、Linux 集群、Linux Pipe、Windows 和跨主机测试。
- 采集吞吐、延迟分位数、成功/失败点数、TsFile、WAL、线程、打开文件、CPU 和磁盘 I/O 等指标。
- 将测试结果写入场景结果表，并将配置、日志、CSV 和运行目录归档到 NAS。
- 通过公共脚本复用任务生命周期、配置、进程、监控、远端部署和安全路径处理。

## 整体架构

```text
                          QA_ATM.ex_commit_history
                                   │
                                   │ 领取 NULL / retest 任务
                                   ▼
atmos.sh ───────────────► script/scenarios/<scene>.sh
                                   │
                 ┌─────────────────┼──────────────────┐
                 ▼                 ▼                  ▼
          script/common       IoTDB 制品/NAS       场景配置与数据集
          公共运行框架         repository/master    conf/DataSet
                 │                 │                  │
                 └─────────────────┼──────────────────┘
                                   ▼
                       本地或远端 IoTDB 测试环境
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
              IoT-Benchmark    SQL/API 工具    Prometheus
                    │              │              │
                    └──────────────┼──────────────┘
                                   ▼
                       MySQL 结果表 + NAS 运行归档
```

## 目录结构

```text
.
├── atmos.sh                 # 总调度入口，根据 test_type_file 启动场景
├── conf/                    # 各场景的 Benchmark、环境和许可证配置
├── docs/
│   ├── scenarios/           # 29 个场景的详细操作说明
│   └── common/              # 20 个公共脚本的调用说明
├── script/
│   ├── scenarios/           # 可执行测试场景入口
│   └── common/              # 运行时、任务、监控、远端等公共模块
└── tools/                   # 编译、任务发布、重测和辅助工具
```

### `script/scenarios`

场景入口负责定义测试机、场景名、协议、数据类型和 API 矩阵，再调用公共框架或执行专用流程。完整列表、测试矩阵、准备步骤和验收标准参见[场景脚本说明索引](docs/scenarios/README.md)。

### `script/common`

公共脚本提供以下能力：

- `runtime_common.sh`：聚合基础运行时、安全路径和常用模块。
- `insert_common.sh`：标准写入类场景完整生命周期。
- `query_common.sh`：标准查询类场景完整生命周期。
- `result_common.sh`：MySQL 访问、任务领取与状态收尾。
- `benchmark_common.sh`：Benchmark 同步、启动、等待和 CSV 解析。
- `iotdb_*`：安装包准备、配置、CLI、服务启停和就绪检查。
- `monitor_common.sh`：Prometheus、CPU、磁盘、文件与线程指标。
- `remote_common.sh`：Linux/Windows 远端部署、清理、重启和等待。

函数、必需变量、扩展 hook 和副作用参见[公共脚本说明索引](docs/common/README.md)。

### `conf`

按场景名组织测试配置，主要包含：

- IoT-Benchmark `config.properties` 模板；
- 不同序列类型、协议、API 或查询用例的配置；
- IoTDB 环境覆盖文件；
- 商业版测试所需的 license；
- SQL、元数据或专项测试输入。

配置文件可能包含环境专用信息。不要把数据库密码或其他新密钥写入仓库；运行密码应通过环境变量提供。

### `tools`

包含编译、任务发布、重测和邮件等辅助脚本。部分工具是历史脚本，使用了与新公共框架不同的变量名、数据库地址或 shell 风格。执行前应先阅读源码并在目标测试环境验证，不要假设其行为与 `script/common` 完全一致。

## 任务生命周期

大多数场景使用以下状态：

| 状态 | 含义 |
| --- | --- |
| `NULL` | 尚未执行，普通待测任务 |
| `retest` | 指定重测，领取优先级高于普通任务 |
| `ontesting` | 已领取，正在执行 |
| `done` | 场景流程完成 |
| `RError` | 启动、执行或结果处理失败 |
| `skip` | 已有更新提交完成，较旧任务被跳过 |
| `NoNeed` | 该提交无需执行该场景 |

标准流程如下：

1. 编译或任务发布工具将提交号、作者、提交时间及场景状态写入任务表。
2. 场景优先领取最新 `retest`，否则领取最新 `NULL` 任务。
3. 场景将状态改为 `ontesting`，选择普通结果表或 `_T` 结果表。
4. 脚本按测试矩阵部署、执行、采集、入库和归档。
5. 所有 case 成功后状态改为 `done`；失败通常改为 `RError`。
6. 普通提交成功后，部分场景会将更早的未测提交改为 `skip`。

`native_api_test.sh`、`tsfile_api_test.sh` 和 `python_api.sh` 等少数场景直接监控 Git 仓库版本，不完全使用上述任务表生命周期，具体以对应文档为准。

## 运行环境

### 基础要求

- Linux 控制端和 Bash；Windows 场景还需要 Windows OpenSSH/PowerShell 任务。
- Java/JDK、`jps`、Node.js/npm 和待测 IoTDB 所需运行环境。
- MySQL 客户端以及访问 `QA_ATM` 的权限。
- IoT-Benchmark 和场景要求的 Java、C/C++、Python 或 SQL 工具链。
- `awk`、`bc`、`curl`、`findmnt`、`jq`、`lsof`、`lsblk`、`scp`、`ssh`、`sudo` 等命令。
- 可访问的 IoTDB 制品仓库、数据集、归档盘和 Prometheus。
- 本地及远端测试账号具备非交互 SSH 和脚本所需的 sudo 权限。

### 数据库密码

数据库密码统一通过环境变量提供：

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
```

不要把密码写入脚本、配置文件、README、命令历史或提交记录。使用 cron、systemd 或 `nohup` 时，应确认变量存在于实际运行进程的环境中。

### 默认基础设施

新公共框架默认使用：

| 服务 | 默认值 |
| --- | --- |
| MySQL | `111.200.37.158:13306` |
| 数据库 | `QA_ATM` |
| 用户 | `iotdbatm` |
| 任务表 | `ex_commit_history` |
| Prometheus | `111.200.37.158:19090` |
| IoTDB 制品根目录 | `/nasdata/repository/master` |
| IoT-Benchmark 制品 | `/nasdata/repository/iot-benchmark` |
| 常用工作根目录 | `/data/atmos/zk_test` |
| 常用测试实例 | `/data/atmos/apache-iotdb` |

部分历史或专项脚本使用不同主机、根目录或环境变量覆盖值，必须以场景文档和脚本当前实现为准。

## 快速开始

### 1. 选择场景

先从[场景索引](docs/scenarios/README.md)找到目标场景，核对：

- 专用测试机和远端节点；
- 测试协议、数据类型和 case 数量；
- 配置、数据集和制品路径；
- 进程清理、目录删除、数据移动和归档覆盖行为；
- 预期结果表、行数和验收条件。

### 2. 检查环境

以下命令仅用于示意；路径和 IP 应替换为场景文档中的实际值：

```bash
hostname -I
df -h /data /nasdata
jps
command -v bash mysql jq jps lsof ssh sudo
test -d /nasdata/repository/master/<commit_id>/apache-iotdb
```

验证数据库：

```bash
MYSQL_PWD="$ATMOS_DB_PASSWORD" mysql -N -B \
  -h111.200.37.158 -P13306 -uiotdbatm QA_ATM \
  -e "select 1;"
```

### 3. 前台运行单个场景

首次验证建议前台执行，以便立即发现依赖、权限和路径问题：

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/compaction.sh \
  2>&1 | tee /data/atmos/zk_test/log_compaction
```

不要使用 `sh script/scenarios/<scene>.sh`。场景脚本使用 Bash 数组、子 Shell和其他 Bash 特性。

### 4. 后台运行

环境验证通过后可以后台执行：

```bash
nohup bash script/scenarios/<scene>.sh \
  >> /data/atmos/zk_test/log_<scene> 2>&1 &
```

### 5. 使用总调度器

```bash
printf '<scene>\n' > /data/atmos/zk_test/test_type_file
cd /data/atmos/zk_test/atmos-ex
bash atmos.sh
```

`atmos.sh` 会读取 `test_type_file`，同步仓库并后台启动对应场景。当前实现包含 `git reset --hard origin/main`，会丢弃部署目录中的本地修改；只能在部署副本中使用。

## 运行观察与验收

### 场景日志

```bash
tail -f /data/atmos/zk_test/log_<scene>
```

### 本地进程和 Benchmark

```bash
jps
find /data/atmos/zk_test/iot-benchmark/data/csvOutput \
  -type f 2>/dev/null
```

集群、Pipe 和 Windows 场景还应同步检查所有远端节点的进程、端口、IoTDB 错误日志和数据同步状态。

### 验收原则

任务状态为 `done` 只表示脚本完成了成功收尾，不能替代结果验收。至少应核对：

1. 结果表包含完整测试矩阵，没有缺行或重复行。
2. 吞吐、延迟和耗时不是超时或错误哨兵值。
3. `failPoint`、错误数和功能断言符合预期。
4. ConfigNode/DataNode 错误日志为空或已完成解释。
5. TsFile、WAL、数据量和双端同步数据符合场景预期。
6. 配置、CSV、日志及运行现场已归档。

常见结果哨兵值包括：

| 值 | 常见含义 |
| --- | --- |
| `-1` | 超时占位或未提取到有效结果 |
| `-2` | Benchmark CSV 缺失或解析失败 |
| `-3` | IoTDB 启动失败 |
| `-4` | root 密码修改失败 |

具体含义可能被场景覆盖，应以对应说明为准。

## 安全边界

运行前务必确认以下事项：

- `check_iotdb_pid` 会按 Java 主类名终止本机所有匹配进程，不区分安装目录。
- 多数场景会删除并重建 `/data/atmos/apache-iotdb` 或场景专用测试目录。
- 查询框架可能使用 `mv` 将数据集移动进 IoTDB；异常中断时数据可能停留在测试目录。
- 归档目录同名时通常先递归删除，再写入新结果。
- 集群和 Pipe 场景会通过 SSH 清理多台 Linux 主机的数据与安装目录。
- Windows 场景会调用远端计划任务和递归目录删除。
- API 场景可能同步 Git 仓库、编译源码、安装/卸载 Python 包或推送报告仓库。
- `git_sync_branch` 和 `atmos.sh` 包含硬重置，不适合保存开发中修改的工作目录。

安全路径检查只能防止部分意外路径展开，不能替代对测试机、账号、挂载和目录归属的人工确认。

## 开发与扩展

### 新增场景

建议流程：

1. 在 `script/scenarios` 新增 Bash 入口，使用 `#!/usr/bin/env bash`。
2. 在 `conf/<scene>` 添加场景配置和必要的许可证/环境文件。
3. 优先复用 `insert_common.sh`、`query_common.sh` 或底层公共模块。
4. 在 `source` 前定义公共框架要求的变量和矩阵。
5. 使用 hook 或明确的函数覆盖实现差异，不复制整套通用生命周期。
6. 对删除、移动、远端执行和归档路径使用现有安全函数。
7. 在 `docs/scenarios` 添加对应操作说明，并更新索引。
8. 若加入任务表调度，更新任务发布、编译和管理工具中的场景字段。

### 修改公共脚本

公共函数通过全局变量协作，修改前应确认所有调用场景。重点关注：

- 函数返回码是否被用于任务成败判断；
- 子 Shell 隔离是否导致变量不能返回父级；
- hook 调用顺序和同名函数覆盖；
- 任务表字段、结果表结构和负值约定；
- 路径白名单及本地/远端破坏性操作；
- Benchmark CSV 格式和 Prometheus 指标名兼容性。

详见[公共脚本说明](docs/common/README.md)。

### Shell 静态检查

```bash
bash script/common/check_shell_style.sh
```

该检查覆盖 Bash shebang、CRLF、`bash -n`、危险 `rm` 写法、直接 SIGKILL、用 `sh` 调用仓库脚本以及历史变量名。

## 文档

- [场景脚本说明索引](docs/scenarios/README.md)
- [场景通用操作说明](docs/scenarios/common-operations.md)
- [公共脚本说明索引](docs/common/README.md)
- [Compaction 场景完整示例](docs/scenarios/compaction.md)

文档描述的是当前脚本实现。固定 IP、路径、测试矩阵或数据库结构发生变化时，应同步更新对应文档，避免操作说明与生产测试环境漂移。

## 维护说明

本仓库主要服务于内部自动化测试基础设施。提交变更时建议同时提供：

- 受影响的场景和测试矩阵；
- 配置、结果表或归档结构变化；
- 本地和远端副作用变化；
- 验证方式及对应日志/结果；
- 文档更新。

不要在 issue、日志、截图或提交中暴露数据库密码、许可证内容、访问令牌或其他凭据。
