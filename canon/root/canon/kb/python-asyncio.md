# Stack profile: python / asyncio

Language-specific code invariants for Python repositories
(extends the universal list in `canon/RULES.md` — those apply
everywhere; this file adds the stack-bound forms). A project may
extend it via its own `kb_rules` digest.

- Blocking calls (`requests`/`open`/`time.sleep`/`subprocess`
  without `await`, heavy CPU) inside `async def` are forbidden —
  they stall the event loop.
- `asyncio.create_task()` — only inside a tracked TaskGroup/set;
  do not swallow `CancelledError`.
- Money/quantities — `Decimal`/int, never `float`. Datetime —
  aware UTC only; naive = bug.
- `except Exception: pass` / bare `except:` — forbidden: either a
  specific exception or log+re-raise.
- `print()` in commits is forbidden — `logging` with a level.
- Risky paths (money, external writes, auth, async lifecycle)
  require a `pytest` test.
- Secrets and PII (tokens, `chat_id`, phones) — never in logs.
- BOLA/IDOR: access by id (`chat_id`, `user_id`) — check
  ownership.
