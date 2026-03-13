#!/bin/bash
#登录用户名
ACCOUNT=root
test_type=tsfile_api_test
#初始环境存放路径
export HTTP_PROXY=http://172.20.31.76:7890
export HTTPS_PROXY=$HTTP_PROXY
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
TSFILE_PATH=${INIT_PATH}/tsfile
JAVA_TOOL_PATH=${INIT_PATH}/java-tsfile-api-test
CPP_TOOL_PATH=${INIT_PATH}/cpp-tsfile-api-test
PYTHON_TOOL_PATH=${INIT_PATH}/python-tsfile-api-test
#BK_PATH=${INIT_PATH}/tsfile_api_test_report # 未创建仓库
#测试数据运行路径
TEST_INIT_PATH=/data/qa
TEST_JAVA_TOOL_PATH=${TEST_INIT_PATH}/java-tsfile-api-test
TEST_CPP_TOOL_PATH=${TEST_INIT_PATH}/cpp-tsfile-api-test
TEST_PYTHON_TOOL_PATH=${TEST_INIT_PATH}/python-tsfile-api-test
############mysql信息##########################
MYSQLHOSTNAME="111.200.37.158" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD=${ATMOS_DB_PASSWORD}
DBNAME="QA_ATM"                   #数据库名称
TABLENAME="tsfile_api_test" #数据库中用例表的名称
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
test_java_tsfile_api_test() { # 测试Java
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
	compile=$(timeout 300s mvn clean install -P with-java -DskipTests)
	if [ $? -eq 0 ]
	then
		echo "编译Java完成，准备开始测试！"
	else
		echo "编译Java失败，写入负值测试结果！"
		tests_num=-2
		errors_num=-2
		failures_num=-2
		skipped_num=-2
		successRate=-2
		insert_sql_java="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'JAVA')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_java}"
		return 1
	fi
	echo "开始测试Java接口"
	start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	start_test=$(nohup mvn surefire-report:report > /dev/null 2>&1 &)
	for (( t_wait = 0; t_wait <= 20; ))
	do
		cd ${TEST_JAVA_TOOL_PATH}
		result_file=${TEST_JAVA_TOOL_PATH}/target/site/surefire-report.html
		if [ ! -f "$result_file" ]; then
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 14400 ]; then
				echo "Java测试失败"
				flag=1
				break
			fi
			continue
		else
			echo "Java测试完成"
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
		tests_num=$(grep -o '<td align="left">[0-9]*</td>' ${TEST_JAVA_TOOL_PATH}/target/site/surefire-report.html | sed -n '1p' | grep -o '[0-9]*')
		errors_num=$(grep -o '<td align="left">[0-9]*</td>' ${TEST_JAVA_TOOL_PATH}/target/site/surefire-report.html | sed -n '2p' | grep -o '[0-9]*')
		failures_num=$(grep -o '<td align="left">[0-9]*</td>' ${TEST_JAVA_TOOL_PATH}/target/site/surefire-report.html | sed -n '3p' | grep -o '[0-9]*')
		skipped_num=$(grep -o '<td align="left">[0-9]*</td>' ${TEST_JAVA_TOOL_PATH}/target/site/surefire-report.html | sed -n '4p' | grep -o '[0-9]*')
		successRate=$(grep -o '<td align="left">[0-9]*%</td>' ${TEST_JAVA_TOOL_PATH}/target/site/surefire-report.html | sed -n '1p' | grep -o '[0-9]*%')
		successRate=${successRate//%/}
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_java="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'JAVA')"
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
			insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark,insert_sql) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'JAVA',"${insert_sql_java}")
