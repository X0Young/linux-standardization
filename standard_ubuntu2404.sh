#!/bin/bash
set -euo pipefail

# 사용법: sudo bash standard_ubuntu2404.sh <생성할_사용자명>
# 예시:   sudo bash standard_ubuntu2404.sh sysadmin
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "[오류] 이 스크립트는 root 또는 sudo로 실행해야 합니다."
  echo "  사용법: sudo bash $0 <사용자명>"
  exit 1
fi

# 사용자명: 인자로 받음 (비대화형 실행 지원)
username="${1:?'[오류] 사용자명 인자가 필요합니다.  예: sudo bash standard_ubuntu2404.sh sysadmin'}"

#====[ 0) 공통: 백업 ]=========================================================
current_date=$(date +%Y-%m-%d)
desti_dir="/root/backup/$current_date"
mkdir -p "$desti_dir"

cp -p /etc/chrony/chrony.conf "$desti_dir/" 2>/dev/null || true
cp -p /etc/ssh/sshd_config "$desti_dir/"
cp -p /etc/pam.d/su "$desti_dir/"
cp -p /etc/security/pwquality.conf "$desti_dir/" 2>/dev/null || true
cp -p /etc/profile "$desti_dir/"
cp -p /etc/security/faillock.conf "$desti_dir/" 2>/dev/null || true
cp -p /etc/pam.d/common-auth "$desti_dir/" 2>/dev/null || true
cp -p /etc/pam.d/common-account "$desti_dir/" 2>/dev/null || true

echo -e "\nconfig 파일 백업 완료 → $desti_dir\n"

#====[ 1) 패키지 업데이트/설치 ]==============================================
echo "패키지 업데이트 시작"
apt-get update -y
apt-get -y upgrade

# snmp: 클라이언트 도구 / snmpd: 모니터링 에이전트 데몬
apt-get install -y \
  vim net-tools rsync tcpdump snmp snmpd dnsutils chrony ufw \
  libpam-pwquality libpam-modules

echo -e "\n패키지 업데이트/설치 완료\n"

#====[ 2) 시간 동기화(chrony + KST 설정) ]====================================
echo "시간 동기화 설정 시작"

systemctl enable --now chrony

# 기본 pool/server 라인 주석 처리 후 사내 NTP 서버 등록
sed -i 's/^\s*pool\s\+/## pool /' /etc/chrony/chrony.conf
sed -i 's/^\s*server\s\+.*iburst/## &/' /etc/chrony/chrony.conf
if ! grep -q '^server 192\.168\.5\.55 iburst' /etc/chrony/chrony.conf; then
  echo "server 192.168.5.55 iburst" >> /etc/chrony/chrony.conf
fi

systemctl restart chrony
sleep 2

echo "한국 표준시(Asia/Seoul)로 변경합니다..."
timedatectl set-timezone Asia/Seoul

echo
echo "==== [시간 동기화 상태 확인] ===="
timedatectl | grep -E 'Local time|Time zone|NTP'
echo
chronyc tracking | grep -E 'Stratum|System time|Last offset|Leap status'
echo "================================="
echo -e "\n시간 동기화 및 한국 표준시 설정 완료\n"

#====[ 3) 개인 계정 생성 + root 원격접속 차단 ]===============================
echo "개인 계정 생성 시작 (사용자: $username)"

if ! id "$username" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$username"
  echo "[안내] 계정이 생성되었습니다. 스크립트 완료 후 패스워드를 설정하세요:"
  echo "       sudo passwd $username"
else
  echo "[안내] 계정 '$username' 이 이미 존재합니다. 패스워드 설정은 수동으로 진행하세요:"
  echo "       sudo passwd $username"
fi

# SSH root 로그인 차단
if grep -qE '^\s*PermitRootLogin' /etc/ssh/sshd_config; then
  sed -i 's/^\s*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
  echo "PermitRootLogin no" >> /etc/ssh/sshd_config
fi

# ==== [ SSH 포트 24477로 변경 ] =============================================
echo "SSH 포트를 24477로 변경합니다."
if grep -qE '^\s*Port\s+' /etc/ssh/sshd_config; then
  sed -i 's/^\s*Port\s\+.*/Port 24477/' /etc/ssh/sshd_config
else
  echo "Port 24477" >> /etc/ssh/sshd_config
fi

# sshd 설정 검증
if sshd -t 2>/tmp/sshd_check.err; then
  systemctl restart ssh
  echo "→ SSH가 24477 포트로 재시작되었습니다."
