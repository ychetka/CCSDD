#!/usr/bin/env python3
# secret_scan.py - the single canonical secret-pattern scanner.
# Used by security_check.sh (delta lines) and partner_call.sh
# (outbound args) - two regex sets that drifted apart would let a
# secret pattern past one boundary the other already knows.
#
#   secret_scan.py            - scan stdin, print "LABEL: <line>" per hit
#   secret_scan.py --quiet    - exit status only
# Exit: 0 clean, 1 hits found.
#
# Pattern policy: credential-shaped ASSIGNMENTS and known token/key
# formats only. Bare words like "token" appear throughout spec text
# and are not secrets - precision beats recall at this boundary.
import re, sys

PATTERNS = [
    (r"(?i)(api[_-]?key|secret|token|password|passwd)\s*[:=]\s*['\"][^'\"]{8,}['\"]",
     "hardcoded credential assignment"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key material"),
    (r"(?i)bearer\s+[a-z0-9._~+/=-]{20,}", "bearer token literal"),
    (r"ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}",
     "github token literal"),
    (r"xox[baprs]-[A-Za-z0-9-]{10,}", "slack token literal"),
    (r"sk-[A-Za-z0-9_-]{20,}", "api key literal (sk-*)"),
    (r"AKIA[0-9A-Z]{16}", "aws access key id"),
    (r"(?i)(?:api[_-]?key|secret|password|passwd|bearer)[\"'\s:=>-]{1,10}[A-Za-z0-9_/+\-.]{20,}",
     "credential-shaped assignment"),
]

def scan_lines(lines):
    hits = []
    for line in lines:
        for rx, label in PATTERNS:
            if re.search(rx, line):
                hits.append(f"{label}: {line.strip()[:120]}")
                break
    return hits

if __name__ == "__main__":
    quiet = "--quiet" in sys.argv[1:]
    hits = scan_lines(sys.stdin)
    if not quiet:
        for h in hits[:30]:
            print(h)
    sys.exit(1 if hits else 0)
