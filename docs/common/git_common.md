# git_common.sh 使用说明

## 1. 职责

读取构建产物和 Git 仓库版本，并在超时保护下同步远端分支。

## 2. 主要函数

- `git_properties_commit FILE`：读取 `git.commit.id.abbrev`。
- `git_current_commit REPO`：返回当前短提交号。
- `git_current_commit_time REPO`：将 HEAD 时间转为 `YYYYmmddHHMMSS`。
- `git_sync_branch REPO [BRANCH] [TIMEOUT]`：fetch、`reset --hard origin/branch`、`pull --ff-only`。
- `git_pull_repository REPO [TIMEOUT]`：仅 `pull --ff-only`。

## 3. 调用示例

```bash
old="$(git_current_commit "${IOTDB_PATH}")"
git_sync_branch "${IOTDB_PATH}" master 100
new="$(git_current_commit "${IOTDB_PATH}")"
```

## 4. 副作用与风险

`git_sync_branch` 会执行硬重置，丢弃目标仓库的未提交修改和偏离远端的本地提交。仅能对明确作为部署缓存的仓库使用；网络和凭据必须支持非交互访问。

## 5. 排查

同步失败检查 `.git`、目标远端分支、代理、凭据和 timeout 命令。`git.properties` 不存在或键缺失时返回空字符串，不会自动报错。
