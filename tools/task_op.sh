#!/bin/bash
operation_list=("RETEST" "retest")
app_name_list=("all" "api_insert" "cluster_insert" "compaction" "config_insert" "routine_test" "se_insert" "se_query" "sql_coverage" "ts_performance" "unse_insert" "unse_query" "weeklytest_insert" "weeklytest_query")
############mysql信息##########################
MYSQLHOSTNAME="111.202.73.147" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD=${ATMOS_DB_PASSWORD}
DBNAME="QA_ATM"  #数据库名称
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
if [ "${PASSWORD}" = "" ]; then
echo "需要关注密码设置！"
fi
#获取用户输入信息
operation=$1
app_name=$2
function contains() { #判断传入的字符串是否被包含在已定义的数组中
	local n=$#
	local value=${!n}
	for ((i=1;i < $#;i++)) {
		if [ "${!i}" == "${value}" ]; then
			echo "y"
			return 0
		fi
	}
	echo "n"
	return 1
}

#按照用户输入执行处理程序
if [[ $(contains "${operation_list[@]}" "${operation}") != "y" ]] ||
	[[ $(contains "${app_name_list[@]}" "${app_name}") != "y" ]]; then
	echo -e "\033[31m请选择要操作的类型[retest]\033[0m"
	echo "例如：./atmos.sh retest se_insert"
	exit 1
fi

commit_id=$3
if [ "${app_name}" = "all" ]; then
	for ((i=2;i < ${#app_name_list[*]};i++)) {
		app_name=${app_name_list[${i}]}
		update_sql="UPDATE ${TASK_TABLENAME} SET ${app_name}=NULL WHERE commit_id='${commit_id}'"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}"
		delete_sql="DELETE FROM ex_${app_name} WHERE commit_id='${commit_id}'"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${delete_sql}"
	}
else
	update_sql="UPDATE ${TASK_TABLENAME} SET ${app_name}=NULL WHERE commit_id='${commit_id}'"
	mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}"
	delete_sql="DELETE FROM ex_${app_name} WHERE commit_id='${commit_id}'"
	mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${delete_sql}"
fi
