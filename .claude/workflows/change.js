export const meta = {
  name: 'change',
  description: 'Plan, build in parallel, verify and document a change to the project, reading only the files each step needs',
  whenToUse: 'A change that touches more than one area of the project. Pass args: { task: "what to change", agents?: { test, review } } (names of subagents to use for verification). Small one-file edits do not need it. Project-specific rules and checks come from CLAUDE.md and .claude/rules/, not from this file.',
  phases: [
    { title: 'Plan', detail: 'one agent maps the task to files using the repo map and Graphify' },
    { title: 'Build', detail: 'one agent per independent work item, disjoint files; owner-question issues opened at the same time' },
    { title: 'Verify', detail: 'the project checks and an adversarial diff review in parallel' },
    { title: 'Docs', detail: 'update log and decisions (after Verify: it records a verified change and must not show up in the diff review)' },
  ],
}

const task = typeof args === 'string' ? args : args && args.task
if (!task) throw new Error('Pass args: { task: "what to change" }')

// Optional project subagents for the Verify phase: args.agents = { test: '<name>', review: '<name>' }.
const AGENTS = (args && args.agents) || {}

const READ_RULE =
  'Read in layers (CLAUDE.md): start from the repo map (.claude/tools/tree.sh), use .claude/tools/graph.sh for questions, ' +
  'and open only files that are named; use Grep or Read with offset/limit instead of whole files. Follow the rules in CLAUDE.md and .claude/rules/.'

const PLAN = {
  type: 'object',
  properties: {
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          goal: { type: 'string', description: 'What this item changes, in one or two sentences' },
          edit: { type: 'array', items: { type: 'string' }, description: 'Repo-relative files this item may edit' },
          readFirst: { type: 'array', items: { type: 'string' }, description: 'Files to read for context, kept to the minimum' },
        },
        required: ['id', 'goal', 'edit'],
      },
    },
    openQuestions: { type: 'array', items: { type: 'string' }, description: 'Facts only the owner can supply' },
    findings: { type: 'string', description: 'What you learned that builders and reviewers need (symbols, callers, constraints, risks), so they do not re-explore' },
  },
  required: ['items'],
}

const BUILT = {
  type: 'object',
  properties: { changed: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } },
  required: ['changed'],
}

const CHECK = {
  type: 'object',
  properties: {
    pass: { type: 'boolean' },
    problems: { type: 'array', items: { type: 'string' } },
  },
  required: ['pass', 'problems'],
}

phase('Plan')
const plan = await agent(
  `Task: ${task}\n\nBreak this into the smallest set of work items. Each item lists the files it may edit. ` +
    `Items must edit DISJOINT files so they can run in parallel; if two pieces need the same file, make them one item. ` +
    `A one-file change is one item. List only what is needed. ` +
    `Put what you learned while mapping (symbols, callers, constraints, risks) in findings: later agents start from it.\n\n${READ_RULE}`,
  { phase: 'Plan', label: 'plan', schema: PLAN }
)
if (!plan || !plan.items || !plan.items.length) throw new Error('Planner returned no work items')

// Merge items that share a file so parallel agents never edit the same file.
const items = []
for (const it of plan.items) {
  const clash = items.find((o) => o.edit.some((f) => it.edit.includes(f)))
  if (clash) {
    clash.goal += ' Also: ' + it.goal
    clash.edit = [...new Set([...clash.edit, ...it.edit])]
    clash.readFirst = [...new Set([...(clash.readFirst || []), ...(it.readFirst || [])])]
    log(`merged overlapping items ${clash.id} and ${it.id}`)
  } else {
    items.push({ ...it, readFirst: it.readFirst || [] })
  }
}
// Context every later agent starts from, so none re-explores what the planner already found.
const FINDINGS = plan.findings ? `Planner's findings (start from these, don't re-derive them): ${plan.findings}\n` : ''
if (plan.openQuestions && plan.openQuestions.length) log('Needs the owner: ' + plan.openQuestions.join(' | '))

phase('Build')
// Owner questions don't depend on the build or its verification, so their issues are opened while the build runs.
// That agent edits no files, so it can't clash with the build items.
const questions = plan.openQuestions || []
const askOwner = questions.length
  ? agent(
      `While another agent works on the task "${task}", open a GitHub issue (search for duplicates first) for each fact only ` +
        `the owner can supply: ${questions.join('; ')}. Do not edit any file and do not commit.`,
      { phase: 'Build', label: 'owner-questions' }
    )
  : null
