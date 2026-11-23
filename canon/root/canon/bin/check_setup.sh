#!/usr/bin/env bash
# check_setup.sh - validate project config and environment. Fail closed.
set -uo pipefail
# canon may sit outside the git toplevel - resolve from script path.
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
PJ="$CANON_DIR/project.json"
fails=0
fail() { echo "SETUP FAIL: $*"; fails=$((fails+1)); }
ok()   { echo "  ok: $*"; }

# Binaries are checked BEFORE any use - a missing python3 would make
# every later check silently degrade.
before=$fails
for bin in gh git python3 flock ssh-keygen; do
  command -v "$bin" >/dev/null || fail "missing binary: $bin"
done
[ $fails -eq $before ] && ok "binaries: gh git python3 flock ssh-keygen"
if ! command -v python3 >/dev/null; then
  echo "SETUP: $fails FAILURES - halt, do not proceed"; exit 1
fi

[ -f "$PJ" ] || fail "$PJ missing"

if [ -f "$PJ" ]; then
CANON_DIR="$CANON_DIR" python3 - <<'PY'
import json, os, re, sys
try:
    cfg = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
except Exception as e:
    print(f"SETUP FAIL: project.json is not valid JSON: {e}")
    sys.exit(1)
if not isinstance(cfg, dict):
    print("SETUP FAIL: project.json must be a JSON object")
    sys.exit(1)
required = {"repo", "text_language", "protected_paths"}
enums = {"text_language": {"en", "ru"},
         "repo_language": {"en", "ru"},
         "task_tracker": {"github_issues", "local", "none"},
         "role": {"worker", "service", "orchestrator"}}
# every key the canonical harness may legitimately declare - an
# incomplete allowlist rejects valid configs and drives instances to
# invent undeclared keys instead
allowed = required | {
    "task_tracker", "cyrillic_paths", "repo_language",
    "version",                    # {file, regex} for repo_version_*
    "review",                     # {reviewer_logins: [...]}
    "migration_dry_run_cmd",      # verify_constraints dry-run
    "instances_bridge_dir",       # transport adapter location
    "canonical_harness_dir",      # canon root override
    "bound_instance", "workspace",# onboard linkage
    "ignored_instances",          # fleet audit exemptions
    "repos",                      # nested multi-repo declaration
    "role",                       # worker|service|orchestrator
    "project_name",               # display name for fleet messages
    "director",                   # {background_executors: int}
    "actors",                     # actor-registry bootstrap overrides
    "partners",                   # {role: {partner_id, model}} bindings
    "forge",                      # panel verdict transport adapter name
    "base_branch",                # trusted base for gate_run scripts
    "gate_checks",                # {name: argv[]} project floor cmds
    "external_checks",            # DAST etc: rollup names required green
    "merge",                      # {gh_bin} merge-gate identity
    "security",                   # {forbidden_patterns: [...]}
}
types = {"protected_paths": list, "cyrillic_paths": list,
         "ignored_instances": list, "repos": list,
         "version": dict, "review": dict, "director": dict,
         "actors": dict, "partners": dict,
         "gate_checks": dict, "external_checks": list,
         "merge": dict, "security": dict,
         "repo": str, "text_language": str, "repo_language": str,
         "role": str, "forge": str, "base_branch": str,
         "migration_dry_run_cmd": str, "instances_bridge_dir": str,
         "canonical_harness_dir": str, "bound_instance": str,
         "workspace": str, "project_name": str, "task_tracker": str}
missing = required - set(cfg)
extra = set(cfg) - allowed
errs = []
if missing: errs.append(f"missing keys: {sorted(missing)}")
if extra: errs.append(f"unknown keys: {sorted(extra)}")
# types BEFORE enums - an enum check on a wrong-typed value crashes
for k, t in types.items():
    if k in cfg and not isinstance(cfg[k], t):
        errs.append(f"{k} must be {t.__name__}")
for k, vals in enums.items():
    # enum keys must validate even when the type check above already
    # flagged them - but only string values can be enum-compared.
    if k in cfg and not isinstance(cfg[k], str):
        errs.append(f"{k} must be a string (enum {sorted(vals)})")
    elif k in cfg and cfg[k] not in vals:
        errs.append(f"{k}={cfg[k]!r} not in {sorted(vals)}")
