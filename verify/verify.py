#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
서버 표준화 스크립트 적용 여부 점검 도구.

표준화 스크립트(standard_ubuntu2404.sh / standard_v8.sh / standard_v9.sh)가
대상 서버에 정상 적용되었는지 확인하고 결과를 엑셀로 저장한다.

사용 예시
---------
  # 원격 서버 점검 (권장) — 점검 PC 에서 실행
  python3 verify.py --host 192.168.5.190 --port 24477 --user emro

  # 대상 서버에서 직접 점검
  sudo python3 verify.py

  # sudo 에 패스워드가 필요해 원격 자동 실행이 안 되는 경우
  python3 verify.py --emit-script > /tmp/collect.sh      # ① 수집 스크립트 생성
  #   서버에서:  sudo bash /tmp/collect.sh > /tmp/result.txt
  python3 verify.py --from-raw /tmp/result.txt           # ② 결과 파일로 엑셀 생성

  # 적용 보안설정 목록(안내용) 생성
  python3 verify.py --settings-only --profile rocky9

프로파일(--profile)을 생략하면 대상 서버의 /etc/os-release 로 자동 판별한다.
엑셀 생성에는 openpyxl 이 필요하다 (pip install openpyxl).
점검 명령은 전부 읽기 전용이며 서버 설정을 변경하지 않는다.
"""
import argparse
import os
import re
import subprocess
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from profiles import PROFILES, detect_from_os_release  # noqa: E402
from judge import judge, APPLIED, NOT_APPLIED, CHECK, NA  # noqa: E402

COLLECT_HEADER = r'''#!/bin/bash
# 자동 생성 — 서버 표준화 스크립트 적용 점검 수집기 (읽기 전용)
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TU=$(awk -F: '$3>=1000 && $3<65534 && $1!="nobody" {print $1}' /etc/passwd | tr '\n' ' ')
export TU

echo "###META_HOST=$(hostname)"
echo "###META_IP=$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "###META_DATE=$(date '+%Y-%m-%d %H:%M:%S')"
echo "###META_TU=$TU"
echo "###META_OS=$(. /etc/os-release 2>/dev/null; echo $PRETTY_NAME)"
echo "###META_OSID=$(. /etc/os-release 2>/dev/null; echo ${ID}-${VERSION_ID})"

run_check() {
  local id="$1"; shift
  echo "###BEGIN $id"
  { eval "$*" ; } 2>&1 | head -60
  echo "###END $id"
}
'''


def make_collect_script(profile):
    out = [COLLECT_HEADER]
    for c in profile["checks"]:
        out.append("run_check '%s' '%s'" % (c["no"], c["cmd"].replace("'", "'\"'\"'")))
    out.append('echo "###DONE"')
    return "\n".join(out) + "\n"


def parse_raw(text, profile):
    meta, results = {}, {}
    for m in re.finditer(r"^###META_(\w+)=(.*)$", text, re.M):
        meta[m.group(1).lower()] = m.group(2).strip()
    for m in re.finditer(r"^###BEGIN (\S+)\n(.*?)^###END \1$", text, re.M | re.S):
        results[m.group(1)] = {"out": m.group(2).rstrip("\n")}
    by_id = {c["no"]: c for c in profile["checks"]}
    for cid, r in results.items():
        r["verdict"] = judge(by_id.get(cid, {}).get("judge", "manual"), r["out"])
    return meta, results


def _run(cmd, stdin_text=None, timeout=None):
    """subprocess.run 래퍼 — Python 3.6 호환 (capture_output/text 미사용)."""
    p = subprocess.Popen(cmd,
                         stdin=subprocess.PIPE if stdin_text is not None else None,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         universal_newlines=True)
    try:
        out, err = p.communicate(input=stdin_text, timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        raise
    return p.returncode, out, err


def ssh_base(args):
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
           "-o", "StrictHostKeyChecking=accept-new"]
    if args.port:
        cmd += ["-p", str(args.port)]
    if args.identity:
        cmd += ["-i", args.identity]
    target = "%s@%s" % (args.user, args.host) if args.user else args.host
    return cmd + [target]


def run_remote(args, script, use_sudo):
    cmd = ssh_base(args) + ["sudo -n bash -s" if use_sudo else "bash -s"]
    return _run(cmd, script, args.timeout)


def run_local(script, use_sudo, timeout):
    cmd = ["sudo", "-n", "bash", "-s"] if use_sudo else ["bash", "-s"]
    return _run(cmd, script, timeout)


def detect_profile(args):
    """대상 서버 OS 로 프로파일 자동 판별."""
    probe = ". /etc/os-release 2>/dev/null; echo \"$ID $VERSION_ID $PRETTY_NAME\""
    try:
        cmd = ssh_base(args) + [probe] if args.host else ["bash", "-c", probe]
        _, out, _ = _run(cmd, timeout=30)
        return detect_from_os_release(out), out.strip()
    except Exception as e:
        return None, str(e)


def main():
    ap = argparse.ArgumentParser(
        description="서버 표준화 스크립트 적용 여부 점검 → 엑셀 저장",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    ap.add_argument("--profile", choices=sorted(PROFILES), help="점검 기준 (생략 시 OS 자동 판별)")
    ap.add_argument("--host", help="원격 서버 주소 (생략 시 로컬 점검)")
    ap.add_argument("--port", type=int, default=None, help="SSH 포트 (기본 22)")
    ap.add_argument("--user", help="SSH 계정")
    ap.add_argument("-i", "--identity", help="SSH 개인키 경로")
    ap.add_argument("--no-sudo", action="store_true", help="sudo 없이 실행 (일부 항목 수집 불가)")
    ap.add_argument("--timeout", type=int, default=600, help="수집 제한 시간(초)")
    ap.add_argument("-o", "--output", help="결과 엑셀 경로")
    ap.add_argument("--raw", help="수집 원본 저장 경로")
    ap.add_argument("--from-raw", help="이미 수집된 원본 파일로 엑셀만 생성")
    ap.add_argument("--emit-script", action="store_true", help="수집 스크립트만 출력하고 종료")
    ap.add_argument("--settings-only", action="store_true", help="적용 보안설정 목록(엑셀+MD)만 생성")
    ap.add_argument("--outdir", default=".", help="산출물 저장 폴더")
    ap.add_argument("--auditor", default="", help="점검자명")
    args = ap.parse_args()

    # ---- 프로파일 결정 ----
    pname = args.profile
    if not pname and not args.from_raw:
        if args.emit_script or args.settings_only:
            ap.error("--profile 을 지정하세요 (자동 판별은 대상 서버 접속이 필요합니다)")
        pname, detail = detect_profile(args)
        if not pname:
            ap.error("OS 자동 판별 실패: %s\n--profile 로 직접 지정하세요." % detail)
        print("[자동 판별] %s → %s" % (detail, pname), file=sys.stderr)

    # ---- 설정 목록만 생성 ----
    if args.settings_only:
        import report
        prof = PROFILES[pname]
        os.makedirs(args.outdir, exist_ok=True)
        x = os.path.join(args.outdir, "적용_보안설정_%s.xlsx" % pname)
        m = os.path.join(args.outdir, "적용_보안설정_%s.md" % pname)
        report.build_settings_xlsx(prof, x)
        report.build_settings_md(prof, m)
        print("생성: %s" % x)
        print("생성: %s" % m)
        return 0

    # ---- 수집 스크립트만 출력 ----
    if args.emit_script:
        sys.stdout.write(make_collect_script(PROFILES[pname]))
        return 0

    # ---- 수집 ----
    if args.from_raw:
        with open(args.from_raw, errors="replace") as f:
            raw = f.read()
        if not pname:
            m = re.search(r"^###META_OSID=(.*)$", raw, re.M)
            osid = m.group(1) if m else ""
            pname = detect_from_os_release(osid) or detect_from_os_release(
                (re.search(r"^###META_OS=(.*)$", raw, re.M) or re.match("", "")).group(1)
                if re.search(r"^###META_OS=(.*)$", raw, re.M) else "")
            if not pname:
                ap.error("원본에서 OS 를 판별하지 못했습니다. --profile 로 지정하세요.")
            print("[자동 판별] %s → %s" % (osid, pname), file=sys.stderr)
    else:
        prof = PROFILES[pname]
        script = make_collect_script(prof)
        use_sudo = not args.no_sudo and os.geteuid() != 0
        where = "%s (원격)" % args.host if args.host else "로컬"
        print("[수집] %s / 기준: %s / 항목 %d개" % (where, pname, len(prof["checks"])), file=sys.stderr)
        try:
            rc, raw, err = (run_remote(args, script, use_sudo) if args.host
                            else run_local(script, use_sudo, args.timeout))
        except subprocess.TimeoutExpired:
            print("[오류] 수집 제한 시간(%ds) 초과" % args.timeout, file=sys.stderr)
            return 2
        if "###DONE" not in raw:
            print("[오류] 수집 실패 (rc=%s)\n%s" % (rc, (err or raw)[:800]), file=sys.stderr)
            if use_sudo:
                print("\nsudo 에 패스워드가 필요한 환경으로 보입니다. 아래 방법을 사용하세요:\n"
                      "  python3 verify.py --profile %s --emit-script > /tmp/collect.sh\n"
                      "  (서버에서) sudo bash /tmp/collect.sh > /tmp/result.txt\n"
                      "  python3 verify.py --from-raw /tmp/result.txt" % pname, file=sys.stderr)
            return 2

    prof = PROFILES[pname]
    meta, results = parse_raw(raw, prof)

    if args.raw:
        with open(args.raw, "w") as f:
            f.write(raw)

    missing = [c["no"] for c in prof["checks"] if c["no"] not in results]
    if missing:
        print("[경고] 수집되지 않은 항목: %s" % ", ".join(missing), file=sys.stderr)

    # ---- 엑셀 생성 ----
    import report
    meta.setdefault("date", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    meta["auditor"] = args.auditor
    meta.setdefault("ip", args.host or meta.get("ip", ""))

    out = args.output
    if not out:
        tag = (meta.get("ip") or meta.get("host") or pname).replace(" ", "")
        stamp = datetime.now().strftime("%Y%m%d")
        os.makedirs(args.outdir, exist_ok=True)
        out = os.path.join(args.outdir, "점검결과_%s_%s.xlsx" % (tag, stamp))

    path, tot = report.build_result_xlsx(prof, results, meta, out)

    total = len(prof["checks"])
    print("\n점검 완료 — %s (%s)" % (meta.get("host", ""), meta.get("ip", "")))
    print("  기준      : %s / %s" % (prof["title"], prof["script"]))
    print("  총 %d개 항목 → %s %d / %s %d / %s %d / %s %d"
          % (total, APPLIED, tot[APPLIED], NOT_APPLIED, tot[NOT_APPLIED],
             CHECK, tot[CHECK], NA, tot[NA]))
    print("  저장      : %s" % path)

    ng = [c for c in prof["checks"] if results.get(c["no"], {}).get("verdict") == NOT_APPLIED]
    if ng:
        print("\n미적용 항목:")
        for c in ng:
            print("  - [%s] %s / %s" % (c["no"], c["sec"], c["item"]))
    return 1 if ng else 0


if __name__ == "__main__":
    sys.exit(main())
