# protocol_common.sh 使用说明

## 1. 职责

将三位协议编码映射为 ConfigNode、SchemaRegion、DataRegion 三个共识实现，并写入 IoTDB properties。

## 2. 调用约定

调用方必须定义 `protocol_class` 数组并加载 `set_iotdb_property`。编码每位都是数组下标，例如 `211` 表示 `protocol_class[2]`、`[1]`、`[1]`。

## 3. 调用示例

```bash
protocol_class=("" SimpleConsensus RatisConsensus IoTConsensus)
set_protocol_class 211 || die "invalid protocol"
```

## 4. 自动流程

函数验证编码长度为 3、三个下标均有非空映射，然后更新 `config_node_consensus_protocol_class`、`schema_region_consensus_protocol_class` 和 `data_region_consensus_protocol_class`。

## 5. 排查

返回 1 通常表示长度错误、数组名/下标错误或 0 对应空值。注意该模块使用小写 `protocol_class`；`iotdb_common.sh` 的同名函数使用大写 `PROTOCOL_CLASS`，不要混用。
