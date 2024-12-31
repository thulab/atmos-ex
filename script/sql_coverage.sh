#!/bin/bash
#登录用户名
ACCOUNT=atmos
test_type=sql_coverage
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
TOOL_PATH=${INIT_PATH}/iotdb-sql
BM_PATH=${INIT_PATH}/iot-benchmark
TC_PATH=${INIT_PATH}/iotdb-sql-testcase
BUCKUP_PATH=/nasdata/repository/sql_coverage/master
REPOS_PATH=/nasdata/repository/master
#测试数据运行路径
TEST_INIT_PATH=/data/atmos
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
TEST_TOOL_PATH=${TEST_INIT_PATH}/iotdb-sql
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(111 223 222 211)
ts_list=(common aligned template tempaligned)
############mysql信息##########################
MYSQLHOSTNAME="111.200.37.158" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD=${ATMOS_DB_PASSWORD}
DBNAME="QA_ATM"                   #数据库名称
TABLENAME="ex_sql_coverage" #数据库中表的名称
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############公用函数##########################
if [ "${PASSWORD}" = "" ]; then
echo "需要关注密码设置！"
fi
#echo "Started at: " date -d today +"%Y-%m-%d %H:%M:%S"
echo "检查iot-benchmark版本"
BM_REPOS_PATH=/nasdata/repository/iot-benchmark
BM_NEW=$(cat ${BM_REPOS_PATH}/git.properties | grep git.commit.id.abbrev | awk -F= '{print $2}')
BM_OLD=$(cat ${BM_PATH}/git.properties | grep git.commit.id.abbrev | awk -F= '{print $2}')
if [ "${BM_OLD}" != "cat: git.properties: No such file or directory" ] && [ "${BM_OLD}" != "${BM_NEW}" ]; then
	rm -rf ${BM_PATH}
	cp -rf ${BM_REPOS_PATH} ${BM_PATH}