else
  echo "!! sshd 설정 오류 발견:"; cat /tmp/sshd_check.err
  echo "설정 오류로 인해 SSH 재시작을 건너뜁니다. 위 오류를 수정하세요."
fi
# ============================================================================

echo -e "\n계정 생성 및 root 원격접속 차단설정 완료\n"

#====[ 4) su 제한 및 sudo 권한 ]==============================================
echo "su 권한 제한 및 sudo 설정 시작"
if ! grep -q '^auth\s\+required\s\+pam_wheel\.so' /etc/pam.d/su; then
  echo 'auth required pam_wheel.so use_uid group=sudo' >> /etc/pam.d/su
fi
chgrp sudo /bin/su
chmod 4750 /bin/su
usermod -aG sudo "$username"
echo -e "\nsudo 설정 완료\n"

#====[ 5) 패스워드 복잡성 ]===================================================
echo "패스워드 복잡성 설정 시작 (/etc/security/pwquality.conf)"
sed -i 's/^\s*#\?\s*minlen\s*=.*/minlen = 8/' /etc/security/pwquality.conf
for key in dcredit ocredit ucredit lcredit; do
  if grep -q "^\s*$key" /etc/security/pwquality.conf; then
    sed -i "s/^\s*$key\s*=.*/$key = -1/" /etc/security/pwquality.conf
  else
    echo "$key = -1" >> /etc/security/pwquality.conf
  fi
done
echo -e "\n패스워드 복잡성 설정 완료\n"

#====[ 6) 방화벽: UFW ]=======================================================
echo "UFW 방화벽 설정 시작"

# 현재 22번 포트로 연결 중일 경우를 대비해 일시 허용 후 마지막에 제거
ufw allow 22/tcp   2>/dev/null || true
ufw allow 24477/tcp
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
# SSH 포트가 24477로 완전 전환됐으므로 22번 규칙 제거
ufw delete allow 22/tcp 2>/dev/null || true
ufw status verbose
echo -e "\n방화벽(UFW) 설정 완료\n"

#====[ 7) HISTORY 전역 보강 (로그인/비로그인 + 즉시 반영 + 중복 방지) ]====
set +e
BASHRC_SYS="/etc/bash.bashrc"
PROFILED_FILE="/etc/profile.d/zzz-history.sh"

sed -i 's/\r$//' "$BASHRC_SYS" 2>/dev/null || true

tee "$PROFILED_FILE" >/dev/null <<'EOS'
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac
shopt -s histappend
export HISTTIMEFORMAT="${HISTTIMEFORMAT:-%F %T }"
export HISTSIZE=${HISTSIZE:-10000}
export HISTFILESIZE=${HISTFILESIZE:-20000}
export HISTCONTROL=ignoredups:erasedups
__append_hist_cmds() { history -a; history -n; }
case "${PROMPT_COMMAND:-}" in
  *__append_hist_cmds* ) ;;
  "" ) PROMPT_COMMAND="__append_hist_cmds" ;;
  * )  PROMPT_COMMAND="${PROMPT_COMMAND%; }; __append_hist_cmds" ;;
esac
export PROMPT_COMMAND
EOS

chown root:root "$PROFILED_FILE"
chmod 0644 "$PROFILED_FILE"
sed -i 's/\r$//' "$PROFILED_FILE" || true

if ! grep -q '__append_hist_cmds' "$BASHRC_SYS"; then
  tee -a "$BASHRC_SYS" >/dev/null <<'EOS'

# === history hardening (ensure last) ===
if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* ]]; then
  shopt -s histappend
  export HISTTIMEFORMAT="${HISTTIMEFORMAT:-%F %T }"
  export HISTSIZE=${HISTSIZE:-10000}
  export HISTFILESIZE=${HISTFILESIZE:-20000}
  export HISTCONTROL=ignoredups:erasedups
  __append_hist_cmds() { history -a; history -n; }
  case "${PROMPT_COMMAND:-}" in
    *__append_hist_cmds* ) ;;
    "" ) PROMPT_COMMAND="__append_hist_cmds" ;;
    * )  PROMPT_COMMAND="${PROMPT_COMMAND%; }; __append_hist_cmds" ;;
  esac
  export PROMPT_COMMAND
fi
# === /history hardening ===
EOS
  sed -i 's/\r$//' "$BASHRC_SYS" || true
fi

if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* ]]; then
  source "$PROFILED_FILE" || true
  source "$BASHRC_SYS" || true
fi

