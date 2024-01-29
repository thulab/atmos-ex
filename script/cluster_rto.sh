#!/bin/sh
#登录用户名
ACCOUNT=atmos
test_type=cluster_rto
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
BUCKUP_PATH=/nasdata/repository/cluster_rto
REPOS_PATH=/nasdata/repository/master
#测试数据运行路径
TEST_PATH=/data/atmos/zk_test/first-rest-test
TEST_DATANODE_PATH=${TEST_PATH}/DN/apache-iotdb
TEST_CONFIGNODE_PATH=${TEST_PATH}/CN/apache-iotdb
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(111 223)
ts_list=(common aligned template tempaligned)

IP_list=(0 11.101.17.131 11.101.17.132 11.101.17.133)
D_IP_list=(0 11.101.17.131 11.101.17.132 11.101.17.133)
C_IP_list=(0 11.101.17.131 11.101.17.132 11.101.17.133)
B_IP_list=(0 11.101.17.130)
config_schema_replication_factor=(0 3 3 3 3 3 3)
config_data_replication_factor=(0 3 3 3 3 3 3)
config_node_config_nodes=(0 11.101.17.131:10710 11.101.17.131:10710 11.101.17.131:10710)
data_node_config_nodes=(0 11.101.17.131:10710 11.101.17.132:10710 11.101.17.133:10710)
Control=11.101.17.130

