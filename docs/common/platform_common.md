# platform_common.sh 使用说明

## 1. 职责

按 `TEST_PLATFORM` 将环境准备分派给 Linux 或 Windows 实现。

## 2. 公开函数

`setup_platform_env ARGS...`：`TEST_PLATFORM` 默认为 `linux`；调用 `setup_env_linux` 或 `setup_env_windows`，其他值通过 `die` 终止。

## 3. 调用示例

```bash
TEST_PLATFORM=windows
setup_env_windows() { deploy_windows "$@"; }
setup_platform_env "${host}"
```

## 4. 依赖与扩展

本文件只负责分派，不定义两个平台实现；调用方必须事先定义相应函数，并加载 `die`。适合 Windows/Linux 共享场景入口。

## 5. 排查

出现 `command not found` 时检查实现函数是否在调用前定义或 source；出现 unsupported 时检查大小写，合法值仅 `linux/windows`。
