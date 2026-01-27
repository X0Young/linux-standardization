#!/bin/bash
set -euo pipefail

#====[ 0) 공통: 백업 ]=========================================================
current_date=$(date +%Y-%m-%d)
desti_dir="/home/backup/$current_date"
sudo mkdir -p "$desti_dir"

sudo cp -p /etc/chrony/chrony.conf "$desti_dir/" 2>/dev/null || true   # Ubuntu 경로
sudo cp -p /etc/ssh/sshd_config "$desti_dir/"
sudo cp -p /etc/pam.d/su "$desti_dir/"
sudo cp -p /etc/security/pwquality.conf "$desti_dir/" 2>/dev/null || true
sudo cp -p /etc/profile "$desti_dir/"
sudo cp -p /etc/security/faillock.conf "$desti_dir/" 2>/dev/null || true
sudo cp -p /etc/pam.d/common-auth "$desti_dir/" 2>/dev/null || true
sudo cp -p /etc/pam.d/common-account "$desti_dir/" 2>/dev/null || true

echo -e "\nconfig 파일 백업 완료 → $desti_dir\n"

#====[ 1) 패키지 업데이트/설치 ]==============================================
echo "패키지 업데이트 시작"
sudo apt-get update -y
sudo apt-get -y upgrade

sudo apt-get install -y \
  vim net-tools rsync tcpdump snmp dnsutils chrony ufw \
  libpam-pwquality libpam-modules

echo -e "\n패키지 업데이트/설치 완료\n"

#====[ 2) 시간 동기화(chrony + KST 설정) ]====================================
echo "시간 동기화 설정 시작"

# chrony 서비스 활성화
sudo systemctl enable --now chrony

# 기본 pool 라인 주석 처리 후 사내 NTP 서버 등록
sudo sed -i 's/^\s*pool\s\+/## pool /' /etc/chrony/chrony.conf
sudo sed -i 's/^\s*server\s\+.*iburst/## &/' /etc/chrony/chrony.conf
if ! grep -q '^server 192\.168\.5\.55 iburst' /etc/chrony/chrony.conf; then
  echo "server 192.168.5.55 iburst" | sudo tee -a /etc/chrony/chrony.conf >/dev/null
fi

# 서비스 재시작 및 안정화 대기
sudo systemctl restart chrony
sleep 2

# 한국 표준시(Asia/Seoul)로 변경
echo "한국 표준시(Asia/Seoul)로 변경합니다..."
sudo timedatectl set-timezone Asia/Seoul

# 상태 출력
echo
echo "==== [시간 동기화 상태 확인] ===="
timedatectl | grep -E 'Local time|Time zone|NTP'
echo
chronyc tracking | grep -E 'Stratum|System time|Last offset|Leap status'
echo "================================="
echo -e "\n시간 동기화 및 한국 표준시 설정 완료\n"

#====[ 3) 개인 계정 생성 + root 원격접속 차단 ]===============================
echo "개인 계정 생성 시작"
read -p "새로 생성할 사용자명을 입력하세요: " username
if ! id "$username" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "$username"
fi
echo "새로 생성된 사용자 $username의 패스워드를 입력하세요:"
sudo passwd "$username"

# SSH root 로그인 차단
if grep -qE '^\s*PermitRootLogin' /etc/ssh/sshd_config; then
  sudo sed -i 's/^\s*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
  echo "PermitRootLogin no" | sudo tee -a /etc/ssh/sshd_config >/dev/null
fi

# ==== [ SSH 포트 24477로 변경 ] =============================================
echo "SSH 포트를 24477로 변경합니다."
if grep -qE '^\s*Port\s+' /etc/ssh/sshd_config; then
  sudo sed -i 's/^\s*Port\s\+.*/Port 24477/' /etc/ssh/sshd_config
else
  echo "Port 24477" | sudo tee -a /etc/ssh/sshd_config >/dev/null
fi

if command -v ufw >/dev/null 2>&1; then
  if sudo ufw status | grep -qi "Status: active"; then
    sudo ufw allow 24477/tcp || true
  fi
