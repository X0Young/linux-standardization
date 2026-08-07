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
# 기본 pool 주석 처리 (재실행해도 '##' 이 되지 않도록 이미 주석인 줄은 제외)
sed -ri 's/^([[:space:]]*pool[[:space:]]+.*)$/#\1/' /etc/chrony.conf

# 사내 NTP 서버 등록 (재실행 시 중복 추가 방지)
if ! grep -qE '^[[:space:]]*server[[:space:]]+192\.168\.5\.55' /etc/chrony.conf; then
  echo "server 192.168.5.55 iburst" >> /etc/chrony.conf
fi
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

# 지시자 자체가 없는 경우 대비
if ! grep -qhE '^\s*PermitRootLogin\s+no' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
  echo "PermitRootLogin no" >> /etc/ssh/sshd_config
fi

# 설정 검증 후 반영 (문법 오류 시 reload 하지 않음)
if sshd -t 2>/tmp/sshd_check.err; then
  systemctl reload sshd
  echo " - sshd 설정 적용 완료 (PermitRootLogin no)"
else
  echo " !! sshd 설정 오류로 reload 생략:"; cat /tmp/sshd_check.err
fi
#sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

echo -e "\n\n"
echo "계정 생성 및 root 원격접속 차단설정 완료"
echo -e "\n\n"

#-------------------------------------------------------------------------------
# 5. su 권한 설정 (wheel 그룹만 su 사용 가능)
#-------------------------------------------------------------------------------
echo "파일 접근 권한 및 su 권한 설정 시작"

# /etc/pam.d/su 에 wheel 제한 적용
# ※ 기존 코드는 's' 가 빠져 있어 GNU sed 가 'a'(append) 명령으로 해석했고,
#   'uth required pam_wheel.so use_uid/' 라는 잘못된 줄이 추가되어
#   PAM 파싱 오류를 유발했다. 공백/탭을 모두 허용하는 치환으로 교정한다.
if ! grep -qE '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so' /etc/pam.d/su; then
  sed -ri 's/^#[[:space:]]*(auth[[:space:]]+required[[:space:]]+pam_wheel\.so[[:space:]]+use_uid.*)$/\1/' /etc/pam.d/su
fi
if ! grep -qE '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so' /etc/pam.d/su; then
  echo 'auth		required	pam_wheel.so use_uid' >> /etc/pam.d/su
fi
# 잘못된 줄이 이미 들어가 있으면 제거 (과거 버전으로 실행된 서버 복구용)
sed -i '/^uth[[:space:]]\+required[[:space:]]\+pam_wheel\.so/d' /etc/pam.d/su

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

# 최대 사용기간 90일
sed -ri 's/^#?\s*PASS_MAX_DAYS\s+.*/PASS_MAX_DAYS   90/' /etc/login.defs

# ※ 패스워드 재사용 제한(remember=2)은 여기서 적용하지 않는다.
#   뒤쪽 faillock 단계의 'authselect select' 가 system-auth / password-auth 를
#   템플릿에서 재생성하므로 여기서 넣으면 지워진다. authselect 이후에 적용한다.

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

# ※ 순서 주의: 프로파일이 선택되지 않은 상태에서는 enable-feature 가 실패한다.
#   'authselect current' 로 확인 후 select → enable-feature 순으로 진행한다.
# ※ authselect select 는 system-auth / password-auth 를 템플릿에서 재생성하므로
#   이 시점 이후에 PAM 파일을 수정해야 한다.
if authselect current >/dev/null 2>&1; then
  echo " - 기존 authselect 프로파일 유지: $(authselect current 2>/dev/null | head -1)"
else
  echo " - authselect 프로파일이 없어 sssd 프로파일을 선택합니다"
  authselect select sssd --force
fi

authselect enable-feature with-faillock
authselect apply-changes 2>/dev/null || true

# 잠금 정책 값 설정
# ※ 기존 코드는 '# unlock_Time'(대문자 T)으로 찾았으나 실제 파일은
#   '# unlock_time'(소문자) 이라 한 번도 매칭되지 않았다.
#   주석 여부와 무관하게 값을 확정하도록 교정한다.
set_faillock() {   # $1=키, $2=값
  local k="$1" v="$2" f=/etc/security/faillock.conf
  if grep -qE "^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=" "$f"; then
    sed -ri "s|^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=.*|${k} = ${v}|" "$f"
  else
    echo "${k} = ${v}" >> "$f"
  fi
}
set_faillock deny 3
set_faillock unlock_time 600
set_faillock fail_interval 900

