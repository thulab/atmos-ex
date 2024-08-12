#!/bin/bash
#登录用户名
ACCOUNT=cluster
test_type=native_api_test
#初始环境存放路径
INIT_PATH=/home/cluster/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
IOTDB_PATH=${INIT_PATH}/iotdb
TOOL_PATH=${INIT_PATH}/java-native-api-testcase
BK_PATH=${INIT_PATH}/native_api_test_report
#测试数据运行路径
TEST_INIT_PATH=/data/qa
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
TEST_DATANODE_PATH=${TEST_INIT_PATH}/apache-iotdb
TEST_TOOL_PATH=${TEST_INIT_PATH}/java-native-api-testcase
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
PASSWORD="iotdb2019"
DBNAME="QA_ATM"                   #数据库名称
TABLENAME="java_native_api_test" #数据库中表的名称
############公用函数##########################
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
tests_num=0
errors_num=0
failures_num=0
skipped_num=0
successRate=0
cost_time=0
start_time=0
end_time=0
flag=0
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
set_env() { 
	# 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_IOTDB_PATH}" ]; then
		mkdir -p ${TEST_IOTDB_PATH}
	else
		rm -rf ${TEST_IOTDB_PATH}
		mkdir -p ${TEST_IOTDB_PATH}
	fi
	cp -rf ${IOTDB_PATH}/distribution/target/apache-iotdb-*-all-bin/apache-iotdb-*-all-bin/* ${TEST_IOTDB_PATH}/
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
modify_iotdb_config() { # iotdb调整内存，开启MQTT
	#修改IoTDB的配置
	sed -i "s/^#MAX_HEAP_SIZE=\"2G\".*$/MAX_HEAP_SIZE=\"6G\"/g" ${TEST_DATANODE_PATH}/conf/datanode-env.sh
}
check_monitor_pid() { # 检查benchmark-moitor的pid，有就停止
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
start_iotdb() { # 启动iotdb
	cd ${TEST_DATANODE_PATH}
	conf_start=$(./sbin/start-confignode.sh >/dev/null 2>&1 &)
	sleep 10
	data_start=$(./sbin/start-datanode.sh >/dev/null 2>&1 &)
	cd ~/
}
while true; do
	init_items
	# 获取git commit对比判定是否启动测试
	cd ${TOOL_PATH}
	last_cid1=$(git log --pretty=format:"%h" -1)
	#更新TC
	git_pull=$(timeout 100s git pull)
	# 获取更新后git commit对比判定是否启动测试
	commit_id1=$(git log --pretty=format:"%h" -1)
	#对比判定是否启动测试
	cd ${IOTDB_PATH}
	#git reset --hard 938c1f19df122ffaafd827a00a65f5931cbc7f4c
	last_cid=$(git log --pretty=format:"%h" -1)
	#last_cid=0
	#更新iotdb代码
	git_pull=$(timeout 100s git fetch --all)
	git_pull=$(git reset --hard origin/master)
	git_pull=$(timeout 100s git pull)
	# 获取更新后git commit对比判定是否启动测试
	commit_id=$(git log --pretty=format:"%h" -1)
	#对比判定是否启动测试	
	if [ "${last_cid}" = "${commit_id}" ] && [ "${last_cid1}" = "${commit_id1}" ]; then
		echo "无代码更新，当前版本${commit_id}已经执行过测试"
		sleep 300s
		continue
	else
		echo "当前版本${commit_id}未执行过测试，即将编译后启动"
		test_date_time=$(date +%Y%m%d%H%M%S)
		#代码编译
		comp_mvn=$(timeout 7200s mvn clean install -DskipTests)
		#comp_mvn=$(timeout 300s mvn clean package -pl distribution -am -DskipTests)
		if [ $? -eq 0 ]
		then
			echo "编译完成，准备开始测试！"
		else
			echo "编译失败，写入负值测试结果！"
			tests_num=-1
			errors_num=-1
			failures_num=-1
			skipped_num=-1
			successRate=-1
			insert_sql="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'master')"
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
			sleep 600
			continue
		fi
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
		# 拷贝测试依赖到各自文件夹
		cd ${TEST_TOOL_PATH}
		compile=$(timeout 300s mvn clean package -DskipTests)
		if [ $? -eq 0 ]
		then
			echo "编译完成，准备开始测试！"
		else
			echo "编译失败，写入负值测试结果！"
			tests_num=-2
			errors_num=-2
			failures_num=-2
			skipped_num=-2
			successRate=-2
			insert_sql="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'master')"
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
			sleep 600
			continue
		fi
		start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		start_test=$(nohup mvn surefire-report:report > /dev/null 2>&1 &)
		echo "开始监控。。。"
		for (( t_wait = 0; t_wait <= 20; ))
		do
			cd ${TEST_TOOL_PATH}
			result_file=${TEST_TOOL_PATH}/details/target/site/surefire-report.html 
			if [ ! -f "$result_file" ]; then
				now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
				t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
				if [ $t_time -ge 14400 ]; then
					echo "测试失败"
					flag=1
					break
				fi
				continue
			else
				echo "测试完成"
				break
			fi
		done
		end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		#停止IoTDB程序
		check_iotdb_pid
		if [ $flag -eq 0 ]; then
			#收集测试结果
			cd ${TEST_TOOL_PATH}
			tests_num=$(sed -n '75,75p' ${TEST_TOOL_PATH}/details/target/site/surefire-report.html | awk -F\> '{print $2}' | awk -F\< '{print $1}')
			errors_num=$(sed -n '76,76p' ${TEST_TOOL_PATH}/details/target/site/surefire-report.html | awk -F\> '{print $2}' | awk -F\< '{print $1}')
			failures_num=$(sed -n '77,77p' ${TEST_TOOL_PATH}/details/target/site/surefire-report.html | awk -F\> '{print $2}' | awk -F\< '{print $1}')
			skipped_num=$(sed -n '78,78p' ${TEST_TOOL_PATH}/details/target/site/surefire-report.html | awk -F\> '{print $2}' | awk -F\< '{print $1}')
			successRate=$(sed -n '79,79p' ${TEST_TOOL_PATH}/details/target/site/surefire-report.html | awk -F\> '{print $2}' | awk -F\% '{print $1}')
			#结果写入mysql
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			insert_sql="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'master')"
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
		else
			#收集测试结果
			cd ${TEST_TOOL_PATH}
			tests_num=-3
			errors_num=-3
			failures_num=-3
			skipped_num=-3
			successRate=-3
			#结果写入mysql
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			insert_sql="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'master')"
			#echo "${insert_sql}"
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
		fi
		#备份本次测试
		#backup_test_data
		rm -rf ${BK_PATH}/site
		cp -rf ${TEST_TOOL_PATH}/details/target/site ${BK_PATH}/
		cd ${BK_PATH}/
		git add .
		git commit -m ${last_cid}_${failures_num}
		git push -f
		###############################测试完成###############################
		echo "本轮测试${test_date_time}已结束."
		#清理过期文件 - 当前策略保留4天
		#find ${BUCKUP_PATH}/ -mtime +4 -type d -name "*" -exec rm -rf {} \;
	fi
done
