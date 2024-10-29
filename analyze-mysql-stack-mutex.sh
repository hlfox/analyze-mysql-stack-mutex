#!/bin/bash
# Copyright 2023 huchengqing
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


#Usage:
#1. 已经有一个堆栈日志（可以用 pstack {mysqld_pid} > stack.log 获取堆栈信息，建议多拿几个）
#2. 然后下载对应版本源码解压在相同目录
#3. 运行脚本 ./analyze-mysql-stack-mutex.sh stack.log
#4. 会生成两个文件
    #summary_callstack 是汇总的所有在等待互斥量、读写锁的线程
    #detail_callstack 中有每个等待线程持有锁和释放锁的调用记录
#5. 文件中有两个数字需要注意，例如：1 1039 #10 srv_export_innodb_status  mysql-8.0.26/storage/...
    #1 表示这个栈帧有 1 个线程重复
    #1039 表示在 stack.log 中的行号，方便找到属于哪一个线程

if [ $# = 0 ]; then
	echo "No Call Stack File."
	exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

TMP_SUMMARY_FILE="tmp_summary_callstack"
SUMMARY_FILE="summary_callstack"
DETAIL_FILE="detail_callstack"
FILE=$1


echo -e "${RED}First Step: Start The Summary Analysis Of Call Stack.${NC}"
> $TMP_SUMMARY_FILE


##
cat $FILE \
| awk '/inline_mysql_mutex_lock|mutex_enter_inline|pfs_rw_lock_.*_lock_func|inline_mysql_cond/ { getline; print NR,$0 }' \
| sed -e "s@(.*-@ mysql-@g" -e 's@\(.*\):@\1#L@g' \
| sort -k2,4 -k1n | uniq -f1 -c | sort -n | tee -a $TMP_SUMMARY_FILE \
| awk -F'-' '{split($2,c,"#L"); location="cat mysql-" c[1] "|sed -n \"s/^[[:space:]]*//;" c[2] "p\""; \
    printf $0 "\033[31m Waiting \033[0m";system(location);}' > $SUMMARY_FILE

echo -e "${GREEN}First Step: Complete The Summary Analysis Of Call Stack.${NC}"

echo -e "${RED}Second Step: Start The Detail Analysis Of Call Stack.${NC}"

echo -e "\n\n${YELLOW}++++++++++++++++++++++++++++++ Start The Detail Analysis Of Every Waiting Function Call Stack ++++++++++++++++++++++++++++++${NC}\n\n" > $DETAIL_FILE


#########
##搜索代码中持有哪些锁的逻辑是：
####1.取得每一行调用栈信息中的函数名、源码文件名、行，构造数组，用 awk {split($2,c,"#L"); split($1,f," ") 实现
####2.到源码文件从 “函数名(“ 开始搜索，直到指定的“行” 结束，用 sed -n \"/" f[2] "(/," c[2] "p\" 实现，比如 sed -n "/ queue_event(/,7267p" mysql-5.6.40/sql/rpl_slave.cc
####3.然后过滤其中获取锁、互斥量、条件变量的关键字并打印出来
##注意：
####1.第 2 步用 “函数名(“ 开始搜索可能会从错误的位置开始开始搜索，因此可能会打印出很多实际没有获取的锁，如果发现某个函数下有很多锁，可以先到代码里找到函数定义的行号，用 sed -n "6874,7267p" 然后 grep 锁关键字来分析
####2.第 3 步过滤的关键字可以根据经验自己补充
#########
cat $TMP_SUMMARY_FILE | while read line ; do
    echo  $line |awk -F'-' '{split($2,c,"#L"); \
    location="cat mysql-" c[1] "|sed -n \"s/^[[:space:]]*//;" c[2] "p\""; \
    printf $0 "\033[31m Waiting \033[0m";system(location)}'
    ff=$(echo $line | awk '{print $2}')
    echo -e "${GREEN}========================== Start The Detail Analysis Of This Waiting Function Call Stack ==========================${NC}\n"
    cmd="sed -n '$ff,/clone ()/p' $FILE"
    eval $cmd \
    | sed -e 's/0x.* in //g' -e "s@ (.*-@ mysql-@g" -e 's/\(.*\):/\1#L/g' \
    | grep -Ev "^$" \
    | awk -F'-' '{split($2,c,"#L"); split($1,f," "); \
    mutex="cat mysql-" c[1] "|sed -n \"/ " f[2] "(/," c[2] "p\" | egrep --color=always \"mysql_mutex_lock|mysql_mutex_unlock|trx_sys_mutex_enter|trx_sys_mutex_exit|mutex_enter|mutex_exit|mysql_mutex_assert_owner|mysql_rwlock|mysql_cond_.*wait\"|sed \"s/^[ \t]*/\t/g\""; \
    location="cat mysql-" c[1] "|sed -n \"s/^[[:space:]]*//;" c[2] "p\""; \
    printf $0 "\033[31m Location \033[0m"; system(location); if ($0 ~ "clone ()" ) {printf("\n")}; system(mutex);}' 2> /dev/null
    echo -e "${GREEN}========================= Compete The Detail Analysis Of This Waiting Function Call Stack =========================${NC}\n\n"
done >> $DETAIL_FILE 

echo -e "${YELLOW}++++++++++++++++++++++++++++++ Complete The Detail Analysis Of Every Waiting Function Call Stack ++++++++++++++++++++++++++++++${NC}" >> $DETAIL_FILE

echo -e "${GREEN}Second Step: Complete The Detail Analysis Of Call Stack.${NC}"

rm -f $TMP_SUMMARY_FILE
