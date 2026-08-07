# 서버 표준화 스크립트 적용 보안설정 — Ubuntu 24.04 LTS

| | |
|---|---|
| 스크립트 | `standard_ubuntu2404.sh` |
| 대상 OS | Ubuntu 24.04 LTS |
| 실행 방법 | `sudo bash standard_ubuntu2404.sh <계정명>` |
| 설정 항목 수 | 44개 |

신규 서버 구축 시 본 스크립트를 1회 실행하여 아래 설정을 일괄 적용합니다.


## 사전 작업

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 설정 파일 백업 | 변경 대상 원본을 날짜별로 보관 | `/root/backup/YYYY-MM-DD/` |
| OS 패키지 최신화 | apt update + upgrade 수행 | - |
| 기본 패키지 설치 | vim, net-tools, rsync, tcpdump, snmp, snmpd,<br>dnsutils, chrony, ufw, libpam-pwquality, libpam-modules | - |

## 시간 동기화

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 시간 동기화 서비스 활성화 | chrony 상시 기동 (부팅 시 자동 시작) | `chrony.service` |
| 사내 NTP 서버 지정 | 192.168.5.55 | `/etc/chrony/chrony.conf` |
| 외부 NTP 서버 차단 | 기본 pool / server 항목 주석 처리 | `/etc/chrony/chrony.conf` |
| 표준시 설정 | Asia/Seoul (KST, +0900) | `timedatectl` |

## 계정 및 원격 접속

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 관리용 개인 계정 생성 | 실행 시 인자로 받은 계정명 (홈 디렉터리 + /bin/bash) | `useradd` |
| root 원격 로그인 차단 | PermitRootLogin no | `/etc/ssh/sshd_config` |
| SSH 포트 변경 | 22 → 24477 | `/etc/ssh/sshd_config` |
| SSH 설정 검증 후 반영 | sshd -t 통과 시에만 서비스 재시작 | `ssh.service` |

## 관리자 권한

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| su 명령 사용 제한 | sudo 그룹 소속 계정만 su 사용 가능 (pam_wheel) | `/etc/pam.d/su` |
| su 실행 파일 권한 제한 | 4750 (root:sudo) | `/bin/su` |
| 관리 계정 sudo 권한 부여 | 생성 계정을 sudo 그룹에 추가 | `usermod -aG sudo` |

## 패스워드 정책

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 최소 길이 | 8자 이상 | `/etc/security/pwquality.conf` |
| 복잡도 | 숫자·특수문자·대문자·소문자 각 1자 이상 | `/etc/security/pwquality.conf` |
| 재사용 제한 | 최근 2개 패스워드 재사용 금지 | `/etc/pam.d/common-password` |
| 최대 사용 기간 | 90일 | `/etc/login.defs` |
| 최소 사용 기간 | 7일 (변경 후 7일간 재변경 불가) | `/etc/login.defs` |
| 기존 계정 일괄 적용 | UID 1000 이상 계정에 90일/7일 정책 소급 적용<br>※ 적용 시 즉시 만료되는 계정은 건너뛰고 목록만 안내<br>  (서비스 계정 로그인 차단 방지) | `chage` |

## 계정 잠금

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 로그인 실패 잠금 | 5회 연속 실패 시 계정 잠금 | `/etc/security/faillock.conf` |
| 실패 카운트 유지 시간 | 900초 (15분) | `/etc/security/faillock.conf` |
| 잠금 해제 시간 | 600초 (10분) 경과 후 자동 해제 | `/etc/security/faillock.conf` |
| 잠금 기능 활성화 | pam_faillock 을 인증 스택에 등록<br>(등록하지 않으면 위 정책이 동작하지 않음) | `/etc/pam.d/common-auth`<br>`/etc/pam.d/common-account` |

## 방화벽

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 방화벽 활성화 | UFW 기동 및 부팅 시 자동 시작 | `ufw` |
| 기본 정책 | 인바운드 차단 / 아웃바운드 허용 | `ufw` |
| SSH 포트 허용 | 24477/tcp 허용, 22/tcp 규칙 제거 | `ufw` |

## 세션 및 명령 이력

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 유휴 세션 자동 종료 | 1800초(30분) 무입력 시 로그아웃 (사용자 변경 불가) | `/etc/profile.d/zzz-timeout.sh` |
| 명령 이력 보관량 | 세션 10,000건 / 파일 20,000건 | `/etc/profile.d/zzz-history.sh` |
| 명령 실행 시각 기록 | 이력에 날짜·시각 함께 저장 (YYYY-MM-DD HH:MM:SS) | `/etc/profile.d/zzz-history.sh` |
| 명령 즉시 기록 | 명령 실행 시점마다 이력 파일에 반영<br>(비정상 종료 시에도 이력 유실 방지) | `PROMPT_COMMAND` |
| 계정별 재정의 방지 | ~/.bashrc 및 /etc/skel/.bashrc 의<br>HISTSIZE·HISTFILESIZE·HISTCONTROL 재정의 무력화 | `~/.bashrc, /etc/skel/.bashrc` |

## 파일 권한

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 계정 정보 파일 | /etc/passwd, /etc/group → 644 (root:root) | - |
| 패스워드 파일 | /etc/shadow → 640 (root:shadow) | - |
| 네트워크 설정 파일 | /etc/hosts, /etc/services → 644 | - |
| 프로파일 / PAM 설정 | /etc/profile → 755, PAM 공통 설정 → 644 | - |
| 관리 명령어 | last, ifconfig → 700 (root 전용 실행) | - |
| cron 접근 제어 | cron.allow, cron.deny → 600 | - |
| 접속 기록 파일 | wtmp, btmp → 600<br>(재부팅 후 원복 방지를 위해 tmpfiles 규칙으로 고정) | `/etc/tmpfiles.d/zzz-wtmp.conf` |
| 로그 파일 | auth.log, syslog → 640 (존재 시) | - |
| 계정 백업 파일 | passwd-, group-, shadow-, gshadow- → 600 | - |
| 신규 파일 기본 권한 | umask 027<br>(생성 파일에 그룹 쓰기·타 사용자 접근 차단) | `/etc/profile.d/zzz-umask.sh` |

## 환경변수 / 콘솔

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| PATH 보호 | PATH 에서 현재 디렉터리(.) 제거<br>(작업 디렉터리의 위장 실행파일 방지) | `/etc/profile.d/zzz-path.sh` |
| root 콘솔 로그인 제한 | 허용 터미널을 물리 콘솔로 한정, 원격 터미널(pts) 제외 | `/etc/securetty` |

## 스크립트 실행 후 수동 조치 사항

| 항목 | 명령 | 비고 |
|---|---|---|
| 계정 패스워드 설정 | `sudo passwd <계정명>` | 스크립트는 계정만 생성하며 패스워드는 설정하지 않음 |
| SSH 재접속 확인 | `ssh -p 24477 <계정명>@<서버IP>` | 현재 세션을 닫기 전에 새 터미널에서 반드시 확인 |
| 인증 설정 정상 동작 확인 | `su - <계정명> / sudo -v` | 계정 잠금 기능 적용에 따른 인증 스택 변경 검증 |

---

적용 여부 확인은 `verify/verify.py` 로 자동 점검할 수 있습니다.

```bash
python3 verify/verify.py --profile ubuntu2404 --host <서버IP> --user <계정>
```
