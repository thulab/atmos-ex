#!/bin/bash
#登录用户名
ACCOUNT=root
test_type=native_api_test
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
IOTDB_PATH=${INIT_PATH}/iotdb
JAVA_TOOL_PATH=${INIT_PATH}/java-native-api-testcase
CPP_TOOL_PATH=${INIT_PATH}/cpp-native-api-testcase
PYTHON_TOOL_PATH=${INIT_PATH}/python-native-api-testcase
BK_PATH=${INIT_PATH}/native_api_test_report
#测试数据运行路径
TEST_INIT_PATH=/data/qa
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
TEST_DATANODE_PATH=${TEST_INIT_PATH}/apache-iotdb
TEST_JAVA_TOOL_PATH=${TEST_INIT_PATH}/java-native-api-testcase
TEST_CPP_TOOL_PATH=${TEST_INIT_PATH}/cpp-native-api-testcase
TEST_PYTHON_TOOL_PATH=${TEST_INIT_PATH}/python-native-api-testcase
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
TABLENAME="native_api_test" #数据库中用例表的名称
############公用函数##########################
if [ "${PASSWORD}" = "" ]; then
	echo "需要关注密码设置！"
fi

init_items() {
############定义监控采集项初始值##########################
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
set_iotdb_env() {
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
	data_start=$(./sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof >/dev/null 2>&1 &)
	cd ~/
}
compile_iotdb() {  # 编译IoTDB
  #代码编译
  cd ${IOTDB_PATH}
  comp_mvn=$(timeout 7200s mvn clean install -DskipTests)
  #comp_mvn=$(timeout 300s mvn clean package -pl distribution -am -DskipTests)
  if [ $? -eq 0 ]
  then
    echo "编译IoTDB完成，准备开始测试！"
  	return 0
  else
		for (( j = 1; j <= 5; j++ ))
		do
			comp_mvn=$(timeout 7200s mvn clean install -DskipTests)
			if [ $? -eq 0 ]
			then
				echo "编译IoTDB完成，准备开始测试！"
				return 0
				break
			else
				echo "第"$j"次尝试编译IoTDB失败"
				if [ $j -eq 5 ]; then
					echo "已经尝试5次编译IoTDB失败，写入负值测试结果！"
					return 1
					break
				fi
			fi
		done
  fi
}
test_java_native_api_test() { # 测试Java原生接口
	# 拷贝Java工具到测试路径
	if [ ! -d "${TEST_JAVA_TOOL_PATH}" ]; then
		mkdir -p ${TEST_JAVA_TOOL_PATH}
	else
		rm -rf ${TEST_JAVA_TOOL_PATH}
		mkdir -p ${TEST_JAVA_TOOL_PATH}
	fi
	cp -rf ${JAVA_TOOL_PATH}/* ${TEST_JAVA_TOOL_PATH}/
	# 编译工具
	cd ${TEST_JAVA_TOOL_PATH}
	compile=$(timeout 300s mvn clean package -DskipTests)
	if [ $? -eq 0 ]
	then
		echo "编译Java原生接口工具完成，准备开始测试！"
	else
		echo "编译Java原生接口工具失败，写入负值测试结果！"
		tests_num=-2
		errors_num=-2
		failures_num=-2
		skipped_num=-2
		successRate=-2
		insert_sql_java="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'JAVA')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_java}"
		return 1
	fi
	echo "开始测试Java原生接口"
	start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	start_test=$(nohup mvn surefire-report:report > /dev/null 2>&1 &)
	for (( t_wait = 0; t_wait <= 20; ))
	do
		cd ${TEST_JAVA_TOOL_PATH}
		result_file=${TEST_JAVA_TOOL_PATH}/details/target/site/surefire-report.html
		if [ ! -f "$result_file" ]; then
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 14400 ]; then
				echo "Java原生接口测试失败"
				flag=1
				break
			fi
			continue
		else
			echo "Java原生接口测试完成"
			break
		fi
	done
	end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	# 防止测试报告文档内容还未生成完全，导致脚本获取空值
	sleep 60
	if [ $flag -eq 0 ]; then
		#收集测试结果
		cd ${TEST_JAVA_TOOL_PATH}
		# 从HTML报告中提取Java测试结果
		tests_num=$(grep -o '<td align="left">[0-9]*</td>' ${TEST_JAVA_TOOL_PATH}/details/target/site/surefire-report.html | sed -n '1p' | grep -o '[0-9]*')
		errors_num=$(grep -o '<td align="left">[0-9]*</td>' ${TEST_JAVA_TOOL_PATH}/details/target/site/surefire-report.html | sed -n '2p' | grep -o '[0-9]*')
		failures_num=$(grep -o '<td align="left">[0-9]*</td>' ${TEST_JAVA_TOOL_PATH}/details/target/site/surefire-report.html | sed -n '3p' | grep -o '[0-9]*')
		skipped_num=$(grep -o '<td align="left">[0-9]*</td>' ${TEST_JAVA_TOOL_PATH}/details/target/site/surefire-report.html | sed -n '4p' | grep -o '[0-9]*')
		successRate=$(grep -o '<td align="left">[0-9]*%</td>' ${TEST_JAVA_TOOL_PATH}/details/target/site/surefire-report.html | sed -n '1p' | grep -o '[0-9]*%')
		successRate=${successRate//%/}
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_java="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'JAVA')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_java}"
		if [ $? -ne 0 ]; then
			echo "执行mysql命令失败"
			#收集测试结果
			tests_num=-4
			errors_num=-4
			failures_num=-4
			skipped_num=-4
			successRate=-4
			#结果写入mysql
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			sql=$(cat <<EOF
			insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark,insert_sql) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'JAVA',"${insert_sql_java}")
EOF
			)
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "$sql"
      echo "备份Java原生接口测试报告"
      mkdir -p /data/qa/backup/java/${last_cid_iotdb}_${failures_num}
      cp -rf  ${TEST_JAVA_TOOL_PATH}/details/target/site /data/qa/backup/java/${last_cid_iotdb}_${failures_num}
			return 1
		fi
	else
		#收集测试结果
		cd ${TEST_JAVA_TOOL_PATH}
		tests_num=-3
		errors_num=-3
		failures_num=-3
		skipped_num=-3
		successRate=-3
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_java="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'JAVA')"
		#echo "${insert_sql_java}"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_java}"
	fi
	#备份本次测试
	echo "备份Java原生接口测试报告"
	#backup_test_data
	rm -rf ${BK_PATH}/java/*
	cp -rf ${TEST_JAVA_TOOL_PATH}/details/target/site ${BK_PATH}/java
	#if [ $failures_num -gt 0 ]; then
	mkdir -p /data/qa/backup/${last_cid_iotdb}_${failures_num}
	cp -rf  ${TEST_IOTDB_PATH}/logs /data/qa/backup/${last_cid_iotdb}_${failures_num}
	find /data/qa/backup/ -mtime +7 -type d -name "*" -exec rm -rf {} \;
	cd ${BK_PATH}/java
	#git add .
	#git commit -m ${last_cid_iotdb}_${failures_num}
	#git push -f
}
test_cpp_native_api_test() {
	# C++代码编译
	echo "编译C++客户端"
	cd ${IOTDB_PATH}
	comp_cpp=$(timeout 7200s  bash -c "source /etc/profile &&  ./mvnw clean package -pl example/client-cpp-example -am -DskipTests -P with-cpp -Diotdb-tools-thrift.version=0.14.1.1-glibc223-SNAPSHOT")
	if [ $? -eq 0 ]; then
		echo "编译C++客户端完成，准备开始测试！"
	else
		echo "编译C++客户端失败，写入负值测试结果！"
		tests_num=-2
		errors_num=-2
		failures_num=-2
		skipped_num=-2
		successRate=-2
		insert_sql_cpp="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_cpp}"
		ruturn 1
	fi
	# 拷贝Cpp工具到测试路径
	if [ ! -d "${TEST_CPP_TOOL_PATH}" ]; then
		mkdir -p ${TEST_CPP_TOOL_PATH}
	else
		rm -rf ${TEST_CPP_TOOL_PATH}
		mkdir -p ${TEST_CPP_TOOL_PATH}
	fi
	cp -rf ${CPP_TOOL_PATH}/* ${TEST_CPP_TOOL_PATH}/
	# 拷贝依赖到工具中
	cp -rf ${IOTDB_PATH}/iotdb-client/client-cpp/target/build/main/generated-sources-cpp/* ${TEST_CPP_TOOL_PATH}/client/include/
	cp -rf ${IOTDB_PATH}/iotdb-client/client-cpp/target/thrift/include/* ${TEST_CPP_TOOL_PATH}/client/include/
	cp -rf ${IOTDB_PATH}/iotdb-client/client-cpp/target/client-cpp-*-SNAPSHOT-cpp-linux-x86_64/lib/* ${TEST_CPP_TOOL_PATH}/client/lib/
	# 编译工具
	cd ${TEST_CPP_TOOL_PATH}
	compile=$(timeout 300s bash -c "source /etc/profile && ./compile.sh")
	if [ $? -eq 0 ]; then
		echo "编译Cpp原生接口测试工具完成，准备开始测试！"
	else
		echo "编译Cpp原生接口工具失败，写入负值测试结果！"
		tests_num=-3
		errors_num=-3
		failures_num=-3
		skipped_num=-3
		successRate=-3
		insert_sql_cpp="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_cpp}"
		return 1
	fi
	echo "开始Cpp原生接口测试"
	start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	start_test=$(timeout 7200s bash -c "source /etc/profile && ./run.sh")
	for (( t_wait = 0; t_wait <= 20; ))
	do
		cd ${TEST_CPP_TOOL_PATH}
		result_file=${TEST_CPP_TOOL_PATH}/build/test/cpp_session_test_report.json
		if [ ! -f "$result_file" ]; then
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 14400 ]; then
				echo "Cpp原生接口测试失败"
				flag=1
				break
			fi
			continue
		else
			echo "Cpp原生接口测试完成"
			break
		fi
	done
	end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	# 防止测试报告文档内容还未生成完全，导致脚本获取空值
	sleep 60
	if [ $flag -eq 0 ]; then
		#收集测试结果
		cd ${TEST_CPP_TOOL_PATH}
		tests_num=$(jq -r '.tests' "${TEST_CPP_TOOL_PATH}/build/test/cpp_session_test_report.json")
		errors_num=$(jq -r '.errors' "${TEST_CPP_TOOL_PATH}/build/test/cpp_session_test_report.json")
		failures_num=$(jq -r '.failures' "${TEST_CPP_TOOL_PATH}/build/test/cpp_session_test_report.json")
		skipped_num=$(jq -r '.disabled' "${TEST_CPP_TOOL_PATH}/build/test/cpp_session_test_report.json")
		successRate=$(awk -v t="$tests_num" -v e="$errors_num" -v f="$failures_num" -v s="$skipped_num" 'BEGIN{printf "%.2f", t?((t-e-f-s)*100/t):0}')
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_cpp="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP')"
		echo "${insert_sql_cpp}"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_cpp}"
		if [ $? -ne 0 ]; then
			echo "执行mysql命令失败"
			#收集测试结果
			tests_num=-5
			errors_num=-5
			failures_num=-5
			skipped_num=-5
			successRate=-5
			#结果写入mysql
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			sql=$(cat <<EOF
			insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark,insert_sql) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP',"${insert_sql_cpp}")
EOF
			)
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "$sql"
			echo "备份Cpp原生接口测试报告"
      mkdir -p /data/qa/backup/cpp/${last_cid_iotdb}_${failures_num}
      cp -rf ${TEST_CPP_TOOL_PATH}/build/test/cpp_session_test_report.json mkdir -p /data/qa/backup/cpp/${last_cid_iotdb}_${failures_num}
			return 1
		fi
	else
		#收集测试结果
		cd ${TEST_CPP_TOOL_PATH}
		tests_num=-4
		errors_num=-4
		failures_num=-4
		skipped_num=-4
		successRate=-4
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_cpp="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP')"
		#echo "${insert_sql_cpp}"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_cpp}"
	fi
	#备份本次测试
	echo "备份Cpp原生接口测试报告"
	#backup_test_data
	rm -rf ${BK_PATH}/cpp/*
	cp -f ${TEST_CPP_TOOL_PATH}/build/test/cpp_session_test_report.json ${BK_PATH}/cpp/
	mkdir -p /data/qa/backup/${last_cid_iotdb}_${failures_num}
	cp -rf  ${TEST_IOTDB_PATH}/logs /data/qa/backup/${last_cid_iotdb}_${failures_num}
	find /data/qa/backup/ -mtime +7 -type d -name "*" -exec rm -rf {} \;
	cd ${BK_PATH}/cpp
	#git add .
	#git commit -m ${last_cid_iotdb}_${failures_num}
	#git push -f
}
test_python_native_api_test() { # 测试Python原生接口
	# Python代码编译
	echo "编译python客户端"
	cd ${IOTDB_PATH}/iotdb-client/client-py
	pip3 install build
	pip3 install numpy==1.25.2
	comp_cpp=$(timeout 7200s  bash -c "./release.sh")
	if [ $? -eq 0 ]; then
		echo "编译Python客户端完成，准备开始测试！"
	else
		echo "编译Python客户端失败，写入负值测试结果！"
		tests_num=-2
		errors_num=-2
		failures_num=-2
		skipped_num=-2
		successRate=-2
		insert_sql_python="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_python}"
		return 1
	fi
	# 拷贝Python工具到测试路径
	if [ ! -d "${TEST_PYTHON_TOOL_PATH}" ]; then
		mkdir -p ${TEST_PYTHON_TOOL_PATH}
	else
		rm -rf ${TEST_PYTHON_TOOL_PATH}
		mkdir -p ${TEST_PYTHON_TOOL_PATH}
	fi
	cp -rf ${PYTHON_TOOL_PATH}/* ${TEST_PYTHON_TOOL_PATH}/
	# 创建测试环境，安装测试依赖
	cd ${TEST_PYTHON_TOOL_PATH}
	python3 -m venv venv
	source venv/bin/activate
	pip3 install pytest
	pip3 install pyyaml
	pip3 install pytest-html
	pip3 install numpy==1.25.2
	pip3 install pandas==2.0.3
	pip3 install greenlet==2.0.2
	pip3 install ${IOTDB_PATH}/iotdb-client/client-py/dist/apache_iotdb-*.dev0-py3-none-any.whl # 引入iotdb依赖
	if [ $? -eq 1 ]; then
		echo "引入iotdb依赖失败"
		tests_num=-3
		errors_num=-3
		failures_num=-3
		skipped_num=-3
		successRate=-3
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_python="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_python}"
		deactivate
		return 1
	fi
	# 开始测试
	echo "Python开始测试"
	cd ${TEST_PYTHON_TOOL_PATH}/tests
	start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	start_test=$(timeout 7200s bash -c "pytest --html=../reports/report.html")
	for (( t_wait = 0; t_wait <= 20; ))
	do
		cd ${TEST_PYTHON_TOOL_PATH}
		result_file=${TEST_PYTHON_TOOL_PATH}/reports/report.html
		if [ ! -f "$result_file" ]; then
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 14400 ]; then
				echo "Python原生接口测试失败"
				flag=1
				break
			fi
			continue
		else
			echo "Python原生接口测试完成"
			break
		fi
	done
	end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	# 防止测试报告文档内容还未生成完全，导致脚本获取空值
	sleep 60
	deactivate
	if [ $flag -eq 0 ]; then
		#收集测试结果
		cd ${TEST_PYTHON_TOOL_PATH}
		# 从HTML报告中提取测试结果
		tests_num=$(grep -o '[0-9]\+ tests' ${TEST_PYTHON_TOOL_PATH}/reports/report.html | head -1 | grep -o '[0-9]\+')
		errors_num=$(grep -o '[0-9]\+ Error' ${TEST_PYTHON_TOOL_PATH}/reports/report.html | head -1 | grep -o '[0-9]\+')
		if [ -z "$errors_num" ]; then
			errors_num=0
		fi
		failures_num=$(grep -o '[0-9]\+ Failed' ${TEST_PYTHON_TOOL_PATH}/reports/report.html | head -1 | grep -o '[0-9]\+')
		if [ -z "$failures_num" ]; then
			failures_num=0
		fi
		skipped_num=$(grep -o '[0-9]\+ Skipped' ${TEST_PYTHON_TOOL_PATH}/reports/report.html | head -1 | grep -o '[0-9]\+')
		if [ -z "$skipped_num" ]; then
			skipped_num=0
		fi
		passed_num=$(grep -o '[0-9]\+ Passed' ${TEST_PYTHON_TOOL_PATH}/reports/report.html | head -1 | grep -o '[0-9]\+')
		if [ -z "$passed_num" ]; then
			passed_num=0
		fi
		successRate=$(echo "scale=2; ($passed_num / ${tests_num}) * 100" | bc)
		if [ -z "$successRate" ]; then
			successRate=0
		fi
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_python="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON')"
		echo "${insert_sql_python}"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_python}"
		if [ $? -ne 0 ]; then
			echo "执行mysql命令失败"
			#收集测试结果
			tests_num=-5
			errors_num=-5
			failures_num=-5
			skipped_num=-5
			successRate=-5
			#结果写入mysql
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			sql=$(cat <<EOF
			insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark,insert_sql) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON',"${insert_sql_python}")
EOF
			)
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "$sql"
			echo "备份Python原生接口测试报告"
      mkdir -p /data/qa/backup/python/${last_cid_iotdb}_${failures_num}
      cp -rf  ${TEST_PYTHON_TOOL_PATH}/reports/* /data/qa/backup/python/${last_cid_iotdb}_${failures_num}
			return 1
		fi
	else
		#收集测试结果
		cd ${TEST_PYTHON_TOOL_PATH}
		tests_num=-4
		errors_num=-4
		failures_num=-4
		skipped_num=-4
		successRate=-4
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_python="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_python}"
	fi
	#备份本次测试
	echo "备份Python原生接口测试报告"
	#backup_test_data
	rm -rf ${BK_PATH}/python/*
	cp -rf ${TEST_PYTHON_TOOL_PATH}/reports/* ${BK_PATH}/python
	mkdir -p /data/qa/backup/${last_cid_iotdb}_${failures_num}
	cp -rf  ${TEST_IOTDB_PATH}/logs /data/qa/backup/${last_cid_iotdb}_${failures_num}
	find /data/qa/backup/ -mtime +7 -type d -name "*" -exec rm -rf {} \;
	cd ${BK_PATH}/python
	#git add .
	#git commit -m ${last_cid_iotdb}_${failures_num}
	#git push -f
}
echo "ontesting" > ${INIT_PATH}/test_type_file
# 初始化参数
init_items
# 收集IoTDB当前和最新的commit，拉取最新的代码
cd ${IOTDB_PATH}
last_cid_iotdb=$(git log --pretty=format:"%h" -1)
git_pull=$(timeout 100s git fetch --all)
git_pull=$(git reset --hard origin/master)
git_pull=$(timeout 100s git pull)
commit_id_iotdb=$(git log --pretty=format:"%h" -1)
# 获取IoTDB的commit信息时间
#test_date_time=$(date -d @$(git show -s --format=%ct HEAD) +%Y%m%d%H%M%S)
test_date_time=$(date +%Y%m%d%H%M%S)
# 更新测试工具
cd ${JAVA_TOOL_PATH}
git_pull=$(timeout 100s git pull)
cd ${CPP_TOOL_PATH}
git_pull=$(timeout 100s git pull)
cd ${PYTHON_TOOL_PATH}
git_pull=$(timeout 100s git pull)
# 对比判定是否启动测试
if [ "${last_cid_iotdb}" != "${commit_id_iotdb}" ]; then # 判断IoTDB代码是否更新
	echo "IoTDB代码有更新，当前新版本commit：${commit_id_iotdb} 未执行过测试"
	# 编译IoTDB并判断是否编译成功
	compile_iotdb
	if [ $? -eq 1 ]; then
		# 编译失败，休眠并退出当前测试
		tests_num=-1
		errors_num=-1
		failures_num=-1
		skipped_num=-1
		successRate=-1
		insert_sql_java="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'JAVA')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_java}"
		insert_sql_cpp="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_cpp}"
		insert_sql_python="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_iotdb}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_python}"
	else
		# 编译成功，开始测试
		#清理环境，确保无旧程序影响
		check_iotdb_pid
		#复制iotdb到执行位置
		set_iotdb_env
		#IoTDB 调整内存，关闭合并
		modify_iotdb_config
		#启动iotdb和monitor监控
		start_iotdb
		sleep 60
		# 测试Java原生接口
		echo "测试Java原生接口"
		test_java_native_api_test
		if [ $? -eq 1 ]; then
			sleep 60
			echo "Java测试失败"
		fi
		# 测试Cpp原生接口
		init_items
		echo "测试Cpp原生接口"
		test_cpp_native_api_test
		if [ $? -eq 1 ]; then
			sleep 60
			echo "Cpp测试失败"
		fi
		# 测试Python原生接口
		init_items
		echo "测试Python原生接口"
		test_python_native_api_test
		if [ $? -eq 1 ]; then
			sleep 60
			echo "Python测试失败"
		fi
		#停止IoTDB程序
		check_iotdb_pid
		###############################测试完成###############################
		echo "本轮测试${test_date_time}已结束."
	fi
else # 没有更新则等待下一轮测试
	echo "没有更新，都执行过测试"
	sleep 300s
fi
echo "${test_type}" > ${INIT_PATH}/test_type_file
