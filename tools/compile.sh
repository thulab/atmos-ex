#!/bin/sh
#登录用户名
ACCOUNT=atmos
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
IOTDB_PATH=${INIT_PATH}/iotdb
FILENAME=${INIT_PATH}/gitlog.txt
REPO_PATH=/data/repository/master
REPO_PATH_BK=/newnasdata/repository/master
filter_list_folder_name=(client-cpp client-go client-py code-coverage compile-tools distribution docker docs example external-api external-pipe-api flink-iotdb-connector flink-tsfile-connector grafana-connector grafana-plugin hadoop hive-connector influxdb-protocol integration integration-test isession licenses mlnode openapi pipe-api rewrite-tsfile-tool schema-engine-rocksdb schema-engine-tag site spark-iotdb-connector spark-tsfile subscription-api test testcontainer tools trigger-api udf-api zeppelin-interpreter)

############mysql信息##########################
MYSQLHOSTNAME="111.200.37.158" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD="iotdb2019"
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_commit_history" #数据库中表的名称
############公用函数##########################
init_items() {
commit_date_time=0
commit_id=0
author=0
se_insert=0
unse_insert=0
se_query=0
unse_query=0
commpaction=0
sql_coverage=0
api_test=0
weeklytest_insert=0
weeklytest_query=0
routine_test=0
config_insert=0
ts_performance=0
remark=0
}
sendEmail() {
sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}
for (( comp_test = 1; comp_test <= 3;))
do
	cd ${IOTDB_PATH}
	git_pull=$(timeout 100s git fetch --all)
	git_pull=$(timeout 100s git reset --hard origin/master)
	git_pull=$(timeout 100s git pull)
	commit_id_list=(`git log --pretty=format:"%h" -11 | awk -F "|" '{print $1}' | cut -c1-7`)
	for (( i = 10; i >= 0; i--))
	do
		query_sql="select commit_id from ${TABLENAME} where commit_id='${commit_id_list[$i]}'"
		echo "$query_sql"
		diff_str=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}" | sed -n '2p')
		if [ "${diff_str}" = "" ]; then
			cd ${IOTDB_PATH}
			git_pull=$(timeout 100s git fetch --all)
			git_pull=$(timeout 100s git reset --hard origin/master)
			git_pull=$(timeout 100s git pull)
			git_reset=$(timeout 100s git reset --hard ${commit_id_list[$i]})
			# 获取更新后git commit对比判定是否启动测试
			commit_id=$(git log --pretty=format:"%h" -1 | cut -c1-7)
			author=$(git log --pretty=format:"%an" -1)
			commit_date_time=$(git log --pretty=format:"%ci" -1 | cut -b 1-19 | sed s/-//g | sed s/://g | sed s/[[:space:]]//g)
			#对比判定是否启动测试
			echo "当前版本${commit_id}未记录,即将编译。"
			#代码编译
			date_time=`date +%Y%m%d%H%M%S`
			comp_mvn=$(mvn clean package -pl distribution -am -DskipTests)
			if [ $? -eq 0 ]
			then
				echo "${commit_id}编译完成！"
				rm -rf ${REPO_PATH}/${commit_id}
				mkdir -p ${REPO_PATH}/${commit_id}/apache-iotdb/
				cp -rf ${IOTDB_PATH}/distribution/target/apache-iotdb-*-all-bin/apache-iotdb-*-all-bin/* ${REPO_PATH}/${commit_id}/apache-iotdb/
				#配置文件整理
				rm -rf ${REPO_PATH}/${commit_id}/apache-iotdb/conf/iotdb-system.properties
				mv ${REPO_PATH}/${commit_id}/apache-iotdb/conf/iotdb-system.properties.template ${REPO_PATH}/${commit_id}/apache-iotdb/conf/iotdb-system.properties
				#向新的网盘环境复制一份备份
				#rm -rf ${REPO_PATH_BK}/${commit_id}
				#mkdir -p ${REPO_PATH_BK}/${commit_id}/apache-iotdb/
				#cp -rf ${IOTDB_PATH}/distribution/target/apache-iotdb-*-all-bin/apache-iotdb-*-all-bin/* ${REPO_PATH_BK}/${commit_id}/apache-iotdb/
				#获取本次更新的变更文件列表
				git log -1 --name-only > $FILENAME
				#按照文件夹名称排除不必要测试文件夹
				for (( ix = 0; ix < ${#filter_list_folder_name[*]}; ix++ ))
				do
					sed -i "/${filter_list_folder_name[${ix}]}/d" $FILENAME
				done
				file_num=0
				non_file_num=0
				while read line;do
					filename=$(basename $line)
					if echo "$filename" | grep -q -E '\.java$'
					then
						file_num=$[${file_num}+1]
					else
						non_file_num=$[${non_file_num}+1]
					fi
				done <  $FILENAME
				if [ "${file_num}" = "0" ]; then
					#不需要测试
					str_noneed='NoNeed'
					insert_sql="insert into ${TABLENAME} (commit_date_time,commit_id,author,se_insert,unse_insert,se_query,unse_query,compaction,insert_records,sql_coverage,weeklytest_insert,weeklytest_query,api_insert,routine_test,config_insert,ts_performance,cluster_insert,cluster_insert_2,restart_db,count_ts,cluster_rto,pipe_test) values(${commit_date_time},'${commit_id}','${author}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}','${str_noneed}')"
					mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
				else
					#正常下派所有任务
					insert_sql="insert into ${TABLENAME} (commit_date_time,commit_id,author) values(${commit_date_time},'${commit_id}','${author}')"
					mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
					echo "${commit_id}测试任务已发布！"
				fi
			else
				echo "${commit_id}编译失败！"
				str_err='CError'
				insert_sql="insert into ${TABLENAME} (commit_date_time,commit_id,author,se_insert,unse_insert,se_query,unse_query,compaction,insert_records,sql_coverage,weeklytest_insert,weeklytest_query,api_insert,routine_test,config_insert,ts_performance,cluster_insert,cluster_insert_2,restart_db,count_ts,cluster_rto,pipe_test) values(${commit_date_time},'${commit_id}','${author}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}','${str_err}')"
                		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
				msgbody='错误类型：'${test_type}'代码编译失败\n报错时间：'${date_time}'\n报错Commit：'${commit_id}'\n提交人：'${author}''
				sendEmail ${msgbody}
			fi
		else
			echo "当前${commit_id_list[$i]}已经存在！"
		fi
	done
	echo "当前查询到的10个commitid确认完毕！"
	echo "别闲着，做一轮服务器空间清理任务吧。删除15天之前的测试记录"
	find /data/repository/*/*/ -mtime +15 -type d -name "*" -exec rm -rf {} \;
	sleep 300s
done