fi

if sudo sshd -t 2>/tmp/sshd_check.err; then
  sudo systemctl restart ssh
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
  echo 'auth required pam_wheel.so use_uid group=sudo' | sudo tee -a /etc/pam.d/su >/dev/null
fi
sudo chgrp sudo /bin/su
sudo chmod 4750 /bin/su
sudo usermod -aG sudo "$username"
echo -e "\nsudo 설정 완료\n"

#====[ 5) 패스워드 복잡성 ]===================================================
echo "패스워드 복잡성 설정 시작 (/etc/security/pwquality.conf)"
sudo sed -i 's/^\s*#\?\s*minlen\s*=.*/minlen = 8/' /etc/security/pwquality.conf
for key in dcredit ocredit ucredit lcredit; do
  if grep -q "^\s*$key" /etc/security/pwquality.conf; then
    sudo sed -i "s/^\s*$key\s*=.*/$key = -1/" /etc/security/pwquality.conf
  else
    echo "$key = -1" | sudo tee -a /etc/security/pwquality.conf >/dev/null
  fi
done
echo -e "\n패스워드 복잡성 설정 완료\n"

#====[ 6) 방화벽: UFW ]=======================================================
echo "UFW 방화벽 설정 시작"
sudo ufw allow 24477/tcp
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo ufw status verbose
echo -e "\n방화벽(UFW) 설정 완료\n"

#====[ 7) HISTORY 전역 보강 (로그인/비로그인 + 즉시 반영 + 중복 방지) ]====
set +e
if [[ $EUID -ne 0 ]]; then SUDO="sudo"; else SUDO=""; fi
BASHRC_SYS="/etc/bash.bashrc"
PROFILED_FILE="/etc/profile.d/zzz-history.sh"

$SUDO sed -i 's/\r$//' "$BASHRC_SYS" 2>/dev/null || true
$SUDO sed -i 's/\r$//' "$PROFILED_FILE" 2>/dev/null || true

$SUDO tee "$PROFILED_FILE" >/dev/null <<'EOS'
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

$SUDO chown root:root "$PROFILED_FILE"
$SUDO chmod 0644 "$PROFILED_FILE"
$SUDO sed -i 's/\r$//' "$PROFILED_FILE" || true

if ! grep -q '__append_hist_cmds' "$BASHRC_SYS"; then
  $SUDO tee -a "$BASHRC_SYS" >/dev/null <<'EOS'

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
  $SUDO sed -i 's/\r$//' "$BASHRC_SYS" || true
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

#====[ 7-추가) TMOUT 전역 강제(조건부, readonly, 600) ]======================
# - 목표: 인터랙티브 bash에서 TMOUT이 "없거나/readonly 아님/값이 600 아님"이면 → 600 + readonly 로 강제
# - 이미 readonly TMOUT=600 이면 그대로 유지. (다른 값으로 readonly 되어 있으면 600으로 재설정)
TIMEOUT_FILE="/etc/profile.d/zzz-timeout.sh"
sudo tee "$TIMEOUT_FILE" >/dev/null <<'EOS'
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac

# 선언 상태 확인
_tm_decl="$(declare -p TMOUT 2>/dev/null || true)"
_tm_is_ro=0
if printf '%s' "$_tm_decl" | grep -q -- 'declare \-.*r'; then _tm_is_ro=1; fi

# 현재 값
_tm_val="${TMOUT:-}"

# 조건: readonly 아니거나 값이 600이 아니면 → 600 + readonly 재설정
if [ "$_tm_is_ro" -eq 0 ] || [ "$_tm_val" != "600" ]; then
  TMOUT=600
  readonly TMOUT
fi

unset _tm_decl _tm_is_ro _tm_val
EOS
sudo chown root:root "$TIMEOUT_FILE"
sudo chmod 0644 "$TIMEOUT_FILE"
sudo sed -i 's/\r$//' "$TIMEOUT_FILE" || true