fi
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
pass_num=0
fail_num=0
start_time=0
end_time=0
cost_time=0
flag=0
}
local_ip=`ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d "addr:"`
sendEmail() {
sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}
check_benchmark_pid() { # 检查benchmark的pid，有就停止
	monitor_pid=$(jps | grep InterFace | awk '{print $1}')
	if [ "${monitor_pid}" = "" ]; then
		echo "未检测到InterFace程序！"
	else
		kill -9 ${monitor_pid}
		echo "InterFace程序已停止！"
	fi
}
check_iotdb_pid() { # 检查iotdb的pid，有就停止
	iotdb_pid=$(jps | grep DataNode | awk '{print $1}')
	if [ "${iotdb_pid}" = "" ]; then
		echo "未检测到DataNode程序！"
	else
		kill -9 ${iotdb_pid}
		echo "DataNode程序已停止！"
	fi
	iotdb_pid=$(jps | grep ConfigNode | awk '{print $1}')
	if [ "${iotdb_pid}" = "" ]; then
		echo "未检测到ConfigNode程序！"
	else
		kill -9 ${iotdb_pid}
		echo "ConfigNode程序已停止！"
	fi
	iotdb_pid=$(jps | grep IoTDB | awk '{print $1}')
	if [ "${iotdb_pid}" = "" ]; then
		echo "未检测到IoTDB程序！"
	else
		kill -9 ${iotdb_pid}
		echo "IoTDB程序已停止！"
	fi
	echo "程序检测和清理操作已完成！"
}
set_env() { 
	# 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_IOTDB_PATH}" ]; then
		mkdir -p ${TEST_IOTDB_PATH}
	else
		rm -rf ${TEST_IOTDB_PATH}
		mkdir -p ${TEST_IOTDB_PATH}
	fi
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_IOTDB_PATH}/
	mkdir -p ${TEST_IOTDB_PATH}/activation
	cp -rf ${ATMOS_PATH}/conf/${test_type}/license ${TEST_IOTDB_PATH}/activation/
	# 拷贝工具到测试路径
	if [ ! -d "${TEST_TOOL_PATH}" ]; then
		mkdir -p ${TEST_TOOL_PATH}
	else
		rm -rf ${TEST_TOOL_PATH}
		mkdir -p ${TEST_TOOL_PATH}
	fi
	cp -rf ${TOOL_PATH}/* ${TEST_TOOL_PATH}/
}
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" ${TEST_IOTDB_PATH}/conf/datanode-env.sh
	#清空配置文件
	# echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "dn_metric_internal_reporter_type=MEMORY" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	#关闭影响写入性能的其他功能
	echo "enable_seq_space_compaction=false" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "enable_unseq_space_compaction=false" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "enable_cross_space_compaction=false" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	#修改集群名称
	echo "cluster_name=${test_type}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	#添加启动监控功能
	echo "cn_enable_metric=true" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "cn_enable_performance_stat=true" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "cn_metric_reporter_list=PROMETHEUS" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "cn_metric_level=ALL" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "cn_metric_prometheus_reporter_port=9081" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	#添加启动监控功能
	echo "dn_enable_metric=true" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "dn_enable_performance_stat=true" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "dn_metric_reporter_list=PROMETHEUS" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "dn_metric_level=ALL" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "dn_metric_prometheus_reporter_port=9091" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	#UDF路径限制扩展
	echo "trusted_uri_pattern=.*" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
}
set_protocol_class() { 
	config_node=$1
	schema_region=$2
	data_region=$3
	#设置协议
	echo "config_node_consensus_protocol_class=${protocol_class[${config_node}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "schema_region_consensus_protocol_class=${protocol_class[${schema_region}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "data_region_consensus_protocol_class=${protocol_class[${data_region}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
}
start_iotdb() { # 启动iotdb
	cd ${TEST_IOTDB_PATH}
	conf_start=$(./sbin/start-confignode.sh >/dev/null 2>&1 &)
	sleep 10
	data_start=$(./sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof >/dev/null 2>&1 &)
	cd ~/
}
stop_iotdb() { # 停止iotdb
	cd ${TEST_IOTDB_PATH}
	data_stop=$(./sbin/stop-datanode.sh >/dev/null 2>&1 &)
	sleep 10
	conf_stop=$(./sbin/stop-confignode.sh >/dev/null 2>&1 &)
	cd ~/
}
backup_test_data() { # 备份测试数据
	sudo rm -rf ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo mkdir -p ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
    sudo rm -rf ${TEST_IOTDB_PATH}/data
	sudo mv ${TEST_IOTDB_PATH} ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo mv ${TEST_TOOL_PATH} ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
}
##准备开始测试
echo "ontesting" > ${INIT_PATH}/test_type_file
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${test_type} is NULL ORDER BY commit_date_time desc limit 1 "
result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
##查询是否有复测任务
if [ "${commit_id}" = "" ]; then
	query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${test_type} = 'retest' ORDER BY commit_date_time desc limit 1 "
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}")
	commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
fi
if [ "${commit_id}" = "" ]; then
	sleep 60s
else
	init_items
	# 获取git commit对比判定是否启动测试
	cd ${TC_PATH}
	last_cid1=$(git log --pretty=format:"%h" -1)
	#更新TC
	git_pull=$(timeout 100s git pull)
	# 获取更新后git commit对比判定是否启动测试
	commit_id1=$(git log --pretty=format:"%h" -1)
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'ontesting' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
	echo "当前版本${commit_id}未执行过测试，即将编译后启动"
	test_date_time=$(date +%Y%m%d%H%M%S)
	#开始测试
	#清理环境，确保无旧程序影响
	check_iotdb_pid
	#复制当前程序到执行位置
	set_env
	#IoTDB 调整内存，关闭合并
	modify_iotdb_config
	set_protocol_class 2 2 3
	#启动iotdb和monitor监控
	start_iotdb
	sleep 60
	####判断IoTDB是否正常启动
	for (( t_wait = 0; t_wait <= 20; t_wait++ ))
	do
	  iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "show cluster" | grep 'Total line number = 2')
	  if [ "${iotdb_state}" = "Total line number = 2" ]; then
		break
	  else
		sleep 30
		continue
	  fi
	done
	if [ "${iotdb_state}" = "Total line number = 2" ]; then
		echo "IoTDB正常启动，准备开始测试"
		F_start_time=$(date +%s%3N)
		F_str1=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "insert into root.ln.wf02.wt02(timestamp, status, hardware) VALUES (3, false, 'v3'),(4, true, 'v4')")
		F_now_time=$(date +%s%3N)
		F_t_time=$[${F_now_time}-${F_start_time}]
		cost_time=${F_t_time}
		pass_num=0
		fail_num=0
		F_str1=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "drop database root.**")
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${F_start_time}','${F_now_time}',${cost_time},'FirstInsertSQL')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
	else
		echo "IoTDB未能正常启动，写入负值测试结果！"
		cost_time=-3
		fail_num=-3
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'master')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
		update_sql="update ${TASK_TABLENAME} set ${test_type} = 'RError' where commit_id = '${commit_id}'"
		result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
		continue
	fi
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
	update_sql02="update ${TASK_TABLENAME} set ${test_type} = 'skip' where ${test_type} is NULL and commit_date_time < '${commit_date_time}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql02}")
fi
echo "${test_type}" > ${INIT_PATH}/test_type_file