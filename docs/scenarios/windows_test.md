# Windows Test 场景操作说明

## 1. 场景概览

`windows_test.sh` 由 Linux 控制端 `11.101.17.111` 操作 Windows 测试机 `11.101.17.128`，远端账号 `Administrator`，Windows 工作目录 `D:\first-rest-test`。协议 `223`，执行四种写入模式；对 `seq_w/unseq_w` 再执行 Q1 至 Q10 查询。结果写入 `ex_windows_test(_T)`。

## 2. 运行前准备

1. 完成[通用准备](common-operations.md#3-运行前步骤)，验证到 `.128` 的远程任务执行和 SCP。
2. 确认 Windows 上名为 `run_iotdb` 的任务、PowerShell/SSH 服务、Java、端口、防火墙和 `D:\first-rest-test` 权限。
3. 检查 `conf/windows_test` 的 env、license、写入与全部查询配置。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/windows_test.sh 2>&1 | tee /data/atmos/zk_test/log_windows_test
```

## 4. 自动流程与验收

脚本准备 Windows 安装包、通过远端任务启动 IoTDB，在 Linux 控制端运行 Benchmark；四种写入均入库，顺序和乱序纯写模式继续跑查询，并把本地 Benchmark 与远端 IoTDB 日志归档到 `/nasdata/repository/windows_test`。验收除性能字段外，必须检查远端任务返回、Windows 路径、日志 SCP 和查询子项；Linux 上 `jps` 正常不能证明 Windows IoTDB 正常。
