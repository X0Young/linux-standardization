#!/bin/bash
#===============================================================================
# 표준화 스크립트 적용 보정 스크립트
#
# 이미 표준화 스크립트를 실행한 서버에서, 구버전 스크립트의 결함 때문에
# 실제로는 적용되지 않은 항목만 골라 보정한다.
# (전체 스크립트를 다시 돌릴 필요가 없는 경우에 사용)
#
#   사용법: sudo bash remediate.sh [--dry-run]
#
# 특징
#   - 멱등성: 여러 번 실행해도 결과가 같다
#   - 변경 전 원본을 백업한다
#   - 로그인 경로를 건드리므로 종료 전 자가 점검을 수행한다
#
# ※ 반드시 별도 root 세션을 열어둔 상태에서 실행할 것.
#===============================================================================
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "[오류] root 또는 sudo 로 실행해야 합니다."
  exit 1
fi

. /etc/os-release 2>/dev/null
case "${ID:-}" in
  ubuntu|debian) OSFAM=deb; BACKUP_ROOT=/root/backup ;;
  rocky|rhel|centos|almalinux) OSFAM=rpm; BACKUP_ROOT=/home/backup ;;
  *) echo "[오류] 지원하지 않는 OS: ${PRETTY_NAME:-unknown}"; exit 1 ;;
esac

BK="$BACKUP_ROOT/$(date +%Y-%m-%d)-remediate"
mkdir -p "$BK"

CHANGED=0
say()  { echo " $*"; }
todo() { echo " [적용] $*"; CHANGED=$((CHANGED+1)); }
skip() { echo " [이미적용] $*"; }
run()  { if [ "$DRY" -eq 1 ]; then echo "        (dry-run) $*"; else eval "$@"; fi; }
bk()   { [ -e "$1" ] && cp -p "$1" "$BK/$(echo "$1" | tr '/' '_')" 2>/dev/null || true; }

echo "==============================================================="
echo " 표준화 적용 보정  —  ${PRETTY_NAME:-?}  ($(hostname))"
echo " 백업 위치: $BK"
[ "$DRY" -eq 1 ] && echo " ※ dry-run 모드 — 실제 변경 없음"
echo "==============================================================="

#---------------------------------------------------------------------------
# 1) 계정 잠금(faillock) 실제 활성화
#---------------------------------------------------------------------------
echo
echo "[1] 계정 잠금 (faillock)"
FL=/etc/security/faillock.conf

if [ -f "$FL" ]; then
  bk "$FL"
  set_fl() {
    local k="$1" v="$2"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=" "$FL"; then
      grep -qE "^[[:space:]]*${k}[[:space:]]*=[[:space:]]*${v}[[:space:]]*$" "$FL" && return 1
      run "sed -ri 's|^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=.*|${k} = ${v}|' '$FL'"
    else
      run "echo '${k} = ${v}' >> '$FL'"
    fi
    return 0
  }
  if [ "$OSFAM" = deb ]; then _deny=5; else _deny=3; fi
  set_fl deny "$_deny"        && todo "deny = $_deny"        || skip "deny = $_deny"
  set_fl fail_interval 900    && todo "fail_interval = 900"  || skip "fail_interval = 900"
  set_fl unlock_time 600      && todo "unlock_time = 600"    || skip "unlock_time = 600"
fi

