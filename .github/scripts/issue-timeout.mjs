import { humanLabels, managedComment, parseReport, READY, WAITING } from './issue-triage.mjs';

export const REMINDER = '<!-- venerax-needs-info-reminder -->';
const DAY = 24 * 60 * 60 * 1000;
const PROTECTED = new Set([336, 349]);
const TRUSTED = new Set(['OWNER', 'MEMBER', 'COLLABORATOR']);
const bot = comment => comment.user?.login === 'github-actions[bot]' && comment.user?.type === 'Bot';
const names = issue => (issue.labels ?? []).map(label => typeof label === 'string' ? label : label.name);

function eligible(issue) {
  const labels = names(issue);
  return issue.state === 'open' && !issue.pull_request && !issue.locked &&
    !PROTECTED.has(issue.number) && !issue.assignees?.length && !issue.milestone &&
    labels.includes(WAITING) && !labels.includes(READY) && !labels.includes('enhancement🚀');
}

export function decide(issue, comments, events, now) {
  if (!eligible(issue)) return null;
  const managed = managedComment(comments);
  if (!managed || managed.state.paused || managed.state.responded || !managed.state.owned.includes(WAITING)) return null;
  const report = parseReport(issue.body, issue.title);
  if (report.sensitive || report.duplicate || ['unknown', 'enhancement'].includes(report.type) || humanLabels(events, issue, report).size) return null;
  // Template type labels may predate the bot; every other label must still be bot-owned.
  const allowed = new Set([...managed.state.owned, 'bug🐞', 'enhancement🚀', 'question']);
  if (names(issue).some(name => !allowed.has(name))) return null;
  if (comments.some(c => c.user?.type !== 'Bot' &&
      (c.user?.login === issue.user.login || TRUSTED.has(c.author_association)))) return null;
  if (events.some(e => e.actor?.type !== 'Bot' &&
      ['assigned', 'unassigned', 'milestoned', 'demilestoned', 'reopened'].includes(e.event))) return null;

  const reminder = comments.filter(c => bot(c) && c.body?.endsWith(REMINDER))
    .sort((a, b) => a.created_at.localeCompare(b.created_at)).at(-1);
  const updated = Date.parse(issue.updated_at);
  const triaged = Date.parse(managed.comment.updated_at);
  const knownUpdate = reminder ? Date.parse(reminder.updated_at) : triaged;
  if (![now, updated, triaged, knownUpdate].every(Number.isFinite)) return null;
  // Unaccounted activity (including a body edit whose workflow failed) cancels this timeout.
  if (updated > knownUpdate) return null;
  if (!reminder) return now - Math.max(updated, triaged) >= 30 * DAY ? { action: 'remind', zh: report.zh } : null;
  const reminded = Date.parse(reminder.created_at);
  return Number.isFinite(reminded) && now - reminded >= 14 * DAY && now - triaged >= 30 * DAY
    ? { action: 'close', zh: report.zh, commentId: reminder.id } : null;
}

async function inspect(github, target, now) {
  const issue = (await github.rest.issues.get(target)).data;
  if (!eligible(issue)) return null;
  const [comments, events] = await Promise.all([
    github.paginate(github.rest.issues.listComments, { ...target, per_page: 100 }),
    github.paginate(github.rest.issues.listEvents, { ...target, per_page: 100 }),
  ]);
  // A human can edit while pagination is in flight, outside the workflow concurrency group.
  const latest = (await github.rest.issues.get(target)).data;
  return decide(latest, comments, events, now);
}

export async function candidates({ github, repo, now = Date.now() }) {
  const issues = await github.paginate(github.rest.issues.listForRepo,
    { ...repo, state: 'open', labels: WAITING, sort: 'updated', direction: 'asc', per_page: 100 });
  const numbers = [];
  for (const issue of issues) {
    if (!eligible(issue) || now - Date.parse(issue.updated_at) < 14 * DAY) continue;
    if (await inspect(github, { ...repo, issue_number: issue.number }, now)) numbers.push(issue.number);
    // GitHub matrices allow 256 jobs; later runs pick up the remaining actionable reports.
    if (numbers.length === 256) break;
  }
  return numbers;
}

export async function run({ github, repo, issueNumber, dryRun = true, now = Date.now() }) {
  const target = { ...repo, issue_number: issueNumber };
  const decision = await inspect(github, target, now);
  if (!decision) return 'skip';
  if (dryRun) return decision.action;
  // Recheck after the matrix wait and immediately before writing, sharing triage's per-Issue lock.
  const current = await inspect(github, target, now);
  if (!current || current.action !== decision.action || current.commentId !== decision.commentId) return 'skip';
  const { zh } = current;
  if (current.action === 'remind') {
    const body = zh
      ? '此 Issue 已等待补充信息至少 30 天。请回复或编辑正文补充信息；暂时无法提供也可以说明。\n\n如果再过 14 天仍未收到回应，将因信息不足暂时关闭。这不代表问题已经修复；补充后可申请重新打开。'
      : 'This Issue has been waiting for information for at least 30 days. Please reply or edit the description; explaining that the information is unavailable is also welcome.\n\nIf there is still no response after another 14 days, it will be closed for lack of information. This does not mean the problem is fixed; you can request reopening after providing an update.';
    await github.rest.issues.createComment({ ...target, body: `${body}\n\n${REMINDER}` });
  } else {
    await github.rest.issues.update({ ...target, state: 'closed', state_reason: 'not_planned' });
    const body = zh
      ? '提醒后至少 14 天仍未收到补充，已因信息不足暂时关闭此 Issue。这不代表问题已经修复；补充后可申请重新打开。'
      : 'No update was received for at least 14 days after the reminder, so this Issue was closed for lack of information. This does not mean the problem is fixed; you can request reopening after providing an update.';
    await github.rest.issues.updateComment({ ...repo, comment_id: current.commentId, body: `${body}\n\n${REMINDER}` });
  }
  return current.action;
}
