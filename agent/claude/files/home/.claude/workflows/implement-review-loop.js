export const meta = {
    name: 'implement-review-loop',
    description: 'Coder implements a task, specialized reviewers (security, code, database when SQL is touched) approve or send it back, until all approve',
    whenToUse: 'Implement a task with a coder/reviewers loop until every selected reviewer signs off',
    phases: [
        {title: 'Implement', detail: 'coder writes the change'},
        {title: 'Route', detail: 'path rules and a SQL content probe select the reviewers'},
        {title: 'Review', detail: 'selected reviewers run in parallel; all must approve'},
    ],
}

function resolveTask(input) {
    if (typeof input === 'string' && input.trim()) return input.trim()
    if (input && typeof input === 'object' && !Array.isArray(input) && typeof input.task === 'string' && input.task.trim()) {
        return input.task.trim()
    }
    return ''
}

const task = resolveTask(args)

if (!task) {
    return {status: 'failed', reason: 'no task provided'}
}

const MAX_ROUNDS = 5
const DRY_STOP = 2

// Owner order: also the tie-break order when merging findings.
const REVIEWERS = {
    security: {agentType: 'jarvis-security-reviewer', rank: 0},
    database: {agentType: 'jarvis-database-reviewer', rank: 1},
    code: {agentType: 'jarvis-code-reviewer', rank: 2},
}

// Same rules as the trigger probe in the orchestrator's delegation policy
// (shared/role/delegation.claude.md). Change both together.
const DOCS_PATH = /^docs\/|\.md$/
const INSTRUCTION_PATH = /(^|\/)(\.claude|shared|agents|skills)\/|(^|\/)(CLAUDE|AGENTS|ROLE|SKILL)\.md$/
const SQL_PATH = /\.sql$|(^|\/)(migrations?|schema|db|database|sql|queries)(\/|$)/

const BASE_PROBE = String.raw`base=$(git merge-base HEAD origin/HEAD 2>/dev/null || git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD origin/master 2>/dev/null || git merge-base HEAD '@{upstream}' 2>/dev/null) || base=HEAD`
const SQL_CONTENT_PROBE = String.raw`{ git diff -U0 "$base" -- . ':!*.md' | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---) '; git ls-files -z --others --exclude-standard -- . ':!*.md' | xargs -0 cat | sed 's/^/+/'; } |
  grep -Eio '(select .* from|insert into|update .* set|delete from|create (table|index)|alter table|drop (table|index)|database/sql|sqlx|gorm|pgx|sqlc|QueryContext|ExecContext|BeginTx|\.(Query|QueryRow|Exec|Prepare)(Context)?\(|^[+-][[:space:]]*(select|update|insert|where|join)[[:space:]])' | sort -u | head -n 20`

// The script has no shell, so a cheap agent runs the probe. Routing uses the
// files git reports, not only the coder's self-reported list.
const PROBE_COMMAND = `git rev-parse --git-dir >/dev/null 2>&1 || { echo "probe: not a git repository"; exit 1; }
${BASE_PROBE}
git rev-parse --verify -q HEAD >/dev/null || base=$(git hash-object -t tree /dev/null)
echo "BASE $base"
{ git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u | sed 's/^/FILE /'
${SQL_CONTENT_PROBE} | sed 's/^/SQL /'`

const PROBE_SCHEMA = {
    type: 'object',
    required: ['exitCode', 'base', 'files', 'sqlMatches'],
    properties: {
        exitCode: {type: 'integer', description: 'the exit status of the command'},
        base: {type: 'string', description: 'the text after "BASE ", verbatim'},
        files: {type: 'array', items: {type: 'string'}, description: 'the text after each "FILE ", verbatim'},
        sqlMatches: {type: 'array', items: {type: 'string'}, description: 'the text after each "SQL ", verbatim'},
    },
}

const SEVERITY_RANK = {CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3}

