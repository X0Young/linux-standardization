#!/bin/bash
#===============================================================================
# Rocky Linux 9 서버 보안 표준화 스크립트
#  - Rocky8 스크립트와 동일한 보안 항목 적용 (추가 하드닝 포함)
#===============================================================================

#-------------------------------------------------------------------------------
# 1. config 파일 변경 전 백업
#-------------------------------------------------------------------------------
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

#-------------------------------------------------------------------------------
# 2. 패키지 업데이트 및 기본 패키지 설치
#-------------------------------------------------------------------------------
echo "패키지 업데이트 시작"
yum update -y

# 기본 유틸 패키지 설치
yum install -y vim net-tools rsync tcpdump net-snmp bind-utils policycoreutils-python-utils

echo -e "\n\n"
echo "패키지 업데이트 및 기본 패키지 설치 완료"
echo -e "\n\n"

#-------------------------------------------------------------------------------
# 3. 시간 동기화 설정 (chrony)
#-------------------------------------------------------------------------------
echo "시간 동기화 설정 시작"
dnf install -y chrony
systemctl enable chronyd
systemctl start chronyd

# 기본 pool 주석 처리 후 내부 NTP 서버로 변경
sed -i '/^pool 2.rocky.pool.ntp.org iburst/s/^/#/' /etc/chrony.conf
echo "server 192.168.5.55 iburst" >> /etc/chrony.conf
systemctl restart chronyd

echo -e "\n\n"
echo "시간 동기화 설정 완료"
echo -e "\n\n"

#-------------------------------------------------------------------------------
# 4. 개인 계정 생성 및 root 원격 접속 차단
#-------------------------------------------------------------------------------
echo "개인 계정 생성 시작"

# 사용자명 입력 받기
read -p "새로 생성할 사용자명을 입력하세요: " username

# 사용자 추가
useradd "$username"
echo "새로 생성된 사용자 $username의 패스워드를 입력하세요:"
passwd "$username"
echo "사용자 $username이 생성되고 비밀번호가 설정되었습니다."

# root 원격 접속 차단 (범용 패턴)

# 메인 설정
sed -ri 's/^#?\s*PermitRootLogin\s+.*/PermitRootLogin no/' /etc/ssh/sshd_config

# 추가 include된 설정 파일들까지 일괄 처리
if ls /etc/ssh/sshd_config.d/*.conf &>/dev/null; then
  sed -ri 's/^#?\s*PermitRootLogin\s+.*/PermitRootLogin no/' /etc/ssh/sshd_config.d/*.conf
fi

# 설정 반영
systemctl reload sshd

echo " - sshd 설정 적용 완료 (PermitRootLogin no)"
#sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

echo -e "\n\n"
echo "계정 생성 및 root 원격접속 차단설정 완료"
echo -e "\n\n"

#-------------------------------------------------------------------------------
# 5. su 권한 설정 (wheel 그룹만 su 사용 가능)
#-------------------------------------------------------------------------------
echo "파일 접근 권한 및 su 권한 설정 시작"

# /etc/pam.d/su에 wheel 제한 적용
sed -i '/^#auth required pam_wheel.so use_uid/auth required pam_wheel.so use_uid/' /etc/pam.d/su

# /bin/su 접근 권한 제한
chgrp wheel /bin/su
chmod 4750 /bin/su

# 새 사용자 wheel 그룹 추가
usermod -aG wheel "$username"

echo -e "\n\n"
echo "sudo / su 권한 설정 완료."
echo -e "\n\n"

#-------------------------------------------------------------------------------
# 6. 패스워드 복잡성 및 사용 기간 정책
#-------------------------------------------------------------------------------
echo "패스워드 복잡성 설정 시작"

# 최소 길이 강화 (예: 8자리)
sed -ri 's/^#?\s*minlen\s*=.*/minlen = 8/' /etc/security/pwquality.conf

# 숫자 / 대문자 / 소문자 / 특수문자 최소 1개씩 포함
sed -ri 's/^#?\s*dcredit\s*=.*/dcredit = -1/' /etc/security/pwquality.conf
sed -ri 's/^#?\s*ucredit\s*=.*/ucredit = -1/' /etc/security/pwquality.conf
sed -ri 's/^#?\s*lcredit\s*=.*/lcredit = -1/' /etc/security/pwquality.conf
sed -ri 's/^#?\s*ocredit\s*=.*/ocredit = -1/' /etc/security/pwquality.conf

# 패스워드 최근 암호 기억 개수 / 최대 사용기간
sed -ri 's/(password\s+sufficient\s+pam.unix.so.*)/\1 remember=2/' /etc/pam.d/system-auth
sed -ri 's/(password\s+sufficient\s+pam.unix.so.*)/\1 remember=2/' /etc/pam.d/password-auth
sed -ri 's/^#?\s*PASS_MAX_DAYS\s+.*/PASS_MAX_DAYS   90/' /etc/login.defs

