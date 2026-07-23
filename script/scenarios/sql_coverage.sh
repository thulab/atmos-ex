#!/usr/bin/env bash
set -o pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/runtime_common.sh"

#登录用户名
ACCOUNT=atmos
IOTDB_PASSWORD="${IOTDB_PASSWORD:-TimechoDB@2021}"
TEST_TYPE="${TEST_TYPE:-sql_coverage}"
#初始环境存放路径
INIT_PATH="${INIT_PATH:-/data/atmos/zk_test}"
ATMOS_PATH=${INIT_PATH}/atmos-ex
TOOL_PATH=${INIT_PATH}/iotdb-sql
BM_PATH=${INIT_PATH}/iot-benchmark
BACKUP_PATH="${BACKUP_PATH:-/nasdata/repository/sql_coverage/master}"
REPOS_PATH="${REPOS_PATH:-/nasdata/repository/master}"
TC_PATH=${INIT_PATH}/iotdb-sql-testcase
#测试数据运行路径
TEST_INIT_PATH="${TEST_INIT_PATH:-/data/atmos}"
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
TEST_AINode_PATH=${TEST_INIT_PATH}/apache-iotdb-ainode
TEST_TOOL_PATH=${TEST_INIT_PATH}/iotdb-sql
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(111 223 222 211)
ts_list=(common aligned template tempaligned)
############mysql信息##########################
MYSQL_HOST="${MYSQL_HOST:-111.200.37.158}"
MYSQL_PORT="${MYSQL_PORT:-13306}"
MYSQL_USERNAME="${MYSQL_USERNAME:-iotdbatm}"
MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
DBNAME="${DBNAME:-QA_ATM}"
TABLENAME="ex_sql_coverage" #数据库中表的名称
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############公用函数##########################
if [ -z "${MYSQL_PASSWORD}" ]; then
    printf '[ERROR] ATMOS_DB_PASSWORD is required\n' >&2
    exit 1
fi
for required_command in awk date mysql sed; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        printf '[ERROR] required command not found: %s\n' "${required_command}" >&2
        exit 1
    fi
done
unset required_command
#echo "Started at: " date -d today +"%Y-%m-%d %H:%M:%S"
log "检查iot-benchmark版本"
BM_REPOS_PATH="${BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}"
BM_NEW=$(cat ${BM_REPOS_PATH}/git.properties | grep git.commit.id.abbrev | awk -F= '{print $2}')
BM_OLD=$(cat ${BM_PATH}/git.properties | grep git.commit.id.abbrev | awk -F= '{print $2}')
if [ "${BM_OLD}" != "cat: git.properties: No such file or directory" ] && [ "${BM_OLD}" != "${BM_NEW}" ]; then
	rm -rf -- "${BM_PATH}"
	cp -rf ${BM_REPOS_PATH} ${BM_PATH}
