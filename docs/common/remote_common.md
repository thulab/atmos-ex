# remote_common.sh 使用说明

## 1. 职责

统一 Linux 与 Windows 测试节点的 SSH/SCP、目录清理、部署、重启、进程/集群等待、远端 Benchmark 和计划任务操作。

## 2. 调用契约

设置 `ACCOUNT` 或 `REMOTE_ACCOUNT`，并定义可信的 `INIT_PATH/TEST_INIT_PATH/BACKUP_PATH/TEST_PATH/BM_PATH`。额外安全根用冒号分隔的 `REMOTE_EXTRA_SAFE_ROOTS`；批量清理根使用 `REMOTE_CLEAR_ROOTS`。依赖 `ssh/scp`，Windows 目录部署另需本地 `tar/mktemp` 和远端 tar。

## 3. 主要函数

- `remote_exec/remote_copy/remote_copy_contents`：执行和复制。
- `remote_path_is_safe/remote_safe_rm/remote_reset_dir/remote_clear_*`：白名单清理。
- `remote_reboot_and_wait/wait_for_remote`：Linux 重启等待。
- `wait_for_remote_java_process/wait_for_remote_iotdb_cluster`：进程和集群就绪。
- `remote_deploy_benchmark/remote_start_benchmark`：远端 Benchmark。
- `remote_windows_reboot/wait_for_remote_windows/remote_windows_reset_dir/remote_windows_copy_contents/remote_windows_run_task`：Windows 操作。

## 4. 调用示例

```bash
REMOTE_ACCOUNT=root
remote_reset_dir "${host}" "${TEST_INIT_PATH}/apache-iotdb"
remote_copy_contents "${local_iotdb}" "${host}" "${TEST_INIT_PATH}/apache-iotdb"
wait_for_remote_iotdb_cluster "${host}" "${cli}" 6
```

## 5. 副作用与安全

清理、重启和 Windows `rmdir /s /q` 都是破坏性操作。Linux 删除有路径白名单；Windows reset 当前没有同等级本地白名单校验，调用前必须人工验证 host/path。`remote_start_background` 接受完整命令字符串，调用方负责安全引用。

## 6. 排查

失败时先独立验证 `ssh user@host true` 和 SCP，再检查 sudo、远端 shell 类型、Windows OpenSSH、计划任务名、tar 可用性与防火墙。集群等待通过固定总行数判断，expected_nodes 必须与部署拓扑一致。
