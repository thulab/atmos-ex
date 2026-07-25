# Pipe Test 场景操作说明

## 1. 场景概览

`pipe_test.sh` 从控制机 `11.101.17.120` 编排 Linux 节点 `11.101.17.144` 与 `.146`，两端互为 Pipe 源/目标；测试协议 `223/224` 和 `common/aligned`，结果写入 `ex_pipe_test(_T)`。

> 脚本会经 SSH 清理并部署两端 IoTDB/Benchmark、创建和删除 Pipe、停止远端进程。必须确认 IP 与专用机器一致。

## 2. 运行前准备

完成[通用准备](common-operations.md#3-运行前步骤)，验证到 `.144/.146` 的免密 SSH、sudo 和双向端口；检查 `conf/pipe_test` 中两台主机的 env、license、common/aligned 配置，确认源端和目标端时间同步、磁盘与 Prometheus target 正常。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/pipe_test.sh 2>&1 | tee /data/atmos/zk_test/log_pipe_test
```

## 4. 自动流程

脚本领取任务并同步 Benchmark，向两端部署对应提交，按协议和序列类型启动实例、创建 Pipe，运行源端写入并等待目标端同步；分别采集 A/B 两端吞吐、延迟、文件、WAL、CPU、磁盘和错误日志，比较最小点数后入库，归档两端日志和 CSV到 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。

## 5. 验收与排查

预期覆盖 2 协议 × 2 类型，并核对 A/B 两端字段。目标端点数、Pipe 状态、延迟和错误日志是核心验收项；仅源端 Benchmark 成功不能判定 Pipe 成功。网络中断、receiver 端口、证书/账号和数据差异需保留双端日志排查。
