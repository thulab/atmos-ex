# iotdb_common.sh 使用说明

## 1. 职责

组合安装包与服务模块，为标准单机 Benchmark 场景提供基础 IoTDB 配置、协议设置和密码修改。

## 2. 调用契约

文件加载时默认设置 `COPY_IOTDB_ENV=1`。调用方需定义 `TEST_TYPE/TEST_IOTDB_PATH/IOTDB_PASSWORD`、大写 `PROTOCOL_CLASS` 数组，并已通过 runtime 获得配置与 CLI 函数。

## 3. 主要函数

- `modify_iotdb_config`：默认 DN 堆内存 `20G`，应用 `base` profile；之后调用可选 `append_iotdb_case_properties FILE` hook。
- `set_protocol_class CODE`：按大写 `PROTOCOL_CLASS` 解析三位编码，并向 properties 追加三项协议。
- `change_root_password`：检测目标密码或从 root/root 修改。

同时可直接使用被加载的 `set_env/start_iotdb/...`。

## 4. 调用示例

```bash
readonly -a PROTOCOL_CLASS=("" SimpleConsensus RatisConsensus IoTConsensus)
append_iotdb_case_properties() { printf 'series_slot_num=10000\n' >> "$1"; }
set_env
modify_iotdb_config
set_protocol_class 223
start_iotdb_and_wait
```

## 5. 注意事项

协议函数用追加方式写属性，重复调用会产生重复键；每个 case 应基于新安装包。`modify_iotdb_config` 默认关闭三类合并并启用指标，专项场景须在 hook 或之后显式覆盖。
