#!/bin/bash
#登录用户名
ACCOUNT=root
test_type=python_api
#初始环境存放路径
INIT_PATH=/root/zk_test
IOTDB_PATH=${INIT_PATH}/iotdb
ATMOS_PATH=${INIT_PATH}/atmos-ex
#测试数据运行路径
TEST_INIT_PATH=/root
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
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
TABLENAME="python_api" #数据库中表的名称
############公用函数##########################
if [ "${PASSWORD}" = "" ]; then
echo "需要关注密码设置！"
fi
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
InsertRecord=0
InsertRecords=0
InsertTablet=0
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
}
modify_iotdb_config() { # iotdb调整内存，开启MQTT
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"2G\"/g" ${TEST_IOTDB_PATH}/conf/datanode-env.sh
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
	cd ${TEST_IOTDB_PATH}
	conf_start=$(./sbin/start-confignode.sh >/dev/null 2>&1 &)
	sleep 10
	data_start=$(./sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof >/dev/null 2>&1 &)
	cd ~/
}
while true; do
	init_items
	# 获取git commit对比判定是否启动测试
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
		rm -rf ${INIT_PATH}/log_python_api
		#代码编译
		comp_mvn=$(timeout 3000s mvn clean package -pl distribution -am -DskipTests)
		if [ $? -eq 0 ]
		then
			echo "编译完成，准备开始测试！"
		else
			echo "编译失败，写入负值测试结果！"
			InsertRecord=-1
			InsertRecords=-1
			InsertTablet=-1
			insert_sql="insert into ${TABLENAME} (test_date_time,commit_id,InsertRecord,InsertRecords,InsertTablet,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id}',${InsertRecord},${InsertRecords},${InsertTablet},'${start_time}','${end_time}',${cost_time},'master')"
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
			sleep 600
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
		echo "开始监控。。。"
		for (( t_wait = 0; t_wait <= 20; ))
		do
			#监控执行情况  
			ts_status=$(cat ${INIT_PATH}/log_python_api | grep 'All executions done!!'| wc -l)
			if [ ${ts_status} -le 0 ]; then
				now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
				t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
				if [ $t_time -ge 7200 ]; then
					echo "测试失败"  #倒序输入形成负数结果
					end_time=-1
					cost_time=-100
					flag=1
					break
				fi
				continue
			else
				echo "测试已完成"
				break
			fi
		done
		end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		#停止IoTDB程序
		check_iotdb_pid
		if [ $flag -eq 0 ]; then
			#收集测试结果
			cd ${TEST_TOOL_PATH}
			InsertRecord=$(find ${INIT_PATH}/* -name log_python_api | xargs grep "InsertRecord " | awk '{print $5}')
			InsertRecords=$(find ${INIT_PATH}/* -name log_python_api | xargs grep "InsertRecords " | awk '{print $5}')
			InsertTablet=$(find ${INIT_PATH}/* -name log_python_api | xargs grep "InsertTablet " | awk '{print $7}')
			#结果写入mysql
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			insert_sql="insert into ${TABLENAME} (test_date_time,commit_id,InsertRecord,InsertRecords,InsertTablet,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id}',${InsertRecord},${InsertRecords},${InsertTablet},'${start_time}','${end_time}',${cost_time},'master')"
			echo ${insert_sql}
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
		else
			#收集测试结果
			cd ${TEST_TOOL_PATH}
			InsertRecord=-3
			InsertRecords=-3
			InsertTablet=-3
			#结果写入mysql
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			insert_sql="insert into ${TABLENAME} (test_date_time,commit_id,InsertRecord,InsertRecords,InsertTablet,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id}',${InsertRecord},${InsertRecords},${InsertTablet},'${start_time}','${end_time}',${cost_time},'master')"
			#echo "${insert_sql}"
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
		fi
		#备份本次测试
		#backup_test_data
		###############################测试完成###############################
		echo "本轮测试${test_date_time}已结束."
		#清理过期文件 - 当前策略保留4天
		#find ${BUCKUP_PATH}/ -mtime +4 -type d -name "*" -exec rm -rf {} \;
	fi
done