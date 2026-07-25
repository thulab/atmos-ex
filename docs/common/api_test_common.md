# api_test_common.sh 使用说明

## 1. 职责

为 Native API、TsFile API 等多语言测试提供统一的步骤隔离、失败等待和套件聚合。

## 2. 调用契约

公共运行时提供 `init_items`、`log` 和 `run_isolated_case`；调用方提供实际测试函数，并通过可选 `init_scenario_state` 初始化专属字段。可用 `API_FAILURE_WAIT_SECONDS` 修改单语言失败后的等待时间，默认 60 秒。

## 3. 主要函数

- `run_api_test_step LABEL FUNCTION`：在子 Shell 中初始化状态并运行一个测试函数。
- `run_api_test_suite LABEL:FUNCTION...`：依次执行所有步骤；某步失败不阻止后续步骤，最终返回是否有失败。

## 4. 调用示例

```bash
run_api_test_suite \
  "Java:test_java_api" \
  "Cpp:test_cpp_api" \
  "Python:test_python_api"
```

## 5. 副作用与排查

步骤在子 Shell 中运行，因此其变量和目录改变不会返回父 Shell；测试结果必须自行入库或写文件。条目以第一个冒号拆分，label/function 不应含冒号。函数不存在或返回非 0 时该步骤失败并等待。
