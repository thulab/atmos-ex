#!/bin/sh
#登录用户名
ACCOUNT=atmos
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
IOTDB_PATH=${INIT_PATH}/iotdb_branch
REPO_PATH=/data/repository/master
REPO_PATH_BK=/newnasdata/repository/master

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

cd ${IOTDB_PATH}
git_pull=$(timeout 100s git fetch --all)
git_pull=$(timeout 100s git reset --hard origin/master)
git_pull=$(timeout 100s git pull)
git_check=$(timeout 100s git checkout $1)
git_pull=$(timeout 100s git pull)
if [ "$1" = "" ]; then
	echo "编译当前分支最新版本"
else
	echo "编译当前分支 $2 版本"
	git_reset=$(timeout 100s git reset --hard $2)
fi
commit_id=$(git log --pretty=format:"%h" -1 | cut -c1-7)
author=$(git log --pretty=format:"%an" -1)
commit_date_time=$(git log --pretty=format:"%ci" -1 | cut -b 1-19 | sed s/-//g | sed s/://g | sed s/[[:space:]]//g)
#对比判定是否启动测试
echo "当前版本${commit_id}即将编译和下派。"
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
	#rm -rf ${REPO_PATH}/${commit_id}/apache-iotdb/conf/iotdb-system.properties
	#mv ${REPO_PATH}/${commit_id}/apache-iotdb/conf/iotdb-system.properties.template ${REPO_PATH}/${commit_id}/apache-iotdb/conf/iotdb-system.properties
	#向新的网盘环境复制一份备份
	#rm -rf ${REPO_PATH_BK}/${commit_id}
	#mkdir -p ${REPO_PATH_BK}/${commit_id}/apache-iotdb/
	#cp -rf ${IOTDB_PATH}/distribution/target/apache-iotdb-*-all-bin/apache-iotdb-*-all-bin/* ${REPO_PATH_BK}/${commit_id}/apache-iotdb/

	#正常下派所有任务
	insert_sql="insert into ${TABLENAME} (commit_date_time,commit_id,author,remark) values(${commit_date_time},'${commit_id}','${author}','$1')"
	mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
else
	echo "${commit_id}编译失败！"
	msgbody='错误类型：'$1'分支代码编译失败\n报错时间：'${date_time}'\n报错Commit：'${commit_id}'\n提交人：'${author}''
	sendEmail ${msgbody}
fi