# 지금 셸이 bash 인터랙티브면 즉시 반영
if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* ]]; then
  # shellcheck disable=SC1091
  source "$TIMEOUT_FILE" || true
fi

# 상태 안내
{
  echo "TMOUT 강제(조건부) 적용됨: $TIMEOUT_FILE  → 인터랙티브 bash에서 readonly TMOUT=600 보장"
} >&2
#=============================================================================


#====[ 8) 계정 잠금 (faillock 정책만 설정 / PAM 직접 수정 없음) ]============
echo "faillock 정책 설정 시작 (PAM 파일은 변경하지 않음)"

FAILLOCK_CONF="/etc/security/faillock.conf"

if [ -f "$FAILLOCK_CONF" ]; then
  sudo cp -p "$FAILLOCK_CONF" "$desti_dir/" 2>/dev/null || true

  # deny
  if grep -qE '^\s*deny\s*=' "$FAILLOCK_CONF"; then
    sudo sed -i 's/^\s*deny\s*=.*/deny = 5/' "$FAILLOCK_CONF"
  else
    echo 'deny = 5' | sudo tee -a "$FAILLOCK_CONF" >/dev/null
  fi

  # fail_interval (15분)
  if grep -qE '^\s*fail_interval\s*=' "$FAILLOCK_CONF"; then
    sudo sed -i 's/^\s*fail_interval\s*=.*/fail_interval = 900/' "$FAILLOCK_CONF"
  else
    echo 'fail_interval = 900' | sudo tee -a "$FAILLOCK_CONF" >/dev/null
  fi

  # unlock_time (10분)
  if grep -qE '^\s*unlock_time\s*=' "$FAILLOCK_CONF"; then
    sudo sed -i 's/^\s*unlock_time\s*=.*/unlock_time = 600/' "$FAILLOCK_CONF"
  else
    echo 'unlock_time = 600' | sudo tee -a "$FAILLOCK_CONF" >/dev/null
  fi
fi

echo -e "\nfaillock 정책 설정 완료\n"
#=============================================================================



#====[ 9) 패스워드 재사용 제한 (remember=2) ]=================================
echo "패스워드 재사용 제한 설정 시작 (remember=2)"

COMMON_PW="/etc/pam.d/common-password"

# 백업
sudo cp -p "$COMMON_PW" "$desti_dir/" 2>/dev/null || true

# Ubuntu 24.04 기본 common-password 구성에서 pam_unix.so 라인 앞에 pam_pwhistory 추가 권장
# - 이미 remember=2 설정이 있으면 추가 안 함
# - pam_pwhistory 모듈은 보통 libpam-modules 패키지에 포함 (이미 설치됨)
if ! grep -qE '^\s*password\s+required\s+pam_pwhistory\.so\b.*\bremember=2\b' "$COMMON_PW"; then
  if grep -qE '^\s*password\s+\[success=1\s+default=ignore\]\s+pam_unix\.so\b' "$COMMON_PW"; then
    sudo sed -i '/^\s*password\s\+\[success=1\s\+default=ignore\]\s\+pam_unix\.so\b/i password required pam_pwhistory.so remember=2 use_authtok' "$COMMON_PW"
  else
    # 예상 라인이 없으면 파일 끝에라도 추가 (최소 적용)
    echo 'password required pam_pwhistory.so remember=2 use_authtok' | sudo tee -a "$COMMON_PW" >/dev/null
  fi
fi

# CRLF 제거
sudo sed -i 's/\r$//' "$COMMON_PW" || true

echo -e "\n패스워드 재사용 제한 설정 완료\n"
#=============================================================================


#====[ 10) PASS_MAX_DAYS=90 / PASS_MIN_DAYS=7 ]================================
echo "패스워드 만료 정책 설정 시작 (/etc/login.defs + chage)"

LOGIN_DEFS="/etc/login.defs"
sudo cp -p "$LOGIN_DEFS" "$desti_dir/" 2>/dev/null || true