{
  echo
  echo "HISTORY 전역 보강 적용됨:"
  echo " - /etc/profile.d/zzz-history.sh (login shell)"
  echo " - /etc/bash.bashrc tail (non-login shell)"
  echo "현재 세션 값:"
  declare -p HISTTIMEFORMAT HISTSIZE HISTFILESIZE HISTCONTROL 2>/dev/null || true
  shopt histappend || true
  printf 'PROMPT_COMMAND=%q\n' "${PROMPT_COMMAND:-}"
  echo
} >&2

set -e

#====[ 7-추가) TMOUT 전역 강제(조건부, readonly, 1800) ]======================
TIMEOUT_FILE="/etc/profile.d/zzz-timeout.sh"
tee "$TIMEOUT_FILE" >/dev/null <<'EOS'
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac

_tm_decl="$(declare -p TMOUT 2>/dev/null || true)"
_tm_is_ro=0
if printf '%s' "$_tm_decl" | grep -q -- 'declare \-.*r'; then _tm_is_ro=1; fi
_tm_val="${TMOUT:-}"

if [ "$_tm_is_ro" -eq 0 ] || [ "$_tm_val" != "1800" ]; then
  TMOUT=1800
  readonly TMOUT
fi

unset _tm_decl _tm_is_ro _tm_val
EOS
chown root:root "$TIMEOUT_FILE"
chmod 0644 "$TIMEOUT_FILE"
sed -i 's/\r$//' "$TIMEOUT_FILE" || true

if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* ]]; then
  source "$TIMEOUT_FILE" || true
fi

{
  echo "TMOUT 강제(조건부) 적용됨: $TIMEOUT_FILE → 인터랙티브 bash에서 readonly TMOUT=1800 보장"
} >&2
#=============================================================================


#====[ 8) 계정 잠금 (faillock 정책 설정) ]====================================
echo "faillock 정책 설정 시작"

FAILLOCK_CONF="/etc/security/faillock.conf"

# pam_faillock.so 가 PAM 스택에 있는지 확인
if ! grep -q 'pam_faillock\.so' /etc/pam.d/common-auth 2>/dev/null; then
  echo "[경고] /etc/pam.d/common-auth 에 pam_faillock.so 가 없습니다."
  echo "       faillock.conf 설정이 적용되지 않을 수 있습니다."
  echo "       'pam-auth-update' 명령으로 faillock 모듈을 활성화하세요."
fi

if [ -f "$FAILLOCK_CONF" ]; then
  cp -p "$FAILLOCK_CONF" "$desti_dir/" 2>/dev/null || true

  if grep -qE '^\s*deny\s*=' "$FAILLOCK_CONF"; then
    sed -i 's/^\s*deny\s*=.*/deny = 5/' "$FAILLOCK_CONF"
  else
    echo 'deny = 5' >> "$FAILLOCK_CONF"
  fi

  if grep -qE '^\s*fail_interval\s*=' "$FAILLOCK_CONF"; then
    sed -i 's/^\s*fail_interval\s*=.*/fail_interval = 900/' "$FAILLOCK_CONF"
  else
    echo 'fail_interval = 900' >> "$FAILLOCK_CONF"
  fi

  if grep -qE '^\s*unlock_time\s*=' "$FAILLOCK_CONF"; then
    sed -i 's/^\s*unlock_time\s*=.*/unlock_time = 600/' "$FAILLOCK_CONF"
  else
    echo 'unlock_time = 600' >> "$FAILLOCK_CONF"
  fi
fi

echo -e "\nfaillock 정책 설정 완료\n"
#=============================================================================


#====[ 9) 패스워드 재사용 제한 (remember=2) ]=================================
echo "패스워드 재사용 제한 설정 시작 (remember=2)"

COMMON_PW="/etc/pam.d/common-password"
cp -p "$COMMON_PW" "$desti_dir/" 2>/dev/null || true

if ! grep -qE '^\s*password\s+required\s+pam_pwhistory\.so\b.*\bremember=2\b' "$COMMON_PW"; then
  if grep -qE '^\s*password\s+\[success=1\s+default=ignore\]\s+pam_unix\.so\b' "$COMMON_PW"; then
    sed -i '/^\s*password\s\+\[success=1\s\+default=ignore\]\s\+pam_unix\.so\b/i password required pam_pwhistory.so remember=2 use_authtok' "$COMMON_PW"
  else
    echo 'password required pam_pwhistory.so remember=2 use_authtok' >> "$COMMON_PW"
  fi
fi

sed -i 's/\r$//' "$COMMON_PW" || true

echo -e "\n패스워드 재사용 제한 설정 완료\n"
#=============================================================================