if [ "$OSFAM" = deb ]; then
  CA=/etc/pam.d/common-auth
  CC=/etc/pam.d/common-account
  # ※ Ubuntu 24.04 에는 /usr/share/pam-configs/faillock 프로파일이 없어
  #   pam-auth-update 로는 활성화되지 않는다. PAM 스택을 직접 편집한다.
  if grep -q 'pam_faillock\.so' "$CA" 2>/dev/null; then
    skip "pam_faillock (common-auth)"
  elif grep -qE '^\s*auth\s+\[success=1\s+default=ignore\]\s+pam_unix\.so' "$CA"; then
    bk "$CA"
    run "sed -i -E '/^\\s*auth\\s+\\[success=1\\s+default=ignore\\]\\s+pam_unix\\.so/i auth\\trequired\\t\\t\\tpam_faillock.so preauth' '$CA'"
    run "sed -i -E '/^\\s*auth\\s+\\[success=1\\s+default=ignore\\]\\s+pam_unix\\.so/a auth\\t[default=die]\\t\\t\\tpam_faillock.so authfail\\nauth\\tsufficient\\t\\t\\tpam_faillock.so authsucc' '$CA'"
    todo "pam_faillock 등록 (common-auth)"
  else
    echo " [경고] $CA 에서 표준 pam_unix 행을 찾지 못해 건너뜁니다"
  fi

  if grep -q 'pam_faillock\.so' "$CC" 2>/dev/null; then
    skip "pam_faillock (common-account)"
  else
    bk "$CC"
    run "sed -i -E '0,/^\\s*account\\s+/s//account\\trequired\\t\\t\\tpam_faillock.so\\n&/' '$CC'"
    todo "pam_faillock 등록 (common-account)"
  fi
else
  if grep -q 'pam_faillock' /etc/pam.d/system-auth 2>/dev/null; then
    skip "pam_faillock (authselect)"
  else
    if ! authselect current >/dev/null 2>&1; then
      run "authselect select sssd --force"
    fi
    run "authselect enable-feature with-faillock"
    run "authselect apply-changes 2>/dev/null || true"
    todo "authselect with-faillock 활성화"
  fi
fi

#---------------------------------------------------------------------------
# 2) 명령 이력 설정이 ~/.bashrc 에 덮어써지는 문제
#---------------------------------------------------------------------------
echo
echo "[2] 명령 이력 (HISTSIZE 재정의 방지)"
HF=/etc/profile.d/zzz-history.sh

# profile.d 의 조건부 대입(${VAR:-값})을 무조건 대입으로 교정
if [ -f "$HF" ] && grep -q 'HISTSIZE:-' "$HF"; then
  bk "$HF"
  run "sed -ri 's/^([[:space:]]*export[[:space:]]+)?HISTSIZE=\\\$\\{HISTSIZE:-10000\\}/export HISTSIZE=10000/' '$HF'"
  run "sed -ri 's/^([[:space:]]*export[[:space:]]+)?HISTFILESIZE=\\\$\\{HISTFILESIZE:-20000\\}/export HISTFILESIZE=20000/' '$HF'"
  run "sed -ri 's|^([[:space:]]*export[[:space:]]+)?HISTTIMEFORMAT=\"\\\$\\{HISTTIMEFORMAT:-%F %T \\}\"|export HISTTIMEFORMAT=\"%F %T \"|' '$HF'"
  todo "profile.d 조건부 대입 → 무조건 대입"
else
  skip "profile.d 이력 설정"
fi