const REVIEW_SCHEMA = {
    type: 'object',
    required: ['approved', 'verdict', 'findings'],
    properties: {
        approved: {type: 'boolean'},
        verdict: {
            type: 'string',
            description: 'One line stating the merge decision and, when rejecting, the whole-change reason.',
        },
        findings: {
            type: 'array',
            items: {
                type: 'object',
                required: ['severity', 'file', 'category', 'issue', 'fix'],
                properties: {
                    severity: {type: 'string', enum: ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']},
                    file: {type: 'string'},
                    line: {type: 'integer', description: 'First line of the affected range, if known.'},
                    category: {type: 'string', description: 'Defect class, e.g. sql-injection, missing-index, error-handling.'},
                    issue: {type: 'string'},
                    fix: {type: 'string'},
                },
            },
        },
    },
}

const IMPLEMENT_SCHEMA = {
    type: 'object',
    required: ['summary', 'files', 'verification'],
    properties: {
        summary: {type: 'string'},
        files: {type: 'array', items: {type: 'string'}},
        verification: {
            type: 'string',
            description: 'Commands run and their result: tests, linters, formatters, static analysis.',
        },
    },
}

function formatFindings(findings) {
    if (!findings || !findings.length) return '(no findings)'
    return findings
        .map((f, i) => {
            const where = f.line ? `${f.file}:${f.line}` : f.file
            const who = f.reviewer ? `${f.reviewer} ` : ''
            const also = (f.alsoReportedBy || [])
                .map(o => `\n   Also reported by ${o.reviewer} [${o.severity}]: ${o.issue}\n   Fix: ${o.fix}`)
                .join('')
            return `${i + 1}. [${f.severity}] ${who}${where}: ${f.issue}\n   Fix: ${f.fix}${also}`
        })
        .join('\n')
}

function normalizeText(value) {
    return String(value == null ? '' : value).toLowerCase().replace(/\s+/g, ' ').trim()
}

function normalizePath(value) {
    return String(value == null ? '' : value).trim().replace(/^\.\//, '')
}

// A reviewer that returned nothing is part of the signature, so a reviewer
// that keeps dying still ends the loop as stuck instead of spinning.
function findingsSignature(findings, missing) {
    const lines = (findings || []).map(f => `${normalizeText(f.file)}::${normalizeText(f.issue)}`)
    for (const key of missing || []) lines.push(`missing::${key}`)
    if (!lines.length) return '(no findings)'
    return lines.sort().join('\n')
}

// isDocsPath: docs-shaped and not an instruction file (agents, skills, rules
// and role prompts grant tools and models, so they get reviewed).
function isDocsPath(p) {
    return DOCS_PATH.test(p) && !INSTRUCTION_PATH.test(p)
}

function routeByPath(files) {
    const paths = [...new Set(files.map(normalizePath).filter(Boolean))]
    return {
        docsOnly: paths.length > 0 && paths.every(isDocsPath),
        sqlPaths: paths.filter(p => SQL_PATH.test(p)),
    }
}

// Findings from one reviewer are never merged with each other. Across
// reviewers, findings merge on file + start line + defect class; without a
// line, the normalized issue text must match too. The wording of the reviewer
// first in owner order (security, database, code) is kept, at the highest
// severity given; the others ride along as alsoReportedBy so the coder sees
// every finding. `results` arrive in owner order.
function mergeFindings(results) {
    const merged = []
    for (const {key, review} of results) {
        if (!review) continue
        for (const f of review.findings || []) {
            const dedupeKey =
                f.line == null
                    ? `${normalizePath(f.file)}::-::${normalizeText(f.category)}::${normalizeText(f.issue)}`
                    : `${normalizePath(f.file)}::${f.line}::${normalizeText(f.category)}`
            const kept = merged.find(m => m.dedupeKey === dedupeKey && !m.reviewers.includes(key))
            if (!kept) {
                merged.push({dedupeKey, reviewers: [key], finding: {...f, reviewer: key, alsoReportedBy: []}})
                continue
            }
            kept.reviewers.push(key)
            kept.finding.alsoReportedBy.push({reviewer: key, severity: f.severity, issue: f.issue, fix: f.fix})
            if (SEVERITY_RANK[f.severity] < SEVERITY_RANK[kept.finding.severity]) kept.finding.severity = f.severity
        }
    }
    return merged
        .map(m => m.finding)
        .sort(
            (a, b) =>
                SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity] ||
                REVIEWERS[a.reviewer].rank - REVIEWERS[b.reviewer].rank,
        )
}

let lastSummary = ''
let lastSignature = null
let dry = 0
const history = []
const changedFiles = []

for (let round = 1; round <= MAX_ROUNDS; round++) {
    const previous = history.length ? history[history.length - 1] : null
    const coderPrompt = previous
        ? `
            The reviewers REJECTED the previous implementation of this task:

            TASK:
            ${task}

            PREVIOUS IMPLEMENTATION:
            ${lastSummary}

            REVIEWER VERDICTS:
            ${previous.verdict}

            REVIEW FINDINGS:
            ${formatFindings(previous.findings)}

            Address every CRITICAL, HIGH, and MEDIUM finding. You may decline a LOW finding.
            List each declined finding by ID, with a one-line cause.

            Apply only the requested fixes. Do not expand scope. Return the files you changed.`
        : `
            Implement this task completely.

            TASK:
            ${task}

            Make the smallest correct change. Return the files you changed.
        `

    phase('Implement')
    log(`Round ${round}/${MAX_ROUNDS}: coder`)

    let implemented
    try {
        implemented = await agent(coderPrompt, {
            agentType: 'jarvis-coder',
            label: `coder-r${round}`,
            phase: 'Implement',
            schema: IMPLEMENT_SCHEMA,
            effort: 'high',
        })
    } catch (e) {
        return {status: 'failed', reason: String(e), rounds: round, history}
    }

    if (!implemented) {
        return {
            status: 'failed',
            reason: `coder did not return a result on round ${round}`,
            rounds: round,
            history,
        }
    }

    lastSummary = implemented.summary
    for (const file of implemented.files || []) {
        if (!changedFiles.includes(file)) changedFiles.push(file)
    }

    // The trigger is re-evaluated every round over everything changed so far:
    // a fix can move the change into another reviewer's domain.
    phase('Route')
    let probe = null
    try {
        probe = await agent(
            `Run this command from the repository root, exactly as written, and report its output.
Do not interpret, edit or extend it.

\`\`\`sh
${PROBE_COMMAND}
\`\`\`

exitCode is the command's exit status; base is the text after "BASE "; files and sqlMatches are the texts after each "FILE " and "SQL " line.`,
            {
                agentType: 'general-purpose',
                label: `probe-r${round}`,
                phase: 'Route',
                schema: PROBE_SCHEMA,
                effort: 'low',
            },
        )
    } catch (e) {
        log(`Round ${round}: probe failed (${String(e)})`)
    }
    // A non-zero exit (e.g. not a git repository) proves nothing about the change.
    if (probe && probe.exitCode !== 0) {
        log(`Round ${round}: probe exited ${probe.exitCode}; treated as failed`)
        probe = null
    }

    let selected
    let base
    let databaseReason
    if (!probe) {
        // Without git's file list neither docs-only nor "no SQL" can be shown.
        selected = ['security', 'database', 'code']
        base = null
        databaseReason = 'probe returned no result; every reviewer runs'
    } else {
        const route = routeByPath([...changedFiles, ...(probe.files || [])])
        if (route.docsOnly) {
            log(`Round ${round}: docs-only change; no reviewer run`)
            history.push({round, files: implemented.files, coder: implemented.summary, reviewers: [], verdict: 'docs-only'})
            return {
                status: 'docs-only',
                reason: 'every changed path is docs (docs/ or *.md, no instruction file); no reviewer was run',
                rounds: round,
                summary: implemented.summary,
                files: changedFiles,
                history,
            }
        }
        base = String(probe.base || '').trim() || 'HEAD'
        if (base === 'HEAD') log(`Round ${round}: base: HEAD (no upstream found; committed changes not reviewed)`)
        const sqlMatches = probe.sqlMatches || []
        databaseReason = route.sqlPaths.length
            ? `SQL paths: ${route.sqlPaths.join(', ')}`
            : sqlMatches.length
              ? `SQL content: ${sqlMatches.join(' | ')}`
              : ''
        selected = databaseReason ? ['security', 'database', 'code'] : ['security', 'code']
    }

    const runLine = selected.map(key => REVIEWERS[key].agentType).join(', ')
    log(
        `Round ${round}: reviewers ${runLine}. security and code: non-docs change. database: ${
            databaseReason || 'no SQL path or content match, skipped'
        }`,
    )

    const baseBlock = base
        ? `Review \`git diff ${base}\` plus untracked files (\`git ls-files --others --exclude-standard\`).`
        : `Compute the base with \`${BASE_PROBE}\`, then review \`git diff "$base"\` plus untracked files (\`git ls-files --others --exclude-standard\`).`

    phase('Review')

    const results = await parallel(
        selected.map(key => () => {
            const prior = previous ? (previous.findings || []).filter(f => f.reviewer === key) : []
            const priorBlock = prior.length
                ? `
        YOUR FINDINGS FROM THE PREVIOUS ROUND:
        ${formatFindings(prior)}

        For each of those findings, state in your verdict whether it is now resolved, and re-report
        any that are not as findings.
        `
                : ''
            return agent(
                `
        Review the coder's work for this task within your scope. Approve only if you would merge it as-is.

        TASK:
        ${task}

        BASE:
        ${baseBlock}

        CODER SUMMARY:
        ${implemented.summary}

        CODER VERIFICATION:
        ${implemented.verification}

        FILES:
        ${changedFiles.join(', ')}

        Reviewers in this run: ${runLine}
        ${priorBlock}
        Inspect the actual diff/files, not just the summary.
        `,
                {
                    agentType: REVIEWERS[key].agentType,
                    label: `${key}-reviewer-r${round}`,
                    phase: 'Review',
                    schema: REVIEW_SCHEMA,
                    effort: 'high',
                },
            )
        }),
    )

    // parallel() resolves a dead or skipped agent to null. That is never an
    // approval: the reviewer's domain went unreviewed.
    const reviews = selected.map((key, i) => ({key, review: results[i] || null}))
    const missing = reviews.filter(r => !r.review).map(r => r.key)
    for (const key of missing) {
        log(`Round ${round}: ${REVIEWERS[key].agentType} returned no result; counted as not approved`)
    }

    // Approval means approved === true with no findings, the same rule the
    // orchestrator applies to "No actionable issues found.".
    for (const r of reviews) {
        if (r.review && r.review.approved === true && (r.review.findings || []).length) {
            log(`Round ${round}: ${REVIEWERS[r.key].agentType} approved with findings; counted as not approved`)
        }
    }
    const approved = reviews.every(
        r => r.review && r.review.approved === true && !(r.review.findings || []).length,
    )
    const findings = mergeFindings(reviews)
    const verdict = reviews
        .map(r => `${r.key}: ${r.review ? r.review.verdict : 'no result (counted as not approved)'}`)
        .join('\n')

    history.push({
        round,
        files: implemented.files,
        coder: implemented.summary,
        verification: implemented.verification,
        reviewers: selected,
        databaseReason,
        approved,
        verdict,
        findings,
        missing,
    })

    if (approved) {
        log(`All reviewers approved on round ${round}`)
        return {
            status: 'approved',
            rounds: round,
            summary: implemented.summary,
            files: changedFiles,
            reviewers: selected,
            review: verdict,
            history,
        }
    }

    const signature = findingsSignature(findings, missing)
    if (lastSignature !== null && signature === lastSignature) {
        dry += 1
    } else {
        dry = 0
    }
    lastSignature = signature

    log(`Rejected on round ${round}: ${findings.length} finding(s) after merge, ${missing.length} reviewer(s) without result. dry=${dry}`)

    if (dry >= DRY_STOP) {
        return {
            status: 'stuck',
            reason: `${DRY_STOP + 1} consecutive rounds with the same findings`,
            rounds: round,
            files: changedFiles,
            history,
        }
    }
}

return {
    status: 'max-rounds',
    reason: `Reviewers did not all approve within ${MAX_ROUNDS} rounds`,
    rounds: MAX_ROUNDS,
    files: changedFiles,
    history,
}
