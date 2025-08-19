#!/bin/bash
#config 파일 변경 전 파일 백업
current_date=$(date +%Y-%m-%d)
desti_dir="/home/backup/$current_date"
mkdir -p "$desti_dir"

cp -p /etc/chrony.conf "$desti_dir/"
cp -p /etc/ssh/sshd_config "$desti_dir/"
cp -p /etc/pam.d/su "$desti_dir/"
cp -p /etc/security/pwquality.conf "$desti_dir/"
cp -p /etc/profile "$desti_dir/"
cp -p /etc/security/faillock.conf "$desti_dir/"

echo -e "\n\n"
echo "config 파일 백업 완료"
echo -e "\n\n"


# Update packages
echo "패키지 업데이트 시작"
yum update -y
# Install packages
yum install -y vim && yum install -y net-tools && yum install -y && yum -y rsync && yum install -y && yum install -y tcpdump && yum install -y net-snmp && yum install -y bind-utils && yum install -y policycoreutils-python-utils

echo -e "\n\n"
echo "패키지 업데이트 완료"
echo -e "\n\n"
 
#시간 동기화 설정
echo "시간 동기화 설정 시작"
dnf install -y chrony
systemctl enable chronyd
systemctl start chronyd
sed -i '/^pool 2.rocky.pool.ntp.org iburst/s/^/#/' /etc/chrony.conf
echo "server 8.8.8.8 iburst" >> /etc/chrony.conf
systemctl restart chronyd
 
echo -e "\n\n"
echo "시간 동기화 설정 완료"
echo -e "\n\n"
 
#개인 계정 생성
echo "개인 계정 생성 시작"
#사용자명 입력 받기
read -p "새로 생성할 사용자명을 입력하세요: " username
# 사용자 추가
sudo useradd "$username"
echo "새로 생성된 사용자 $username의 패스워드를 입력하세요:"
sudo passwd "$username"
echo "사용자 $username이 생성되고 비밀번호가 설정되었습니다."
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config

echo -e "\n\n" 
echo "계정 생성 및 root 원격접속 차단설정 완료"
echo -e "\n\n" 


#ssh 포트22 -> 1234 변경
echo -e "\n\n"
echo "SSH 포트 1234로 변경"
echo -e "\n\n"

sed -i 's/^#Port 22/Port 1234/' /etc/ssh/sshd_config
sudo yum install policycoreutils-python-utils
sudo semanage port -a -t ssh_port_t -p tcp 1234
sudo systemctl restart sshd

echo -e "\n\n"
echo "SSH 포트 1234로 변경 완료"
echo -e "\n\n"

 
#su 권한 설정
echo "파일 접근 권한 및 su 권한 설정 시작"
sed -i '/^#auth required pam_wheel.so use_uid/auth required pam_wheel.so use_uid/' /etc/pam.d/su
#su파일 접근권한 변경
chgrp wheel /bin/su
chmod 4750 /bin/su
#chmod +w /etc/sudoers
#chmod -w /etc/sudoers
sudo usermod -aG wheel $username

echo -e "\n\n" 
echo "sudo 설정 완료."
echo -e "\n\n" 
 
#보안설정
#패스워드 복잡성 설정
echo "패스워드 복잡성 설정 시작"
sed -i 's/^# minlen = 8/minlen = 8/' /etc/security/pwquality.conf
sed -i 's/^# dcredit = 0/decredit = 1/' /etc/security/pwquality.conf
sed -i 's/^# ocredit = 0/ocredit = 1/' /etc/security/pwquality.conf

echo -e "\n\n" 
echo "패스워드 복잡성 설정 완료"
echo -e "\n\n" 


#방화벽 DROP ZONE 설정
echo "방화벽 DROP ZONE 설정 시작"
firewall-cmd --set-default-zone=drop
firewall-cmd --permanent --add-port=1234/tcp
firewall-cmd --reload

echo -e "\n\n" 
echo "방화벽 DROP ZONE 설정 완료."
echo -e "\n\n" 

#로그인 접속 세션 시간 설정
echo "로그인 접속 세션 설정 및 HISTORY 타임라인 표시 설정 시작"
echo "export TMOUT=600" >> /etc/profile
echo "readonly TMOUT" >> /etc/profile
 
#HISTORY 타임라인 표시
sed -i 's/^HISTSIZE=1000/HISTSIZE=10000/' /etc/profile
sed -i '46a HISTTIMEFORMAT="%F %T "' /etc/profile
sed -i '54s/$/ HISTTIMEFORMAT TMOUT/' /etc/profile
source /etc/profile

echo -e "\n\n" 
echo "로그인 접속 세션 설정 및 HISTORY 타임라인 표시 완료"
echo -e "\n\n"


#faillock 계정잠금 설정
echo "faillock 계정 잠금 설정 시작"
authselect enable-feature with-faillock
authselect select -f -f sssd
 
sed -i 's/^# silent/silent/' /etc/security/faillock.conf
sed -i 's/^# deny = 3/deny = 3/' /etc/security/faillock.conf
sed -i 's/^# unlock_Time = 600/unlock_time = 600' /etc/security/faillock.conf
 
faillock
faillock --user $username

echo -e "\n\n" 
echo "faillock 계정잠금 설정 완료."
echo -e "\n\n"

echo -e "\n\n" 
echo "서버 표준화 설정 작업 완료!"
echo -e "\n\n" 
