# linux-standardization

신규 리눅스 서버 구축 시 **기본 시스템 설정과 보안 하드닝을 일괄 적용**하는 표준화 스크립트 모음.

서버 생성 → 스크립트 1회 실행 → 적용 여부 점검까지 한 흐름으로 처리한다.

## 구성

| 경로 | 내용 |
|---|---|
| `standard_ubuntu2404.sh` | Ubuntu 24.04 LTS 표준화 스크립트 |
| `standard_v8.sh` | Rocky Linux 8 표준화 스크립트 |
| `standard_v9.sh` | Rocky Linux 9 표준화 스크립트 |
| `docs/` | OS별 적용 보안설정 목록 (마크다운) |
| `xlsx/` | OS별 적용 보안설정 목록 (엑셀) |
| `verify/` | 적용 여부 점검 도구 — 결과를 엑셀로 저장 |

## 1. 표준화 스크립트 실행

```bash
# Ubuntu 24.04 — 생성할 계정명을 인자로 전달 (비대화형)
sudo bash standard_ubuntu2404.sh sysadmin

# Rocky Linux 8 / 9 — 실행 중 계정명·패스워드를 입력
sudo bash standard_v8.sh
sudo bash standard_v9.sh
```

> **주의** — SSH·PAM 설정을 변경하므로 **별도 root 세션을 열어둔 채로 실행**하고,
> 현재 세션을 닫기 전에 새 터미널에서 접속과 `sudo` 동작을 반드시 확인할 것.
> 변경 전 원본은 Ubuntu 는 `/root/backup/<날짜>/`, Rocky 는 `/home/backup/<날짜>/` 에 보관된다.

## 2. 적용되는 보안설정

OS별 상세 목록은 아래 문서 참고. 엑셀 버전은 `xlsx/` 에 동일한 내용으로 있다.

- [Ubuntu 24.04](docs/적용_보안설정_ubuntu2404.md) — 44개 항목
- [Rocky Linux 8](docs/적용_보안설정_rocky8.md) — 33개 항목
- [Rocky Linux 9](docs/적용_보안설정_rocky9.md) — 33개 항목

주요 항목 요약:

| 구분 | 적용 내용 |
|---|---|
| 시간 동기화 | 사내 NTP(192.168.5.55) 지정, 외부 NTP 차단, KST (Ubuntu) |
| 계정·원격 접속 | 관리용 개인 계정 생성, root 원격 로그인 차단, SSH 포트 24477 (Ubuntu) |
| 관리자 권한 | su 사용을 sudo/wheel 그룹으로 제한, `/bin/su` 4750 |
| 패스워드 정책 | 8자 이상 + 복잡도 4종, 재사용 2회 금지, 최대 90일 |
| 계정 잠금 | 로그인 실패 시 잠금 (Ubuntu 5회 / Rocky 3회), 600초 후 해제 |
| 방화벽 | 기본 차단 정책, 24477/tcp 만 허용 |
| 세션·이력 | 유휴 30분 자동 종료, 명령 이력 1만건 + 실행 시각 기록 |
| 파일 권한 | 계정·인증 관련 주요 파일 권한 하드닝, umask 027 |
| 환경변수 | PATH 에서 현재 디렉터리(.) 제거 |

### OS별 차이

| 항목 | Ubuntu 24.04 | Rocky 8 / 9 |
|---|---|---|
| SSH 포트 | 22 → **24477 변경** | **변경하지 않음** (방화벽만 24477 개방) |
| 관리자 그룹 | `sudo` | `wheel` |
| 방화벽 | UFW | firewalld (default zone = drop) |
| 계정 잠금 | `pam_faillock` 직접 등록, 5회 | `authselect with-faillock`, 3회 |
| 패스워드 최소 사용 기간 | 7일 | 미설정 |
| `/etc/shadow` | 640 (root:shadow) | 400 (root:root) |
| 표준시 | Asia/Seoul 설정 | 미설정 |

## 3. 적용 여부 점검

점검 PC 에서 실행하면 대상 서버를 점검해 **결과를 엑셀로 저장**한다.

```bash
pip3 install openpyxl

python3 verify/verify.py --host 192.168.5.190 --port 24477 --user emro
```

```
점검 완료 — jenkins-prod (192.168.5.190)
  기준      : Ubuntu 24.04 LTS / standard_ubuntu2404.sh
  총 58개 항목 → 적용됨 44 / 미적용 11 / 확인필요 3 / 해당없음 0
  저장      : ./점검결과_192.168.5.190_20260807.xlsx
```

기준(`--profile`)은 대상 서버 OS 로 자동 판별한다. 옵션과 sudo 패스워드가 필요한 경우의 대응은 [verify/README.md](verify/README.md) 참고.

점검 명령은 전부 읽기 전용이라 운영 서버에 그대로 사용할 수 있다.

---

본 저장소의 점검 도구는 **표준화 스크립트가 의도대로 적용되었는지** 확인하는 용도다.
KISA·ISMS-P·CIS Benchmark 등 외부 보안 기준에 대한 취약점 진단은 별도로 수행해야 한다.