############mysql信息##########################
MYSQLHOSTNAME="111.202.73.147" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD="iotdb2019"
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_cluster_rto" #数据库中表的名称
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############公用函数##########################
#echo "Started at: " date -d today +"%Y-%m-%d %H:%M:%S"
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
ts_type=0
start_time=0
end_time=0
cost_time=0
rto_time=0
maxNumofOpenFiles=0
maxNumofThread=0
errorLogSize=0
############定义监控采集项初始值##########################
}
local_ip=`ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d "addr:"`
sendEmail() {
sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}
check_benchmark_pid() { # 检查benchmark的pid，有就停止
	monitor_pid=$(jps | grep App | awk '{print $1}')
	if [ "${monitor_pid}" = "" ]; then
		echo "未检测到监控程序！"
	else
		kill -9 ${monitor_pid}
		echo "BM程序已停止！"
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
set_env() { # 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_PATH}" ]; then
		mkdir -p ${TEST_PATH}
		mkdir -p ${TEST_PATH}/CN/apache-iotdb
		mkdir -p ${TEST_PATH}/DN/apache-iotdb
	else
		rm -rf ${TEST_PATH}
		mkdir -p ${TEST_PATH}
		mkdir -p ${TEST_PATH}/CN/apache-iotdb
		mkdir -p ${TEST_PATH}/DN/apache-iotdb
	fi
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_PATH}/CN/apache-iotdb/
	mkdir -p ${TEST_PATH}/CN/apache-iotdb/activation
	cp -rf ${ATMOS_PATH}/conf/${test_type}/license ${TEST_PATH}/CN/apache-iotdb/activation/
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_PATH}/DN/apache-iotdb/
}
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" ${TEST_DATANODE_PATH}/conf/datanode-env.sh
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"6G\"/g" ${TEST_CONFIGNODE_PATH}/conf/confignode-env.sh
	#关闭影响写入性能的其他功能
	sed -i "s/^# enable_seq_space_compaction=true.*$/enable_seq_space_compaction=false/g" ${TEST_DATANODE_PATH}/conf/iotdb-common.properties
	sed -i "s/^# enable_unseq_space_compaction=true.*$/enable_unseq_space_compaction=false/g" ${TEST_DATANODE_PATH}/conf/iotdb-common.properties
	sed -i "s/^# enable_cross_space_compaction=true.*$/enable_cross_space_compaction=false/g" ${TEST_DATANODE_PATH}/conf/iotdb-common.properties
	#修改集群名称
	sed -i "s/^cluster_name=.*$/cluster_name=Apache-IoTDB/g" ${TEST_DATANODE_PATH}/conf/iotdb-common.properties
	sed -i "s/^cluster_name=.*$/cluster_name=Apache-IoTDB/g" ${TEST_CONFIGNODE_PATH}/conf/iotdb-common.properties
	#修改Region数量
	sed -i "s/^# default_data_region_group_num_per_database=.*$/default_data_region_group_num_per_database=1/g" ${TEST_DATANODE_PATH}/conf/iotdb-common.properties
	sed -i "s/^# default_data_region_group_num_per_database=.*$/default_data_region_group_num_per_database=1/g" ${TEST_CONFIGNODE_PATH}/conf/iotdb-common.properties
	#添加启动监控功能
	sed -i "s/^# cn_enable_metric=.*$/cn_enable_metric=true/g" ${TEST_CONFIGNODE_PATH}/conf/iotdb-confignode.properties
	sed -i "s/^# cn_enable_performance_stat=.*$/cn_enable_performance_stat=true/g" ${TEST_CONFIGNODE_PATH}/conf/iotdb-confignode.properties
	sed -i "s/^# cn_metric_reporter_list=.*$/cn_metric_reporter_list=PROMETHEUS/g" ${TEST_CONFIGNODE_PATH}/conf/iotdb-confignode.properties
	sed -i "s/^# cn_metric_level=.*$/cn_metric_level=ALL/g" ${TEST_CONFIGNODE_PATH}/conf/iotdb-confignode.properties
	sed -i "s/^# cn_metric_prometheus_reporter_port=.*$/cn_metric_prometheus_reporter_port=9081/g" ${TEST_CONFIGNODE_PATH}/conf/iotdb-confignode.properties
	#添加启动监控功能
	sed -i "s/^# dn_enable_metric=.*$/dn_enable_metric=true/g" ${TEST_DATANODE_PATH}/conf/iotdb-datanode.properties
	sed -i "s/^# dn_enable_performance_stat=.*$/dn_enable_performance_stat=true/g" ${TEST_DATANODE_PATH}/conf/iotdb-datanode.properties
	sed -i "s/^# dn_metric_reporter_list=.*$/dn_metric_reporter_list=PROMETHEUS/g" ${TEST_DATANODE_PATH}/conf/iotdb-datanode.properties
	sed -i "s/^# dn_metric_level=.*$/dn_metric_level=ALL/g" ${TEST_DATANODE_PATH}/conf/iotdb-datanode.properties
	sed -i "s/^dn_metric_prometheus_reporter_port=.*$/dn_metric_prometheus_reporter_port=9091/g" ${TEST_DATANODE_PATH}/conf/iotdb-datanode.properties
}
set_protocol_class() { 
	config_node=$1
	schema_region=$2
	data_region=$3
	#设置协议
	sed -i "s/^# config_node_consensus_protocol_class=.*$/config_node_consensus_protocol_class=${protocol_class[${config_node}]}/g" ${TEST_DATANODE_PATH}/conf/iotdb-common.properties
	sed -i "s/^# schema_region_consensus_protocol_class=.*$/schema_region_consensus_protocol_class=${protocol_class[${schema_region}]}/g" ${TEST_DATANODE_PATH}/conf/iotdb-common.properties
	sed -i "s/^# data_region_consensus_protocol_class=.*$/data_region_consensus_protocol_class=${protocol_class[${data_region}]}/g" ${TEST_DATANODE_PATH}/conf/iotdb-common.properties
	#设置协议
	sed -i "s/^# config_node_consensus_protocol_class=.*$/config_node_consensus_protocol_class=${protocol_class[${config_node}]}/g" ${TEST_CONFIGNODE_PATH}/conf/iotdb-common.properties
	sed -i "s/^# schema_region_consensus_protocol_class=.*$/schema_region_consensus_protocol_class=${protocol_class[${schema_region}]}/g" ${TEST_CONFIGNODE_PATH}/conf/iotdb-common.properties
	sed -i "s/^# data_region_consensus_protocol_class=.*$/data_region_consensus_protocol_class=${protocol_class[${data_region}]}/g" ${TEST_CONFIGNODE_PATH}/conf/iotdb-common.properties
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
	sleep 60
	echo "setting env to ${IP_list[${i}]} ..."
	#删除原有路径下所有
	ssh ${ACCOUNT}@${IP_list[${i}]} "rm -rf ${TEST_PATH}"
	ssh ${ACCOUNT}@${IP_list[${i}]} "mkdir -p ${TEST_PATH}"
	#复制三项到客户机
	scp -r ${TEST_PATH}/* ${ACCOUNT}@${IP_list[${i}]}:${TEST_PATH}/
done
for ((j = 1; j <= $bm_num; j++)); do
	ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}/logs"
	ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}/data"
done
echo "开始部署ConfigNode！"
for (( i = 1; i <= $config_num; i++ ))
do
	#修改IoTDB ConfigNode的配置
	ssh ${ACCOUNT}@${C_IP_list[${i}]} "sed -i \"s/^cn_internal_address.*$/cn_internal_address=${C_IP_list[${i}]}/g\" ${TEST_CONFIGNODE_PATH}/conf/iotdb-confignode.properties"
	ssh ${ACCOUNT}@${C_IP_list[${i}]} "sed -i \"s/^cn_seed_config_node.*$/cn_seed_config_node=${config_node_config_nodes[${i}]}/g\" ${TEST_CONFIGNODE_PATH}/conf/iotdb-confignode.properties"
	ssh ${ACCOUNT}@${C_IP_list[${i}]} "sed -i \"s/^schema_replication_factor.*$/schema_replication_factor=${config_schema_replication_factor[${i}]}/g\" ${TEST_CONFIGNODE_PATH}/conf/iotdb-common.properties"
	ssh ${ACCOUNT}@${C_IP_list[${i}]} "sed -i \"s/^data_replication_factor.*$/data_replication_factor=${config_data_replication_factor[${i}]}/g\" ${TEST_CONFIGNODE_PATH}/conf/iotdb-common.properties"
done
echo "开始部署DataNode！"
for (( i = 1; i <= $data_num; i++ ))
do
	#修改IoTDB DataNode的配置
	ssh ${ACCOUNT}@${D_IP_list[${i}]} "sed -i \"s/^dn_rpc_address.*$/dn_rpc_address=${D_IP_list[${i}]}/g\" ${TEST_DATANODE_PATH}/conf/iotdb-datanode.properties"
	ssh ${ACCOUNT}@${D_IP_list[${i}]} "sed -i \"s/^dn_internal_address.*$/dn_internal_address=${D_IP_list[${i}]}/g\" ${TEST_DATANODE_PATH}/conf/iotdb-datanode.properties"
	ssh ${ACCOUNT}@${D_IP_list[${i}]} "sed -i \"s/^dn_seed_config_node.*$/dn_seed_config_node=${dcn_str}/g\" ${TEST_DATANODE_PATH}/conf/iotdb-datanode.properties"
done
#启动config_num个IoTDB ConfigNode节点
for (( j = 1; j <= $config_num; j++ ))
do
	echo "starting IoTDB ConfigNode on ${C_IP_list[${j}]} ..."
	pid3=$(ssh ${ACCOUNT}@${C_IP_list[${j}]} "${TEST_CONFIGNODE_PATH}/sbin/start-confignode.sh  > /dev/null 2>&1 &")
	#主节点需要先启动，所以等待10秒是为了保证主节点启动完毕
	sleep 10
done
#启动data_num个IoTDB DataNode节点
for (( j = 1; j <= $data_num; j++ ))
do
	echo "starting IoTDB DataNode on ${D_IP_list[${j}]} ..."
	pid3=$(ssh ${ACCOUNT}@${D_IP_list[${j}]} "${TEST_DATANODE_PATH}/sbin/start-datanode.sh   > /dev/null 2>&1 &")
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
	  str1=$(ssh ${ACCOUNT}@${D_IP_list[${j}]} "${TEST_DATANODE_PATH}/sbin/start-cli.sh -h ${D_IP_list[1]} -p 6667 -u root -pw root -e \"show cluster\" | grep 'Total line number = ${total_nodes}'")
	  if [ "$str1" = "Total line number = 6" ]; then
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
if [ "$check_config_num" == "$config_num" ] && [ "$check_data_num" == "$data_num" ]; then
	echo "All ${check_config_num} ConfigNodes and ${check_data_num} DataNodes have been started"
	#启动benchmark
	if [ "$bm_num" != '' ];
	then
		for ((j = 1; j <= $bm_num; j++)); do
			ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}/logs"
			ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}/data"
			ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}/conf/config.properties"
			scp -r ${BM_PATH}/conf/config.properties ${ACCOUNT}@${B_IP_list[${j}]}:${BM_PATH}/conf/config.properties
			#echo "启动BM： ${B_IP_list[${j}]} ..."
			ssh ${ACCOUNT}@${B_IP_list[${j}]} "cd ${BM_PATH};${BM_PATH}/benchmark.sh > /dev/null 2>&1 &" &
		done
		wait
		echo "All BMs have been started"
	fi	
	sleep 60
fi
#获取Leader节点IP
Leader_IP=$(ssh ${ACCOUNT}@${D_IP_list[1]} "${TEST_DATANODE_PATH}/sbin/start-cli.sh -h ${D_IP_list[1]} -p 6667 -u root -pw root -e \"show data regions of database root.test.g_0\" | grep 'Leader' | awk -F\| '{print $9}'")
for (( i = 1; i < ${#D_IP_list[*]}; i++ ))
do
	if [ "$D_IP_list[${i}]" != "$Leader_IP" ]; then
		mv_config_file ${ts_type} ${data_type}
		sed -i "s/^HOST=.*$/HOST=$D_IP_list[${i}]/g" ${BM_PATH}/conf/config.properties
		break
	fi
done
if [ "$check_config_num" == "$config_num" ] && [ "$check_data_num" == "$data_num" ]; then
	echo "All ${check_config_num} ConfigNodes and ${check_data_num} DataNodes have been started"
	#启动benchmark
	sleep 10
	if [ "$bm_num" != '' ];
	then
		for ((j = 1; j <= $bm_num; j++)); do
			ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}/logs"
			ssh ${ACCOUNT}@${B_IP_list[${j}]} "rm -rf ${BM_PATH}/data"
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
	maxNumofOpenFiles=(0 0 0 0)
	maxNumofThread=(0 0 0 0)
	while true; do
		for (( j = 1; j <= 3; j++ ))
		do
			temp_file_num_d=0
			temp_thread_num_d=0
			temp_file_num_c=0
			temp_thread_num_c=0
			dn_pid=$(ssh ${ACCOUNT}@${D_IP_list[${j}]} "jps | grep DataNode | awk '{print $1}'")
			cn_pid=$(ssh ${ACCOUNT}@${C_IP_list[${j}]} "jps | grep ConfigNode | awk '{print $1}'")
			if [ "$dn_pid" = "" ] && [ "${cn_pid}" = "" ]; then
				temp_file_num_d=0
				temp_thread_num_d=0
				temp_file_num_c=0
				temp_thread_num_c=0
			elif [ "$dn_pid" = "" ] && [ "${cn_pid}" != "" ]; then
				temp_file_num_d=0
				temp_thread_num_d=0
				temp_thread_num_c=$(ssh ${ACCOUNT}@${C_IP_list[${j}]} "pstree -p \$(ps aux | grep -v grep | grep ConfigNode | awk '{print \$2}') | wc -l" 2>/dev/null)
				temp_file_num_c=$(ssh ${ACCOUNT}@${C_IP_list[${j}]} "ps aux | grep -v grep | grep ConfigNode | awk '{print \$2}' | xargs /usr/sbin/lsof -p | wc -l" 2>/dev/null)
			elif [ "$dn_pid" != "" ] && [ "${cn_pid}" = "" ]; then
				temp_thread_num_d=$(ssh ${ACCOUNT}@${D_IP_list[${j}]} "pstree -p \$(ps aux | grep -v grep | grep DataNode | awk '{print \$2}') | wc -l" 2>/dev/null)
				temp_file_num_d=$(ssh ${ACCOUNT}@${D_IP_list[${j}]} "ps aux | grep -v grep | grep DataNode | awk '{print \$2}' | xargs /usr/sbin/lsof -p | wc -l" 2>/dev/null)
				temp_file_num_c=0
				temp_thread_num_c=0
			elif [ "$dn_pid" != "" ] && [ "${cn_pid}" != "" ]; then
				temp_thread_num_d=$(ssh ${ACCOUNT}@${D_IP_list[${j}]} "pstree -p \$(ps aux | grep -v grep | grep DataNode | awk '{print \$2}') | wc -l" 2>/dev/null)
				temp_file_num_d=$(ssh ${ACCOUNT}@${D_IP_list[${j}]} "ps aux | grep -v grep | grep DataNode | awk '{print \$2}' | xargs /usr/sbin/lsof -p | wc -l" 2>/dev/null)
				temp_thread_num_c=$(ssh ${ACCOUNT}@${C_IP_list[${j}]} "pstree -p \$(ps aux | grep -v grep | grep ConfigNode | awk '{print \$2}') | wc -l" 2>/dev/null)
				temp_file_num_c=$(ssh ${ACCOUNT}@${C_IP_list[${j}]} "ps aux | grep -v grep | grep ConfigNode | awk '{print \$2}' | xargs /usr/sbin/lsof -p | wc -l" 2>/dev/null)
			else
				echo "无法计算！"
			fi		
			#监控打开文件数量			
			let temp_file_num=${temp_file_num_d}+${temp_file_num_c}
			if [ ${maxNumofOpenFiles[${j}]} -lt ${temp_file_num} ]; then
				maxNumofOpenFiles[${j}]=${temp_file_num}
			fi
			#监控线程数
			let temp_thread_num=${temp_thread_num_d}+${temp_thread_num_c}
			if [ ${maxNumofThread[${j}]} -lt ${temp_thread_num} ]; then
				maxNumofThread[${j}]=${temp_thread_num}
			fi
		done
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
		if [ $t_time -ge 600 ]; then
			ssh ${ACCOUNT}@${Leader_IP} "sudo reboot"
		fi
		if [ $t_time -ge 7200 ]; then
			echo "测试失败"  #倒序输入形成负数结果
			end_time=-1
			cost_time=-1
			break
		fi
		if [ "$flag" = "1" ]; then
			end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			break
		fi
	done
}
collect_monitor_data() { # 收集iotdb数据大小，顺、乱序文件数量
	TEST_IP=$1
	dataFileSize=0
	dataFileSize=$(ssh ${ACCOUNT}@${D_IP_list[${TEST_IP}]} "du -h -d0 ${TEST_DATANODE_PATH}/data/datanode/data | awk {'print \$1'} | awk '{sub(/.$/,\"\")}1'")
	UNIT=$(ssh ${ACCOUNT}@${D_IP_list[${TEST_IP}]} "du -h -d0 ${TEST_DATANODE_PATH}/data/datanode/data | awk {'print \$1'} | awk -F '' '\$0=\$NF'")
	if [ "$UNIT" = "M" ]; then
		dataFileSize=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize'/'1024'}'`
	elif [ "$UNIT" = "K" ]; then
		dataFileSize=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize'/'1048576'}'`
    elif [ "$UNIT" = "T" ]; then
        dataFileSize=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize'*'1024'}'`
	else
		dataFileSize=${dataFileSize}
	fi	
	numOfSe0Level=0
	numOfUnse0Level=0
	numOfSe0Level=$(ssh ${ACCOUNT}@${D_IP_list[${TEST_IP}]} "find ${TEST_DATANODE_PATH}/data/datanode/data/sequence -name "*.tsfile" | wc -l")
	numOfUnse0Level=$(ssh ${ACCOUNT}@${D_IP_list[${TEST_IP}]} "find ${TEST_DATANODE_PATH}/data/datanode/data/unsequence -name "*.tsfile" | wc -l")
}
backup_test_data() { # 备份测试数据
	sudo mkdir -p ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
    sudo rm -rf ${TEST_DATANODE_PATH}/data
	sudo mv ${TEST_DATANODE_PATH} ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo cp -rf ${BM_PATH}/data/csvOutput ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
}
mv_config_file() { # 移动配置文件
	rm -rf ${BM_PATH}/conf/config.properties
	cp -rf ${ATMOS_PATH}/conf/${test_type}/$1/$2 ${BM_PATH}/conf/config.properties
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
	else
		echo "协议设置错误！"
		return
	fi

	mv_config_file ${ts_type} ${data_type}
	sed -i "s/^HOST=.*$/HOST=$D_IP_list[1]/g" ${BM_PATH}/conf/config.properties
	sed -i "s/^LOOP=.*$/LOOP=1/g" ${BM_PATH}/conf/config.properties

	setup_nCmD -c3 -d3 -t1
		
	echo "测试开始！"
	start_time=`date -d today +"%Y-%m-%d %H:%M:%S"`

	#等待1分钟
	sleep 60
	monitor_test_status
	#测试结果收集写入数据库
	rm -rf ${BM_PATH}/TestResult/csvOutput/*
	scp -r ${ACCOUNT}@${B_IP_list[1]}:${BM_PATH}/data/csvOutput/*result.csv ${BM_PATH}/TestResult/csvOutput/
	for ((j = 1; j <= 3; j++)); do
		#收集启动后基础监控数据
		collect_monitor_data ${j}
		csvOutputfile=${BM_PATH}/TestResult/csvOutput/*result.csv
		read okOperation okPoint failOperation failPoint throughput <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '1,1p' | awk -F, '{print $2,$3,$4,$5,$6}')
		read Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '2,2p' | awk -F, '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
		#cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		node_id=${j}
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,node_id,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${node_id},'${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles[${j}]},${maxNumofThread[${j}]},'${data_type}')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
		
		sudo mkdir -p ${BUCKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}/${j}/CN
		sudo mkdir -p ${BUCKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}/${j}/DN
		ssh ${ACCOUNT}@${C_IP_list[${j}]} "sudo cp -rf ${TEST_CONFIGNODE_PATH}/logs ${BUCKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}/${j}/CN"
		ssh ${ACCOUNT}@${D_IP_list[${j}]} "sudo cp -rf ${TEST_DATANODE_PATH}/logs ${BUCKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}/${j}/DN"
	done
	sudo cp -rf ${BM_PATH}/TestResult/csvOutput/* ${BUCKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}/
}

##准备开始测试
echo "ontesting" > ${INIT_PATH}/test_type_file
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${test_type} is NULL ORDER BY commit_date_time desc limit 1 "
result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
if [ "${commit_id}" = "" ]; then
	sleep 60s
else
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'ontesting' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
	echo "当前版本${commit_id}未执行过测试，即将编译后启动"
	init_items
	test_date_time=`date +%Y%m%d%H%M%S`
	###############################普通时间序列###############################
	echo "开始测试普通时间序列顺序写入！"
	test_operation common seq_w 223
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
fi
echo "${test_type}" > ${INIT_PATH}/test_type_file