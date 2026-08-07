# verify — 표준화 스크립트 적용 점검 도구

표준화 스크립트가 대상 서버에 정상 적용되었는지 확인하고 **결과를 엑셀로 저장**한다.

점검 명령은 전부 읽기 전용(`stat`, `grep`, `systemctl is-*`, `ss`, `ufw status`, `firewall-cmd --list-*`)이며 서버 설정을 변경하지 않는다.

## 요구 사항

| | |
|---|---|
| 점검 PC | Python 3.6 이상, `openpyxl` (`pip3 install openpyxl`) |
| 대상 서버 | bash, root 권한 (일부 항목은 `/etc/shadow` 등 읽기에 필요) |

엑셀 생성은 점검 PC에서만 수행하므로 **대상 서버에는 Python 이나 openpyxl 이 필요 없다.**

## 사용법

### 원격 점검 (권장)

```bash
python3 verify.py --host 192.168.5.190 --port 24477 --user emro
```

`--profile` 을 생략하면 대상 서버의 `/etc/os-release` 로 기준을 자동 판별한다.

### 대상 서버에서 직접 점검

```bash
sudo python3 verify.py -o /tmp/점검결과.xlsx
```

### sudo 에 패스워드가 필요한 경우

원격에서 `sudo` 가 패스워드를 요구하면 비대화형 실행이 불가능하다. 이때는 수집과 보고서 생성을 분리한다.

```bash
# ① 점검 PC — 수집 스크립트 생성
python3 verify.py --profile ubuntu2404 --emit-script > collect.sh
scp -P 24477 collect.sh emro@192.168.5.190:/tmp/

# ② 대상 서버 — 수집 (읽기 전용)
sudo bash /tmp/collect.sh > /tmp/result.txt

# ③ 점검 PC — 결과 파일로 엑셀 생성
scp -P 24477 emro@192.168.5.190:/tmp/result.txt .
python3 verify.py --from-raw result.txt
```

### 적용 보안설정 목록 생성 (안내 문서)

```bash
python3 verify.py --settings-only --profile rocky9 --outdir ../docs
```

## 주요 옵션

| 옵션 | 설명 |
|---|---|
| `--profile` | `ubuntu2404` / `rocky8` / `rocky9` (생략 시 자동 판별) |
| `--host` `--port` `--user` `-i` | 원격 접속 정보 (생략 시 로컬 점검) |
| `--no-sudo` | sudo 없이 실행. 권한이 필요한 항목은 미적용으로 표시되니 주의 |
| `-o` `--outdir` | 결과 엑셀 경로 / 저장 폴더 |
| `--raw` | 수집 원본 텍스트 저장 (재판정·증빙용) |
| `--from-raw` | 수집 원본으로 엑셀만 생성 |
| `--emit-script` | 수집 스크립트만 출력 |
| `--auditor` | 점검자명 (표지에 기록) |

종료 코드는 미적용 항목이 있으면 `1`, 없으면 `0` 이라 CI 에서도 쓸 수 있다.

## 결과 엑셀 구성

| 시트 | 내용 |
|---|---|
| 표지 | 대상 서버·OS·점검 일시·판정 기준 |
| 점검 요약 | 구분별 적용 현황 집계 및 조치 대상 번호 |
| 점검 결과 | 전체 항목 상세 (기대값 / 판정 / 실제 확인 결과) |
| 조치 필요 항목 | 미적용·확인필요만 추출 |

판정 열은 드롭다운 + 조건부 서식이라 담당자가 직접 수정해도 색상이 유지된다.

| 판정 | 의미 |
|---|---|
| 적용됨 | 스크립트 설정이 정상 적용됨 |
| 미적용 | 적용되지 않았거나 이후 변경됨 — 조치 필요 |
| 확인필요 | 자동 판정 불가 — 담당자 확인 필요 |
| 해당없음 | 미설치 / 미해당 환경 |

## 파일 구성

| 파일 | 역할 |
|---|---|
| `verify.py` | 진입점 — 수집, 판정, 엑셀 저장 |
| `profiles.py` | OS별 적용 설정 목록 및 점검 항목 정의 |
| `judge.py` | 수집 결과 자동 판정 규칙 |
| `report.py` | 엑셀·마크다운 생성 |

점검 항목을 추가하려면 `profiles.py` 의 `checks` 에 항목을 넣고, 필요하면 `judge.py` 에 판정 규칙을 추가한다.

```python
dict(sec="파일 권한", no="9-16", item="예시 항목",
     cmd="stat -c '%n %a' /etc/example",
     exp="600", judge="contains:600"),
```