# silent 는 값이 없는 단독 옵션
if grep -qE '^[[:space:]]*#[[:space:]]*silent[[:space:]]*$' /etc/security/faillock.conf; then
  sed -ri 's/^[[:space:]]*#[[:space:]]*silent[[:space:]]*$/silent/' /etc/security/faillock.conf
elif ! grep -qE '^[[:space:]]*silent[[:space:]]*$' /etc/security/faillock.conf; then
  echo 'silent' >> /etc/security/faillock.conf
fi

echo "==== [faillock 설정값 확인] ===="
grep -nE '^[[:space:]]*(deny|unlock_time|fail_interval|silent)' /etc/security/faillock.conf
echo "==============================="

# 패스워드 재사용 제한 (authselect 가 PAM 을 재생성한 이후에 적용해야 유지된다)
for f in /etc/pam.d/system-auth /etc/pam.d/password-auth; do
  [ -f "$f" ] || continue
  if ! grep -qE 'pam_unix\.so.*remember=2' "$f"; then
    sed -ri 's/(^[[:space:]]*password[[:space:]]+sufficient[[:space:]]+pam_unix\.so.*)$/\1 remember=2/' "$f"
  fi
done
echo " - 패스워드 재사용 제한(remember=2) 적용"

faillock || true
faillock --user "$username" || true

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

# ※ 이미 readonly 로 지정된 TMOUT 에 다시 대입하면
#   "TMOUT: readonly variable" 오류로 로그인 스크립트가 중단된다.
#   → 현재 상태를 확인해 필요한 경우에만 대입한다.
cat <<'EOF' > "$TMOUT_FILE"
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac

_tm_decl="$(declare -p TMOUT 2>/dev/null || true)"
_tm_is_ro=0
if printf '%s' "$_tm_decl" | grep -q -- 'declare \-.*r'; then _tm_is_ro=1; fi

if [ "$_tm_is_ro" -eq 0 ] || [ "${TMOUT:-}" != "1800" ]; then
  TMOUT=1800
  readonly TMOUT
  export TMOUT
fi

unset _tm_decl _tm_is_ro
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

# ※ 실제 백업 파일명은 'passwd-' (하이픈) 이다. '/etc/passwd.*' (점) 글로브는
#   어느 파일에도 매칭되지 않아 적용된 적이 없었다.
for f in /etc/passwd- /etc/group- /etc/shadow- /etc/gshadow- \
         /etc/passwd.* /etc/group.* /etc/shadow.* /etc/gshadow.*; do
  [ -e "$f" ] || continue
  chown root:root "$f" 2>/dev/null || true
  chmod 0600 "$f"
  echo "   백업 파일 권한 적용: $f"
done

echo " - 주요 보안 파일 권한 설정 완료"

#====[ F) faillock 상태 점검 ]=================================================
echo "==== [faillock 상태 확인] ===="
faillock || true
faillock --user "$username" || true
echo "==============================="


#====[ H) 추가 하드닝 (Ubuntu 표준과 항목 맞춤) ]==============================
# ※ 이 구간은 계정 만료·crontab·명령 실행 권한을 건드리므로
#   로그인이나 서비스가 끊기지 않도록 아래 원칙을 지킨다.
#     - 계정을 '즉시 만료' 상태로 만들지 않는다 (SSH 키 로그인까지 막힌다)
#     - 빈 /etc/cron.allow 를 만들어 기존 crontab 사용자를 차단하지 않는다
#     - 파일이 존재할 때만 권한을 조정한다
echo "추가 하드닝 시작 (표준시 / 만료정책 / cron / 접속기록 / 로그 / 명령어 / PAM 권한)"

# H-1) 표준시 (Asia/Seoul)
if timedatectl set-timezone Asia/Seoul 2>/dev/null; then
  echo " - 표준시 Asia/Seoul 적용"
else
  echo " - [건너뜀] 표준시 설정 실패"
fi

# H-2) 패스워드 최소 사용 기간 (변경 직후 재변경으로 이력 정책을 우회하는 것 방지)
if grep -qE '^[[:space:]]*#?[[:space:]]*PASS_MIN_DAYS' /etc/login.defs; then
  sed -ri 's/^#?[[:space:]]*PASS_MIN_DAYS[[:space:]]+.*/PASS_MIN_DAYS   7/' /etc/login.defs
else
  printf 'PASS_MIN_DAYS   7\n' >> /etc/login.defs
fi
echo " - PASS_MIN_DAYS 7 적용"

