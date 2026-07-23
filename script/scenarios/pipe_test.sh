#!/usr/bin/env bash
set -o pipefail

#登录用户名
ACCOUNT=root
IOTDB_PASSWORD="${IOTDB_PASSWORD:-TimechoDB@2021}"
TEST_TYPE="${TEST_TYPE:-pipe_test}"
#初始环境存放路径
INIT_PATH="${INIT_PATH:-/data/atmos/zk_test}"
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
BACKUP_PATH="${BACKUP_PATH:-/nasdata/repository/pipe_test}"
REPOS_PATH="${REPOS_PATH:-/nasdata/repository/master}"
TEST_INIT_PATH="${TEST_INIT_PATH:-${INIT_PATH}/first-rest-test}"
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
TEST_BM_PATH=${TEST_INIT_PATH}/iot-benchmark
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
# 4. org.apache.iotdb.consensus.iot.IoTConsensusV2
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus org.apache.iotdb.consensus.iot.IoTConsensusV2)
protocol_list=(223 224)
ts_list=(common aligned)
IP_list=(0 11.101.17.144 11.101.17.146)
PIPE_list=(0 11.101.17.146 11.101.17.144)
Control=11.101.17.120
config_node_config_nodes=(0 11.101.17.144:10710 11.101.17.146:10710)
data_node_config_nodes=(0 11.101.17.144:10710 11.101.17.146:10710)
############mysql信息##########################
MYSQL_HOST="${MYSQL_HOST:-111.200.37.158}"
MYSQL_PORT="${MYSQL_PORT:-13306}"
MYSQL_USERNAME="${MYSQL_USERNAME:-iotdbatm}"
MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
DBNAME="${DBNAME:-QA_ATM}"
TABLENAME="ex_pipe_test" #数据库中表的名称
TABLENAME_T="ex_pipe_test_T" #企业版结果表名
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############prometheus##########################
METRIC_SERVER="${METRIC_SERVER:-111.200.37.158:19090}"
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
echo "检查iot-benchmark版本"
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
ts_type=0
start_time=0
end_time=0
cost_time=0
wait_time=0
failPointA=0
throughputA=0
LatencyA=0
numOfSe0LevelA=0
numOfUnse0LevelA=0
dataFileSizeA=0
maxNumofOpenFilesA=0
maxNumofThreadA=0
walFileSizeA=0
errorLogSizeA=0
failPointB=0
throughputB=0
LatencyB=0
numOfSe0LevelB=0
numOfUnse0LevelB=0
dataFileSizeB=0
maxNumofOpenFilesB=0
maxNumofThreadB=0
walFileSizeB=0
errorLogSizeB=0
maxCPULoadA=0
avgCPULoadA=0
maxDiskIOOpsReadA=0
maxDiskIOOpsWriteA=0
maxDiskIOSizeReadA=0
maxDiskIOSizeWriteA=0
maxCPULoadB=0
avgCPULoadB=0
maxDiskIOOpsReadB=0
maxDiskIOOpsWriteB=0
maxDiskIOSizeReadB=0
maxDiskIOSizeWriteB=0
minPointNum=222222
############定义监控采集项初始值##########################
pipflag=0
}
local_ip=`ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d "addr:"`
# 功能：保留或执行测试异常通知逻辑
sendEmail() {
sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}
# 功能：准备当前测试所需的本地安装目录与运行环境
set_env() { # 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_INIT_PATH}" ]; then
		mkdir -p ${TEST_INIT_PATH}
		mkdir -p ${TEST_IOTDB_PATH}
	else
		rm -rf -- "${TEST_INIT_PATH}"
		mkdir -p ${TEST_IOTDB_PATH}
	fi
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_IOTDB_PATH}/
	mkdir -p ${TEST_IOTDB_PATH}/activation
	cp -rf ${BM_PATH} ${TEST_INIT_PATH}/
}
# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" ${TEST_IOTDB_PATH}/conf/datanode-env.sh
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"6G\"/g" ${TEST_IOTDB_PATH}/conf/confignode-env.sh
	#清空配置文件
	# echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "query_timeout_threshold" "6000000"
	#关闭影响写入性能的其他功能
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "enable_seq_space_compaction" "false"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "enable_unseq_space_compaction" "false"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "enable_cross_space_compaction" "false"
	#修改集群名称
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cluster_name" "${TEST_TYPE}"
	#开启自动创建
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "enable_auto_create_schema" "true"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "default_storage_group_level" "2"
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
# 功能：部署并初始化当前测试运行环境
setup_env_linux() {
	echo "开始重置环境！"
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}
		remote_reboot "${TEST_IP}"
	done
	sleep 120
	for (( i = 1; i < ${#IP_list[*]}; i++ ))
	do
		echo "开始部署${IP_list[$i]}！"
		TEST_IP=${IP_list[$i]}
		echo "setting env to ${TEST_IP} ..."
		#删除原有路径下所有
		remote_reset_dir "${TEST_IP}" "${TEST_INIT_PATH}"
		#修改IoTDB的配置		
		set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_rpc_address" "${TEST_IP}"
		set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_internal_address" "${TEST_IP}"
		set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_seed_config_node" "${data_node_config_nodes[$i]}"
		set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_internal_address" "${TEST_IP}"
		set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_seed_config_node" "${config_node_config_nodes[$i]}"
		#准备配置文件和license
		mv_config_file ${ts_type} ${TEST_IP}
		#sed -i "s/^HOST=.*$/HOST=${TEST_IP}/g" ${TEST_BM_PATH}/conf/config.properties
		rm -rf -- "${TEST_INIT_PATH}/apache-iotdb/activation"
		mkdir -p ${TEST_INIT_PATH}/apache-iotdb/activation
		cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/${TEST_IP} ${TEST_INIT_PATH}/apache-iotdb/activation/license
		cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/env_${TEST_IP} ${TEST_INIT_PATH}/apache-iotdb/.env
		#复制三项到客户机
		remote_copy_contents "${TEST_INIT_PATH}" "${TEST_IP}" "${TEST_INIT_PATH}"
		#scp -r ${TEST_INIT_PATH}/* ${ACCOUNT}@${TEST_IP}:${TEST_INIT_PATH}/  > /dev/null 2>&1 &
	done	
	sleep 3
	for (( i = 1; i < ${#IP_list[*]}; i++ ))
	do
		TEST_IP=${IP_list[$i]}
		#启动ConfigNode节点
		echo "starting IoTDB ConfigNode on ${TEST_IP} ..."
		remote_start_background "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-confignode.sh"
		#主节点需要先启动，所以等待10秒是为了保证主节点启动完毕
		sleep 5
		#启动DataNode节点
		echo "starting IoTDB DataNode on ${TEST_IP} ..."
		remote_start_background "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof"
		#等待60s，让服务器完成前期准备
		sleep 10
		for (( t_wait = 0; t_wait <= 50; t_wait++ ))
		do
		  if remote_iotdb_cluster_ready "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh" 2; then
			echo "All Nodes is ready"
			flag=1
			change_pwd=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -h ${TEST_IP} -p 6667 -e \"ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}';\"")
			break
		  else
			echo "All Nodes is not ready.Please wait ..."
			sleep 3
			continue
		  fi
		done
		if [ "$flag" = "0" ]; then
		  echo "All Nodes is not ready!"
		  exit -1
		fi
	done
	sleep 3
	if [ "${ts_type}" = "tablemode" ]; then
		for (( i = 1; i < ${#IP_list[*]}; i++ ))
		do
			TEST_IP=${IP_list[$i]}
			str1=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -sql_dialect table -h ${TEST_IP} -p 6667 -e \"create pipe test with source ('source.realtime.mode'='stream','source.realtime.enable'='true','source.forwarding-pipe-requests'='false','source.batch.enable'='true','source.history.enable'='true') with sink ('sink'='iotdb-thrift-sink','username'='root','password'='${IOTDB_PASSWORD}', 'sink.node-urls'='${PIPE_list[$i]}:6667');\"")
			echo $str1
			sleep 3
			str1=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -sql_dialect table -h ${TEST_IP} -p 6667 -e \"start pipe test;\"")
			echo $str1
			str1=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -sql_dialect table -h ${TEST_IP} -p 6667 -e \"show pipes;\" | grep 'Total line number = 1'")
			str2=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -sql_dialect table -h ${TEST_IP} -p 6667 -e \"show pipes;\" | grep 'Total line number = 2'")
			echo $str1
			echo $str2
			if [[ "$str1" = "Total line number = 1" ]]  || [[ "$str2" = "Total line number = 2" ]] ; then
				echo "PIPE is ready"
				pipflag=$[${pipflag}+1]
			fi
		done
	else
		for (( i = 1; i < ${#IP_list[*]}; i++ ))
		do
			TEST_IP=${IP_list[$i]}
			str1=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${TEST_IP} -p 6667 -e \"create pipe test with source ('source.pattern'='root', 'source.realtime.mode'='stream','source.realtime.enable'='true','source.forwarding-pipe-requests'='false','source.batch.enable'='true','source.history.enable'='true') with sink ('sink'='iotdb-thrift-sink', 'username'='root','password'='${IOTDB_PASSWORD}', 'sink.node-urls'='${PIPE_list[$i]}:6667');\"")
			echo $str1
			sleep 3
			str1=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${TEST_IP} -p 6667 -e \"start pipe test;\"")
			echo $str1
			str1=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${TEST_IP} -p 6667 -e \"show pipes;\" | grep 'Total line number = 1'")
			str2=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${TEST_IP} -p 6667 -e \"show pipes;\" | grep 'Total line number = 2'")
			echo $str1
			echo $str2
			if [[ "$str1" = "Total line number = 1" ]]  || [[ "$str2" = "Total line number = 2" ]] ; then
				echo "PIPE is ready"
				pipflag=$[${pipflag}+1]
			fi
		done
	fi
	echo $pipflag
}
# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() { # 监控测试运行状态，获取最大打开文件数量和最大线程数
	TEST_IP=$1
	for (( device = 0; device < 50; device++ ))
	do
		numOfPointsA[${device}]=0
		numOfPointsB[${device}]=0
	done
	while true; do
		now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
		flagBM=0
		for (( m = 1; m <= 2; m++ ))
		do
			if [ $t_time -ge 3600 ]; then
				echo "测试失败"  #倒序输入形成负数结果
				end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
				flagBM=-1
				cost_time=-1
				break
			fi
			str1=$(ssh ${ACCOUNT}@${IP_list[${m}]} "jps | grep -w App | grep -v grep | wc -l" 2>/dev/null)
			if [ "$str1" = "1" ]; then
				echo "BM写入未结束:${IP_list[${m}]}"  > /dev/null 2>&1 &
			else
				echo "BM写入已结束:${IP_list[${m}]}"
				flagBM=$[${flagBM}+1]
			fi
		done
		if [ $flagBM -ge 2 ]; then
			if [ "${ts_type}" = "tablemode" ]; then
				fstr1=$(ssh ${ACCOUNT}@${IP_list[1]} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -sql_dialect table -h ${IP_list[1]} -p 6667 -e \"flush\"")
				fstr2=$(ssh ${ACCOUNT}@${IP_list[2]} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -sql_dialect table -h ${IP_list[2]} -p 6667 -e \"flush\"")
			else
				fstr1=$(ssh ${ACCOUNT}@${IP_list[1]} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${IP_list[1]} -p 6667 -e \"flush\"")
				fstr2=$(ssh ${ACCOUNT}@${IP_list[2]} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${IP_list[2]} -p 6667 -e \"flush\"")
			fi
			#BM写入结束前不进行判定
			#确认是否测试已结束
			flagA=0
			flagB=0
			for (( device = 0; device < 50; device++ ))
			do
				if [ "${ts_type}" = "tablemode" ]; then
					str1=$(ssh ${ACCOUNT}@${IP_list[1]} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -sql_dialect table -h ${IP_list[1]} -p 6667 -e \"select count(s_0) from test_g_0.table_0 where device_id = 'd_${device}'\" | sed -n '4p' | sed s/\|//g | sed 's/[[:space:]]//g' ")
					if [[ "${numOfPointsA[${device}]}" == "$str1" ]]; then
						flagA=$[${flagA}+1]
					else
						numOfPointsA[${device}]=$str1
						last_update_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					fi
					str2=$(ssh ${ACCOUNT}@${IP_list[2]} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -sql_dialect table -h ${IP_list[2]} -p 6667 -e \"select count(s_0) from test_g_0.table_0 where device_id = 'd_${device}'\" | sed -n '4p' | sed s/\|//g | sed 's/[[:space:]]//g' ")
					if [[ "${numOfPointsB[${device}]}" == "$str2" ]]; then
						flagB=$[${flagB}+1]
					else
						numOfPointsB[${device}]=$str2
						last_update_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					fi
				else
					str1=$(ssh ${ACCOUNT}@${IP_list[1]} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${IP_list[1]} -p 6667 -e \"select count(s_0) from root.test.g_0.d_${device}\" | sed -n '4p' | sed s/\|//g | sed 's/[[:space:]]//g' ")
					if [[ "${numOfPointsA[${device}]}" == "$str1" ]]; then
						flagA=$[${flagA}+1]
					else
						numOfPointsA[${device}]=$str1
						last_update_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					fi
					str2=$(ssh ${ACCOUNT}@${IP_list[2]} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${IP_list[2]} -p 6667 -e \"select count(s_0) from root.test.g_0.d_${device}\" | sed -n '4p' | sed s/\|//g | sed 's/[[:space:]]//g' ")
					if [[ "${numOfPointsB[${device}]}" == "$str2" ]]; then
						flagB=$[${flagB}+1]
					else
						numOfPointsB[${device}]=$str2
						last_update_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					fi
				fi
				#echo "flagA=${flagA}"
				#echo "flagB=${flagB}"
				#echo "numOfPointsA=${numOfPointsA}"
				#echo "numOfPointsB=${numOfPointsB}"
				#echo "last_update_time=${last_update_time}"
			done
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${last_update_time}")))
			if [ $t_time -ge 600 ]; then
				echo "10分钟无数据更新同步，结束等待"  #倒序输入形成负数结果
				end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
				cost_time=$(($(date +%s -d "${last_update_time}") - $(date +%s -d "${start_time}")))
				minPointNum=222222
				for (( device = 0; device < 50; device++ ))
				do
					if [ $minPointNum -ge ${numOfPointsA[${device}]} ]; then
						minPointNum=${numOfPointsA[${device}]}
					fi
					if [ $minPointNum -ge ${numOfPointsB[${device}]} ]; then
						minPointNum=${numOfPointsB[${device}]}
					fi
				done
				break
			fi
		elif [ "$flagBM" = "-1" ]; then
			break
		fi
	done
}
# 功能：采集当前测试窗口内的资源和文件指标
collect_monitor_data() { # 收集iotdb数据大小，顺、乱序文件数量
	dataFileSizeA=0
	numOfSe0LevelA=0
	numOfUnse0LevelA=0
	dataFileSizeB=0
	numOfSe0LevelB=0
	numOfUnse0LevelB=0
	maxNumofOpenFilesA=0
	maxNumofThreadA=0
	maxNumofOpenFilesB=0
	maxNumofThreadB=0
	walFileSizeA=0
	walFileSizeB=0
	maxCPULoadA=0
	avgCPULoadA=0
	maxDiskIOOpsReadA=0
	maxDiskIOOpsWriteA=0
	maxDiskIOSizeReadA=0
	maxDiskIOSizeWriteA=0
	maxCPULoadB=0
	avgCPULoadB=0
	maxDiskIOOpsReadB=0
	maxDiskIOOpsWriteB=0
	maxDiskIOSizeReadB=0
	maxDiskIOSizeWriteB=0
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}	
		if [ $j -eq 1 ]; then
			#调用监控获取数值
			dataFileSizeA=$(get_single_index "sum(file_global_size{instance=~\"${TEST_IP}:9091\"})" $m_end_time)
			dataFileSizeA=`awk 'BEGIN{printf "%.2f\n",'$dataFileSizeA'/'1048576'}'`
			dataFileSizeA=`awk 'BEGIN{printf "%.2f\n",'$dataFileSizeA'/'1024'}'`
			numOfSe0LevelA=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"seq\"})" $m_end_time)
			numOfUnse0LevelA=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"unseq\"})" $m_end_time)
			maxNumofThreadA_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9081\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxNumofThreadA_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			let maxNumofThreadA=${maxNumofThreadA_C}+${maxNumofThreadA_D}
			maxNumofOpenFilesA=$(get_single_index "max_over_time(file_count{instance=~\"${TEST_IP}:9091\",name=\"open_file_handlers\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			walFileSizeA=$(get_single_index "max_over_time(file_size{instance=~\"${TEST_IP}:9091\",name=~\"wal\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			walFileSizeA=`awk 'BEGIN{printf "%.2f\n",'$walFileSizeA'/'1048576'}'`
			walFileSizeA=`awk 'BEGIN{printf "%.2f\n",'$walFileSizeA'/'1024'}'`
			maxCPULoadA=$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			avgCPULoadA=$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOOpsReadA=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOOpsWriteA=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOSizeReadA=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOSizeWriteA=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
		else
			#调用监控获取数值
			dataFileSizeB=$(get_single_index "sum(file_global_size{instance=~\"${TEST_IP}:9091\"})" $m_end_time)
			dataFileSizeB=`awk 'BEGIN{printf "%.2f\n",'$dataFileSizeB'/'1048576'}'`
			dataFileSizeB=`awk 'BEGIN{printf "%.2f\n",'$dataFileSizeB'/'1024'}'`
			numOfSe0LevelB=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"seq\"})" $m_end_time)
			numOfUnse0LevelB=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"unseq\"})" $m_end_time)
			maxNumofThreadB_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9081\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxNumofThreadB_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			let maxNumofThreadB=${maxNumofThreadB_C}+${maxNumofThreadB_D}
			maxNumofOpenFilesB=$(get_single_index "max_over_time(file_count{instance=~\"${TEST_IP}:9091\",name=\"open_file_handlers\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			walFileSizeB=$(get_single_index "max_over_time(file_size{instance=~\"${TEST_IP}:9091\",name=~\"wal\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			walFileSizeB=`awk 'BEGIN{printf "%.2f\n",'$walFileSizeB'/'1048576'}'`
			walFileSizeB=`awk 'BEGIN{printf "%.2f\n",'$walFileSizeB'/'1024'}'`
			maxCPULoadB=$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			avgCPULoadB=$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOOpsReadB=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOOpsWriteB=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOSizeReadB=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOSizeWriteB=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
		fi
	done
}
# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() { # 备份测试数据
	sudo rm -rf -- "${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}"
	sudo mkdir -p ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}/
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}
		sudo mkdir -p ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}/${TEST_IP}/
		remote_safe_rm "${TEST_IP}" "${TEST_IOTDB_PATH}/data"
		scp -r ${ACCOUNT}@${TEST_IP}:${TEST_IOTDB_PATH}/ ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}/${TEST_IP}/
	done
	sudo cp -rf ${TEST_BM_PATH}/TestResult/ ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}/
}
# 功能：选择并安装当前用例对应的配置文件
mv_config_file() { # 移动配置文件
	rm -rf -- "${TEST_BM_PATH}/conf/config.properties"
	cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/$1/$2 ${TEST_BM_PATH}/conf/config.properties
}
# 功能：清理超过保留期限的历史测试文件
clear_expired_file() { # 清理超过七天的文件
	find $1 -mtime +7 -type d -name "*" -exec rm -rf {} \;
}
# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
	protocol_class=$1
	ts_type=$2
	pipflag=0
	echo "开始测试${ts_type}时间序列！"
	#复制当前程序到执行位置
	set_env
	#修改IoTDB的配置
	modify_iotdb_config
	if [ "${protocol_class}" = "111" ]; then
		set_protocol_class 1 1 1
	elif [ "${protocol_class}" = "222" ]; then
		set_protocol_class 2 2 2
	elif [ "${protocol_class}" = "223" ]; then
		set_protocol_class 2 2 3
    elif [ "${protocol_class}" = "211" ]; then
        set_protocol_class 2 1 1
    elif [ "${protocol_class}" = "224" ]; then
        set_protocol_class 2 2 4
	else
		echo "协议设置错误！"
		return
	fi
	#启动iotdb
	setup_platform_env
	sleep 60
	#启动写入程序
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}
		echo "开始写入！"
		pid3=$(ssh ${ACCOUNT}@${TEST_IP} "cd ${TEST_BM_PATH};${TEST_BM_PATH}/benchmark.sh > /dev/null 2>&1 &")
	done
	start_time=`date -d today +"%Y-%m-%d %H:%M:%S"`
	m_start_time=$(date +%s)
	#等待1分钟
	sleep 10
	#判断PIPE设置情况
	if [ $pipflag -ge 2 ]; then
		monitor_test_status
	else
		#PIPE启动失败
		cost_time=-5
	fi
	#收集启动后基础监控数据
	m_end_time=$(date +%s)
	collect_monitor_data
	#测试结果收集写入数据库
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		rm -rf -- "${TEST_BM_PATH:?}/TestResult/csvOutput/"*
		mkdir -p ${TEST_BM_PATH}/TestResult/csvOutput/
		scp -r ${ACCOUNT}@${IP_list[${j}]}:${TEST_BM_PATH}/data/csvOutput/*result.csv ${TEST_BM_PATH}/TestResult/csvOutput/
		#收集启动后基础监控数据
		csvOutputfile=${TEST_BM_PATH}/TestResult/csvOutput/*result.csv
		if [ ! -f $csvOutputfile ]; then
			okOperation=0
			okPoint=0
			failOperation=0
			failPoint=0
			throughput=0
		else
			if [ $j -eq 1 ]; then
				read okOperationA okPointA failOperationA failPointA throughputA <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '1,1p' | awk -F, '{print $2,$3,$4,$5,$6}')
				read LatencyA MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '2,2p' | awk -F, '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
			else
				read okOperationB okPointB failOperationB failPointB throughputB <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '1,1p' | awk -F, '{print $2,$3,$4,$5,$6}')
				read LatencyB MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '2,2p' | awk -F, '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
			fi
		fi
	done	
	#cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
	insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,start_time,end_time,cost_time,wait_time,failPointA,throughputA,LatencyA,numOfSe0LevelA,numOfUnse0LevelA,dataFileSizeA,maxNumofOpenFilesA,maxNumofThreadA,walFileSizeA,avgCPULoadA,maxCPULoadA,maxDiskIOSizeReadA,maxDiskIOSizeWriteA,maxDiskIOOpsReadA,maxDiskIOOpsWriteA,errorLogSizeA,failPointB,throughputB,LatencyB,numOfSe0LevelB,numOfUnse0LevelB,dataFileSizeB,maxNumofOpenFilesB,maxNumofThreadB,walFileSizeB,avgCPULoadB,maxCPULoadB,maxDiskIOSizeReadB,maxDiskIOSizeWriteB,maxDiskIOOpsReadB,maxDiskIOOpsWriteB,errorLogSizeB,minPointNum,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${start_time}','${end_time}',${cost_time},${wait_time},${failPointA},${throughputA},${LatencyA},${numOfSe0LevelA},${numOfUnse0LevelA},${dataFileSizeA},${maxNumofOpenFilesA},${maxNumofThreadA},${walFileSizeA},${avgCPULoadA},${maxCPULoadA},${maxDiskIOSizeReadA},${maxDiskIOSizeWriteA},${maxDiskIOOpsReadA},${maxDiskIOOpsWriteA},${errorLogSizeA},${failPointB},${throughputB},${LatencyB},${numOfSe0LevelB},${numOfUnse0LevelB},${dataFileSizeB},${maxNumofOpenFilesB},${maxNumofThreadB},${walFileSizeB},${avgCPULoadB},${maxCPULoadB},${maxDiskIOSizeReadB},${maxDiskIOSizeWriteB},${maxDiskIOOpsReadB},${maxDiskIOOpsWriteB},${errorLogSizeB},${minPointNum},${protocol_class})"

	mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${insert_sql}"
	for (( i = 1; i < ${#IP_list[*]}; i++ ))
	do
		TEST_IP=${IP_list[$i]}
		str1=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/stop-standalone.sh")
	done
	#备份本次测试
	backup_test_data ${ts_type}
}
##准备开始测试
# 功能：校验运行环境并编排当前脚本的完整测试流程
main() {
    ensure_runtime_dependencies
    check_password
    trap restore_test_type_file EXIT
printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} = 'retest' ORDER BY commit_date_time desc limit 1 "
result_string=$(mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
##查询是否有复测任务
if [ "${commit_id}" = "" ]; then
	query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} is NULL ORDER BY commit_date_time desc limit 1 "
	result_string=$(mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${query_sql}")
	commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
fi
if [ "${commit_id}" = "" ]; then
	sleep 60s
else
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'ontesting' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${update_sql}")
	echo "当前版本${commit_id}未执行过测试，即将编译后启动"
	if [ "${author}" != "Timecho" ]; then
		TABLENAME=${TABLENAME}
	else
		TABLENAME=${TABLENAME_T}
	fi
	init_items
	test_date_time=`date +%Y%m%d%H%M%S`	
	echo "开始测试223协议下的tablemode时间序列！"
	test_operation 223 tablemode
	echo "开始测试223协议下的common时间序列！"
	test_operation 223 common
	echo "开始测试223协议下的aligned时间序列！"
	test_operation 223 aligned
	echo "开始测试224协议下的aligned时间序列！"
	test_operation 224 aligned
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${update_sql}")
	update_sql02="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < '${commit_date_time}'"
	if [ "${author}" != "Timecho" ]; then
		result_string=$(mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${update_sql02}")
	fi
fi
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/runtime_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/monitor_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/remote_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/platform_common.sh"

main "$@"