fi
# 功能：重置当前测试用例使用的指标和运行状态
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
# 功能：保留或执行测试异常通知逻辑
sendEmail() {
sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}
# 功能：检查当前场景的前置条件、进程状态或结果有效性
check_sql_test_pid() { # 检查benchmark的pid，有就停止
	monitor_pid=$(jps | grep InterFace | awk '{print $1}')
	if [ "${monitor_pid}" = "" ]; then
		log "未检测到InterFace程序！"
	else
		kill -TERM "${monitor_pid}" 2>/dev/null || true
		sleep 2
		kill -KILL "${monitor_pid}" 2>/dev/null || true
		log "InterFace程序已停止！"
	fi
}
# 功能：准备当前测试所需的本地安装目录与运行环境
set_env() { 
	# 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_IOTDB_PATH}" ]; then
		mkdir -p ${TEST_IOTDB_PATH}
	else
		rm -rf -- "${TEST_IOTDB_PATH}"
		mkdir -p ${TEST_IOTDB_PATH}
	fi
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_IOTDB_PATH}/
	mkdir -p ${TEST_IOTDB_PATH}/activation
	cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/license ${TEST_IOTDB_PATH}/activation/
	if [ ! -d "${TEST_AINode_PATH}" ]; then
		mkdir -p ${TEST_AINode_PATH}
	else
		rm -rf -- "${TEST_AINode_PATH}"
		mkdir -p ${TEST_AINode_PATH}
	fi
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb-ainode/* ${TEST_AINode_PATH}/
	#cp -rf /data/atmos/zk_test/AINode/venv ${TEST_AINode_PATH}/
	cp -rf  ${INIT_PATH}/data ${TEST_AINode_PATH}/
	mv /data/atmos/zk_test/AINode/venv ${TEST_AINode_PATH}/
	mkdir -p ${TEST_AINode_PATH}/data/ainode/models/weights/timerxl
	cp -rf /data/atmos/zk_test/AINode/timerxl/model.safetensors ${TEST_AINode_PATH}/data/ainode/models/weights/timerxl/
	# 拷贝工具到测试路径
	if [ ! -d "${TEST_TOOL_PATH}" ]; then
		mkdir -p ${TEST_TOOL_PATH}
	else
		rm -rf -- "${TEST_TOOL_PATH}"
		mkdir -p ${TEST_TOOL_PATH}
	fi
	cp -rf ${TOOL_PATH}/* ${TEST_TOOL_PATH}/
}
# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" ${TEST_IOTDB_PATH}/conf/datanode-env.sh
	#清空配置文件
	# echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_metric_internal_reporter_type" "MEMORY"
	#关闭影响写入性能的其他功能
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "enable_seq_space_compaction" "false"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "enable_unseq_space_compaction" "false"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "enable_cross_space_compaction" "false"
	#修改集群名称
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cluster_name" "${TEST_TYPE}"
	#添加启动监控功能
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_enable_metric" "true"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_enable_performance_stat" "true"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_metric_reporter_list" "PROMETHEUS"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_metric_level" "ALL"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_metric_prometheus_reporter_port" "9081"
	#添加启动监控功能
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_enable_metric" "true"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_enable_performance_stat" "true"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_metric_reporter_list" "PROMETHEUS"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_metric_level" "ALL"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_metric_prometheus_reporter_port" "9091"
	#UDF路径限制扩展
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "trusted_uri_pattern" ".*"
	#修改AINode名称
	echo "# 修改AINode名称" >> ${TEST_AINode_PATH}/conf/iotdb-ainode.properties
	echo "cluster_name=${TEST_TYPE}" >> ${TEST_AINode_PATH}/conf/iotdb-ainode.properties
}
# 功能：根据协议编号设置各共识组使用的协议实现
set_protocol_class() { 
	config_node=$1
	schema_region=$2
	data_region=$3
	#设置协议
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "config_node_consensus_protocol_class" "${protocol_class[${config_node}]}"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "schema_region_consensus_protocol_class" "${protocol_class[${schema_region}]}"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "data_region_consensus_protocol_class" "${protocol_class[${data_region}]}"
}
# 功能：启动当前场景中的 IoTDB 服务
start_iotdb() { # 启动iotdb
	cd "${TEST_IOTDB_PATH}" || return 1
	conf_start=$(./sbin/start-confignode.sh >/dev/null 2>&1 &)
	sleep 10
	data_start=$(./sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof >/dev/null 2>&1 &)
	cd ~/
}
# 功能：启动指定服务、工具或测试步骤
start_iotdb_ainode() { # 启动iotdb
	cd "${TEST_AINode_PATH}" || return 1
	ai_start=$(./sbin/start-ainode.sh -r >/dev/null 2>&1 &)
	for (( t_wait = 0; t_wait <= 20; t_wait++ ))
	do
		ai_status=$(lsof -i:10810)
		if [ "${ai_status}" = "" ]; then
			log "更新依赖中。。。"
			sleep 60s
		else
			log "AINode已启动。。。"
			break
		fi
		log "AINode启动失败。。。"
	done
	cd ~/
}
# 功能：停止当前场景中的 IoTDB 服务
stop_iotdb() { # 停止iotdb
	cd "${TEST_AINode_PATH}" || return 1
	ai_stop=$(./sbin/stop-ainode.sh >/dev/null 2>&1 &)
	cd "${TEST_IOTDB_PATH}" || return 1
	data_stop=$(./sbin/stop-datanode.sh >/dev/null 2>&1 &)
	sleep 10
	conf_stop=$(./sbin/stop-confignode.sh >/dev/null 2>&1 &)
	cd ~/
}
# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() { # 备份测试数据
	sudo rm -rf -- "${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}"
	sudo mkdir -p ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
    sudo rm -rf -- "${TEST_IOTDB_PATH}/data"
	#sudo rm -rf ${TEST_AINode_PATH}/venv
	#sudo mv ${TEST_AINode_PATH}/venv /data/atmos/zk_test/AINode/
	if [ -d "${TEST_AINode_PATH}/venv" ]; then
		sudo mv ${TEST_AINode_PATH}/venv /data/atmos/zk_test/AINode/
	fi
	sudo mv ${TEST_IOTDB_PATH} ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo mv ${TEST_AINode_PATH} ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo mv ${TEST_TOOL_PATH} ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
}
##准备开始测试
# 功能：校验运行环境并编排当前脚本的完整测试流程
main() {
    ensure_runtime_dependencies
    check_password
    trap restore_test_type_file EXIT
printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} = 'retest' ORDER BY commit_date_time desc limit 1 "
result_string=$(mysql_exec "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
##查询是否有复测任务
if [ "${commit_id}" = "" ]; then
	query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} is NULL ORDER BY commit_date_time desc limit 1 "
	result_string=$(mysql_exec "${query_sql}")
	commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
fi
if [ "${commit_id}" = "" ]; then
	sleep 60s
else
	#测试表模型
	init_items
	# 获取git commit对比判定是否启动测试
	cd "${TC_PATH}" || return 1
	#last_cid1=$(git log --pretty=format:"%h" -1)
	#更新TC
	git_pull=$(timeout 100s git pull)
	# 获取更新后git commit对比判定是否启动测试
	#commit_id1=$(git log --pretty=format:"%h" -1)
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'ontesting' where commit_id = '${commit_id}'"
	result_string=$(mysql_exec "${update_sql}")
	log "当前版本${commit_id}未执行过测试，即将编译后启动"
	test_date_time=$(date +%Y%m%d%H%M%S)
	#开始测试
	#清理环境，确保无旧程序影响
	check_iotdb_pid
	check_sql_test_pid
	#复制当前程序到执行位置
	set_env
	#IoTDB 调整内存，关闭合并
	modify_iotdb_config
	set_protocol_class 2 2 3
	#启动iotdb和monitor监控
	start_iotdb
	sleep 30
	####判断IoTDB是否正常启动
	for (( t_wait = 0; t_wait <= 10; t_wait++ ))
	do
	  iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "show cluster" | grep 'Total line number = 2')
	  if [ "${iotdb_state}" = "Total line number = 2" ]; then
		break
	  else
		sleep 5
		continue
	  fi
	done
	if [ "${iotdb_state}" = "Total line number = 2" ]; then
		log "IoTDB正常启动"
		change_pwd=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'")
		F_start_time=$(date +%s%3N)
		F_str1=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -e "insert into root.ln.wf02.wt02(timestamp, status, hardware) VALUES (3, false, 'v3'),(4, true, 'v4')")
		F_now_time=$(date +%s%3N)
		F_t_time=$[${F_now_time}-${F_start_time}]
		cost_time=${F_t_time}
		pass_num=0
		fail_num=0
		F_str1=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -e "drop database root.**")
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${F_start_time}','${F_now_time}',${cost_time},'FirstInsertSQL')"
		mysql_exec "${insert_sql}"
	else
		log "IoTDB未能正常启动，写入负值测试结果！"
		cost_time=-3
		fail_num=-3
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'tablemode')"
		mysql_exec "${insert_sql}"
		update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'RError' where commit_id = '${commit_id}'"
		result_string=$(mysql_exec "${update_sql}")
		continue
	fi
	# 拷贝测试依赖到各自文件夹
	#cp -rf ${TC_PATH}/lib/trigger_jar/ext ${TEST_IOTDB_PATH}/ext/trigger/
	#cp -rf ${TC_PATH}/lib/udf_jar/envelop ${TEST_IOTDB_PATH}/ext/udf/
	#cp -rf ${TC_PATH}/lib/udf_jar/ext ${TEST_IOTDB_PATH}/ext/udf/
	#cp -rf ${TC_PATH}/lib/udf_jar/example ${TEST_IOTDB_PATH}/ext/udf/
	#cp -rf ${TC_PATH}/lib/trigger_jar/local/* /data/nginx/
	cp -rf ${TC_PATH}/lib/udf_jar/local/* /data/nginx/
	cp -rf ${TC_PATH}/lib/udf_jar/example ${TEST_IOTDB_PATH}/ext/udf/
	cp -rf ${TC_PATH}/table/scripts ${TEST_TOOL_PATH}/user/
	cp -rf ${TEST_IOTDB_PATH}/lib/* ${TEST_TOOL_PATH}/user/driver/iotdb/
	cd "${TEST_TOOL_PATH}" || return 1
	sed -i "s/sql_dialect=tree$/sql_dialect=table/g" ${TEST_TOOL_PATH}/user/CONFIG/otf_new.properties
	sed -i "s/setup$/test/g" ${TEST_TOOL_PATH}/user/CONFIG/otf_new.properties
	#start_test=$(./test.sh)
	#javac -encoding gbk -cp '${TEST_TOOL_PATH}/user/driver/iotdb/*:${TEST_TOOL_PATH}/lib/*:${TEST_TOOL_PATH}/user/driver/POI/*:.' ${TEST_TOOL_PATH}/src/*.java -d ${TEST_TOOL_PATH}/bin
	compile=$(./compile.sh)
	start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	start_test=$(./test.sh >/dev/null 2>&1 &)
	for (( t_wait = 0; t_wait <= 20; ))
	do
		cd "${TEST_TOOL_PATH}" || return 1
		result_file=${TEST_TOOL_PATH}/result.xml
		if [ ! -f "$result_file" ]; then
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 7200 ]; then
				log "测试失败"
				flag=1
				break
			fi
			continue
		else
			log "测试完成"
			break
		fi
	done
	end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	#停止IoTDB程序
	stop_iotdb
	sleep 30
	check_iotdb_pid
	if [ "${flag}" = "0" ]; then
		#收集测试结果
		cd "${TEST_TOOL_PATH}" || return 1
		pass_num=$(grep -n 'run" result="PASS"' ${TEST_TOOL_PATH}/result.xml | wc -l)
		fail_num=$(grep -n 'run" result="FAIL"' ${TEST_TOOL_PATH}/result.xml | wc -l)
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'tablemode')"
		#echo "${insert_sql}"
		mysql_exec "${insert_sql}"
	else
		#收集测试结果
		cd "${TEST_TOOL_PATH}" || return 1
		pass_num=0
		fail_num=-1
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'tablemode')"
		#echo "${insert_sql}"
		mysql_exec "${insert_sql}"
	fi
	#备份本次测试
	backup_test_data tablemode
	
	if [ 1 -ge 5 ]; then
		#测试AINode_tree
		init_items
		# 获取git commit对比判定是否启动测试
		cd "${TC_PATH}" || return 1
		#last_cid1=$(git log --pretty=format:"%h" -1)
		#更新TC
		git_pull=$(timeout 100s git pull)
		# 获取更新后git commit对比判定是否启动测试
		#commit_id1=$(git log --pretty=format:"%h" -1)
		update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'ontesting' where commit_id = '${commit_id}'"
		result_string=$(mysql_exec "${update_sql}")
		log "当前版本${commit_id}未执行过测试，即将编译后启动"
		test_date_time=$(date +%Y%m%d%H%M%S)
		#开始测试
		#清理环境，确保无旧程序影响
		check_iotdb_pid
		check_sql_test_pid
		#复制当前程序到执行位置
		set_env
		#IoTDB 调整内存，关闭合并
		modify_iotdb_config
		set_protocol_class 2 2 3
		#启动iotdb和monitor监控
		start_iotdb
		sleep 30
		####判断IoTDB是否正常启动
		for (( t_wait = 0; t_wait <= 10; t_wait++ ))
		do
		  iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "show cluster" | grep 'Total line number = 2')
		  if [ "${iotdb_state}" = "Total line number = 2" ]; then
			break
		  else
			sleep 5
			continue
		  fi
		done
		if [ "${iotdb_state}" = "Total line number = 2" ]; then
			log "IoTDB正常启动"
			change_pwd=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'")
		else
			log "IoTDB未能正常启动，写入负值测试结果！"
			cost_time=-3
			fail_num=-3
			insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'AINode_tree')"
			mysql_exec "${insert_sql}"
			update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'RError' where commit_id = '${commit_id}'"
			result_string=$(mysql_exec "${update_sql}")
			continue
		fi
		####判断IoTDB-AINode是否正常启动
		start_iotdb_ainode
		sleep 60
		for (( t_wait = 0; t_wait <= 20; t_wait++ ))
		do
		  iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -e "show cluster" | grep 'Total line number = 3')
		  if [ "${iotdb_state}" = "Total line number = 3" ]; then
			break
		  else
			sleep 30
			continue
		  fi
		done
		if [ "${iotdb_state}" = "Total line number = 3" ]; then
			log "IoTDB-AINode正常启动，准备开始测试"
			change_pwd=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'")
			F_start_time=$(date +%s%3N)
			F_str1=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -e "insert into root.ln.wf02.wt02(timestamp, status, hardware) VALUES (3, false, 'v3'),(4, true, 'v4')")
			F_now_time=$(date +%s%3N)
			F_t_time=$[${F_now_time}-${F_start_time}]
			cost_time=${F_t_time}
			pass_num=0
			fail_num=0
			F_str1=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -e "drop database root.**")
			insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${F_start_time}','${F_now_time}',${cost_time},'FirstInsertSQL')"
			mysql_exec "${insert_sql}"
			# 拷贝测试依赖到各自文件夹
			#cp -rf ${TC_PATH}/lib/trigger_jar/ext ${TEST_IOTDB_PATH}/ext/trigger/
			#cp -rf ${TC_PATH}/lib/udf_jar/envelop ${TEST_IOTDB_PATH}/ext/udf/
			#cp -rf ${TC_PATH}/lib/udf_jar/ext ${TEST_IOTDB_PATH}/ext/udf/
			#cp -rf ${TC_PATH}/lib/udf_jar/example ${TEST_IOTDB_PATH}/ext/udf/
			#cp -rf ${TC_PATH}/lib/trigger_jar/local/* /data/nginx/
			cp -rf ${TC_PATH}/lib/udf_jar/local/* /data/nginx/
			cp -rf ${TC_PATH}/ainode_tree/scripts ${TEST_TOOL_PATH}/user/
			#cp -rf ${TC_PATH}/lib/udf_jar/example ${TEST_IOTDB_PATH}/ext/udf/
			cp -rf ${TEST_IOTDB_PATH}/lib/* ${TEST_TOOL_PATH}/user/driver/iotdb/
			cd "${TEST_TOOL_PATH}" || return 1
			sed -i "s/sql_dialect=table$/sql_dialect=tree/g" ${TEST_TOOL_PATH}/user/CONFIG/otf_new.properties
			#start_test=$(./test.sh)
			#javac -encoding gbk -cp '${TEST_TOOL_PATH}/user/driver/iotdb/*:${TEST_TOOL_PATH}/lib/*:${TEST_TOOL_PATH}/user/driver/POI/*:.' ${TEST_TOOL_PATH}/src/*.java -d ${TEST_TOOL_PATH}/bin
			compile=$(./compile.sh)
			start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			start_test=$(./test.sh >/dev/null 2>&1 &)
			for (( t_wait = 0; t_wait <= 20; ))
			do
				cd "${TEST_TOOL_PATH}" || return 1
				result_file=${TEST_TOOL_PATH}/result.xml
				if [ ! -f "$result_file" ]; then
					now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
					if [ $t_time -ge 7200 ]; then
						log "测试失败"
						flag=1
						break
					fi
					continue
				else
					log "测试完成"
					break
				fi
			done
			end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			#停止IoTDB程序
			stop_iotdb
			sleep 30
			check_iotdb_pid
			if [ "${flag}" = "0" ]; then
				#收集测试结果
				cd "${TEST_TOOL_PATH}" || return 1
				pass_num=$(grep -n 'run" result="PASS"' ${TEST_TOOL_PATH}/result.xml | wc -l)
				fail_num=$(grep -n 'run" result="FAIL"' ${TEST_TOOL_PATH}/result.xml | wc -l)
				#结果写入mysql
				cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
				insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'AINode_tree')"
				#echo "${insert_sql}"
				mysql_exec "${insert_sql}"
			else
				#收集测试结果
				cd "${TEST_TOOL_PATH}" || return 1
				pass_num=0
				fail_num=-1
				#结果写入mysql
				cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
				insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'AINode_tree')"
				#echo "${insert_sql}"
				mysql_exec "${insert_sql}"
			fi
			#备份本次测试
			backup_test_data ainode_tree
		else
			log "IoTDB未能正常启动，写入负值测试结果！"
			cost_time=-5
			fail_num=-5
			insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'AINode_tree')"
			mysql_exec "${insert_sql}"
			update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'RError' where commit_id = '${commit_id}'"
			result_string=$(mysql_exec "${update_sql}")
			continue
		fi
	
		#测试AINode_table
		init_items
		# 获取git commit对比判定是否启动测试
		cd "${TC_PATH}" || return 1
		#last_cid1=$(git log --pretty=format:"%h" -1)
		#更新TC
		git_pull=$(timeout 100s git pull)
		# 获取更新后git commit对比判定是否启动测试
		#commit_id1=$(git log --pretty=format:"%h" -1)
		update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'ontesting' where commit_id = '${commit_id}'"
		result_string=$(mysql_exec "${update_sql}")
		log "当前版本${commit_id}未执行过测试，即将编译后启动"
		test_date_time=$(date +%Y%m%d%H%M%S)
		#开始测试
		#清理环境，确保无旧程序影响
		check_iotdb_pid
		check_sql_test_pid
		#复制当前程序到执行位置
		set_env
		#IoTDB 调整内存，关闭合并
		modify_iotdb_config
		set_protocol_class 2 2 3
		#启动iotdb和monitor监控
		start_iotdb
		sleep 30
		####判断IoTDB是否正常启动
		for (( t_wait = 0; t_wait <= 10; t_wait++ ))
		do
		  iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "show cluster" | grep 'Total line number = 2')
		  if [ "${iotdb_state}" = "Total line number = 2" ]; then
			break
		  else
			sleep 5
			continue
		  fi
		done
		if [ "${iotdb_state}" = "Total line number = 2" ]; then
			log "IoTDB正常启动"
			change_pwd=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'")
		else
			log "IoTDB未能正常启动，写入负值测试结果！"
			cost_time=-3
			fail_num=-3
			insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'AINode_table')"
			mysql_exec "${insert_sql}"
			update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'RError' where commit_id = '${commit_id}'"
			result_string=$(mysql_exec "${update_sql}")
			continue
		fi
		####判断IoTDB-AINode是否正常启动
		start_iotdb_ainode
		sleep 60
		for (( t_wait = 0; t_wait <= 20; t_wait++ ))
		do
		  iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -e "show cluster" | grep 'Total line number = 3')
		  if [ "${iotdb_state}" = "Total line number = 3" ]; then
			break
		  else
			sleep 30
			continue
		  fi
		done
		if [ "${iotdb_state}" = "Total line number = 3" ]; then
			log "IoTDB-AINode正常启动，准备开始测试"
			change_pwd=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'")
			# 拷贝测试依赖到各自文件夹
			#cp -rf ${TC_PATH}/lib/trigger_jar/ext ${TEST_IOTDB_PATH}/ext/trigger/
			#cp -rf ${TC_PATH}/lib/udf_jar/envelop ${TEST_IOTDB_PATH}/ext/udf/
			#cp -rf ${TC_PATH}/lib/udf_jar/ext ${TEST_IOTDB_PATH}/ext/udf/
			#cp -rf ${TC_PATH}/lib/udf_jar/example ${TEST_IOTDB_PATH}/ext/udf/
			#cp -rf ${TC_PATH}/lib/trigger_jar/local/* /data/nginx/
			cp -rf ${TC_PATH}/lib/udf_jar/local/* /data/nginx/
			cp -rf ${TC_PATH}/ainode_tree/scripts ${TEST_TOOL_PATH}/user/
			#cp -rf ${TC_PATH}/lib/udf_jar/example ${TEST_IOTDB_PATH}/ext/udf/
			cp -rf ${TEST_IOTDB_PATH}/lib/* ${TEST_TOOL_PATH}/user/driver/iotdb/
			cd "${TEST_TOOL_PATH}" || return 1
			sed -i "s/sql_dialect=table$/sql_dialect=table/g" ${TEST_TOOL_PATH}/user/CONFIG/otf_new.properties
			#start_test=$(./test.sh)
			#javac -encoding gbk -cp '${TEST_TOOL_PATH}/user/driver/iotdb/*:${TEST_TOOL_PATH}/lib/*:${TEST_TOOL_PATH}/user/driver/POI/*:.' ${TEST_TOOL_PATH}/src/*.java -d ${TEST_TOOL_PATH}/bin
			compile=$(./compile.sh)
			start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			start_test=$(./test.sh >/dev/null 2>&1 &)
			for (( t_wait = 0; t_wait <= 20; ))
			do
				cd "${TEST_TOOL_PATH}" || return 1
				result_file=${TEST_TOOL_PATH}/result.xml
				if [ ! -f "$result_file" ]; then
					now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
					if [ $t_time -ge 7200 ]; then
						log "测试失败"
						flag=1
						break
					fi
					continue
				else
					log "测试完成"
					break
				fi
			done
			end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			#停止IoTDB程序
			stop_iotdb
			sleep 30
			check_iotdb_pid
			if [ "${flag}" = "0" ]; then
				#收集测试结果
				cd "${TEST_TOOL_PATH}" || return 1
				pass_num=$(grep -n 'run" result="PASS"' ${TEST_TOOL_PATH}/result.xml | wc -l)
				fail_num=$(grep -n 'run" result="FAIL"' ${TEST_TOOL_PATH}/result.xml | wc -l)
				#结果写入mysql
				cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
				insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'AINode_table')"
				#echo "${insert_sql}"
				mysql_exec "${insert_sql}"
			else
				#收集测试结果
				cd "${TEST_TOOL_PATH}" || return 1
				pass_num=0
				fail_num=-1
				#结果写入mysql
				cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
				insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'AINode_table')"
				#echo "${insert_sql}"
				mysql_exec "${insert_sql}"
			fi
			#备份本次测试
			backup_test_data ainode_table
		else
			log "IoTDB未能正常启动，写入负值测试结果！"
			cost_time=-5
			fail_num=-5
			insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,pass_num,fail_num,start_time,end_time,cost_time,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${pass_num},${fail_num},'${start_time}','${end_time}',${cost_time},'AINode_table')"
			mysql_exec "${insert_sql}"
			update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'RError' where commit_id = '${commit_id}'"
			result_string=$(mysql_exec "${update_sql}")
			continue
		fi
	fi
	###############################测试完成###############################
	log "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql_exec "${update_sql}")
	update_sql02="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < '${commit_date_time}'"
	if [ "${author}" != "Timecho" ]; then
		result_string=$(mysql_exec "${update_sql02}")
	fi
fi
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/monitor_common.sh"

main "$@"
