# check_shell_style.sh 使用说明

## 1. 职责

这是 `script/common` 中唯一设计为独立执行的脚本，用于扫描整个 `script` 目录的 Bash 语法、换行符、shebang 和仓库约定。

## 2. 检查规则

1. 所有 `.sh` 第一行必须是 `#!/usr/bin/env bash`。
2. 禁止 CRLF，且每个文件必须通过 `bash -n`。
3. 禁止 `function name` 写法。
4. 禁止用 `sh` 调用仓库脚本。
5. 递归 `rm -rf` 路径必须引用并使用 `--`。
6. 禁止直接 `kill -9`。
7. 禁止历史遗留变量名。

## 3. 启动步骤

```bash
cd /data/atmos/zk_test/atmos-ex
bash script/common/check_shell_style.sh
```

退出码 0 表示通过，1 表示至少一项违规。

## 4. 扩展方式

用 `report_matches DESCRIPTION REGEX` 增加文本规则；需要语义判断时在文件遍历循环中添加检查，并设置 `status=1`。

## 5. 排查

规则基于 grep，可能匹配注释或字符串；修复前查看输出行上下文。Windows 编辑器应保存 LF。语法失败可单独执行 `bash -n <file>`。