# H-3) 기존 계정에 만료 정책 소급 적용
# ※ 마지막 변경일이 90일을 넘은 계정에 -M 90 을 걸면 그 즉시 만료되어
#   패스워드는 물론 SSH 키 로그인까지 거부된다(PAM account 단계에서 차단).
#   서비스 계정이 여기 걸리면 운영이 멈추므로, 해당 계정은 적용하지 않고
#   목록만 출력해 담당자가 판단하도록 한다.
_today=$(( $(date +%s) / 86400 ))
_skipped=""
for _u in $(awk -F: '$3>=1000 && $3<65534 && $1!="nobody" {print $1}' /etc/passwd); do
  _pw=$(awk -F: -v u="$_u" '$1==u{print $2}' /etc/shadow 2>/dev/null)
  case "$_pw" in
    ''|'!'*|'*'*)
      echo "   건너뜀(패스워드 미설정 또는 잠금): $_u"; continue ;;
  esac
  _last=$(awk -F: -v u="$_u" '$1==u{print $3}' /etc/shadow 2>/dev/null)
  if [ -n "$_last" ] && [ "$_last" -gt 0 ] 2>/dev/null; then
    _age=$(( _today - _last ))
    if [ "$_age" -ge 90 ]; then
      echo "   !! 건너뜀(적용 시 즉시 만료됨 · 최종변경 ${_age}일 경과): $_u"
      _skipped="$_skipped $_u"
      continue
    fi
  else
    echo "   건너뜀(최종 변경일 불명): $_u"; continue
  fi
  chage -M 90 -m 7 "$_u" 2>/dev/null && echo "   적용: $_u" || echo "   실패(무시): $_u"
done
if [ -n "$_skipped" ]; then
  echo "   ※ 아래 계정은 패스워드를 먼저 변경한 뒤 정책을 적용하세요:"
  echo "      passwd <계정> && chage -M 90 -m 7 <계정>"
  echo "     대상:$_skipped"
fi
unset _today _u _pw _last _age _skipped

# H-4) cron 접근 제어
# ※ /etc/cron.allow 가 생기면 '여기 없는 계정은 crontab 사용 불가' 가 된다.
#   빈 파일로 만들면 기존 crontab 사용자가 전부 막히므로,
#   root 와 현재 crontab 을 보유한 계정을 담아 기능을 유지한다.
if [ ! -f /etc/cron.allow ]; then
  {
    echo root
    ls /var/spool/cron 2>/dev/null
  } | awk 'NF' | sort -u > /etc/cron.allow
  echo " - /etc/cron.allow 생성 (허용 계정 $(wc -l < /etc/cron.allow)개: $(tr '\n' ' ' < /etc/cron.allow))"
fi
chown root:root /etc/cron.allow 2>/dev/null || true
chmod 0600 /etc/cron.allow 2>/dev/null || true
if [ -f /etc/cron.deny ]; then
  chown root:root /etc/cron.deny 2>/dev/null || true
  chmod 0600 /etc/cron.deny 2>/dev/null || true
fi
echo " - cron 접근 제어 파일 권한 600 적용"

# H-5) 접속 기록 파일 (wtmp/btmp)
# ※ chmod 만으로는 재부팅 시 원복된다.
#   /usr/lib/tmpfiles.d/var.conf 의 0664/0660 규칙을 systemd-tmpfiles 가
#   부팅마다 재적용하기 때문. /etc/tmpfiles.d 가 우선하므로 덮어써 고정한다.
chown root:utmp /var/log/wtmp 2>/dev/null || true
chmod 0600 /var/log/wtmp 2>/dev/null || true
chown root:utmp /var/log/btmp 2>/dev/null || true
chmod 0600 /var/log/btmp 2>/dev/null || true
cat <<'EOS' > /etc/tmpfiles.d/zzz-wtmp.conf
# /usr/lib/tmpfiles.d/var.conf 의 wtmp/btmp 권한 규칙을 덮어쓴다 (감사 정책 0600)
f /var/log/wtmp 0600 root utmp -
f /var/log/btmp 0600 root utmp -
EOS
chown root:root /etc/tmpfiles.d/zzz-wtmp.conf
chmod 0644 /etc/tmpfiles.d/zzz-wtmp.conf
systemd-tmpfiles --create /etc/tmpfiles.d/zzz-wtmp.conf 2>/dev/null || true
echo " - wtmp/btmp 600 적용 및 재부팅 후 유지 규칙 생성"
echo "   ※ 일반 사용자의 last/who 출력이 제한됩니다"

