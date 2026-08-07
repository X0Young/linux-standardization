# 서버 표준화 스크립트 적용 보안설정 — Rocky Linux 8

| | |
|---|---|
| 스크립트 | `standard_v8.sh` |
| 대상 OS | Rocky Linux 8 |
| 실행 방법 | `sudo bash standard_v8.sh   (실행 중 계정명·패스워드 입력)` |
| 설정 항목 수 | 33개 |

신규 서버 구축 시 본 스크립트를 1회 실행하여 아래 설정을 일괄 적용합니다.


## 사전 작업

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 설정 파일 백업 | 변경 대상 원본을 날짜별로 보관 | `/home/backup/YYYY-MM-DD/` |
| OS 패키지 최신화 | yum update 수행 | - |
| 기본 패키지 설치 | vim, net-tools, rsync, tcpdump, net-snmp,<br>bind-utils, policycoreutils-python-utils, chrony | - |

## 시간 동기화

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 시간 동기화 서비스 활성화 | chronyd 상시 기동 (부팅 시 자동 시작) | `chronyd.service` |
| 사내 NTP 서버 지정 | 192.168.5.55 | `/etc/chrony.conf` |
| 외부 NTP 서버 차단 | 기본 pool (2.rocky.pool.ntp.org) 주석 처리 | `/etc/chrony.conf` |

## 계정 및 원격 접속

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 관리용 개인 계정 생성 | 실행 중 입력받은 계정명 (패스워드도 함께 설정) | `useradd / passwd` |
| root 원격 로그인 차단 | PermitRootLogin no | `/etc/ssh/sshd_config` |

## 관리자 권한

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| su 명령 사용 제한 | wheel 그룹 소속 계정만 su 사용 가능 (pam_wheel) | `/etc/pam.d/su` |
| su 실행 파일 권한 제한 | 4750 (root:wheel) | `/bin/su` |
| 관리 계정 sudo 권한 부여 | 생성 계정을 wheel 그룹에 추가 | `usermod -aG wheel` |

## 패스워드 정책

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 최소 길이 | 8자 이상 | `/etc/security/pwquality.conf` |
| 복잡도 | 숫자·특수문자·대문자·소문자 각 1자 이상 | `/etc/security/pwquality.conf` |
| 재사용 제한 | 최근 2개 패스워드 재사용 금지 | `/etc/pam.d/system-auth`<br>`/etc/pam.d/password-auth` |
| 최대 사용 기간 | 90일 | `/etc/login.defs` |

## 계정 잠금

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 잠금 기능 활성화 | authselect with-faillock 기능 활성화 | `authselect` |
| 로그인 실패 잠금 | 3회 연속 실패 시 계정 잠금 | `/etc/security/faillock.conf` |
| 잠금 해제 시간 | 600초 (10분) 경과 후 자동 해제 | `/etc/security/faillock.conf` |
| 실패 기록 표시 억제 | silent 옵션 활성화 | `/etc/security/faillock.conf` |

## 방화벽

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 기본 존 설정 | default zone = drop (미허용 트래픽 폐기) | `firewalld` |
| SSH 포트 허용 | 24477/tcp 허용 (permanent) | `firewalld` |

## 세션 및 명령 이력

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 명령 이력 보관량 | 세션 10,000건 / 파일 20,000건 | `/etc/profile.d/zzz-history.sh` |
| 명령 실행 시각 기록 | 이력에 날짜·시각 함께 저장 (YYYY-MM-DD HH:MM:SS) | `/etc/profile.d/zzz-history.sh` |
| 명령 즉시 기록 | 명령 실행 시점마다 이력 파일에 반영 | `PROMPT_COMMAND` |

## 파일 권한

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 계정 정보 파일 | /etc/passwd, /etc/group → 644 (root:root) | - |
| 패스워드 파일 | /etc/shadow → 400 (root:root) | - |
| 네트워크 설정 파일 | /etc/hosts, /etc/services → 644 | - |
| 프로파일 | /etc/profile → 755 | - |
| 계정 백업 파일 | passwd-, group-, shadow- → 600 | - |
| 신규 파일 기본 권한 | umask 027 | `/etc/profile.d/zzz-umask.sh` |

## 환경변수 / 콘솔

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| PATH 보호 | PATH 에서 현재 디렉터리(.) 제거 | `/etc/profile.d/zzz-path.sh` |

## 세션 및 명령 이력

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| 유휴 세션 자동 종료 | 1800초(30분) 무입력 시 로그아웃 | `/etc/profile` |

## 환경변수 / 콘솔

| 보안 설정 항목 | 적용 내용 | 설정 위치 |
|---|---|---|
| root 콘솔 로그인 제한 | pam_securetty 적용 및 원격 터미널(pts) 제외 | `/etc/pam.d/login`<br>`/etc/securetty` |

## 스크립트 실행 후 수동 조치 사항

| 항목 | 명령 | 비고 |
|---|---|---|
| SSH 포트 확인 | `ss -tlnp | grep sshd` | 방화벽은 24477 을 열지만 스크립트가 sshd 포트를 바꾸지는 않음.<br>포트 변경이 필요하면 sshd_config 수정 + semanage port 등록 필요 |
| SELinux 포트 등록 | `semanage port -a -t ssh_port_t -p tcp 24477` | SSH 포트를 변경하는 경우에만 필요 |
| 접속 확인 | `새 터미널에서 SSH 재접속` | 현재 세션을 닫기 전에 반드시 확인 |

---

적용 여부 확인은 `verify/verify.py` 로 자동 점검할 수 있습니다.

```bash
python3 verify/verify.py --profile rocky8 --host <서버IP> --user <계정>
```
