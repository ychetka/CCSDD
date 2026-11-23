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
    (r"(?i)(api[_-]?key|secret|token|password|passwd)\s*[:=]\s*['\"]([^'\"]{8,})['\"]",
     "hardcoded credential assignment"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key material"),
    (r"(?i)bearer\s+[a-z0-9._~+/=-]{20,}", "bearer token literal"),
    (r"(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}",
     "github token literal"),
    (r"xox[baprs]-[A-Za-z0-9-]{10,}", "slack token literal"),
    (r"sk-[A-Za-z0-9_-]{20,}", "api key literal (sk-*)"),
    (r"AKIA[0-9A-Z]{16}", "aws access key id"),
    # (?!\() after the value run: secret = get_secret_from_vault() is
    # a function call, not a literal credential - the run stops at
    # '(' but without the lookahead it would still match.
    (r"(?i)(?:api[_-]?key|secret|password|passwd|bearer)[\"'\s:=>-]{1,10}([A-Za-z0-9_/+\-.]{20,})(?!\()",
     "credential-shaped assignment"),
]

# Documentation placeholders are not leaked credentials - the same
# exemption hygiene_check.sh applies, so 'api_key: your_key_here'
# in docs passes both boundaries identically.
PLACEHOLDER_RE = re.compile(
    r"(?i)^(your|example|sample|dummy|changeme|change_me|placeholder|"
    r"fake|redacted|xxx|\[|<|\$\{|not.real|test|todo|fixme|sk-your|ghp-your)")

def scan_lines(lines):
    hits = []
    for line in lines:
        for rx, label in PATTERNS:
            m = re.search(rx, line)
            if not m:
                continue
            if "assignment" in label and m.lastindex:
                if PLACEHOLDER_RE.match(m.group(m.lastindex)):
                    continue
            hits.append(f"{label}: {line.strip()[:120]}")
            break
    return hits

if __name__ == "__main__":
    quiet = "--quiet" in sys.argv[1:]
    # Force UTF-8 with replacement: diffs may contain non-UTF-8 bytes
    # (binary blobs scanned with --text, legacy encodings) - a decode
    # crash must never silently skip the scan.
    sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    hits = scan_lines(sys.stdin)
    if not quiet:
        for h in hits[:30]:
            print(h)
    sys.exit(1 if hits else 0)
