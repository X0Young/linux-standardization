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

# Rocky 계열 패키지명을 Ubuntu로 치환
# - bind-utils → dnsutils
# - net-snmp → snmp (클라이언트 툴)
# - firewalld → ufw
# - policycoreutils-python-utils (Ubuntu 불필요)
sudo apt-get install -y \
  vim net-tools rsync tcpdump snmp dnsutils chrony ufw \
  libpam-pwquality libpam-modules

echo -e "\n패키지 업데이트/설치 완료\n"

#====[ 2) 시간 동기화(chrony) ]===============================================
echo "시간 동기화 설정 시작"
# Ubuntu: 서비스명 'chrony', 설정파일 '/etc/chrony/chrony.conf'
sudo systemctl enable --now chrony

# 기본 pool 라인 주석 처리 후 사내 NTP 서버 추가 (필요 시 IP 변경)
sudo sed -i 's/^\s*pool\s\+/## pool /' /etc/chrony/chrony.conf
sudo sed -i 's/^\s*server\s\+.*iburst/## &/' /etc/chrony/chrony.conf
if ! grep -q '^server 192\.168\.5\.55 iburst' /etc/chrony/chrony.conf; then
  echo "server 192.168.5.55 iburst" | sudo tee -a /etc/chrony/chrony.conf >/dev/null
fi
sudo systemctl restart chrony
echo -e "\n시간 동기화 설정 완료\n"

#====[ 3) 개인 계정 생성 + root 원격접속 차단 ]===============================
echo "개인 계정 생성 시작"
read -p "새로 생성할 사용자명을 입력하세요: " username
# Ubuntu에선 'adduser'가 인터랙티브하므로 useradd 사용(심플)
if ! id "$username" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "$username"
fi
echo "새로 생성된 사용자 $username의 패스워드를 입력하세요:"
sudo passwd "$username"

# SSH root 로그인 차단 (Ubuntu: 기본 prohibit-password → 명시적 no로 통일)
# 다양한 기존 값을 안전하게 치환
if grep -qE '^\s*PermitRootLogin' /etc/ssh/sshd_config; then
  sudo sed -i 's/^\s*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
  echo "PermitRootLogin no" | sudo tee -a /etc/ssh/sshd_config >/dev/null
fi

# ==== [ SSH 포트 24477로 변경 ] =============================================
echo "SSH 포트를 24477로 변경합니다."

# 1) sshd_config에 Port 줄 추가/치환 (여러 Port 라인이 있어도 최종적으로 24477이 되도록)
if grep -qE '^\s*Port\s+' /etc/ssh/sshd_config; then
  sudo sed -i 's/^\s*Port\s\+.*/Port 24477/' /etc/ssh/sshd_config
else
  echo "Port 24477" | sudo tee -a /etc/ssh/sshd_config >/dev/null
fi

# 2) UFW가 이미 활성 상태라면, 선제적으로 24477 허용(잠금 방지)
if command -v ufw >/dev/null 2>&1; then
  if sudo ufw status | grep -qi "Status: active"; then
    sudo ufw allow 24477/tcp || true
  fi
fi

# 3) 설정 문법 검사 후 서비스 재시작
if sudo sshd -t 2>/tmp/sshd_check.err; then
  sudo systemctl restart ssh
  echo "→ SSH가 24477 포트로 재시작되었습니다."
else
  echo "!! sshd 설정 오류 발견:"
  cat /tmp/sshd_check.err
  echo "설정 오류로 인해 SSH 재시작을 건너뜁니다. 위 오류를 수정하세요."
fi
# ============================================================================

echo -e "\n계정 생성 및 root 원격접속 차단설정 완료\n"

#====[ 4) su 제한 및 sudo 권한 ]==============================================
echo "su 권한 제한 및 sudo 설정 시작"
# Ubuntu는 wheel 그룹 대신 sudo 그룹 사용
# /etc/pam.d/su 에 pam_wheel.so 가 없을 수 있으므로 안전하게 추가(있으면 유지)
if ! grep -q '^auth\s\+required\s\+pam_wheel\.so' /etc/pam.d/su; then
  # pam_wheel 사용, sudo 그룹만 su 허용
  echo 'auth required pam_wheel.so use_uid group=sudo' | sudo tee -a /etc/pam.d/su >/dev/null
fi

# su 바이너리 접근권한: root: sudo, 4750 (원문 의도 유지)
sudo chgrp sudo /bin/su
sudo chmod 4750 /bin/su

# 사용자에게 sudo 권한 부여
sudo usermod -aG sudo "$username"
echo -e "\nsudo 설정 완료\n"

#====[ 5) 패스워드 복잡성 ]===================================================
echo "패스워드 복잡성 설정 시작 (/etc/security/pwquality.conf)"
# 우분투는 libpam-pwquality 사용. '음수' 크레딧이 요구조건.
sudo sed -i 's/^\s*#\?\s*minlen\s*=.*/minlen = 8/' /etc/security/pwquality.conf

# dcredit/ocredit/ucredit/lcredit 강제(최소 각 1자 요구)
if grep -q '^\s*dcredit' /etc/security/pwquality.conf; then
  sudo sed -i 's/^\s*dcredit\s*=.*/dcredit = -1/' /etc/security/pwquality.conf
else
  echo 'dcredit = -1' | sudo tee -a /etc/security/pwquality.conf >/dev/null
fi
if grep -q '^\s*ocredit' /etc/security/pwquality.conf; then
  sudo sed -i 's/^\s*ocredit\s*=.*/ocredit = -1/' /etc/security/pwquality.conf
else
  echo 'ocredit = -1' | sudo tee -a /etc/security/pwquality.conf >/dev/null
