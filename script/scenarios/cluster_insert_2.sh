#!/usr/bin/env bash

set -o pipefail

TEST_TYPE="cluster_insert_2"
BACKUP_PATH="${BACKUP_PATH:-/nasdata/repository/cluster_insert_2}"
REMOTE_EXTRA_SAFE_ROOTS="${REMOTE_EXTRA_SAFE_ROOTS:-/data/datanode:/data1/datanode:/ssd/datanode}"
REMOTE_CLEAR_ROOTS="${REMOTE_CLEAR_ROOTS:-/data/datanode:/data1/datanode:/ssd/datanode}"
CLUSTER_CREATE_QA_USER=0

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cluster_insert.sh"

protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus org.apache.iotdb.consensus.iot.IoTConsensusV2)
protocol_list=(111 223 222 224)
IP_list=(0 11.101.17.211 11.101.17.212 11.101.17.213 11.101.17.214 11.101.17.215)
D_IP_list=(0 11.101.17.211 11.101.17.212 11.101.17.213 11.101.17.214 11.101.17.215)
C_IP_list=(0 11.101.17.211 11.101.17.212 11.101.17.213 11.101.17.214 11.101.17.215)
B_IP_list=(0 11.101.17.211)
config_node_config_nodes=(0 11.101.17.211:10710 11.101.17.211:10710 11.101.17.211:10710)
data_node_config_nodes=(0 11.101.17.211:10710 11.101.17.212:10710 11.101.17.213:10710)
Control=11.101.17.210
TABLENAME="ex_cluster_insert_2"
TABLENAME_T="ex_cluster_insert_2_T"
TABLENAME_QUERY="ex_cluster_insert_2_query"
TABLENAME_QUERY_T="ex_cluster_insert_2_query_T"
CLUSTER_NAME="Apache-IoTDB-2"

# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" ${TEST_DATANODE_PATH}/conf/datanode-env.sh
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"6G\"/g" ${TEST_CONFIGNODE_PATH}/conf/confignode-env.sh
	#清空配置文件
	# echo "只保留要修改的参数" > ${TEST_DATANODE_PATH}/conf/iotdb-system.properties
	#关闭影响写入性能的其他功能
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "enable_seq_space_compaction" "false"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "enable_unseq_space_compaction" "false"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "enable_cross_space_compaction" "false"
	#修改集群名称
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cluster_name" "Apache-IoTDB-2"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "cluster_name" "Apache-IoTDB-2"
	#添加启动监控功能
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_enable_metric" "true"
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_enable_performance_stat" "true"
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_metric_reporter_list" "PROMETHEUS"
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_metric_level" "ALL"
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_metric_prometheus_reporter_port" "9081"
	#添加启动监控功能
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_enable_metric" "true"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_enable_performance_stat" "true"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_metric_reporter_list" "PROMETHEUS"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_metric_level" "ALL"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_metric_prometheus_reporter_port" "9091"
	#添加多路径
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_data_dirs" "/data/datanode/data,/data1/datanode/data"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_wal_dirs" "/ssd/datanode/wal"
}

# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() { # 监控测试运行状态，获取最大打开文件数量和最大线程数
	while true; do
		flag=0
		for (( j = 1; j <= 1; j++ ))
		do
			str1=$(ssh ${ACCOUNT}@${B_IP_list[${j}]} "jps | grep -w App | grep -v grep | wc -l" 2>/dev/null)
			if [ "$str1" = "1" ]; then
				echo "测试未结束:${B_IP_list[${j}]}"  > /dev/null 2>&1 &
			else
				echo "测试已结束:${B_IP_list[${j}]}"
				flag=$[${flag}+1]
			fi
		done
		now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
		if [ $t_time -ge 6000 ]; then
			echo "测试失败"
			end_time=-1
			cost_time=-1
			remote_reset_dir "${B_IP_list[1]}" "${BM_PATH}/data/csvOutput"
			ssh ${ACCOUNT}@${B_IP_list[1]} "touch ${BM_PATH}/data/csvOutput/Stuck_result.csv"
			array1="INGESTION ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1"
			for ((i=0;i<100;i++))
			do
				ssh ${ACCOUNT}@${B_IP_list[1]} "echo $array1 >> ${BM_PATH}/data/csvOutput/Stuck_result.csv"
			done
			break
		fi
		if [ "$flag" = "1" ]; then
			end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			break
		fi
	done
}

# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
	ts_type=$1
	data_type=$2
	protocol_class=$3
	echo "开始测试${ts_type}时间序列！"
	#复制当前程序到执行位置
	set_env
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
	
	mv_config_file ${ts_type} ${data_type}
	sed -i "s/^HOST=.*$/HOST=${D_IP_list[1]}/g" ${BM_PATH}/conf/config.properties
	setup_nCmD -c3 -d5 -t1
		
	echo "测试开始！"
	start_time=`date -d today +"%Y-%m-%d %H:%M:%S"`
	m_start_time=$(date +%s)

	#等待1分钟
	sleep 60
	monitor_test_status
	m_end_time=$(date +%s)
	#测试结果收集写入数据库
	if [ ! -d "${BM_PATH}/TestResult/csvOutput/" ]; then
		mkdir -p ${BM_PATH}/TestResult/csvOutput/
	fi
	rm -rf -- "${BM_PATH:?}/TestResult/csvOutput/"*
	scp -r ${ACCOUNT}@${B_IP_list[1]}:${BM_PATH}/data/csvOutput/*result.csv ${BM_PATH}/TestResult/csvOutput/
	for ((j = 1; j <= 5; j++)); do
		#收集启动后基础监控数据
		collect_monitor_data ${j}
		csvOutputfile=${BM_PATH}/TestResult/csvOutput/*result.csv
		read okOperation okPoint failOperation failPoint throughput <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '1,1p' | awk -F, '{print $2,$3,$4,$5,$6}')
		read Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '2,2p' | awk -F, '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
		#cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		node_id=${j}
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,node_id,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark,protocol) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${node_id},'${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},'${data_type}','${protocol_class}')"
		mysql_exec "${insert_sql}"
		
		sudo mkdir -p ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/${j}/CN
		sudo mkdir -p ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/${j}/DN
		ssh ${ACCOUNT}@${C_IP_list[${j}]} "sudo cp -rf ${TEST_CONFIGNODE_PATH}/logs ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/${j}/CN"
		ssh ${ACCOUNT}@${D_IP_list[${j}]} "sudo cp -rf ${TEST_DATANODE_PATH}/logs ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/${j}/DN"
		ssh ${ACCOUNT}@${D_IP_list[${j}]} "sudo mv ${TEST_DATANODE_PATH}/dn_dump.hprof ${INIT_PATH}/${ts_type}_${commit_date_time}_${commit_id}_${data_type}_${protocol_class}_dn_dump.hprof"
		ssh ${ACCOUNT}@${C_IP_list[${j}]} "sudo mv ${TEST_CONFIGNODE_PATH}/cn_dump.hprof ${INIT_PATH}/${ts_type}_${commit_date_time}_${commit_id}_${data_type}_${protocol_class}_cn_dump.hprof"
	done
	
	if  [ "${data_type}" = "unseq_rw" ] || [ "${data_type}" = "seq_rw" ]; then
		csvOutputfile=${BM_PATH}/TestResult/csvOutput/*result.csv
		for (( i = 0; i < ${#query_type_csv[*]}; i++ ))
		do
			read okOperation okPoint failOperation failPoint throughput <<<$(cat ${csvOutputfile} | grep ^${query_type_csv[${i}]} | sed -n '1,1p' | awk -F, '{print $2,$3,$4,$5,$6}')
			read Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<$(cat ${csvOutputfile} | grep ^${query_type_csv[${i}]} | sed -n '2,2p' | awk -F, '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
			node_id=1
			insert_sql="insert into ${TABLENAME_QUERY} (commit_date_time,test_date_time,commit_id,author,node_id,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark,protocol,query_type) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${node_id},'${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},'${data_type}','${protocol_class}','${query_type_name[${i}]}')"
			mysql_exec "${insert_sql}"
		done
	fi
	
	sudo cp -rf ${BM_PATH}/TestResult/csvOutput/* ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/
	sudo scp -r ${ACCOUNT}@${B_IP_list[1]}:${BM_PATH}/logs ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/
}

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
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'ontesting' where commit_id = '${commit_id}'"
	result_string=$(mysql_exec "${update_sql}")
	echo "当前版本${commit_id}未执行过测试，即将编译后启动"
	if [ "${author}" != "Timecho" ]; then
		TABLENAME=${TABLENAME}
		TABLENAME_QUERY=${TABLENAME_QUERY}
	else
		TABLENAME=${TABLENAME_T}
		TABLENAME_QUERY=${TABLENAME_QUERY_T}
	fi
	init_items
	test_date_time=`date +%Y%m%d%H%M%S`
	########优先测试
	echo "开始测试普通时间序列顺序写入！"
	test_operation common seq_w 223
	echo "开始测试对齐时间序列顺序写入！"
	test_operation aligned seq_w 223
	#test_operation aligned seq_w 222
	test_operation aligned seq_w 224
	echo "开始测试表模型时间序列顺序写入！"
	test_operation tablemode seq_w 223
	###############################普通时间序列###############################
	#echo "开始测试普通时间序列顺序写入！"
	#test_operation common seq_w 223
	echo "开始测试普通时间序列乱序写入！"
	test_operation common unseq_w 223
	#echo "开始测试普通时间序列顺序读写混合！"
	#test_operation common seq_rw 223
	#echo "开始测试普通时间序列乱序读写混合！"
	#test_operation common unseq_rw 223
	###############################对齐时间序列###############################
	#echo "开始测试对齐时间序列顺序写入！"
	#test_operation aligned seq_w 223
	#test_operation aligned seq_w 222
	echo "开始测试对齐时间序列乱序写入！"
	test_operation aligned unseq_w 223
	#test_operation aligned unseq_w 222
	test_operation aligned unseq_w 224
	echo "开始测试对齐时间序列顺序读写混合！"
	test_operation aligned seq_rw 223
	echo "开始测试对齐时间序列乱序读写混合！"
	test_operation aligned unseq_rw 223
	###############################模板时间序列###############################
	#echo "开始测试模板时间序列顺序写入！"
	#test_operation template seq_w 223
	#echo "开始测试模板时间序列乱序写入！"
	#test_operation template unseq_w 223
	#echo "开始测试模板时间序列顺序读写混合！"
	#test_operation template seq_rw 223
	#echo "开始测试模板时间序列乱序读写混合！"
	#test_operation template unseq_rw 223
	###############################对齐模板时间序列###############################
	#echo "开始测试对齐模板时间序列顺序写入！"
	#test_operation tempaligned seq_w 223
	#echo "开始测试对齐模板时间序列乱序写入！"
	#test_operation tempaligned unseq_w 223
	#echo "开始测试对齐模板时间序列顺序读写混合！"
	#test_operation tempaligned seq_rw 223
	#echo "开始测试对齐模板时间序列乱序读写混合！"
	#test_operation tempaligned unseq_rw 223	
	###############################表模型时间序列###############################
	#echo "开始测试表模型时间序列顺序写入！"
	#test_operation tablemode seq_w 223
	echo "开始测试表模型时间序列乱序写入！"
	test_operation tablemode unseq_w 223
	echo "开始测试表模型时间序列顺序读写混合！"
	test_operation tablemode seq_rw 223
	echo "开始测试表模型时间序列乱序读写混合！"
	test_operation tablemode unseq_rw 223
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql_exec "${update_sql}")
	update_sql02="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < '${commit_date_time}'"
	if [ "${author}" != "Timecho" ]; then
		result_string=$(mysql_exec "${update_sql02}")
	fi
fi
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

main "$@"