EOF
			)
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "$sql"
      echo "备份Java测试报告"
      mkdir -p /data/qa/backup/java/${last_cid_TsFile}_${failures_num}
      cp -rf  ${TEST_JAVA_TOOL_PATH}/target/site /data/qa/backup/java/${last_cid_TsFile}_${failures_num}
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
		insert_sql_java="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'JAVA')"
		#echo "${insert_sql_java}"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_java}"
	fi
	#备份本次测试
	echo "备份Java测试报告"
	rm -rf ${BK_PATH}/java/*
	cp -rf ${TEST_JAVA_TOOL_PATH}/target/site ${BK_PATH}/java
	mkdir -p /data/qa/backup/${last_cid_TsFile}_${failures_num}
	find /data/qa/backup/ -mtime +7 -type d -name "*" -exec rm -rf {} \;
#	cd ${BK_PATH}/java
#	git add .
#	git commit -m ${last_cid_TsFile}_${failures_num}
#	git push -f
}
test_cpp_tsfile_api_test() {
	# C++代码编译
	echo "编译C++"
	cd ${TSFILE_PATH}
	comp_cpp=$(timeout 7200s  bash -c "mvn clean install -P with-cpp -DskipTests")
	if [ $? -eq 0 ]; then
		echo "编译C++完成，准备开始测试！"
	else
		echo "编译C++失败，写入负值测试结果！"
		tests_num=-2
		errors_num=-2
		failures_num=-2
		skipped_num=-2
		successRate=-2
		insert_sql_cpp="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP')"
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
	cp -rf ${TSFILE_PATH}/cpp/target/build/include/* ${TEST_CPP_TOOL_PATH}/include/
	cp -rf ${TSFILE_PATH}/cpp/third_party/antlr4-cpp-runtime-4/runtime/src/* ${TEST_CPP_TOOL_PATH}/include/
	cp -rf ${TSFILE_PATH}/cpp/target/build/lib/* ${TEST_CPP_TOOL_PATH}/lib/
	# 编译工具
	cd ${TEST_CPP_TOOL_PATH}
	compile=$(timeout 300s bash -c "source /etc/profile && ./compile.sh")
	if [ $? -eq 0 ]; then
		echo "编译Cpp测试工具完成，准备开始测试！"
	else
		echo "编译Cpp工具失败，写入负值测试结果！"
		tests_num=-3
		errors_num=-3
		failures_num=-3
		skipped_num=-3
		successRate=-3
		insert_sql_cpp="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_cpp}"
		return 1
	fi
	echo "开始Cpp测试"
	start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	start_test=$(timeout 7200s bash -c "source /etc/profile && ./run.sh")
	for (( t_wait = 0; t_wait <= 20; ))
	do
		cd ${TEST_CPP_TOOL_PATH}
		result_file=${TEST_CPP_TOOL_PATH}/build/test/cpp_tsfile_test_report.json
		if [ ! -f "$result_file" ]; then
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 14400 ]; then
				echo "Cpp测试失败"
				flag=1
				break
			fi
			continue
		else
			echo "Cpp测试完成"
			break
		fi
	done
	end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	# 防止测试报告文档内容还未生成完全，导致脚本获取空值
	sleep 60
	if [ $flag -eq 0 ]; then
		#收集测试结果
		cd ${TEST_CPP_TOOL_PATH}
		tests_num=$(jq -r '.tests' "${TEST_CPP_TOOL_PATH}/build/test/cpp_tsfile_test_report.json")
		errors_num=$(jq -r '.errors' "${TEST_CPP_TOOL_PATH}/build/test/cpp_tsfile_test_report.json")
		failures_num=$(jq -r '.failures' "${TEST_CPP_TOOL_PATH}/build/test/cpp_tsfile_test_report.json")
		skipped_num=$(jq -r '.disabled' "${TEST_CPP_TOOL_PATH}/build/test/cpp_tsfile_test_report.json")
		successRate=$(awk -v t="$tests_num" -v e="$errors_num" -v f="$failures_num" -v s="$skipped_num" 'BEGIN{printf "%.2f", t?((t-e-f-s)*100/t):0}')
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_cpp="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP')"
		#echo "${insert_sql_cpp}"
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
			insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark,insert_sql) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP',"${insert_sql_cpp}")
EOF
			)
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "$sql"
			echo "备份Cpp测试报告"
      mkdir -p /data/qa/backup/cpp/${last_cid_TsFile}_${failures_num}
      cp -rf ${TEST_CPP_TOOL_PATH}/build/test/cpp_tsfile_test_report.json mkdir -p /data/qa/backup/cpp/${last_cid_TsFile}_${failures_num}
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
		insert_sql_cpp="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'CPP')"
		#echo "${insert_sql_cpp}"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_cpp}"
	fi
	#备份本次测试
	echo "备份Cpp测试报告"
	rm -rf ${BK_PATH}/cpp/*
	cp -f ${TEST_CPP_TOOL_PATH}/build/test/cpp_tsfile_test_report.json ${BK_PATH}/cpp/
	mkdir -p /data/qa/backup/${last_cid_TsFile}_${failures_num}
	find /data/qa/backup/ -mtime +7 -type d -name "*" -exec rm -rf {} \;
#	cd ${BK_PATH}/cpp
#	git add .
#	git commit -m ${last_cid_TsFile}_${failures_num}
#	git push -f
}
test_python_tsfile_api_test() { # 测试Python
	# Python代码编译
	echo "编译python"
	cd ${TSFILE_PATH}
	comp_python=$(timeout 7200s  bash -c "mvn clean install -P with-python -DskipTests")
	if [ $? -eq 0 ]; then
		echo "编译Python完成，准备开始测试！"
	else
		echo "编译Python失败，写入负值测试结果！"
		tests_num=-2
		errors_num=-2
		failures_num=-2
		skipped_num=-2
		successRate=-2
		insert_sql_python="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON')"
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
	pip3 install ${TSFILE_PATH}/python/dist/tsfile-*.dev0-cp310-cp310-linux_x86_64.whl
 # 引入TsFile依赖
	if [ $? -eq 1 ]; then
		echo "引入TsFile依赖失败"
		tests_num=-3
		errors_num=-3
		failures_num=-3
		skipped_num=-3
		successRate=-3
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_python="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON')"
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
				echo "Python测试失败"
				flag=1
				break
			fi
			continue
		else
			echo "Python测试完成"
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
		failures_num=$(grep -o '[0-9]\+ Failed' ${TEST_PYTHON_TOOL_PATH}/reports/report.html | head -1 | grep -o '[0-9]\+')
		skipped_num=$(grep -o '[0-9]\+ Skipped' ${TEST_PYTHON_TOOL_PATH}/reports/report.html | head -1 | grep -o '[0-9]\+')
		passed_num=$(grep -o '[0-9]\+ Passed' ${TEST_PYTHON_TOOL_PATH}/reports/report.html | head -1 | grep -o '[0-9]\+')
		successRate=$(echo "scale=2; ($passed_num / ${tests_num}) * 100" | bc)
		#结果写入mysql
		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql_python="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON')"
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
			insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark,insert_sql) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON',"${insert_sql_python}")
EOF
			)
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "$sql"
			echo "备份Python测试报告"
      mkdir -p /data/qa/backup/python/${last_cid_TsFile}_${failures_num}
      cp -rf  ${TEST_PYTHON_TOOL_PATH}/reports/* /data/qa/backup/python/${last_cid_TsFile}_${failures_num}
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
		insert_sql_python="insert into ${TABLENAME} (test_date_time,commit_id,tests_num,errors_num,failures_num,skipped_num,successRate,start_time,end_time,cost_time,remark) values(${test_date_time},'${commit_id_TsFile}',${tests_num},${errors_num},${failures_num},${skipped_num},${successRate},'${start_time}','${end_time}',${cost_time},'PYTHON')"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql_python}"
	fi
	#备份本次测试
	echo "备份Python测试报告"
	rm -rf ${BK_PATH}/python/*
	cp -rf ${TEST_PYTHON_TOOL_PATH}/reports/* ${BK_PATH}/python
	mkdir -p /data/qa/backup/${last_cid_TsFile}_${failures_num}
	find /data/qa/backup/ -mtime +7 -type d -name "*" -exec rm -rf {} \;
#	cd ${BK_PATH}/python
#	git add .
#	git commit -m ${last_cid_TsFile}_${failures_num}
#	git push -f
}
echo "ontesting" > ${INIT_PATH}/test_type_file
# 初始化参数
init_items
# 收集TsFile当前和最新的commit，拉取最新的代码
cd ${TSFILE_PATH}
last_cid_TsFile=$(git log --pretty=format:"%h" -1)
git_pull=$(timeout 100s git fetch --all)
git_pull=$(git reset --hard origin/develop)
git_pull=$(timeout 100s git pull)
commit_id_TsFile=$(git log --pretty=format:"%h" -1)
# 获取TsFile的commit信息时间
test_date_time=$(date -d @$(git show -s --format=%ct HEAD) +%Y%m%d%H%M%S)
# 更新测试工具
cd ${JAVA_TOOL_PATH}
git_pull=$(timeout 100s git pull)
cd ${CPP_TOOL_PATH}
git_pull=$(timeout 100s git pull)
cd ${PYTHON_TOOL_PATH}
git_pull=$(timeout 100s git pull)
# 对比判定是否启动测试
if [ "${last_cid_TsFile}" != "${commit_id_TsFile}" ]; then
	echo "TsFile代码有更新，当前新版本commit：${commit_id_TsFile} 未执行过测试"
	# 测试Java
	echo "测试Java"
	test_java_tsfile_api_test
	if [ $? -eq 1 ]; then
		sleep 60
		echo "Java测试失败"
	fi
	# 测试Cpp
	init_items
	echo "测试Cpp"
	test_cpp_tsfile_api_test
	if [ $? -eq 1 ]; then
		sleep 60
		echo "Cpp测试失败"
	fi
	# 测试Python
	init_items
	echo "测试Python"
	test_python_tsfile_api_test
	if [ $? -eq 1 ]; then
		sleep 60
		echo "Python测试失败"
	fi
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
else
	echo "没有更新，都执行过测试"
	sleep 300s
fi
echo "${test_type}" > ${INIT_PATH}/test_type_file
