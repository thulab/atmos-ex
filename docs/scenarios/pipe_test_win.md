# Pipe Test Win 场景操作说明

## 1. 场景概览

`pipe_test_win.sh` 在默认 `/root/zk_test` 控制环境中编排 Windows 节点 `11.101.17.126` 和 `.127`，两端互为 Pipe 源/目标；测试协议 `223/224`、`common/aligned`，结果写入 `ex_pipe_test_win(_T)`。

## 2. 运行前准备

验证 Windows 两端的 Administrator 远程执行、SSH/SCP、PowerShell 任务、Java、路径权限和防火墙；检查 `conf/pipe_test_win` 中两台主机的 env/license/类型配置。确认控制机 `.120`、两端时钟及 Prometheus target 正常，并完成[通用准备](common-operations.md#3-运行前步骤)。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /root/zk_test/atmos-ex
bash script/scenarios/pipe_test_win.sh 2>&1 | tee /root/zk_test/log_pipe_test_win
```

## 4. 自动流程与验收

脚本在两台 Windows 主机部署 IoTDB、配置并创建 Pipe，运行写入、等待同步、采集双端结果后归档到 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。验收覆盖 4 个协议/类型组合，检查 A/B 点数、Pipe 状态、双端错误日志和远端日志复制；Linux 控制端正常不代表 Windows 端成功。
