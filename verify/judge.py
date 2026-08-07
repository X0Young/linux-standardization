# -*- coding: utf-8 -*-
"""점검 항목 자동 판정 로직."""
import re

APPLIED = "적용됨"
NOT_APPLIED = "미적용"
CHECK = "확인필요"
NA = "해당없음"

ORDER = [NOT_APPLIED, CHECK, APPLIED, NA]


def judge(rule, out):
    """rule: profiles.py 의 judge 값, out: 명령 표준출력. 반환: 판정 문자열."""
    o = (out or "").strip()
    low = o.lower()

    if not rule or rule == "manual":
        return CHECK

    if rule.startswith("contains:"):
        return APPLIED if rule[9:].lower() in low else NOT_APPLIED
    if rule.startswith("absent:"):
        return APPLIED if rule[7:].lower() not in low else NOT_APPLIED
    if rule.startswith("regex:"):
        return APPLIED if re.search(rule[6:], o) else NOT_APPLIED
    if rule.startswith("both:"):
        return APPLIED if all(t.lower() in low for t in rule[5:].split(",")) else NOT_APPLIED
    if rule.startswith("allmatch:"):
        pat = rule[9:].lower()
        lines = [l for l in o.splitlines() if l.strip()]
        return APPLIED if lines and all(pat in l.lower() for l in lines) else NOT_APPLIED
    if rule.startswith("allmatch_first2:"):
        pat = rule[16:].lower()
        lines = [l for l in o.splitlines() if l.strip()][:2]
        return APPLIED if len(lines) == 2 and all(pat in l.lower() for l in lines) else NOT_APPLIED
    if rule.startswith("emptyexcept:"):
        mark = rule[12:]
        return APPLIED if not [l for l in o.splitlines() if l.strip() and l.strip() != mark] else NOT_APPLIED

    if rule == "nonempty":
        return APPLIED if o else NOT_APPLIED

    if rule == "ge1":
        try:
            return APPLIED if int(o.split()[0]) >= 1 else NOT_APPLIED
        except Exception:
            return NOT_APPLIED

    if rule == "pwstatus":
        rows = [l.split() for l in o.splitlines() if l.strip()]
        if not rows:
            return CHECK
        return APPLIED if all(len(r) > 1 and r[1] == "P" for r in rows) else NOT_APPLIED

    if rule == "credits":
        return APPLIED if all(re.search(r"%s\s*=\s*-1" % k, o)
                              for k in ("dcredit", "ocredit", "ucredit", "lcredit")) else NOT_APPLIED

    if rule == "pwhistory_order":
        hist = unix = None
        for l in o.splitlines():
            m = re.match(r"^(\d+):", l)
            if not m:
                continue
            n = int(m.group(1))
            if "pam_pwhistory" in l and hist is None:
                hist = n
            if "pam_unix" in l and unix is None:
                unix = n
        if hist is None:
            return NOT_APPLIED
        if unix is None:
            return CHECK
        return APPLIED if hist < unix else NOT_APPLIED

    if rule == "chagemaxmin":
        found = False
        for b in re.split(r"^== ", o, flags=re.M):
            if "Maximum" not in b:
                continue
            found = True
            mx = re.search(r"Maximum.*?:\s*(\S+)", b)
            mn = re.search(r"Minimum.*?:\s*(\S+)", b)
            if not (mx and mx.group(1) == "90") or not (mn and mn.group(1) == "7"):
                return NOT_APPLIED
        return APPLIED if found else CHECK

    if rule == "faillock_stack":
        if "NOT_ENABLED" in o:
            return NOT_APPLIED
        return APPLIED if all("pam_faillock.so " + d in o for d in ("preauth", "authfail", "authsucc")) else NOT_APPLIED

    if rule == "ufwdefault":
        return APPLIED if ("deny (incoming)" in low and "allow (outgoing)" in low) else NOT_APPLIED

    if rule == "tmout":
        if "1800" not in o:
            return NOT_APPLIED
        return APPLIED if re.search(r"declare\s+-\w*r", o) else CHECK

    if rule == "hist":
        return APPLIED if ("HISTSIZE=10000" in o and "HISTFILESIZE=20000" in o
                           and "%F %T" in o and "ignoredups:erasedups" in o) else NOT_APPLIED

    if rule == "ifconfig":
        return NA if "NOT_INSTALLED" in o else (APPLIED if " 700" in o else NOT_APPLIED)

    if rule == "logperm":
        return CHECK if "NOT_EXIST" in o else (APPLIED if " 640" in o else NOT_APPLIED)

    if rule == "backupperm":
        lines = [l for l in o.splitlines() if l.strip() and l.strip() != "EOL"]
        if not lines:
            return NA
        return APPLIED if all("root:root 600" in l for l in lines) else NOT_APPLIED

    if rule == "backupperm_mode":
        lines = [l for l in o.splitlines() if l.strip() and l.strip() != "EOL"]
        if not lines:
            return NA
        return APPLIED if all(l.strip().endswith(" 600") for l in lines) else NOT_APPLIED

    if rule == "pathdot":
        m = re.search(r"PATH=(.*)", o)
        if not m:
            return CHECK
        parts = m.group(1).strip().split(":")
        return NOT_APPLIED if ("." in parts or "" in parts) else APPLIED

    if rule == "securetty_pair":
        if "PAM_NOT_SET" in o:
            return NOT_APPLIED
        if "NO_SECURETTY_FILE" in o:
            # pam_securetty 는 있는데 목록 파일이 없으면 콘솔 로그인이 전면 차단된다
            return CHECK
        m = re.search(r"pts 항목 수:\s*(\d+)", o)
        if not m:
            return CHECK
        return APPLIED if int(m.group(1)) == 0 else NOT_APPLIED

    return CHECK