# /etc/login.defs 값 강제
if grep -qE '^\s*PASS_MAX_DAYS' "$LOGIN_DEFS"; then
  sudo sed -i 's/^\s*PASS_MAX_DAYS\s\+.*/PASS_MAX_DAYS\t90/' "$LOGIN_DEFS"
else
  echo -e "\nPASS_MAX_DAYS\t90" | sudo tee -a "$LOGIN_DEFS" >/dev/null
fi

if grep -qE '^\s*PASS_MIN_DAYS' "$LOGIN_DEFS"; then
  sudo sed -i 's/^\s*PASS_MIN_DAYS\s\+.*/PASS_MIN_DAYS\t7/' "$LOGIN_DEFS"
else
  echo -e "PASS_MIN_DAYS\t7" | sudo tee -a "$LOGIN_DEFS" >/dev/null
fi

# 신규 생성 사용자/루트 계정에 즉시 반영 (감사 점검 시 shadow 기준에도 걸리도록)
# - root 적용이 부담되면 아래 root 라인만 주석 처리하면 됨.
sudo chage -M 90 -m 7 "$username" || true
#sudo chage -M 90 -m 7 root || true

# 점검용 출력 (요구사항에 있는 awk와 동일 의미)
echo "==== [PASS_MAX/MIN 점검] ===="
grep -nE '^\s*PASS_(MAX|MIN)_DAYS' "$LOGIN_DEFS" || true
echo
awk -F: '($5 > 90 || $5 == "") { print $1 ":" $5 }' /etc/shadow || true
echo "============================="

echo -e "\n패스워드 만료 정책 설정 완료\n"
#=============================================================================


#====[ 11) umask 전역 설정 (022 또는 027) ]====================================
echo "umask 전역 설정 시작 (권고: 027)"

UMASK_PROFILED="/etc/profile.d/zzz-umask.sh"
sudo tee "$UMASK_PROFILED" >/dev/null <<'EOS'
# Global umask hardening
# - 022 or 027 accepted by typical audit baselines
# - Choose 027 for stricter default permissions
umask 027
EOS
sudo chown root:root "$UMASK_PROFILED"
sudo chmod 0644 "$UMASK_PROFILED"
sudo sed -i 's/\r$//' "$UMASK_PROFILED" || true

# 비로그인 인터랙티브 쉘에서 /etc/profile.d가 안 먹는 케이스 대비(/etc/bash.bashrc)
# (중복 삽입 방지)
if ! grep -q 'zzz-umask\.sh' /etc/bash.bashrc 2>/dev/null; then
  sudo tee -a /etc/bash.bashrc >/dev/null <<'EOS'

# === umask hardening (ensure non-login shells too) ===
if [ -r /etc/profile.d/zzz-umask.sh ]; then
  . /etc/profile.d/zzz-umask.sh
else
  umask 027
fi
# === /umask hardening ===
EOS
  sudo sed -i 's/\r$//' /etc/bash.bashrc || true
fi

echo "현재 세션 umask(참고):"
umask || true
echo -e "\numask 전역 설정 완료\n"
#=============================================================================


#====[ 12) PATH 환경변수에 '.' 포함 제거(예방) ]===============================
echo "PATH에 현재디렉토리(.) 포함 방지 설정 시작"

PATH_HARDEN="/etc/profile.d/zzz-path.sh"
sudo tee "$PATH_HARDEN" >/dev/null <<'EOS'
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
sudo chown root:root "$PATH_HARDEN"
sudo chmod 0644 "$PATH_HARDEN"
sudo sed -i 's/\r$//' "$PATH_HARDEN" || true

echo -e "\nPATH 하드닝 완료\n"
#=============================================================================


#====[ 13) 주요 보안 파일 권한/소유자 하드닝(누락 항목) ]=====================
echo "주요 파일 권한/소유자 하드닝 시작"

# /etc/passwd, /etc/group
sudo chown root:root /etc/passwd /etc/group || true
sudo chmod 0644 /etc/passwd /etc/group || true

