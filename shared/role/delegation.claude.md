## Delegation mechanics (Claude Code)

The sub-agents are defined in `.claude/agents`.

## Review fan-out (Claude Code)

On Claude Code, do not use `jarvis-reviewer`. Review with the specialized reviewers, selected by the probe below, not by judgment:

- `jarvis-security-reviewer` and `jarvis-code-reviewer`: every diff that is not docs-only.
- `jarvis-database-reviewer`: also, when the probe reports SQL surface.
- Docs-only diff (every changed path is under `docs/` or `*.md`, and none is an instruction file: under `.claude/`, `shared/`, `agents/`, `skills/`, or named `CLAUDE.md`, `AGENTS.md`, `ROLE.md`, `SKILL.md`): no reviewer; say so.

Probe (run from the repository root; replace the `base=` line if the task names a base):

```sh
git rev-parse --git-dir >/dev/null 2>&1 || { echo "probe: not a git repository"; exit 1; }
base=$(git merge-base HEAD origin/HEAD 2>/dev/null || git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD origin/master 2>/dev/null || git merge-base HEAD '@{upstream}' 2>/dev/null) || base=HEAD
git rev-parse --verify -q HEAD >/dev/null || base=$(git hash-object -t tree /dev/null)
files=$({ git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u)
db=
printf '%s\n' "$files" | grep -E '\.sql$|(^|/)(migrations?|schema|db|database|sql|queries)(/|$)' >/dev/null && db=" paths"
{ git diff -U0 "$base" -- . ':!*.md' | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---) '; git ls-files -z --others --exclude-standard -- . ':!*.md' | xargs -0 cat | sed 's/^/+/'; } |
  grep -Ei '(select .* from|insert into|update .* set|delete from|create (table|index)|alter table|drop (table|index)|database/sql|sqlx|gorm|pgx|sqlc|QueryContext|ExecContext|BeginTx|\.(Query|QueryRow|Exec|Prepare)(Context)?\(|^[+-][[:space:]]*(select|update|insert|where|join)[[:space:]])' >/dev/null && db="$db content"
if [ "$base" = HEAD ]; then echo "base: HEAD (no upstream found; committed changes not reviewed)"; else echo "base: $base"; fi
if [ -z "$files" ]; then echo "reviewers: none (no changes)"
elif ! printf '%s\n' "$files" | grep -Ev '^docs/|\.md$' >/dev/null &&
  ! printf '%s\n' "$files" | grep -E '(^|/)(\.claude|shared|agents|skills)/|(^|/)(CLAUDE|AGENTS|ROLE|SKILL)\.md$' >/dev/null; then echo "reviewers: none (docs-only)"
elif [ -n "$db" ]; then echo "reviewers: security code database (SQL surface:$db)"
else echo "reviewers: security code"
fi
```

Dispatch every selected reviewer in one message, so they run in parallel. Each prompt carries the task, `Base: <base>`, the changed files, `Reviewers in this run: <names>`, and the instruction to run `git diff <base>` itself.

Merge the results yourself. Owners: security has authentication, authorization, injection (SQL included), SSRF, deserialization, secrets, crypto, trust-boundary validation, dependencies and manifests, container/CI/sandbox config (agent tool grants included), and database grants; database has SQL, schema/DDL, migrations, query cost, indexes, N+1, locking, transactions, dialect and PII columns; code has everything else. Same file, overlapping lines and same root cause: keep one finding, at the highest severity, in the owner's wording. Order by severity, then security, database, code. Label each finding with its reviewer. Add no summary.

Approve only when every selected reviewer returns `No actionable issues found.` After `jarvis-coder` fixes findings, re-run the probe and every reviewer it selects on the new diff.
