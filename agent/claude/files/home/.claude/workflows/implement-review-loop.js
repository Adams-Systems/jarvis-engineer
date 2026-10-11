export const meta = {
    name: 'implement-review-loop',
    description: 'Coder implements a task, reviewer approves or sends it back, until approved',
    whenToUse: 'Implement a task with a coder/reviewer loop until the reviewer signs off',
    phases: [
        {title: 'Implement', detail: 'coder writes the change'},
        {title: 'Review', detail: 'reviewer approves or rejects'},
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
                required: ['severity', 'file', 'issue', 'fix'],
                properties: {
                    severity: {type: 'string', enum: ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']},
                    file: {type: 'string'},
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
        .map((f, i) => `${i + 1}. [${f.severity}] ${f.file}: ${f.issue}\n   Fix: ${f.fix}`)
        .join('\n')
}

function normalizeText(value) {
    return String(value == null ? '' : value).toLowerCase().replace(/\s+/g, ' ').trim()
}

function findingsSignature(findings) {
    if (!findings || !findings.length) return '(no findings)'
    return findings
        .map(f => `${normalizeText(f.file)}::${normalizeText(f.issue)}`)
        .sort()
        .join('\n')
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
            The reviewer REJECTED the previous implementation of this task:

            TASK:
            ${task}
            
            PREVIOUS IMPLEMENTATION:
            ${lastSummary}
            
            REVIEWER VERDICT:
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
            agentType: 'coder',
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

    const priorFindingsBlock = previous
        ? `
        FINDINGS FROM THE PREVIOUS ROUND:
        ${formatFindings(previous.findings)}
        
        For each of those findings, state in your verdict whether it is now resolved, and re-report
        any that are not as findings.
        `
        : ''

    phase('Review')
    log(`Round ${round}/${MAX_ROUNDS}: reviewer`)

    let review
    try {
        review = await agent(
            `
        Review the coder's work for this task. Approve only if you would merge it as-is.

        TASK:
        ${task}
        
        CODER SUMMARY:
        ${implemented.summary}
        
        CODER VERIFICATION:
        ${implemented.verification}
        
        FILES:
        ${(implemented.files || []).join(', ')}
        ${priorFindingsBlock}
        Inspect the actual diff/files, not just the summary.
        `,
            {
                agentType: 'reviewer',
                label: `reviewer-r${round}`,
                phase: 'Review',
                schema: REVIEW_SCHEMA,
                effort: 'high',
            },
        )
    } catch (e) {
        return {status: 'failed', reason: String(e), rounds: round, history}
    }

    if (!review) {
        return {
            status: 'failed',
            reason: `reviewer did not return a result on round ${round}`,
            rounds: round,
            history,
        }
    }

    history.push({
        round,
        files: implemented.files,
        coder: implemented.summary,
        verification: implemented.verification,
        approved: review.approved,
        verdict: review.verdict,
        findings: review.findings || [],
    })

    if (review.approved) {
        log(`Reviewer approved on round ${round}`)
        return {
            status: 'approved',
            rounds: round,
            summary: implemented.summary,
            files: changedFiles,
            review: review.verdict,
            history,
        }
    }

    const signature = findingsSignature(review.findings)
    if (lastSignature !== null && signature === lastSignature) {
        dry += 1
    } else {
        dry = 0
    }
    lastSignature = signature

    log(`Rejected on round ${round}: ${(review.findings || []).length} finding(s). dry=${dry}`)

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
    reason: `Reviewer did not approve within ${MAX_ROUNDS} rounds`,
    rounds: MAX_ROUNDS,
    files: changedFiles,
    history,
}