# H-6) 로그 파일 권한 (존재할 때만)
# ※ Rocky 는 auth.log/syslog 가 아니라 secure/messages 다.
#   journald 전용 환경에서는 파일이 없으므로 건너뛴다.
for _f in /var/log/secure /var/log/messages; do
  if [ -f "$_f" ]; then
    chown root:root "$_f" 2>/dev/null || true
    chmod 0600 "$_f" 2>/dev/null || true
    echo " - $_f 권한 600 적용"
  else
    echo " - [해당없음] $_f 없음 (journald 전용 환경)"
  fi
done
unset _f

# H-7) 관리 명령어 root 전용 실행
[ -f /usr/bin/last ]       && chmod 0700 /usr/bin/last       2>/dev/null && echo " - /usr/bin/last 700 적용"
[ -f /usr/sbin/ifconfig ]  && chmod 0700 /usr/sbin/ifconfig  2>/dev/null && echo " - /usr/sbin/ifconfig 700 적용"

# H-8) PAM 설정 파일 권한
for _f in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/su /etc/pam.d/login; do
  [ -e "$_f" ] || continue
  chown root:root "$_f" 2>/dev/null || true
  chmod 0644 "$_f" 2>/dev/null || true
done
unset _f
echo " - PAM 설정 파일 권한 644 적용"

echo "추가 하드닝 완료"

#====[ I) 로그인 영향 자가 점검 ]=============================================
# 인증·로그인 경로를 건드렸으므로, 세션을 닫기 전에 문제를 잡아낸다.
echo
echo "==== [로그인 영향 자가 점검] ===="
_login_warn=0

# PAM 파일 형식 검사 (첫 필드가 auth/account/password/session 이어야 한다)
for _f in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/su /etc/pam.d/login; do
  [ -f "$_f" ] || continue
  _bad=$(grep -vE '^[[:space:]]*(#|$)' "$_f" | grep -vE '^[[:space:]]*-?(auth|account|password|session)[[:space:]]' || true)
  if [ -n "$_bad" ]; then
    echo " !! $_f 에 형식이 잘못된 줄이 있습니다:"; echo "$_bad" | sed 's/^/      /'
    _login_warn=1
  fi
done

# 로그인 시 읽히는 스크립트 문법 검사
bash -n /etc/profile 2>/dev/null || { echo " !! /etc/profile 문법 오류"; _login_warn=1; }
for _f in /etc/profile.d/*.sh; do
  [ -f "$_f" ] || continue
  bash -n "$_f" 2>/dev/null || { echo " !! $_f 문법 오류"; _login_warn=1; }
done

# sshd 설정 검증
sshd -t 2>/dev/null || { echo " !! sshd 설정 오류 (원격 접속 불가 위험)"; _login_warn=1; }

# 즉시 만료된 계정 확인
_expired=$(awk -F: -v t="$(( $(date +%s) / 86400 ))" \
  '$2 ~ /^\$/ && $5 ~ /^[0-9]+$/ && $5 > 0 && $3 ~ /^[0-9]+$/ && (t - $3) > $5 {print $1}' /etc/shadow 2>/dev/null)
if [ -n "$_expired" ]; then
  echo " !! 패스워드가 만료되어 로그인이 거부될 수 있는 계정:"
  echo "$_expired" | sed 's/^/      /'
  echo "      복구: chage -d $(date +%Y-%m-%d) <계정>  또는  passwd <계정>"
  _login_warn=1
fi

# securetty 정합성 (pam_securetty 가 있는데 목록이 없으면 콘솔 root 로그인 차단)
if grep -q pam_securetty.so /etc/pam.d/login 2>/dev/null && [ ! -f /etc/securetty ]; then
  echo " !! pam_securetty 가 적용되어 있으나 /etc/securetty 가 없습니다 (콘솔 root 로그인 차단)"
  _login_warn=1
fi

if [ "$_login_warn" -eq 0 ]; then
  echo " 이상 없음 — 로그인 경로에 문제가 될 설정은 발견되지 않았습니다."
else
  echo
  echo " !! 위 항목을 먼저 해결하세요. 현재 세션을 닫기 전에 반드시"
  echo "    새 터미널에서 SSH 접속과 sudo 동작을 확인하십시오."
fi
echo "================================="
unset _f _bad _expired _login_warn

echo "=== [추가 하드닝] Rocky Linux 9 보안 설정 완료 ==="
###############################################################################

echo -e "\n\n"
echo "서버 표준화 설정 작업 완료!"
echo -e "\n\n"