# /etc/shadow (정책표는 400을 요구하지만 Ubuntu 표준은 640(root:shadow)인 경우가 많음)
# - 안전/호환을 위해 root:shadow + 640 권장
if getent group shadow >/dev/null 2>&1; then
  sudo chown root:shadow /etc/shadow || true
  sudo chmod 0640 /etc/shadow || true
else
  sudo chown root:root /etc/shadow || true
  sudo chmod 0400 /etc/shadow || true
fi

# /etc/hosts, /etc/services (정책: 600 또는 644)
sudo chown root:root /etc/hosts /etc/services || true
sudo chmod 0644 /etc/hosts /etc/services || true

# /etc/profile (정책: 755)
sudo chown root:root /etc/profile || true
sudo chmod 0755 /etc/profile || true

# PAM 파일 권한 (타 사용자 쓰기 금지)
sudo chown root:root /etc/pam.d/common-password /etc/pam.d/common-auth /etc/pam.d/common-account 2>/dev/null || true
sudo chmod 0644 /etc/pam.d/common-password /etc/pam.d/common-auth /etc/pam.d/common-account 2>/dev/null || true

# cron.allow / cron.deny (없으면 생성)
if [ ! -f /etc/cron.allow ]; then
  sudo touch /etc/cron.allow
fi
sudo chown root:root /etc/cron.allow || true
sudo chmod 0600 /etc/cron.allow || true

if [ -f /etc/cron.deny ]; then
  sudo chown root:root /etc/cron.deny || true
  sudo chmod 0600 /etc/cron.deny || true
fi

# wtmp/btmp 권한 (Ubuntu는 /var/log)
sudo chown root:utmp /var/log/wtmp 2>/dev/null || true
sudo chmod 0600 /var/log/wtmp 2>/dev/null || true
sudo chown root:utmp /var/log/btmp 2>/dev/null || true
sudo chmod 0600 /var/log/btmp 2>/dev/null || true

# auth.log/messages 권한 (정책표: messages 644)
[ -f /var/log/auth.log ] && sudo chmod 0640 /var/log/auth.log || true
[ -f /var/log/messages ] && sudo chmod 0644 /var/log/messages || true

# 유사 백업 파일(예: passwd.old, hosts.bak 등) 권한 600 이하로 제한
for f in /etc/passwd.* /etc/group.* /etc/shadow.* /etc/hosts.* /etc/services.*; do
  [ -e "$f" ] || continue
  sudo chown root:root "$f" || true
  sudo chmod 0600 "$f" || true
done

echo -e "\n주요 파일 권한/소유자 하드닝 완료\n"
#=============================================================================


#====[ 14) securetty(pts) 제거 및 pam_securetty 존재 확인(콘솔 root) ]========
echo "securetty/pam_securetty 점검 시작 (콘솔 root 로그인 제한)"

PAM_LOGIN="/etc/pam.d/login"
SECURETTY="/etc/securetty"

# pam_securetty 라인 존재 확인 (Ubuntu 기본 구성에 있는 편)
if [ -f "$PAM_LOGIN" ]; then
  sudo cp -p "$PAM_LOGIN" "$desti_dir/" 2>/dev/null || true
  if ! grep -qE 'pam_securetty\.so' "$PAM_LOGIN"; then
    # 가장 위쪽에 추가(보수적으로)
    sudo sed -i '1i auth required pam_securetty.so' "$PAM_LOGIN" || true
  fi
fi

# /etc/securetty 에 pts/* 있으면 제거 (정책표 요구)
if [ -f "$SECURETTY" ]; then
  sudo cp -p "$SECURETTY" "$desti_dir/" 2>/dev/null || true
  sudo sed -i '/^\s*pts\/[0-9]\+\s*$/d' "$SECURETTY" || true
fi

echo -e "\nsecuretty/pam_securetty 점검 완료\n"
#=============================================================================


echo -e "\n[추가 하드닝] 누락 항목 보완 완료\n"

                                                                                                                                                                                                                                   