const [builtAll] = await Promise.all([
  parallel(
    items.map((it) => () =>
      agent(
        `Task overall: ${task}\n\nYour item (${it.id}): ${it.goal}\n` +
          `You may edit ONLY: ${it.edit.join(', ')}\nRead first, if you need context: ${it.readFirst.join(', ') || 'nothing'}\n${FINDINGS}` +
          `These files are already located for you: don't re-map the repo.\n\n` +
          `Make the change, keeping each file's one-line purpose comment accurate. Do not commit.\n\n${READ_RULE}`,
        { phase: 'Build', label: `build:${it.id}`, schema: BUILT }
      )
    )
  ),
  askOwner,
])
const built = builtAll.filter(Boolean)
const changed = [...new Set(built.flatMap((b) => b.changed))]
log(`changed: ${changed.join(', ') || 'nothing'}`)
const notes = built.map((b) => b.notes).filter(Boolean)
const brief = () =>
  `Changed files: ${changed.join(', ') || 'none'} (uncommitted: \`git diff\` plus untracked).\n${FINDINGS}` +
  (notes.length ? `Builders' notes: ${notes.join(' | ')}\n` : '')

// `before` carries the previous round's results into a re-verify, so agents focus on what was fixed.
const verify = (before = '') =>
  parallel([
    () =>
      agent(
        brief() + before +
        'Run the checks described under "Checking changes" in CLAUDE.md and report pass=false with each problem if anything fails. ' +
          'Start checks that do not depend on each other at the same time (one shell call with background jobs and wait, ' +
          'collecting each exit code) and keep only real dependencies in order, such as a build before the checks that read its output. ' +
          'Clean up anything you start (servers, temp files).',
        { phase: 'Verify', label: 'verify:checks', schema: CHECK, agentType: AGENTS.test }
      ),
    () =>
      agent(
        brief() + before +
        `Review \`git diff\` and untracked files against this task: ${task}\n` +
          'Try to REFUTE that the change is correct and safe. Look for: breaking a rule in CLAUDE.md or .claude/rules/, ' +
          'edits outside the planned files (' + changed.join(', ') + '), a page missing a script or stylesheet it now needs, broken links, ' +
          'a new file without the one-line purpose the repo map needs. Default to pass=false if you are unsure.',
        { phase: 'Verify', label: 'verify:review', schema: CHECK, agentType: AGENTS.review }
      ),
  ])

phase('Verify')
let results = (await verify()).filter(Boolean)
let problems = results.flatMap((r) => (r.pass ? [] : r.problems))
if (problems.length) {
  log(`fixing ${problems.length} problem(s), then re-verifying once`)
  const fixed = await agent(
    `Fix these problems from verification of the task "${task}". Touch only what is needed.\n- ${problems.join('\n- ')}\n\n` +
      `${brief()}${READ_RULE}`,
    { phase: 'Verify', label: 'fix', schema: BUILT }
  )
  for (const f of (fixed && fixed.changed) || []) if (!changed.includes(f)) changed.push(f)
  results = (await verify(`Previous round found, and an agent then fixed: ${problems.join(' | ')}. Confirm those are gone.\n`)).filter(Boolean)
  problems = results.flatMap((r) => (r.pass ? [] : r.problems))
}

phase('Docs')
if (!problems.length) {
  await agent(
    `The task "${task}" is done and verified. ${brief()}` +
      `Verification: ${results.map((r) => (r.pass ? 'pass' : 'fail: ' + r.problems.join('; '))).join(' / ')}.\n` +
      `Write from this; read only the notes you edit. Update docs/: add a dated line to docs/log.md ` +
      `(issues for the owner's open questions were already opened during Build: ${questions.join('; ') || 'none'}), ` +
      `and add docs/decisions.md only if a real decision was made. Bump \`updated:\` on notes you touch. Do not commit.`,
    { phase: 'Docs', label: 'docs' }
  )
}

return {
  task,
  changed,
  verified: problems.length === 0,
  remainingProblems: problems,
  openQuestions: questions,
  next: problems.length ? 'Fix the remaining problems by hand.' : 'Review the diff, then commit and push.',
}
