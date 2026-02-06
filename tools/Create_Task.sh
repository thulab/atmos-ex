#!/bin/sh
############mysql信息##########################
MYSQLHOSTNAME="111.200.37.158" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD=${ATMOS_DB_PASSWORD}
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_commit_history" #数据库中表的名称
TABLENAME_T="commit_history" #数据库中表的名称
#测试包存放位置
REPO_PATH=/nasdata/repository/master
REPO_PATH_EX=/ex_nasdata/repository/master
#检查是否设置密码参数
if [ "${PASSWORD}" = "" ]; then
echo "需要关注密码设置！"
fi
# 获取当前的星期（1表示星期一，7表示星期天）和小时
day_of_week=$(date +%u)  # 星期几（1-7，1表示星期一）
hour=$(date +%H)         # 当前小时（00-23）
######################################

#查询企业版任务列表最新一条测试任务commit
query_sql="select commit_id from ${TABLENAME_T} ORDER BY commit_date_time DESC LIMIT 1"
commit_id=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}" | sed -n '2p')
echo ${commit_id}
commit_date_time=$(date +%Y%m%d230000)
author='Timecho'
if [ ! -d "${REPO_PATH}/${commit_id}/apache-iotdb" ]; then
	#这个版本已经被清除了，没有办法下派任务了
	echo "这个版本的发布包已经被清除了，没有办法下派任务了"
else
	query_sql="select commit_id from ${TABLENAME} where commit_id='${commit_id}'"
	diff_str=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}" | sed -n '2p')
	if [ "${diff_str}" = "" ]; then
		echo "这是一个新的版本，没有下派过任务，可以操作下派了"
		commit_id_new=${commit_id}
	else
		#这个版本已经下派过任务了
		echo "这个版本已经下派过任务了"
		commit_id_new=${commit_id}_${day_of_week}	
		echo ${commit_id} "和" ${commit_id_new}
	fi
	mkdir -p ${REPO_PATH_EX}/${commit_id_new}/apache-iotdb/
	cp -rf ${REPO_PATH}/${commit_id}/apache-iotdb/* ${REPO_PATH_EX}/${commit_id_new}/apache-iotdb/
	delete_sql="delete from ${TABLENAME} where commit_id='${commit_id_new}'"
	mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${delete_sql}"
	sleep 10
	str_type='retest'
	insert_sql="insert into ${TABLENAME} (commit_date_time,commit_id,author,se_insert,unse_insert,se_query,unse_query,compaction,api_insert,ts_performance,insert_records,pipe_test,last_cache_query,api_insert_cts,se_query_test,config_insert,weeklytest_insert,weeklytest_query,restart_db,count_ts,sql_coverage,routine_test,windows_test,benchants,helishi_test,cluster_insert,cluster_insert_2,remark) values(${commit_date_time},'${commit_id_new}','${author}','${str_type}','${str_type}','${str_type}','${str_type}','${str_type}','${str_type}','${str_type}','${str_type}','${str_type}','${str_type}','${str_type}','${str_type}','NoNeed','NoNeed','NoNeed','NoNeed','NoNeed','NoNeed','NoNeed','NoNeed','NoNeed','NoNeed','NoNeed','NoNeed','TimechoDB')"
	mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
	echo "${commit_id_new}测试任务已发布！${commit_date_time}" >> /root/timecho/log.txt
	sleep 10
	# 判断是否是每周六
	if [ "$day_of_week" -eq 6 ]; then
		echo $date "  今天是周六，准备下派长耗时任务"
		update_sql="update ${TABLENAME} set cluster_insert = '${str_type}',cluster_insert_2 = '${str_type}',restart_db = '${str_type}',count_ts = '${str_type}' where commit_id = '${commit_id_new}'"
		result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
	fi
fi