#====[ 10) PASS_MAX_DAYS=90 / PASS_MIN_DAYS=7 ]================================
echo "패스워드 만료 정책 설정 시작 (/etc/login.defs + chage)"

LOGIN_DEFS="/etc/login.defs"
cp -p "$LOGIN_DEFS" "$desti_dir/" 2>/dev/null || true

if grep -qE '^\s*PASS_MAX_DAYS' "$LOGIN_DEFS"; then
  sed -i 's/^\s*PASS_MAX_DAYS\s\+.*/PASS_MAX_DAYS\t90/' "$LOGIN_DEFS"
else
  printf '\nPASS_MAX_DAYS\t90\n' >> "$LOGIN_DEFS"
fi

if grep -qE '^\s*PASS_MIN_DAYS' "$LOGIN_DEFS"; then
  sed -i 's/^\s*PASS_MIN_DAYS\s\+.*/PASS_MIN_DAYS\t7/' "$LOGIN_DEFS"
else
  printf 'PASS_MIN_DAYS\t7\n' >> "$LOGIN_DEFS"
fi

chage -M 90 -m 7 "$username" || true
#chage -M 90 -m 7 root || true

# 기존 일반 계정 전체에도 동일 적용
echo "기존 일반 계정 패스워드 만료 정책 일괄 적용 중..."
for _u in $(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd); do
  chage -M 90 -m 7 "$_u" && echo "  chage 적용: $_u" || echo "  chage 실패(무시): $_u"
done

echo "==== [PASS_MAX/MIN 점검] ===="
grep -nE '^\s*PASS_(MAX|MIN)_DAYS' "$LOGIN_DEFS" || true
echo
# /etc/shadow 읽기에는 root 권한 필요 (스크립트는 root로 실행됨)
awk -F: '($5 > 90 || $5 == "") { print $1 ":" $5 }' /etc/shadow || true
echo "============================="

echo -e "\n패스워드 만료 정책 설정 완료\n"
#=============================================================================


#====[ 11) umask 전역 설정 (027) ]=============================================
echo "umask 전역 설정 시작 (027)"

UMASK_PROFILED="/etc/profile.d/zzz-umask.sh"
tee "$UMASK_PROFILED" >/dev/null <<'EOS'
# Global umask hardening
umask 027
EOS
chown root:root "$UMASK_PROFILED"
chmod 0644 "$UMASK_PROFILED"
sed -i 's/\r$//' "$UMASK_PROFILED" || true

if ! grep -q 'zzz-umask\.sh' /etc/bash.bashrc 2>/dev/null; then
  tee -a /etc/bash.bashrc >/dev/null <<'EOS'

# === umask hardening (ensure non-login shells too) ===
if [ -r /etc/profile.d/zzz-umask.sh ]; then
  . /etc/profile.d/zzz-umask.sh
else
  umask 027
fi
# === /umask hardening ===
EOS
  sed -i 's/\r$//' /etc/bash.bashrc || true
fi

echo "현재 세션 umask(참고):"
umask || true
echo -e "\numask 전역 설정 완료\n"
#=============================================================================


#====[ 12) PATH 환경변수에 '.' 포함 제거(예방) ]===============================
echo "PATH에 현재디렉토리(.) 포함 방지 설정 시작"

PATH_HARDEN="/etc/profile.d/zzz-path.sh"
tee "$PATH_HARDEN" >/dev/null <<'EOS'
# Remove '.' from PATH to prevent execution from current directory
sanitize_path() {
  local IFS=':' new=() p
  for p in $PATH; do
    [ -z "$p" ] && continue
    [ "$p" = "." ] && continue
    new+=("$p")
  done
  PATH="$(IFS=:; echo "${new[*]}")"
  export PATH
}
sanitize_path
unset -f sanitize_path
EOS
chown root:root "$PATH_HARDEN"
chmod 0644 "$PATH_HARDEN"
sed -i 's/\r$//' "$PATH_HARDEN" || true

echo -e "\nPATH 하드닝 완료\n"
#=============================================================================


#====[ 13) 주요 보안 파일 권한/소유자 하드닝 ]=================================
echo "주요 파일 권한/소유자 하드닝 시작"

chown root:root /etc/passwd /etc/group || true
chmod 0644 /etc/passwd /etc/group || true

# /etc/shadow: Ubuntu 표준 root:shadow 640
if getent group shadow >/dev/null 2>&1; then
  chown root:shadow /etc/shadow || true
  chmod 0640 /etc/shadow || true