echo -e "\n\n"
echo "패스워드 복잡성 및 사용 기간 설정 완료"
echo -e "\n\n"

#-------------------------------------------------------------------------------
# 7. 방화벽 DROP ZONE 설정 및 SSH 포트 오픈
#-------------------------------------------------------------------------------
echo "방화벽 DROP ZONE 설정 시작"

firewall-cmd --set-default-zone=drop
firewall-cmd --permanent --add-port=24477/tcp
firewall-cmd --reload

echo -e "\n\n"
echo "방화벽 DROP ZONE 설정 완료."
echo -e "\n\n"

#-------------------------------------------------------------------------------
# 8. (삭제됨) 로그인 세션 & HISTORY /etc/profile 직접 수정
#   -> profile.d 기반 하드닝에서 통합 관리
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# 9. faillock 계정 잠금 설정
#-------------------------------------------------------------------------------
echo "faillock 계정 잠금 설정 시작"

authselect enable-feature with-faillock
authselect select -f -f sssd   # 기존 형태 유지

sed -i 's/^# silent/silent/' /etc/security/faillock.conf
sed -i 's/^# deny = 3/deny = 3/' /etc/security/faillock.conf
sed -i 's/^# unlock_Time = 600/unlock_time = 600/' /etc/security/faillock.conf

faillock
faillock --user "$username"

echo -e "\n\n"
echo "faillock 계정잠금 설정 완료."
echo -e "\n\n"

###############################################################################
# [추가] Rocky Linux 9 보안 하드닝 (Rocky8 스크립트와 동일 항목)
###############################################################################

echo "=== [추가 하드닝] Rocky Linux 9 보안 설정 시작 ==="

#====[ A) HISTORY 전역 보강 ]=================================================
HIST_FILE="/etc/profile.d/zzz-history.sh"

cat <<'EOF' > "$HIST_FILE"
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac

shopt -s histappend
export HISTTIMEFORMAT="%F %T "
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoredups:erasedups

__append_hist_cmds() { history -a; history -n; }

case "${PROMPT_COMMAND:-}" in
  *__append_hist_cmds* ) ;;
  "" ) PROMPT_COMMAND="__append_hist_cmds" ;;
  * ) PROMPT_COMMAND="${PROMPT_COMMAND}; __append_hist_cmds" ;;
esac

export PROMPT_COMMAND
EOF

chmod 0644 "$HIST_FILE"
chown root:root "$HIST_FILE"

echo " - HISTORY 전역 보강 완료"

#====[ B) TMOUT 전역 강제 (1800초, readonly) ]=================================
TMOUT_FILE="/etc/profile.d/zzz-timeout.sh"

cat <<'EOF' > "$TMOUT_FILE"
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac

TMOUT=1800
readonly TMOUT
export TMOUT
EOF

chmod 0644 "$TMOUT_FILE"
chown root:root "$TMOUT_FILE"

echo " - TMOUT 전역 강제 완료"

#====[ C) umask 전역 설정 (027) ]=============================================
UMASK_FILE="/etc/profile.d/zzz-umask.sh"

cat <<'EOF' > "$UMASK_FILE"
umask 027
EOF

chmod 0644 "$UMASK_FILE"
chown root:root "$UMASK_FILE"

echo " - umask 027 전역 설정 완료"

#====[ D) PATH에 현재 디렉토리(.) 제거 ]======================================
PATH_FILE="/etc/profile.d/zzz-path.sh"

cat <<'EOF' > "$PATH_FILE"
sanitize_path() {
  local IFS=':' newpath=() p
  for p in $PATH; do
    [ "$p" = "." ] && continue
    newpath+=("$p")
  done
  PATH="$(IFS=:; echo "${newpath[*]}")"
  export PATH
}
sanitize_path
unset -f sanitize_path
EOF

chmod 0644 "$PATH_FILE"
chown root:root "$PATH_FILE"

echo " - PATH 하드닝 완료"

#====[ E) 주요 보안 파일 권한/소유자 하드닝 ]=================================
chown root:root /etc/passwd /etc/group
chmod 0644 /etc/passwd /etc/group

chown root:root /etc/shadow
chmod 0400 /etc/shadow

chmod 0644 /etc/hosts /etc/services
chmod 0755 /etc/profile

for f in /etc/passwd.* /etc/group.* /etc/shadow.*; do
  [ -e "$f" ] || continue
  chmod 0600 "$f"
done

echo " - 주요 보안 파일 권한 설정 완료"

#====[ F) faillock 상태 점검 ]=================================================
echo "==== [faillock 상태 확인] ===="
faillock || true
faillock --user "$username" || true
echo "==============================="

echo "=== [추가 하드닝] Rocky Linux 9 보안 설정 완료 ==="
###############################################################################

echo -e "\n\n"
echo "서버 표준화 설정 작업 완료!"
echo -e "\n\n"
