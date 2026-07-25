# SE Query Test 场景操作说明

## 1. 场景概览

`se_query_test.sh` 是精简顺序查询矩阵：测试机 `11.101.17.141`，协议 `211`，仅 `tablemode` 和 `tempaligned`，每种执行 25 个查询，共 50 个 case。运行时还会创建 `qa_user` 并授权树模型和表模型权限。

## 2. 运行前准备

完成[通用运行前步骤](common-operations.md#3-运行前步骤)，检查 `conf/se_query_test/{tablemode,tempaligned}/<Q*>`、许可证和 `/data/atmos/DataSet/211/{tablemode,tempaligned}/data`。确认安全策略允许创建测试用户 `qa_user`。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/se_query_test.sh 2>&1 | tee /data/atmos/zk_test/log_se_query_test
```

## 4. 自动流程

脚本按两种类型移动预置数据并逐查询启动 IoTDB；每轮尝试创建 `qa_user`，授予 `root.**` 和 table dialect 权限，然后运行 Benchmark、入库和保存日志。数据最终恢复到数据集仓库，运行目录归档到 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。

## 5. 验收与排查

预期 50 行。除性能字段外，检查 QA 用户相关用例是否真正以目标账号执行；创建用户命令允许已存在错误，因此重复执行不会单独判失败。数据移动和哨兵值处理与其他查询场景相同。
