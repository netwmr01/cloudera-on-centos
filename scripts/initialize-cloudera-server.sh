#!/usr/bin/env bash

execname=$0

log() {
  echo "$(date): [${execname}] $@" >> /tmp/initialize-cloudera-server.log
}

#fail on any error
set -e

ClusterName=$1
key=$2
mip=$3
worker_ip=$4
HA=$5
User=$6
Password=$7

log "BEGIN: master node deployments"

log "Beginning process of disabling SELinux"

log "Running as $(whoami) on $(hostname)"

# Use the Cloudera-documentation-suggested workaround
log "about to set setenforce to 0"
set +e
setenforce 0 >> /tmp/setenforce.out

exitcode=$?
log "Done with settiing enforce. Its exit code was $exitcode"

log "Running setenforce inline as $(setenforce 0)"

getenforce
log "Running getenforce inline as $(getenforce)"
getenforce >> /tmp/getenforce.out

log "should be done logging things"


cat /etc/selinux/config > /tmp/beforeSelinux.out
log "ABOUT to replace enforcing with disabled"
sed -i 's^SELINUX=enforcing^SELINUX=disabled^g' /etc/selinux/config || true

cat /etc/selinux/config > /tmp/afterSeLinux.out
log "Done disabling selinux"

set +e

log "Set cloudera-manager.repo to CM v5"
yum clean all >> /tmp/initialize-cloudera-server.log
rpm --import http://archive.cloudera.com/cdh5/redhat/6/x86_64/cdh/RPM-GPG-KEY-cloudera >> /tmp/initialize-cloudera-server.log
wget http://archive.cloudera.com/cm5/redhat/6/x86_64/cm/cloudera-manager.repo -O /etc/yum.repos.d/cloudera-manager.repo >> /tmp/initialize-cloudera-server.log
# this often fails so adding retry logic
n=0
until [ $n -ge 5 ]
do
    yum install -y oracle-j2sdk* cloudera-manager-daemons cloudera-manager-server >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err && break
    n=$[$n+1]
    sleep 15s
done
if [ $n -ge 5 ]; then log "scp error $remote, exiting..." & exit 1; fi

#######################################################################################################################
log "installing external DB"
echo "export LANGUAGE=en_US.UTF-8" >> ~/.bashrc
echo "export LANG=en_US.UTF-8" >> ~/.bashrc
echo "export LC_ALL=en_US.UTF-8" >> ~/.bashrc

source ~/.bashrc
sudo yum install postgresql-server -y
sudo service postgresql initdb
sudo service postgresql start

#put this line to the top of the ident
sed -i '/host.*127.*ident/i \
host    all         all         127.0.0.1/32          md5  \' /var/lib/pgsql/data/pg_hba.conf

#configure the postgresql server to start at boot
sudo /sbin/chkconfig postgresql on

sudo service postgresql restart

#create DB roles
sudo -u postgres psql -c"CREATE ROLE scm LOGIN PASSWORD 'scm';"
sudo -u postgres psql -c"CREATE DATABASE scm OWNER scm ENCODING 'UTF8';"

sudo -u postgres psql -c"CREATE ROLE amon LOGIN PASSWORD 'amon_password';"
sudo -u postgres psql -c"CREATE DATABASE amon OWNER amon ENCODING 'UTF8';"

sudo -u postgres psql -c"CREATE ROLE rman LOGIN PASSWORD 'rman_password';"
sudo -u postgres psql -c"CREATE DATABASE rman OWNER rman ENCODING 'UTF8';"

sudo -u postgres psql -c"CREATE ROLE hive LOGIN PASSWORD 'hive_password';"
sudo -u postgres psql -c"CREATE DATABASE metstore OWNER hive ENCODING 'UTF8';"

sudo -u postgres psql -c"CREATE ROLE sentry LOGIN PASSWORD 'sentry_password';"
sudo -u postgres psql -c"CREATE DATABASE sentry OWNER sentry ENCODING 'UTF8';"

sudo -u postgres psql -c"CREATE ROLE nav LOGIN PASSWORD 'nav_password';"
sudo -u postgres psql -c"CREATE DATABASE nav OWNER nav ENCODING 'UTF8';"

sudo -u postgres psql -c"CREATE ROLE navms LOGIN PASSWORD 'navms_password';"
sudo -u postgres psql -c"CREATE DATABASE navms OWNER navms ENCODING 'UTF8';"

sudo -u postgres psql -c"ALTER DATABASE Metastore SET standard_conforming_strings = off;"

/usr/share/cmf/schema/scm_prepare_database.sh postgresql scm scm scm >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err

log "finished external DB"
#######################################################################################################################

log "start cloudera-scm-server services"
#service cloudera-scm-server-db start >> /tmp/initialize-cloudera-server.log
service cloudera-scm-server start >> /tmp/initialize-cloudera-server.log

#log "Create HIVE metastore DB Cloudera embedded PostgreSQL"
#export PGPASSWORD=$(head -1 /var/lib/cloudera-scm-server-db/data/generated_password.txt)
#SQLCMD=( """CREATE ROLE hive LOGIN PASSWORD 'hive';""" """CREATE DATABASE hive OWNER hive ENCODING 'UTF8';""" """ALTER DATABASE hive SET standard_conforming_strings = off;""" )
#for SQL in "${SQLCMD[@]}"; do
#	psql -A -t -d scm -U cloudera-scm -h localhost -p 7432 -c "${SQL}" >> /tmp/initialize-cloudera-server.log
#done
#while ! (exec 6<>/dev/tcp/$(hostname)/7180) ; do log 'Waiting for cloudera-scm-server to start...'; sleep 15; done
log "END: master node deployments"



# Set up python
rpm -ivh http://dl.fedoraproject.org/pub/epel/6/i386/epel-release-6-8.noarch.rpm >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err
yum -y install python-pip >> /tmp/initialize-cloudera-server.log
pip install cm_api >> /tmp/initialize-cloudera-server.log

# trap file to indicate done
log "creating file to indicate finished"
touch /tmp/readyFile

# Execute script to deploy Cloudera cluster
log "BEGIN: CM deployment - starting"
# mingrui changed command to print both key info and password.
logCmd="Command: python cmxDeployOnIbiza.py -n "\""$ClusterName"\"" -u "\""$User"\"" -p "\""$Password"\"" -k "\""$key"\"" -m "\""$mip"\"" -w "\""$worker_ip"\"""
if $HA; then
    logCmd="$logCmd -a"
fi
log $logCmd
if $HA; then
    python cmxDeployOnIbiza.py -n "$ClusterName" -u $User -p $Password  -m "$mip" -w "$worker_ip" -a >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err
else
    python cmxDeployOnIbiza.py -n "$ClusterName" -u $User -p $Password  -m "$mip" -w "$worker_ip" >> /tmp/initialize-cloudera-server.log 2>> /tmp/initialize-cloudera-server.err
fi
log "END: CM deployment ended"