v = cfg.get("version")
if isinstance(v, dict):
    vf, vr = v.get("file"), v.get("regex")
    if not isinstance(vf, str) or not vf.strip():
        errs.append("version.file must be a non-empty path string")
    if not isinstance(vr, str) or not vr:
        errs.append("version.regex must be a non-empty regex string")
    else:
        try:
            re.compile(vr)
        except re.error as e:
            errs.append(f"version.regex does not compile: {e}")
r = cfg.get("review")
if isinstance(r, dict):
    if "reviewer_logins" not in r:
        # absent -> the merge gate fails closed; an explicitly
        # declared list may never be empty or malformed
        pass
    else:
        rl = r["reviewer_logins"]
        if not isinstance(rl, list) or not rl:
            errs.append("review.reviewer_logins must be a non-empty array")
        else:
            for login in rl:
                # GitHub App logins carry a [bot] suffix.
                if not isinstance(login, str) or not re.fullmatch(r"[A-Za-z0-9-]+(\[bot\])?", login or ""):
                    errs.append(f"review.reviewer_logins entry {login!r} is not a valid GitHub login")
    if "gh_bin" in r:
        gb = r["gh_bin"]
        if not isinstance(gb, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", gb or ""):
            errs.append("review.gh_bin must be a bare binary basename (no path separators)")
    if "api_bin" in r:
        ab = r["api_bin"]
        if not isinstance(ab, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", ab or ""):
            errs.append("review.api_bin must be a bare binary basename (no path separators)")
    if "panel" in r:
        pn = r["panel"]
        if not isinstance(pn, list) or not all(isinstance(x, str) for x in pn):
            errs.append("review.panel must be an array of domain names")
m = cfg.get("merge")
if isinstance(m, dict):
    for _k in ("gh_bin", "api_bin"):
        if _k in m:
            _v = m[_k]
            if not isinstance(_v, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", _v or ""):
                errs.append(f"merge.{_k} must be a bare binary basename (no path separators)")
# Identity separation: the merge/author binary must differ from the
# reviewer binary whenever a reviewer identity is configured on a
# real forge. The comparison uses EFFECTIVE binaries through the
# same resolution order as gh_id.sh - api_bin beats gh_bin and an
# omitted key resolves to the forge default - so "api_bin set on
# one side" can never smuggle an identity collision past the check.
# Same binary => PR author == reviewer => forge self-approve
# rejection and a merge identity able to publish review signals.
_fr = cfg.get("forge")
_fdef = {"gitlab": "glab"}.get(_fr, "gh")
_reviewer_cfg = isinstance(r, dict) and (
    bool(r.get("reviewer_logins")) or bool(r.get("reviewer_profiles")))
if _reviewer_cfg and _fr != "test":
    _mb = ((m.get("api_bin") or m.get("gh_bin"))
           if isinstance(m, dict) else None) or _fdef
    _rb = ((r.get("api_bin") or r.get("gh_bin"))
           if isinstance(r, dict) else None) or _fdef
    if _mb == _rb:
        errs.append("merge.gh_bin must differ from review.gh_bin "
                    "(author and reviewer identities must be separate; "
                    f"both resolve to {_mb!r})")
# reviewer_profiles: {<login>: {"gh_bin": <basename>, ...}} - keys are
# the panel logins (canonical schema, also read by panel_gate.sh).
rp = r.get("reviewer_profiles") if isinstance(r, dict) else None
if rp is not None:
    if not isinstance(rp, dict):
        errs.append("review.reviewer_profiles must be an object keyed by reviewer login")
    else:
        for login, prof in rp.items():
            if not re.fullmatch(r"[A-Za-z0-9-]+(\[bot\])?", login or ""):
                errs.append(f"review.reviewer_profiles key {login!r} is not a valid GitHub login")
            if isinstance(prof, dict):
                for _k in ("gh_bin", "api_bin"):
                    _v2 = prof.get(_k)
                    if _v2 is not None and not re.fullmatch(r"[A-Za-z0-9_-]+", str(_v2)):
                        errs.append(f"review.reviewer_profiles.{login}.{_k} must be a bare binary basename")
                mf = prof.get("model_family")
                if mf is not None and not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*", str(mf)):
                    errs.append(f"review.reviewer_profiles.{login}.model_family must be a slug (e.g. 'anthropic', 'openai')")
                if prof.get("high_risk_only") is True and not mf:
                    errs.append(f"review.reviewer_profiles.{login} sets high_risk_only but no model_family - "
                                "a risk:high family check cannot distinguish it from the default family")
            elif prof is not None:
                errs.append(f"review.reviewer_profiles.{login} must be an object")
# risk: high capability check: when any declared profile carries a
# model_family, a risk:high fragment needs >=2 distinct families to
# ever pass - flag a single-family config at setup, not at merge.
if rp:
    fams = {str((v or {}).get("model_family")).strip()
            for v in rp.values() if isinstance(v, dict)
            and (v or {}).get("model_family")}
    if len(fams) == 1:
        errs.append("review.reviewer_profiles declares exactly one model_family "
                    f"({sorted(fams)[0]!r}) - a risk: high fragment can never "
                    "collect approvals from two distinct families")
fr = cfg.get("forge")
if isinstance(fr, str) and not re.fullmatch(r"[a-z][a-z0-9_]*", fr):
    errs.append("forge must be a lowercase adapter name")
gc = cfg.get("gate_checks")
if isinstance(gc, dict):
    for name, argv in gc.items():
        if not re.fullmatch(r"[a-z][a-z0-9_]*", name or ""):
            errs.append(f"gate_checks key {name!r} is not a valid check name")
        if name.endswith("_optional"):
            # opt-out flag for an unconfigured project floor
            if not isinstance(argv, bool):
                errs.append(f"gate_checks.{name} must be a bool")
            continue
        if not isinstance(argv, list) or not argv \
                or not all(isinstance(x, str) and x for x in argv):
            errs.append(f"gate_checks.{name} must be a non-empty argv array")
ec = cfg.get("external_checks")
if isinstance(ec, list):
    for n in ec:
        if not isinstance(n, str) or not n.strip():
            errs.append("external_checks entries must be non-empty strings")
d = cfg.get("director")
if isinstance(d, dict) and "background_executors" in d:
    be = d["background_executors"]
    # bool subclasses int in Python - "background_executors": true
    # would pass isinstance(be, int); type() excludes it.
    if type(be) is not int or not (1 <= be <= 8):
        errs.append("director.background_executors must be an int in 1..8")
pp = cfg.get("protected_paths")
if isinstance(pp, list):
    for p in pp:
        if not isinstance(p, str) or not p.strip():
            errs.append(f"protected_paths entry {p!r} must be a non-empty string")
if errs:
    for e in errs: print(f"SETUP FAIL: project.json schema error: {e}")
    sys.exit(1)
PY
  if [ $? -eq 0 ]; then ok "project.json schema"; else fails=$((fails+1)); fi
fi

# Review-panel registry: canon/config/review_panel.json must parse,
# every domain declare a valid class, gate_check names resolve to a
# canon script OR a project gate_checks argv, and llm/hybrid domains
# must name an existing profile. review.panel (project override) may
# only SUBSET the registry - widening the panel through project.json
# would let a repo skip mandatory review.
RP="$CANON_DIR/config/review_panel.json"
if [ ! -f "$RP" ]; then
  fail "missing canon/config/review_panel.json (review panel registry)"
else
CANON_DIR="$CANON_DIR" RP="$RP" PJ="$PJ" python3 - <<'PY'
import json, os, re, sys
canon_dir = os.environ["CANON_DIR"]
errs = []
try:
    reg = json.load(open(os.environ["RP"]))
    domains = reg.get("domains")
    if not isinstance(domains, dict) or not domains:
        raise ValueError("'domains' must be a non-empty object")
except Exception as e:
    print(f"SETUP FAIL: review_panel.json unreadable: {e}")
    sys.exit(1)
try:
    pj = json.load(open(os.environ["PJ"]))
except Exception:
    pj = {}
gate_checks = pj.get("gate_checks") or {}
for name, e in domains.items():
    if not re.fullmatch(r"[a-z][a-z0-9_]*", name or ""):
        errs.append(f"domain name {name!r} invalid")
    if not isinstance(e, dict):
        errs.append(f"domain {name}: entry must be an object"); continue
    cls = e.get("class")
    if cls not in ("ci", "llm", "hybrid"):
        errs.append(f"domain {name}: class must be ci|llm|hybrid")
    if not isinstance(e.get("required", True), bool):
        errs.append(f"domain {name}: required must be a bool")
    gc = e.get("gate_check")
    if gc is not None:
        if not isinstance(gc, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", gc):
            errs.append(f"domain {name}: gate_check name invalid")
        elif not (os.path.isfile(os.path.join(canon_dir, "bin", gc + ".sh"))
                  or gc in gate_checks
                  or gate_checks.get(gc + "_optional") is True):
            errs.append(f"domain {name}: gate_check '{gc}' resolves to nothing "
                        f"(canon/bin/{gc}.sh absent, no gate_checks.{gc}, "
                        f"no gate_checks.{gc}_optional)")
    if cls in ("llm", "hybrid") and e.get("required", True):
        prof = e.get("profile") or f"reviewer_{name}"
        if not os.path.isfile(os.path.join(canon_dir, "agents", prof + ".md")):
            errs.append(f"domain {name}: profile canon/agents/{prof}.md missing")
panel = (pj.get("review") or {}).get("panel")
if isinstance(panel, list):
    extra = [d for d in panel if d not in domains]
    if extra:
        errs.append(f"review.panel names unknown domains: {extra}")
if errs:
    for e in errs: print(f"SETUP FAIL: review_panel registry: {e}")
    sys.exit(1)
PY
  [ $? -eq 0 ] && ok "review panel registry" || fails=$((fails+1))
fi

# Control-plane configs: partner_call.sh and the runtime adapters
# consume policy.json / partners.json at call time - a corrupt file
# there currently degrades to hardcoded defaults (fail-open).
# Deployment validation is where the failure must surface.
CANON_DIR="$CANON_DIR" python3 - <<'PY'
import json, os, sys
canon_dir = os.environ["CANON_DIR"]
errs = []
try:
    pol = json.load(open(os.path.join(canon_dir, "config", "policy.json"),
                            encoding="utf-8"))
    ex = pol.get("exec")
    if not isinstance(ex, dict):
        errs.append("policy.json: 'exec' must be an object")
    else:
        for k in ("deny", "allow"):
            if not isinstance(ex.get(k), list) or \
               not all(isinstance(v, str) for v in ex[k]):
                errs.append(f"policy.json: exec.{k} must be a string array")
        roles = ex.get("roles")
        if not isinstance(roles, dict):
            errs.append("policy.json: exec.roles must be an object")
    if not isinstance(pol.get("gateway"), dict):
        errs.append("policy.json: 'gateway' must be an object")
except Exception as e:
    errs.append(f"policy.json unreadable: {e}")
try:
    preg = json.load(open(os.path.join(canon_dir, "config", "partners.json"),
                             encoding="utf-8"))
    roles = preg.get("roles")
    if not isinstance(roles, dict) or not roles:
        errs.append("partners.json: 'roles' must be a non-empty object")
    else:
        for rid, r in roles.items():
            if not isinstance(r, dict) or not isinstance(r.get("profile"), str):
                errs.append(f"partners.json: role {rid!r} lacks a 'profile' string")
except Exception as e:
    errs.append(f"partners.json unreadable: {e}")
if errs:
    for e in errs: print(f"SETUP FAIL: {e}")
    sys.exit(1)
PY
[ $? -eq 0 ] && ok "policy.json + partners.json schema" || fails=$((fails+1))

# Canon deploy stamp: canon/canon_manifest.json must exist (written by
# onboard/rollout), carry a readable canon_version, and every file it
# lists must be present in the workspace - that is the deployment
# completeness check. files/sha256 must be non-empty and complete:
# an empty hash map silently disables integrity verification.
CM="$CANON_DIR/canon_manifest.json"
if [ ! -f "$CM" ]; then
  fail "missing canon/canon_manifest.json (canon deploy stamp)"
else
  CANON_DIR="$CANON_DIR" CM="$CM" python3 - <<'PY'
import json, os, sys
canon_dir, cm_path = os.environ["CANON_DIR"], os.environ["CM"]
try:
    m = json.load(open(cm_path, encoding="utf-8"))
    ver = m["canon_version"]
except Exception as e:
    print(f"SETUP FAIL: canon_manifest.json unreadable: {e}")
    sys.exit(1)
files = m.get("files")
def _ok_rel(f):
    return (isinstance(f, str) and f and not f.startswith("/")
            and ".." not in f.split("/") and "\n" not in f)
if not isinstance(files, list) or not files or not all(_ok_rel(f) for f in files):
    print("SETUP FAIL: canon_manifest.json 'files' must be a non-empty list "
          "of normalized relative paths inside the workspace")
    sys.exit(1)
missing = [f for f in files
           if not os.path.isfile(os.path.join(canon_dir, "..", f))]
if missing:
    print(f"SETUP FAIL: canon files missing per manifest: {missing[:5]}{'...' if len(missing)>5 else ''}")
    sys.exit(1)
import hashlib, re as _re, subprocess
sha = m.get("sha256") or {}
if not isinstance(sha, dict) or not sha:
    print("SETUP FAIL: canon_manifest.json 'sha256' map is empty/not an object - integrity check disabled")
    sys.exit(1)
if not all(_ok_rel(k) and isinstance(v, str) and _re.fullmatch(r"[0-9a-fA-F]{64}", v)
           for k, v in sha.items()):
    print("SETUP FAIL: canon_manifest.json 'sha256' must map relative paths to 64-hex digests")
    sys.exit(1)
no_hash = [f for f in files if f not in sha]
if no_hash:
    print(f"SETUP FAIL: canon files lacking a sha256 entry: {no_hash[:5]}{'...' if len(no_hash)>5 else ''}")
    sys.exit(1)
tampered = [f for f, want in sha.items()
            if os.path.isfile(os.path.join(canon_dir, "..", f))
            and hashlib.sha256(
                open(os.path.join(canon_dir, "..", f), "rb").read()
            ).hexdigest() != want]
if tampered:
    print(f"SETUP FAIL: canon files tampered/drifted vs manifest: {tampered[:5]}{'...' if len(tampered)>5 else ''}")
    sys.exit(1)
# extra canon files on disk that the manifest does not list hide from
# integrity verification - scan the whole canon tree, not a fixed
# subdir set: an executable planted at the canon root runs inside
# gate scripts without tripping anything.
# Allowed without a manifest entry:
#   - pinned adapter hooks: rel in stamp adapters_sha256 AND the
#     current bytes match the pinned sha (a modified hook is a
#     tamper, an unpinned one is an extra file);
#   - runtime/project data: non-executable state the cycle writes
#     (journals, stamps, config) or the operator drops in.
RUNTIME_OK = {
    "canon/project.json", "canon/canon_manifest.json",
    "canon/actors.json", "canon/cycle_log.jsonl",
    "canon/harness_log.jsonl", "canon/scope_whitelist.txt",
    "canon/migration_ok", "canon/migration_rollforward.md",
    "canon/gateway.db", "canon/gateway.db-wal", "canon/gateway.db-shm",
    "canon/gateway_counters.json", "canon/gateway_counters.json.migrated",
    "canon/roadmap.md", "canon/quota_park.json",
    "canon/release_history.jsonl",
    "canon/gate_runs.jsonl", "canon/gate_runs.jsonl.lock",
    "canon/panel_signals_fixture.json", "canon/panel_comments_fixture.jsonl",
}
RUNTIME_DIRS = ("canon/partner_journal/", "canon/human_signoffs/", "canon/kb/")
pinned = m.get("adapters_sha256") or {}
extra, drifted_hooks = [], []
listed = {f for f in files}
for dp, _dn, fns in os.walk(canon_dir):
    for name in sorted(fns):
        # Atomic-write siblings (*.tmp, *.lock, *.pyc) are transient
        # by design - a parallel writer must not trip the tamper
        # scan on its own rename target.
        if name.endswith((".lock", ".pyc", ".tmp")):
            continue
        ap = os.path.join(dp, name)
        rel = "canon/" + os.path.relpath(ap, canon_dir)
        if rel in listed or rel in RUNTIME_OK \
           or any(rel.startswith(d) for d in RUNTIME_DIRS):
            continue
        if rel in pinned:
            want = pinned[rel]
            got = hashlib.sha256(open(ap, "rb").read()).hexdigest()
            if got != want:
                drifted_hooks.append(rel)
            continue
        # Declared project hooks (version_source.sh, baseline_env.sh)
        # added mid-project are legal when the repo itself tracks
        # them - git ls-files is authoritative, no extra pin needed.
        if rel in ("canon/version_source.sh", "canon/baseline_env.sh"):
            tr = subprocess.run(
                ["git", "ls-files", "--error-unmatch", rel],
                capture_output=True)
            if tr.returncode == 0:
                continue
        extra.append(rel)
if drifted_hooks:
    print(f"SETUP FAIL: pinned adapter hooks drifted vs deploy stamp: {drifted_hooks[:5]}")
    sys.exit(1)
if extra:
    print(f"SETUP FAIL: files under canon/ not listed in canon manifest "
          f"or deploy-stamp pins: {extra[:5]} "
          f"(re-run start_project.sh to pin declared adapter hooks)")
    sys.exit(1)
not_exec = [f for f in files
            if f.startswith("canon/bin/")
            and os.path.isfile(os.path.join(canon_dir, "..", f))
            and not os.access(os.path.join(canon_dir, "..", f), os.X_OK)]
if not_exec:
    print(f"SETUP FAIL: manifest scripts not executable: {not_exec[:5]}")
    sys.exit(1)
# actor registry, when present, must be schema-valid: every entry
# {actor_id, role, token_sha256, registered_at}; roles come from the
# canon enum.
aj = os.path.join(canon_dir, "actors.json")
if os.path.isfile(aj):
    try:
        actors = json.load(open(aj, encoding="utf-8"))
        roles = {"orchestrator","root","director","executor","code_writer",
                 "designer","judge","reviewer","resolver","repository","git",
                 "reader","hygiene","partner",
                 # the seven review-panel domain reviewers (policy.json)
                 "reviewer_design","reviewer_docs","reviewer_fidelity",
                 "reviewer_product","reviewer_quality","reviewer_security",
                 "reviewer_tester"}
        lst = actors.get("actors") if isinstance(actors, dict) else actors
        if not isinstance(lst, list):
            raise ValueError("actors must be a list")
        import re as _re
        ids = set()
        for a in lst:
            if not isinstance(a, dict):
                raise ValueError(f"bad actor entry: {a!r}")
            aid = a.get("actor_id")
            ts = a.get("token_sha256")
            ra = a.get("registered_at")
            if not isinstance(aid, str) or not aid:
                raise ValueError(f"bad actor_id: {a!r}")
            if a.get("role") not in roles:
                raise ValueError(f"bad actor role: {a!r}")
            if not isinstance(ts, str) or not _re.fullmatch(r"[0-9a-f]{64}", ts):
                raise ValueError(f"token_sha256 must be a 64-hex digest: {a!r}")
            if not isinstance(ra, str) or not ra:
                raise ValueError(f"missing registered_at: {a!r}")
            if aid in ids:
                raise ValueError(f"duplicate actor_id: {aid}")
            ids.add(aid)
    except Exception as e:
        print(f"SETUP FAIL: actors.json invalid: {e}")
        sys.exit(1)
print(f"canon_version deployed: {ver}")
PY
  [ $? -eq 0 ] && ok "canon manifest completeness" || fails=$((fails+1))
fi

# Canon gitignore block: harness files are deployed, not tracked - the
# GIT REPO's .gitignore must carry every canon pattern so the harness
# does not pollute it. In nested workspaces canon/ sits at the
# workspace root while the repo lives in a subdir (code/) - the check
# must resolve the real git top, and when canon/ is outside the repo
# the block is simply not needed.
GIT_TOP=$(git -C "$CANON_DIR/.." rev-parse --show-toplevel 2>/dev/null \
          || git -C "$CANON_DIR/../code" rev-parse --show-toplevel 2>/dev/null \
          || true)
# Physical paths via python (realpath -m is GNU-only; falling back to
# the uncanonicalized string silently broke the containment check on
# symlinked workspace paths).
if [ -n "$GIT_TOP" ]; then
  GIT_TOP=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$GIT_TOP" 2>/dev/null || printf '%s' "$GIT_TOP")
fi
CANON_REAL=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CANON_DIR" 2>/dev/null || printf '%s' "$CANON_DIR")
if [ -z "$GIT_TOP" ]; then
  ok "no enclosing git repo resolved (gitignore block not needed)"
else
case "$CANON_REAL" in
  "$GIT_TOP"/*)
    GI="$GIT_TOP/.gitignore"
    if [ -f "$CM" ]; then
      GIT_TOP="$GIT_TOP" CM="$CM" GI="$GI" python3 - <<'PY'
import json, os, re, subprocess, sys
top, gi = os.environ["GIT_TOP"], os.environ["GI"]
try:
    m = json.load(open(os.environ["CM"], encoding="utf-8"))
except Exception:
    print("SETUP FAIL: canon_manifest.json unreadable for gitignore check")
    sys.exit(1)
pats = m.get("gitignore") or []
if not pats:
    print("SETUP FAIL: canon manifest 'gitignore' list is empty")
    sys.exit(1)
gi_body = open(gi, encoding="utf-8").read() if os.path.isfile(gi) else ""
missing = [p for p in pats if p not in gi_body.splitlines()]
if missing:
    print(f"SETUP FAIL: .gitignore missing canon patterns: {missing[:6]}")
    sys.exit(1)
# Tracked first: `git check-ignore` returns 1 for any TRACKED file
# even when a gitignore pattern matches it - running check-ignore
# first would emit a misleading "not ignored" error and shadow the
# real defect (deployed canon files must never be tracked).
r = subprocess.run(["git","-C",top,"ls-files","-z"] +
                   [f for f in m.get("files") or []],
                   capture_output=True)
tracked = [l for l in r.stdout.split(b"\0") if l.strip()]
if tracked:
    print(f"SETUP FAIL: canon files tracked in git (must be deployed, not tracked): "
          f"{[t.decode('utf-8','replace') for t in tracked[:6]]}")
    sys.exit(1)
# then prove canon files are actually ignored, not just listed:
# --no-index consults the ignore rules only (a tracked file would
# otherwise still exit 1).
bad = []
for f in m.get("files") or []:
    r = subprocess.run(["git","-C",top,"check-ignore","-q","--no-index","--",f])
    if r.returncode != 0:
        bad.append(f)
if bad:
    print(f"SETUP FAIL: canon files not actually ignored: {bad[:6]}")
    sys.exit(1)
# EVERY regular file under canon/ inside this repo - not just the
# manifest list - must be untracked: a non-manifest file under git
# hides from integrity verification entirely.
import os.path as _osp
canon_root_dir = os.path.realpath(os.path.dirname(os.environ["CM"]))
extra_tracked = []
for dirpath, dirnames, filenames in os.walk(canon_root_dir):
    for name in filenames:
        p = _osp.join(dirpath, name)
        rel = _osp.relpath(_osp.realpath(p), top)
        if rel.startswith("..") or name.endswith((".lock", ".pyc")):
            continue
        r = subprocess.run(["git","-C",top,"ls-files","--error-unmatch","--",rel],
                           capture_output=True)
        if r.returncode == 0:
            extra_tracked.append(rel)
if extra_tracked:
    print(f"SETUP FAIL: non-manifest canon files tracked in git: {extra_tracked[:6]}")
    sys.exit(1)
print("canon gitignore block complete")
PY
      [ $? -eq 0 ] && ok "canon gitignore block" || fails=$((fails+1))
    else
      grep -q "^# >>> canon" "$GI" 2>/dev/null \
        && ok "canon gitignore block (header only - no manifest)" \
        || fail ".gitignore missing canon block (run onboard/rollout to install)"
    fi ;;
  *) ok "canon deployed outside git repo (gitignore block not needed)" ;;
esac
fi

# Forge-aware credential check: the test forge needs no CLI auth at
# all; github/gitlab resolve the merge identity through gh_id.sh
# (api_bin > gh_bin > forge default) and ask THAT binary for auth
# status - a gitlab project must never be graded on `gh`.
FORGE=$(CANON_DIR="$CANON_DIR" python3 -c 'import json,os
try: print((json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json"))).get("forge") or "github"))
except Exception: print("github")' 2>/dev/null || echo github)
if [ "$FORGE" = "test" ]; then
  ok "forge=test - no forge CLI auth required"
else
  AUTH_BIN=$(bash "$CANON_DIR/bin/gh_id.sh" merge 2>/dev/null || true)
  AUTH_BIN="${AUTH_BIN:-gh}"
  case "$AUTH_BIN" in
    gh|glab)
      if command -v "$AUTH_BIN" >/dev/null 2>&1 \
         && "$AUTH_BIN" auth status >/dev/null 2>&1; then
        ok "$AUTH_BIN auth"
      else
        fail "$AUTH_BIN not authenticated"
      fi ;;
    *)
      if command -v "$AUTH_BIN" >/dev/null 2>&1; then
        ok "forge CLI $AUTH_BIN present (auth check is forge-specific)"
      else
        fail "forge CLI $AUTH_BIN not found"
      fi ;;
  esac
fi

# Runtime adapter integrity: the Devin adapter wires .devin/* ->
# canon/ plus a .windsurfrules symlink and a compiled
# .devin/config.json. A swapped symlink or a deleted compiled file
# silently un-wires the rules the runtime actually reads - verify
# the glue whenever .devin exists at all. A workspace that never
# applied the devin adapter has no .devin dir and is simply skipped.
WS_DIR="$(cd -P "$CANON_DIR/.." && pwd)"
ADAPT_FAIL=""
if [ -d "$WS_DIR/.devin" ]; then
  for n in agents bin specs; do
    if ! { [ -L "$WS_DIR/.devin/$n" ] \
           && [ "$(readlink "$WS_DIR/.devin/$n")" = "../canon/$n" ]; }; then
      ADAPT_FAIL="$ADAPT_FAIL .devin/$n"
    fi
  done
  [ -f "$WS_DIR/.devin/config.json" ] \
    || ADAPT_FAIL="$ADAPT_FAIL .devin/config.json"
  # gate_checks drift: adapters/devin.sh compiles project.json
  # gate_checks.* command heads into .devin/config.json allow
  # entries at adapter-run time; editing project.json afterwards
  # leaves the compiled policy stale - every new check head is
  # denied at exec time.
  if [ -f "$WS_DIR/.devin/config.json" ] && [ -f "$CANON_DIR/project.json" ]; then
    DRIFT=$(WS_DIR="$WS_DIR" CANON_DIR="$CANON_DIR" python3 - <<'PY'
import json, os, sys
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
    cfg = json.load(open(os.path.join(os.environ["WS_DIR"], ".devin", "config.json")))
except Exception:
    sys.exit(0)
gc = pj.get("gate_checks") or {}
# devin.sh compiles each gate_checks argv as its full joined prefix
# (Exec(python3 -m pytest), not Exec(python3)) so interpreter heads
# can stay denied globally - drift compares the same join.
argvs = {" ".join(str(a) for a in v) for v in gc.values()
         if isinstance(v, list) and v and isinstance(v[0], str) and v[0]}
allow = set((cfg.get("permissions") or {}).get("allow") or [])
missing = sorted(a for a in argvs if f"Exec({a})" not in allow)
if missing:
    print(" ".join(missing))
PY
)
    [ -n "$DRIFT" ] \
      && ADAPT_FAIL="$ADAPT_FAIL gate_checks-not-compiled($DRIFT)"
  fi
  if [ -L "$WS_DIR/.windsurfrules" ]; then
    [ "$(readlink "$WS_DIR/.windsurfrules")" = "canon/RULES.md" ] \
      || ADAPT_FAIL="$ADAPT_FAIL .windsurfrules(target)"
  else
    ADAPT_FAIL="$ADAPT_FAIL .windsurfrules(missing/not-a-symlink)"
  fi
fi
if [ -z "$ADAPT_FAIL" ]; then
  ok "runtime adapter glue"
else
  fail "runtime adapter glue broken:$ADAPT_FAIL - re-run adapters/devin.sh"
fi

# canary check: canon/RULES.md must end with the canary token declared
# by the deployed canon stamp (canon/canon_manifest.json "canary") -
# if it is missing, the injected rules were truncated (16KB incident
# class) and the instance must halt instead of running on partial
# rules. The expected token comes from the deploy manifest, never
# hardcoded: the same canon ships to multiple repos and onboard
# generates a per-repo token. An absent/placeholder canary key in the
# stamp is a setup defect, not a pass.
EXPECTED_CANARY=$(CANON_DIR="$CANON_DIR" python3 -c 'import json,os,re
try:
    v = json.load(open(os.path.join(os.environ["CANON_DIR"], "canon_manifest.json"))).get("canary") or ""
    # the canary becomes a grep pattern - multi-line or non-token
    # values must never reach the pattern slot (grep -F treats \n as
    # an OR-ed alternation and would match a blank line); only a
    # token-charset value is printed, anything else yields empty output
    if isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9._-]+", v):
        print(v)
except Exception:
    pass' 2>/dev/null) || EXPECTED_CANARY=""
WRULES="$CANON_DIR/RULES.md"
case "$EXPECTED_CANARY" in
  ""|GENERATED_AT_DEPLOY)
    fail "canon_manifest.json has no usable canary token (missing/placeholder/unsafe charset) - rerun onboard" ;;
  *)
    LAST_LINE=$(tail -n 1 "$WRULES" 2>/dev/null || true)
    printf '%s' "$LAST_LINE" | grep -qxF "CANARY_EOF_TOKEN:$EXPECTED_CANARY" \
      && ok "canary token present" \
      || fail "canary token '$EXPECTED_CANARY' is not the last line of canon/RULES.md (rules truncated?)" ;;
esac

if [ $fails -gt 0 ]; then
  echo "SETUP: $fails FAILURES - halt, do not proceed"
  exit 1
fi
CANON_DIR="$CANON_DIR" PJ="$PJ" python3 -c 'import json,os
c = json.load(open(os.environ["PJ"]))
print("SETUP OK:", c.get("project_name") or c["repo"], c["text_language"])' 2>/dev/null \
  || echo "SETUP OK"
