#!/usr/bin/env bash
set -o pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/runtime_common.sh"

#登录用户名
ACCOUNT=root
TEST_TYPE="${TEST_TYPE:-python_api}"
#初始环境存放路径
INIT_PATH="${INIT_PATH:-/root/zk_test}"
IOTDB_PATH=${INIT_PATH}/iotdb
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH="${BM_PATH:-${INIT_PATH}/iot-benchmark}"
#测试数据运行路径
TEST_INIT_PATH="${TEST_INIT_PATH:-/root}"
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
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
TABLENAME="python_api" #数据库中表的名称
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
write_python_api_result() {
	insert_sql="insert into ${TABLENAME} (test_date_time,commit_id,InsertRecord,InsertRecords,InsertTablet,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id}',${InsertRecord},${InsertRecords},${InsertTablet},'${start_time}','${end_time}',${cost_time},'master')"
	log "${insert_sql}"
	mysql_exec "${insert_sql}"
}

skip_failure_result_for_pending_retry() {
	if [ -n "${pending_commit_id}" ]; then
		log "commit ${commit_id} 失败结果暂不写入 MySQL；已安排 ${pending_run_mode} 执行 ${pending_commit_id}。"
		return 0
	fi
	return 1
}

write_python_api_failure_result() {
	local failure_value="$1"

	InsertRecord="${failure_value}"
	InsertRecords="${failure_value}"
	InsertTablet="${failure_value}"
	if [ -z "${start_time}" ] || [ "${start_time}" = "-1" ]; then
		start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	fi
	if [ -z "${end_time}" ] || [ "${end_time}" = "-1" ]; then
		end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	fi
	cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
	write_python_api_result
}
# 功能：重置当前测试用例使用的指标和运行状态
init_scenario_state() {
############定义监控采集项初始值##########################
InsertRecord=0
InsertRecords=0
InsertTablet=0
flag=0
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
# 功能：准备当前测试所需的本地安装目录与运行环境
set_env() {
	# 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_IOTDB_PATH}" ]; then
		mkdir -p ${TEST_IOTDB_PATH}
	else
		rm -rf -- "${TEST_IOTDB_PATH}"
		mkdir -p ${TEST_IOTDB_PATH}
	fi
	cp -rf ${IOTDB_PATH}/distribution/target/apache-iotdb-*-all-bin/apache-iotdb-*-all-bin/* ${TEST_IOTDB_PATH}/
	mkdir -p ${TEST_IOTDB_PATH}/activation
	install_iotdb_runtime_config
}
# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() { # iotdb调整内存，开启MQTT
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"2G\"/g" ${TEST_IOTDB_PATH}/conf/datanode-env.sh
}
# 功能：检查当前场景的前置条件、进程状态或结果有效性
check_monitor_pid() { # 检查benchmark-moitor的pid，有就停止
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
# 功能：启动当前场景中的 IoTDB 服务
start_iotdb() { # 启动iotdb
	cd "${TEST_IOTDB_PATH}" || return 1
	conf_start=$(./sbin/start-confignode.sh >/dev/null 2>&1 &)
	sleep 10
	data_start=$(./sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof >/dev/null 2>&1 &)
	cd ~/
}

# 测试失败后立即同步代码，并安排下一轮任务。
# 有新提交时测试新提交；没有新提交时仅重试当前提交一次。
schedule_task_after_failure() {
	local failed_commit="$1"
	local failed_run_mode="$2"
	local updated_commit=""

	log "测试失败，立即更新 IoTDB 代码。"
	if git_sync_branch "${IOTDB_PATH}" master 100; then
		updated_commit=$(git_current_commit "${IOTDB_PATH}")
	else
		updated_commit="${failed_commit}"
		log "IoTDB 代码更新失败，按无代码更新处理。"
	fi
	if [ "${updated_commit}" != "${failed_commit}" ]; then
		pending_commit_id="${updated_commit}"
		pending_run_mode="updated"
		log "检测到代码更新，将运行下一个 commit ${updated_commit} 的任务。"
	elif [ "${failed_run_mode}" != "retry" ]; then
		pending_commit_id="${failed_commit}"
		pending_run_mode="retry"
		log "未检测到代码更新，将对当前 commit ${failed_commit} 重新运行一次测试。"
	else
		pending_commit_id=""
		pending_run_mode=""
		log "当前 commit ${failed_commit} 重试后仍失败，不再重复重试。"
	fi
}
# 功能：校验运行环境并编排当前脚本的完整测试流程
main() {
    ensure_runtime_dependencies
    check_password
	pending_commit_id=""
	pending_run_mode=""
while true; do
	init_items
	current_run_mode="normal"
	# 获取git commit对比判定是否启动测试
	#对比判定是否启动测试
	cd "${IOTDB_PATH}" || return 1
	#git reset --hard 938c1f19df122ffaafd827a00a65f5931cbc7f4c
	last_cid=$(git_current_commit "${IOTDB_PATH}")
	#last_cid=0
	#更新iotdb代码
	git_sync_branch "${IOTDB_PATH}" master 100
	# 获取更新后git commit对比判定是否启动测试
	commit_id=$(git_current_commit "${IOTDB_PATH}")
	#对比判定是否启动测试
	if [ -n "${pending_commit_id}" ] && [ "${pending_commit_id}" = "${commit_id}" ]; then
		current_run_mode="${pending_run_mode}"
		pending_commit_id=""
		pending_run_mode=""
		log "按失败处理计划执行 commit ${commit_id}，模式：${current_run_mode}。"
	elif [ "${last_cid}" = "${commit_id}" ] && [ "${last_cid1}" = "${commit_id1}" ]; then
		log "无代码更新，当前版本${commit_id}已经执行过测试"
		sleep 300s
		continue
	else
		log "当前版本${commit_id}未执行过测试，即将编译后启动"
		test_date_time=$(date +%Y%m%d%H%M%S)
		rm -rf -- "${INIT_PATH}/log_python_api"
		#代码编译
		start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		comp_mvn=$(timeout 3000s mvn clean package -pl distribution -am -DskipTests)
		if [ $? -eq 0 ]
		then
			log "编译完成，准备开始测试！"
		else
			log "编译失败，先安排重试，暂不写入 MySQL 失败结果。"
			end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			schedule_task_after_failure "${commit_id}" "${current_run_mode}"
			if skip_failure_result_for_pending_retry; then
				continue
			fi
			write_python_api_failure_result -1
			continue
		fi
		cd ${IOTDB_PATH}/iotdb-client/client-py
		comp_py=$(sh ./release.sh >/dev/null 2>&1 &)
		sleep 2
		pip_uninstall=$(pip3 uninstall apache-iotdb -y >/dev/null 2>&1 &)
		sleep 2
		#开始测试
		#清理环境，确保无旧程序影响
		check_iotdb_pid
		#复制当前程序到执行位置
		set_env
		#IoTDB 调整内存，关闭合并
		modify_iotdb_config
		#启动iotdb和monitor监控
		start_iotdb
		sleep 60
		cd ${IOTDB_PATH}/iotdb-client/client-py/dist/
		pip_install=$(pip3 install apache_iotdb-*-py3-none-any.whl >/dev/null 2>&1 &)
		sleep 20
		start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		start_test=$(python3 ${ATMOS_PATH}/tools/python_api.py > ${INIT_PATH}/log_python_api)
		log "开始监控。。。"
		for (( t_wait = 0; t_wait <= 20; ))
		do
			#监控执行情况  
			ts_status=$(cat ${INIT_PATH}/log_python_api | grep 'All executions done!!'| wc -l)
			if [ ${ts_status} -le 0 ]; then
				now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
				t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
				if [ $t_time -ge 7200 ]; then
					log "测试失败"  #倒序输入形成负数结果
					end_time=-1
					cost_time=-100
					flag=1
					break
				fi
				continue
			else
				log "测试已完成"
				break
			fi
		done
		end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		#停止IoTDB程序
		check_iotdb_pid
		if [ "${flag}" -ne 0 ]; then
			schedule_task_after_failure "${commit_id}" "${current_run_mode}"
		fi
		if [ $flag -eq 0 ]; then
			#收集测试结果
			InsertRecord=$(find ${INIT_PATH}/* -name log_python_api | xargs grep "InsertRecord " | awk '{print $5}')
			InsertRecords=$(find ${INIT_PATH}/* -name log_python_api | xargs grep "InsertRecords " | awk '{print $5}')
			InsertTablet=$(find ${INIT_PATH}/* -name log_python_api | xargs grep "InsertTablet " | awk '{print $7}')
			#结果写入mysql
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			write_python_api_result
		elif skip_failure_result_for_pending_retry; then
			:
		else
			write_python_api_failure_result -3
		fi
		#备份本次测试
		case_id="$(backup_build_case_id language python workload session_api)"
		backup_begin_case "${case_id}" || return 1
		backup_add_iotdb_runtime
		backup_add result "${INIT_PATH}/log_python_api" python-api.log required
		if [ "${flag}" -eq 0 ]; then
			backup_finish_case completed
		else
			backup_finish_case failed
		fi
		###############################测试完成###############################
		log "本轮测试${test_date_time}已结束."
		#清理过期文件 - 当前策略保留4天
	fi
done
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/monitor_common.sh"

main "$@"
