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

echo "=== [추가 하드닝] Rocky Linux 9 보안 설정 완료 ==="
###############################################################################

echo -e "\n\n"
echo "서버 표준화 설정 작업 완료!"
echo -e "\n\n"