# ~/.bashrc 와 /etc/skel/.bashrc 의 재정의 주석 처리
_rc_done=0
for _rc in /etc/skel/.bashrc /root/.bashrc /home/*/.bashrc; do
  [ -f "$_rc" ] || continue
  if grep -qE '^[[:space:]]*(HISTSIZE|HISTFILESIZE|HISTCONTROL)=' "$_rc"; then
    bk "$_rc"
    run "sed -ri 's/^([[:space:]]*)(HISTSIZE|HISTFILESIZE|HISTCONTROL)=/\\1# [hardening] &/' '$_rc'"
    todo "이력 재정의 주석 처리: $_rc"
    _rc_done=1
  fi
done
[ "$_rc_done" -eq 0 ] && skip "~/.bashrc 이력 재정의 (이미 처리됨)"
unset _rc _rc_done

#---------------------------------------------------------------------------
# 3) 접속 기록 파일 (wtmp/btmp) — 재부팅 후 원복 방지
#---------------------------------------------------------------------------
echo
echo "[3] 접속 기록 파일 (wtmp/btmp)"
TMPF=/etc/tmpfiles.d/zzz-wtmp.conf
if [ -f "$TMPF" ] && grep -q '0600' "$TMPF"; then
  skip "tmpfiles 고정 규칙"
else
  run "mkdir -p /etc/tmpfiles.d"
  run "printf '%s\\n' '# /usr/lib/tmpfiles.d/var.conf 의 wtmp/btmp 권한 규칙을 덮어쓴다 (감사 정책 0600)' 'f /var/log/wtmp 0600 root utmp -' 'f /var/log/btmp 0600 root utmp -' > '$TMPF'"
  run "chown root:root '$TMPF'; chmod 0644 '$TMPF'"
  todo "tmpfiles 고정 규칙 생성 ($TMPF)"
fi
for _f in /var/log/wtmp /var/log/btmp; do
  [ -e "$_f" ] || continue
  if [ "$(stat -c '%a' "$_f")" = "600" ]; then
    skip "$_f 권한"
  else
    run "chown root:utmp '$_f' 2>/dev/null || true"
    run "chmod 0600 '$_f'"
    todo "$_f → 600"
  fi
done
unset _f
run "systemd-tmpfiles --create '$TMPF' 2>/dev/null || true"

#---------------------------------------------------------------------------
# 4) 계정 백업 파일 권한 (passwd- / group- / shadow- / gshadow-)
#---------------------------------------------------------------------------
echo
echo "[4] 계정 백업 파일 권한"
_bk_done=0
for _f in /etc/passwd- /etc/group- /etc/shadow- /etc/gshadow-; do
  [ -e "$_f" ] || continue
  if [ "$(stat -c '%a' "$_f")" = "600" ]; then
    skip "$_f"
  else
    run "chown root:root '$_f' 2>/dev/null || true"
    run "chmod 0600 '$_f'"
    todo "$_f → 600"
    _bk_done=1
  fi
done
[ "$_bk_done" -eq 0 ] && say "(변경 대상 없음)"
unset _f _bk_done

#---------------------------------------------------------------------------
# 5) Rocky 전용 보정
#---------------------------------------------------------------------------
if [ "$OSFAM" = rpm ]; then
  echo
  echo "[5] Rocky 전용 보정"

  # 5-1) 구버전 sed 가 남긴 잘못된 PAM 줄 제거
  if grep -qE '^uth[[:space:]]+required[[:space:]]+pam_wheel\.so' /etc/pam.d/su 2>/dev/null; then
    bk /etc/pam.d/su
    run "sed -i '/^uth[[:space:]]\\+required[[:space:]]\\+pam_wheel\\.so/d' /etc/pam.d/su"
    todo "잘못된 PAM 줄 제거 (/etc/pam.d/su)"
  fi

  # 5-2) su 사용 제한 (wheel)
  if grep -qE '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so' /etc/pam.d/su 2>/dev/null; then
    skip "su 사용 제한 (pam_wheel)"
  else
    bk /etc/pam.d/su
    run "sed -ri 's/^#[[:space:]]*(auth[[:space:]]+required[[:space:]]+pam_wheel\\.so[[:space:]]+use_uid.*)\$/\\1/' /etc/pam.d/su"
    todo "su 사용 제한 활성화 (pam_wheel)"
  fi

  # 5-3) /etc/profile 에 구버전이 남긴 파손 흔적 정리
  if grep -qE '^[[:space:]]+HISTTIMEFORMAT[[:space:]]+TMOUT[[:space:]]*$' /etc/profile 2>/dev/null; then
    bk /etc/profile
    run "sed -ri '/^[[:space:]]+HISTTIMEFORMAT[[:space:]]+TMOUT[[:space:]]*\$/d' /etc/profile"
    todo "/etc/profile 파손 줄 제거"
  fi
  # 중복 TMOUT 정의 (readonly 뒤 재대입 → 로그인 오류) 정리
  if [ "$(grep -cE '^[[:space:]]*(export[[:space:]]+)?TMOUT=' /etc/profile 2>/dev/null)" -gt 1 ] 2>/dev/null; then
    bk /etc/profile
    run "sed -ri '/^[[:space:]]*(export[[:space:]]+)?TMOUT=/d; /^[[:space:]]*readonly[[:space:]]+TMOUT[[:space:]]*\$/d' /etc/profile"
    todo "/etc/profile 중복 TMOUT 정의 제거 (profile.d 로 관리)"
  fi

  # 5-4) securetty 정합성
  if grep -q pam_securetty.so /etc/pam.d/login 2>/dev/null && [ ! -f /etc/securetty ]; then
    run "printf '%s\\n' '# root 로그인을 허용할 터미널 목록 (pts/* 제외)' console tty1 tty2 tty3 tty4 tty5 tty6 ttyS0 > /etc/securetty"
    run "chown root:root /etc/securetty; chmod 0600 /etc/securetty"
    todo "/etc/securetty 생성 (콘솔 root 로그인 차단 해소)"
  fi
  [ -f /etc/securetty ] && run "sed -i '/^[[:space:]]*pts\\/[0-9]\\+[[:space:]]*\$/d' /etc/securetty"
fi

#---------------------------------------------------------------------------
# 자가 점검
#---------------------------------------------------------------------------
echo
echo "==============================================================="
echo " 로그인 영향 자가 점검"
echo "==============================================================="
WARN=0

if [ "$OSFAM" = deb ]; then
  PAMF="/etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-password /etc/pam.d/su /etc/pam.d/login"
else
  PAMF="/etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/su /etc/pam.d/login"
fi
for f in $PAMF; do
  [ -f "$f" ] || continue
  bad=$(grep -vE '^[[:space:]]*(#|$)' "$f" | grep -vE '^[[:space:]]*(@include|-?(auth|account|password|session)[[:space:]])' || true)
  if [ -n "$bad" ]; then
    echo " !! $f 형식 이상:"; echo "$bad" | sed 's/^/      /'; WARN=1
  fi
done

if [ "$OSFAM" = deb ] && grep -q 'pam_faillock' /etc/pam.d/common-auth 2>/dev/null; then
  for d in preauth authfail authsucc; do
    grep -q "pam_faillock.so $d" /etc/pam.d/common-auth || { echo " !! faillock 스택 불완전: $d 없음"; WARN=1; }
  done
fi

bash -n /etc/profile 2>/dev/null || { echo " !! /etc/profile 문법 오류"; WARN=1; }
for f in /etc/profile.d/*.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" 2>/dev/null || { echo " !! $f 문법 오류"; WARN=1; }
done

sshd -t 2>/dev/null || { echo " !! sshd 설정 오류 (원격 접속 불가 위험)"; WARN=1; }

expired=$(awk -F: -v t="$(( $(date +%s) / 86400 ))" \
  '$2 ~ /^\$/ && $5 ~ /^[0-9]+$/ && $5 > 0 && $3 ~ /^[0-9]+$/ && (t - $3) > $5 {print $1}' /etc/shadow 2>/dev/null)
if [ -n "$expired" ]; then
  echo " !! 패스워드 만료로 로그인이 거부될 수 있는 계정:"
  echo "$expired" | sed 's/^/      /'
  echo "      복구: chage -d $(date +%Y-%m-%d) <계정>  또는  passwd <계정>"
  WARN=1
fi

if grep -q pam_securetty.so /etc/pam.d/login 2>/dev/null && [ ! -f /etc/securetty ]; then
  echo " !! pam_securetty 적용 상태에서 /etc/securetty 없음 (콘솔 root 로그인 차단)"
  WARN=1
fi

echo
if [ "$WARN" -eq 0 ]; then
  echo " 자가 점검 이상 없음"
else
  echo " !! 위 경고를 먼저 해결하세요."
fi

echo
echo "==============================================================="
echo " 보정 완료 — 변경 $CHANGED 건 / 백업: $BK"
echo "==============================================================="
echo " ※ 현재 세션을 닫기 전에 새 터미널에서 반드시 확인하십시오:"
echo "     ssh -p <포트> <계정>@$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "     sudo -v"
echo
echo " 문제 발생 시 복구:"
echo "     cp $BK/_etc_pam.d_common-auth /etc/pam.d/common-auth"
echo "     cp $BK/_etc_pam.d_common-account /etc/pam.d/common-account"
echo " ※ 이력/TMOUT 설정은 재로그인 후부터 반영됩니다."