fi
if grep -q '^\s*ucredit' /etc/security/pwquality.conf; then
  sudo sed -i 's/^\s*ucredit\s*=.*/ucredit = -1/' /etc/security/pwquality.conf
else
  echo 'ucredit = -1' | sudo tee -a /etc/security/pwquality.conf >/dev/null
fi
if grep -q '^\s*lcredit' /etc/security/pwquality.conf; then
  sudo sed -i 's/^\s*lcredit\s*=.*/lcredit = -1/' /etc/security/pwquality.conf
else
  echo 'lcredit = -1' | sudo tee -a /etc/security/pwquality.conf >/dev/null
fi
echo -e "\n패스워드 복잡성 설정 완료\n"

#====[ 6) 방화벽: UFW (firewalld 대체) ]======================================
echo "UFW 방화벽 설정 시작"
# SSH 차단 방지 위해 먼저 22 허용 (최초 적용 시 안전)
sudo ufw allow 22/tcp >/dev/null 2>&1 || true
# 필요한 포트 허용(SSH 새 포트)
sudo ufw allow 24477/tcp

# 기본 정책: inbound deny, outbound allow
sudo ufw default deny incoming
sudo ufw default allow outgoing

# 활성화(비대화형)
yes | sudo ufw enable
sudo ufw status verbose

# ※ 새 포트 접속 확인 후 22/tcp 닫고 싶다면 아래 주석 해제
# sudo ufw delete allow 22/tcp

echo -e "\n방화벽(UFW) 설정 완료\n"

#====[ 7) 세션 타임아웃 & 히스토리 타임스탬프 ]===============================
echo "세션 타임아웃 및 HISTORY 타임라인 설정 시작"

# 7-1) 로그인 쉘용: /etc/profile.d/99-hardening.sh
HARDEN_FILE="/etc/profile.d/99-hardening.sh"
sudo touch "$HARDEN_FILE"
sudo chmod 644 "$HARDEN_FILE"

# TMOUT/HISTTIMEFORMAT/HISTSIZE 설정(중복 방지)
grep -q '^export TMOUT=600' "$HARDEN_FILE" || echo 'export TMOUT=600' | sudo tee -a "$HARDEN_FILE" >/dev/null
grep -q '^readonly TMOUT' "$HARDEN_FILE" || echo 'readonly TMOUT' | sudo tee -a "$HARDEN_FILE" >/dev/null
grep -q '^export HISTTIMEFORMAT=' "$HARDEN_FILE" || echo 'export HISTTIMEFORMAT="%F %T "' | sudo tee -a "$HARDEN_FILE" >/dev/null
grep -q '^export HISTSIZE=' "$HARDEN_FILE" || echo 'export HISTSIZE=10000' | sudo tee -a "$HARDEN_FILE" >/dev/null

# 7-2) 비로그인 bash용: /etc/bash.bashrc
BASHRC_SYS="/etc/bash.bashrc"
# HISTTIMEFORMAT/HISTSIZE만 bashrc에도 보강 (TMOUT은 로그인 쉘로도 충분하지만 원하면 넣어도 됨)
sudo grep -q '^export HISTTIMEFORMAT=' "$BASHRC_SYS" || echo 'export HISTTIMEFORMAT="%F %T "' | sudo tee -a "$BASHRC_SYS" >/dev/null
sudo grep -q '^HISTSIZE=' "$BASHRC_SYS" || echo 'HISTSIZE=10000' | sudo tee -a "$BASHRC_SYS" >/dev/null

# 현재 세션에 즉시 적용(가능한 경우)
# shellcheck disable=SC1091
source "$HARDEN_FILE" 2>/dev/null || true

echo -e "\n세션 타임아웃 & HISTORY 타임스탬프 설정 완료\n"


#====[ 8) 계정 잠금 (pam_faillock) ]=========================================
echo "faillock 계정 잠금 설정 시작"

# Ubuntu는 authselect 미사용. common-auth / common-account에 pam_faillock 직접 포함 필요.
# 중복 삽입 방지하며 안전하게 추가.
AUTH_FILE="/etc/pam.d/common-auth"
ACCT_FILE="/etc/pam.d/common-account"

# preauth 라인
if ! grep -q '^auth\s\+required\s\+pam_faillock\.so\s\+preauth' "$AUTH_FILE"; then
  sudo sed -i '1i auth required pam_faillock.so preauth silent audit deny=3 unlock_time=600' "$AUTH_FILE"
fi
# authfail 라인 (pam_unix.so 뒤쪽에 오도록 맨 아래에 한번 더 보강)
if ! grep -q 'pam_faillock\.so authfail' "$AUTH_FILE"; then
  echo 'auth [default=die] pam_faillock.so authfail audit deny=3 unlock_time=600' | sudo tee -a "$AUTH_FILE" >/dev/null
fi
# account에 pam_faillock 포함
if ! grep -q 'pam_faillock\.so' "$ACCT_FILE"; then
  echo 'account required pam_faillock.so' | sudo tee -a "$ACCT_FILE" >/dev/null
fi

# /etc/security/faillock.conf 기본값 조정(있다면)
if [ -f /etc/security/faillock.conf ]; then
  sudo sed -i 's/^\s*#\?\s*deny\s*=.*/deny = 3/' /etc/security/faillock.conf
  sudo sed -i 's/^\s*#\?\s*unlock_time\s*=.*/unlock_time = 600/' /etc/security/faillock.conf
fi

# 현재 상태 출력 (없으면 0)
sudo faillock || true
sudo faillock --user "$username" || true

echo -e "\nfaillock 계정 잠금 설정 완료\n"

echo -e "\n서버 표준화 설정 작업 완료! (Ubuntu 24.04 LTS)\n"