else
  chown root:root /etc/shadow || true
  chmod 0400 /etc/shadow || true
fi

chown root:root /etc/hosts /etc/services || true
chmod 0644 /etc/hosts /etc/services || true

chown root:root /etc/profile || true
chmod 0755 /etc/profile || true

chown root:root /etc/pam.d/common-password /etc/pam.d/common-auth /etc/pam.d/common-account 2>/dev/null || true
chmod 0644 /etc/pam.d/common-password /etc/pam.d/common-auth /etc/pam.d/common-account 2>/dev/null || true

# 주요 명령어 root 전용 실행 (700)
chmod 0700 /usr/bin/last 2>/dev/null || true
[ -f /usr/sbin/ifconfig ] && chmod 0700 /usr/sbin/ifconfig 2>/dev/null || true

if [ ! -f /etc/cron.allow ]; then
  touch /etc/cron.allow
fi
chown root:root /etc/cron.allow || true
chmod 0600 /etc/cron.allow || true

if [ -f /etc/cron.deny ]; then
  chown root:root /etc/cron.deny || true
  chmod 0600 /etc/cron.deny || true
fi

# wtmp/btmp: 0664(root:utmp) → 감사 정책상 0600 설정
# ※ 0600 설정 시 일반 유저의 last/who 명령 결과가 제한됩니다
chown root:utmp /var/log/wtmp 2>/dev/null || true
chmod 0600 /var/log/wtmp 2>/dev/null || true
chown root:utmp /var/log/btmp 2>/dev/null || true
chmod 0600 /var/log/btmp 2>/dev/null || true

# Ubuntu: auth.log (Rocky/RHEL: /var/log/secure)
[ -f /var/log/auth.log ] && chmod 0640 /var/log/auth.log || true
# Ubuntu 24.04는 /var/log/messages 기본 없음 (syslog/journald 사용)
[ -f /var/log/messages ] && chmod 0644 /var/log/messages || true
[ -f /var/log/syslog   ] && chmod 0640 /var/log/syslog   || true

for f in /etc/passwd.* /etc/group.* /etc/shadow.* /etc/hosts.* /etc/services.*; do
  [ -e "$f" ] || continue
  chown root:root "$f" || true
  chmod 0600 "$f" || true
done

echo -e "\n주요 파일 권한/소유자 하드닝 완료\n"
#=============================================================================


#====[ 14) securetty(pts) 제거 및 pam_securetty 존재 확인(콘솔 root) ]========
echo "securetty/pam_securetty 점검 시작 (콘솔 root 로그인 제한)"

PAM_LOGIN="/etc/pam.d/login"
SECURETTY="/etc/securetty"

if [ -f "$PAM_LOGIN" ]; then
  cp -p "$PAM_LOGIN" "$desti_dir/" 2>/dev/null || true
  if ! grep -qE 'pam_securetty\.so' "$PAM_LOGIN"; then
    # /etc/securetty 가 없는 Ubuntu 22.04+ 에서 추가하면 콘솔 root 로그인 전면 차단됨
    # → /etc/securetty 존재 시에만 추가
    if [ -f "$SECURETTY" ]; then
      sed -i '1i auth required pam_securetty.so' "$PAM_LOGIN" || true
      echo "[적용] pam_securetty.so 추가됨"
    else
      echo "[건너뜀] /etc/securetty 없음 → Ubuntu 22.04+ 에서는 pam_securetty.so 추가 생략"
      echo "         콘솔 root 로그인 제한이 필요하면 수동으로 /etc/securetty 를 생성하세요."
    fi
  else
    echo "[확인] pam_securetty.so 이미 존재"
  fi
fi

# /etc/securetty 에 pts/* 있으면 제거
if [ -f "$SECURETTY" ]; then
  cp -p "$SECURETTY" "$desti_dir/" 2>/dev/null || true
  sed -i '/^\s*pts\/[0-9]\+\s*$/d' "$SECURETTY" || true
  echo "[적용] /etc/securetty 에서 pts/* 항목 제거됨"
fi

echo -e "\nsecuretty/pam_securetty 점검 완료\n"
#=============================================================================


echo -e "\n======================================================"
echo " 보안 하드닝 완료"
echo "======================================================"
echo " ※ 아래 작업은 수동으로 진행하세요:"
echo "   1. 패스워드 설정:  sudo passwd $username"
echo "   2. SSH 재접속 포트 확인: 24477"
echo "   3. faillock PAM 활성화 확인: grep pam_faillock /etc/pam.d/common-auth"
echo "======================================================"
