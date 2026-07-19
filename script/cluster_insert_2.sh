#!/usr/bin/env bash

set -o pipefail

TEST_TYPE="cluster_insert_2"
BACKUP_PATH="${BACKUP_PATH:-/nasdata/repository/cluster_insert_2}"

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

setup_nCmD() {
while getopts 'c:d:t:' OPT; do
    case $OPT in
        c) config_num="$OPTARG";;
        d) data_num="$OPTARG";;
		t) bm_num="$OPTARG";;
        ?) echo "ERROR";;
    esac
done
###检查参数
if [[ "$config_num" == '' ]] || [[ "$data_num" == '' ]] 
then
  echo "Enter the number of ConfigNodes and datanodes to start."
  exit -1
fi
#拼接config_node参数
dcn_str=''
for (( j = 1; j <= ${config_num}; j++ ))
do
	if [ "$dcn_str" == '' ]; then
		dcn_str=${data_node_config_nodes[${j}]}
	else
		dcn_str=${dcn_str},${data_node_config_nodes[${j}]}
	fi
done
echo "开始重置环境！"
for (( i = 1; i < ${#IP_list[*]}; i++ ))
do
	#ssh ${ACCOUNT}@${IP_list[${i}]} "killall -u ${ACCOUNT} > /dev/null 2>&1 &"
	ssh ${ACCOUNT}@${IP_list[${i}]} "sudo reboot"
done
sleep 180
for (( i = 1; i < ${#IP_list[*]}; i++ ))
do
	echo "setting env to ${IP_list[${i}]} ..."
	#删除原有路径下所有
	ssh ${ACCOUNT}@${IP_list[${i}]} "rm -rf ${TEST_PATH}"
	ssh ${ACCOUNT}@${IP_list[${i}]} "rm -rf /data/datanode/*"
	ssh ${ACCOUNT}@${IP_list[${i}]} "rm -rf /data1/datanode/*"
	ssh ${ACCOUNT}@${IP_list[${i}]} "rm -rf /ssd/datanode/*"
	ssh ${ACCOUNT}@${IP_list[${i}]} "mkdir -p ${TEST_PATH}"
	#复制三项到客户机
	scp -r ${TEST_PATH}/* ${ACCOUNT}@${IP_list[${i}]}:${TEST_PATH}/
	sleep 10
done
for ((j = 1; j <= $bm_num; j++)); do
	ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}/logs"
	ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}/data"
done
echo "开始部署ConfigNode！"
for (( i = 1; i <= $config_num; i++ ))
do
	#修改IoTDB ConfigNode的配置
	ssh ${ACCOUNT}@${C_IP_list[${i}]} "echo \"cn_internal_address=${C_IP_list[${i}]}\" >> ${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties"
	ssh ${ACCOUNT}@${C_IP_list[${i}]} "echo \"cn_seed_config_node=${config_node_config_nodes[${i}]}\" >> ${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties"
	ssh ${ACCOUNT}@${C_IP_list[${i}]} "echo \"schema_replication_factor=${config_schema_replication_factor[${i}]}\" >> ${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties"
	ssh ${ACCOUNT}@${C_IP_list[${i}]} "echo \"data_replication_factor=${config_data_replication_factor[${i}]}\" >> ${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties"	
done
echo "开始部署DataNode！"
for (( i = 1; i <= $data_num; i++ ))
do
	#修改IoTDB DataNode的配置
	ssh ${ACCOUNT}@${D_IP_list[${i}]} "echo \"dn_rpc_address=${D_IP_list[${i}]}\" >> ${TEST_DATANODE_PATH}/conf/iotdb-system.properties"
	ssh ${ACCOUNT}@${D_IP_list[${i}]} "echo \"dn_internal_address=${D_IP_list[${i}]}\" >> ${TEST_DATANODE_PATH}/conf/iotdb-system.properties"
	ssh ${ACCOUNT}@${D_IP_list[${i}]} "echo \"dn_seed_config_node=${dcn_str}\" >> ${TEST_DATANODE_PATH}/conf/iotdb-system.properties"
done
#启动config_num个IoTDB ConfigNode节点
for (( j = 1; j <= $config_num; j++ ))
do
	echo "starting IoTDB ConfigNode on ${C_IP_list[${j}]} ..."
	pid3=$(ssh ${ACCOUNT}@${C_IP_list[${j}]} "${TEST_CONFIGNODE_PATH}/sbin/start-confignode.sh > /dev/null 2>&1 &")
	#主节点需要先启动，所以等待10秒是为了保证主节点启动完毕
	sleep 10
done
#启动data_num个IoTDB DataNode节点
for (( j = 1; j <= $data_num; j++ ))
do
	echo "starting IoTDB DataNode on ${D_IP_list[${j}]} ..."
	pid3=$(ssh ${ACCOUNT}@${D_IP_list[${j}]} "${TEST_DATANODE_PATH}/sbin/start-datanode.sh -H ${TEST_DATANODE_PATH}/dn_dump.hprof  > /dev/null 2>&1 &")
done
#等待60s，让服务器完成前期准备
sleep 60
#检查IoTDB ConfigNode节点
check_config_num=0
for (( j = 1; j <= $config_num; j++ ))
do
	for (( t_wait = 0; t_wait <= 3; t_wait++ ))
	do
	  str1=$(ssh ${ACCOUNT}@${C_IP_list[${j}]} "jps | grep -w ConfigNode | grep -v grep | wc -l")
	  if [ "$str1" = "1" ]; then
		echo "ConfigNode has been started on PC:${C_IP_list[${j}]}"
		check_config_num=$[${check_config_num}+1]
		break
	  else
		echo "ConfigNode has not been started on PC:${C_IP_list[${j}]}"
		sleep 30
		continue
	  fi
	done
done
#检查IoTDB DataNode节点
check_data_num=0
for (( j = 1; j <= $data_num; j++ ))
do
	for (( t_wait = 0; t_wait <= 3; t_wait++ ))
	do
	  str1=$(ssh ${ACCOUNT}@${D_IP_list[${j}]} "jps | grep -w DataNode | grep -v grep | wc -l")
	  if [ "$str1" = "1" ]; then
		echo "DataNode has been started on PC:${D_IP_list[${j}]}"
		check_data_num=$[${check_data_num}+1]
		break
	  else
		echo "DataNode has not been started on PC:${D_IP_list[${j}]}"
		sleep 30
		continue
	  fi
	done
done
#检查iotdb DataNode是否可连接节点
total_nodes=$(($config_num+$data_num))
for (( j = 1; j <= $data_num; j++ ))
do
	for (( t_wait = 0; t_wait <= 20; t_wait++ ))
	do
	  str1=$(ssh ${ACCOUNT}@${D_IP_list[${j}]} "${TEST_DATANODE_PATH}/sbin/start-cli.sh -h ${D_IP_list[${j}]} -p 6667 -e \"show cluster\" | grep 'Total line number = ${total_nodes}'")
	  if [ "$str1" = "Total line number = 8" ]; then
		echo "All Nodes is ready"
		flag=1
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
change_pwd=$(ssh ${ACCOUNT}@${D_IP_list[1]} "${TEST_DATANODE_PATH}/sbin/start-cli.sh -h ${D_IP_list[1]} -p 6667 -e \"ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'\"")
if [ "$check_config_num" == "$config_num" ] && [ "$check_data_num" == "$data_num" ]; then
	echo "All ${check_config_num} ConfigNodes and ${check_data_num} DataNodes have been started"
	#启动benchmark
	sleep 60
	if [ "$bm_num" != '' ];
	then
		for ((j = 1; j <= $bm_num; j++)); do
			ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}"
			scp -r ${BM_PATH} ${ACCOUNT}@${B_IP_list[${j}]}:${BM_PATH}
			ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}/conf/config.properties"
			scp -r ${BM_PATH}/conf/config.properties ${ACCOUNT}@${B_IP_list[${j}]}:${BM_PATH}/conf/config.properties
			#echo "启动BM： ${B_IP_list[${j}]} ..."
			ssh ${ACCOUNT}@${B_IP_list[${j}]} "cd ${BM_PATH};${BM_PATH}/benchmark.sh > /dev/null 2>&1 &" &
		done
		wait
		echo "All BMs have been started"
	fi	
fi
}

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
			ssh ${ACCOUNT}@${B_IP_list[1]} "rm -rf ${BM_PATH}/data/csvOutput"
			ssh ${ACCOUNT}@${B_IP_list[1]} "mkdir -p ${BM_PATH}/data/csvOutput"
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
		mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${insert_sql}"
		
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
			mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${insert_sql}"
		done
	fi
	
	sudo cp -rf ${BM_PATH}/TestResult/csvOutput/* ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/
	sudo scp -r ${ACCOUNT}@${B_IP_list[1]}:${BM_PATH}/logs ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/
}

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
	result_string=$(mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${update_sql}")
	update_sql02="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < '${commit_date_time}'"
	if [ "${author}" != "Timecho" ]; then
		result_string=$(mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${update_sql02}")
	fi
fi
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

main "$@"
