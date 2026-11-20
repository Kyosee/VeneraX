import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

export const MARKER = '<!-- venerax-triage:';
export const READY = 'status: triage';
export const WAITING = 'status: needs-info';
const BOT = 'github-actions[bot]';
const TYPES = { bug: 'bug🐞', enhancement: 'enhancement🚀', question: 'question' };
const PLATFORMS = ['Android', 'iOS', 'HarmonyOS', 'Windows', 'macOS', 'linux'];
const MANAGED = new Set([...Object.values(TYPES), READY, WAITING,
  ...PLATFORMS.map(p => `platform: ${p.toLowerCase()}`)]);
const TRUSTED = new Set(['OWNER', 'MEMBER', 'COLLABORATOR']);
const ROOT = resolve(import.meta.dirname, '../..');
const EMPTY = /^(?:_?no response_?|none|n\/a|无|暂无|待补充|todo|[-—.\s]*)$/i;
const SECRET = /(?:\b(?:sk-[a-z0-9_-]{16,}|gh[pousr]_[a-z0-9]{15,}|github_pat_[a-z0-9_]{15,})|-----BEGIN [A-Z ]*PRIVATE KEY-----|["']?(?:authorization|cookie|api[_ -]?key|access[_ -]?token|password|密码|密钥)["']?\s*[:=]\s*["']?(?:(?:bearer|basic)\s+)?[^\s"'`]{8,})/i;
const FIELDS = {
  actual: ['实际发生了什么？ / What happened?', '实际发生了什么？', 'What happened?', '实际行为 / Actual behavior'],
  steps: ['怎样触发？ / How can we reproduce it?', '怎样触发？', 'How can we reproduce it?', '复现步骤 / Steps to reproduce'],
  expected: ['你期望的结果 / Expected result', '你期望的结果', 'Expected result', '预期行为 / Expected behavior'],
  category: ['问题分类 / Category', '问题分类', 'Category', '问题类型 / Issue type'],
  version: ['VeneraX 版本 / App version', 'VeneraX 版本', 'App version', '应用版本 / App version'],
  platform: ['应用平台 / App platform', '应用平台', 'App platform', '平台 / Platform', '适用平台（选填） / Relevant platforms (optional)'],
  environment: ['设备与系统版本 / Device and OS version', '设备与系统版本', 'Device and OS version', '设备与系统 / Device and OS'],
  inconvenience: ['现在有什么不方便？ / What is inconvenient today?', '现在有什么不方便？', 'What is inconvenient today?'],
  desired: ['希望改成怎样？ / What would work better?', '希望改成怎样？', 'What would work better?'],
  question: ['你想完成什么？ / What would you like to do?', '你想完成什么？', 'What would you like to do?'],
  tried: ['试过什么，卡在哪里？ / What have you tried?', '试过什么，卡在哪里？', 'What have you tried?'],
};
const FIELD_NAMES = {
  actual: ['具体异常现象', 'the actual symptom'], steps: ['最近一次发生时的操作经过', 'what you did when it last happened'],
  expected: ['期望结果', 'the expected result'], version: ['具体应用版本（无法取得时说明即可）', 'the exact app version, or why it is unavailable'],
  platform: ['应用平台（APK 选 Android，原生 HAP 选 HarmonyOS）', 'the app platform (Android for APK, HarmonyOS for native HAP)'],
  environment: ['设备型号与系统版本', 'the device and OS version'],
  inconvenience: ['使用场景与当前不方便的地方', 'your use case and current limitation'], desired: ['希望达到的效果', 'the desired outcome'],
  question: ['想完成的事情与具体疑问', 'your goal and question'], tried: ['卡住的位置；尚未尝试也可以说明', 'where you are stuck, or that you have not tried yet'],
};

const choose = (zh, cn, en) => zh ? cn : en;
const names = issue => (issue.labels ?? []).map(l => typeof l === 'string' ? l : l.name);
const plain = text => String(text ?? '').replace(/<!--[\s\S]*?-->/g, '').trim();
const clean = text => plain(text).replace(/https?:\/\/[^\s<>]+/gi, '[link omitted]')
  .replace(/@[\w-]+/g, '[mention omitted]').replace(/<[^>]*>/g, '').trim();

export function parseReport(body = '', title = '', supplements = []) {
  const byHeading = new Map(Object.entries(FIELDS).flatMap(([id, headings]) => headings.map(h => [h.toLowerCase(), id])));
  const fields = {};
  let current, fence, duplicate = false;
  for (const line of plain(body).replace(/\r/g, '').split('\n')) {
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = null;
      if (current) fields[current] += `${line}\n`;
      continue;
    }
    const heading = !fence && line.match(/^###\s+(.+?)\s*$/);
    if (heading) {
      current = byHeading.get(heading[1].toLowerCase());
      if (current) {
        if (Object.hasOwn(fields, current)) duplicate = true;
        else fields[current] = '';
      }
    } else if (current) fields[current] += `${line}\n`;
  }
  for (const key of Object.keys(fields)) fields[key] = fields[key].trim();
  let platformEvidence = fields.environment ?? '';
  for (const supplement of supplements) {
    const extra = parseReport(supplement.body);
    if (extra.duplicate) continue;
    let platform = extra.fields.platform;
    let inFence;
    for (const line of plain(supplement.body).split('\n')) {
      const marker = line.match(/^ {0,3}(`{3,}|~{3,})/);
      if (marker) {
        if (!inFence) inFence = marker[1];
        else if (marker[1][0] === inFence[0] && marker[1].length >= inFence.length) inFence = null;
        continue;
      }
      const explicit = !inFence && line.match(/^\s*(?:应用平台(?:补充)?|平台|App platform|Platform)(?:\s*\/\s*App platform)?\s*[:：]\s*(.+)$/i);
      if (explicit) platform = explicit[1];
    }
    if (platform && !EMPTY.test(platform)) {
      fields.platform = platform;
      // Package evidence must come from the same explicit platform correction.
      platformEvidence = supplement.body;
      if (extra.fields.environment) fields.environment = extra.fields.environment;
    }
  }
  const type = Object.hasOwn(fields, 'actual') ? 'bug' : Object.hasOwn(fields, 'inconvenience') ? 'enhancement' : Object.hasOwn(fields, 'question') ? 'question' : 'unknown';
  const narrative = [title, fields.actual, fields.steps, fields.inconvenience, fields.desired, fields.question, fields.tried].filter(Boolean).join('\n');
  const chinese = (narrative.match(/\p{Script=Han}/gu) ?? []).length;
  const zh = chinese >= 4 || chinese > (narrative.match(/[a-z]/gi) ?? []).length / 4;
  const platforms = (fields.platform ?? '').split(/[,，\n]/).map(x => x.replace(/^\s*-\s*\[[xX]\]\s*/, '').trim())
    .map(x => PLATFORMS.find(p => p.toLowerCase() === x.toLowerCase())).filter(Boolean);
  const conflict = (platforms.includes('HarmonyOS') && /\bAPK\b/i.test(platformEvidence) && !platforms.includes('Android')) ||
    (platforms.includes('Android') && /\bHAP\b/i.test(platformEvidence) && !platforms.includes('HarmonyOS'));
  const required = type === 'bug' ? ['actual', 'steps', 'expected', 'version', 'platform', 'environment'] :
    type === 'enhancement' ? ['inconvenience', 'desired'] : type === 'question' ? ['question', 'tried'] : [];
  const missing = duplicate ? [] : required.filter(k => !fields[k] || EMPTY.test(fields[k]));
  if (!duplicate && type === 'bug' && /^(?:最新版(?:本)?|最新|latest(?: version)?|up.to.date)[.!。\s]*$/i.test(fields.version ?? '') && !missing.includes('version')) missing.push('version');
  if (conflict && !missing.includes('platform')) missing.push('platform');
  return { type, fields, zh, platforms: conflict || duplicate ? [] : [...new Set(platforms)], missing, duplicate,
    sensitive: SECRET.test(body) || SECRET.test(title) || /security|安全问题/i.test(fields.category ?? '') };
}

function blocks(text, path, repo, ref) {
  const lines = text.split(/\r?\n/);
  const out = [];
  let start = 0, heading = '';
  const save = end => {
    const content = clean(lines.slice(start, end).join('\n'));
    if (content) out.push({ text: content, heading, url: `https://github.com/${repo}/blob/${ref}/${path}#L${start + 1}` });
  };
  for (let i = 0; i < lines.length; i++) {
    if (/^#{1,4}\s|^\*\*[^*]+\*\*\s*$/.test(lines[i])) {
      save(i); start = i; heading = lines[i];
    }
  }
  save(lines.length);
  return out;
}

export async function knowledge(report, text, repo, ref, root = ROOT) {
  const [readme, guide] = await Promise.all([
    readFile(resolve(root, report.zh ? 'README.md' : 'README_EN.md'), 'utf8'),
    readFile(resolve(root, report.zh ? 'doc/guide.zh.md' : 'doc/guide.en.md'), 'utf8'),
  ]);
  const readmePath = report.zh ? 'README.md' : 'README_EN.md';
  const guidePath = report.zh ? 'doc/guide.zh.md' : 'doc/guide.en.md';
  // Select excerpts locally; no embeddings or extra model call is needed.
  const tokens = [...new Set((text.toLowerCase().match(/[a-z][a-z0-9-]{2,}|\p{Script=Han}{2,}/gu) ?? []).flatMap(t => /\p{Script=Han}/u.test(t) ? Array.from({ length: t.length - 1 }, (_, i) => t.slice(i, i + 2)) : [t]))].slice(0, 120);
  const items = [...blocks(guide, guidePath, repo, ref), ...blocks(readme, readmePath, repo, ref)];
  const ranked = items.map(b => ({ ...b, score: tokens.reduce((n, t) => n + (b.text.toLowerCase().includes(t) ? 1 : 0) + (b.heading.toLowerCase().includes(t) ? 2 : 0), 0) }))
    .filter(b => b.score > 0 && !/目录|Contents|Star History|致谢|Acknowledg/i.test(b.heading))
    .sort((a, b) => b.score - a.score);
  const agreement = readme.match(/## VeneraX (?:用户协议与免责声明|User Agreement and Disclaimer)([\s\S]*?)(?=\n## |$)/)?.[0] ?? '';
  const policy = blocks(agreement, readmePath, repo, ref)
    .filter(b => /用户协议|User Agreement|重要说明|Important|隐私|Privacy|问题反馈|Feedback|许可|Licens/i.test(b.heading))
    .slice(0, 4).map(b => b.text.slice(0, 325)).join('\n').slice(0, 1300);
  let remaining = 3000;
  const documents = ranked.slice(0, 3).map((item, i) => {
    const excerpt = item.text.slice(0, Math.min(1200, remaining)); remaining -= excerpt.length;
    return { id: `D${i + 1}`, text: excerpt, url: item.url };
  }).filter(d => d.text);
  return { policy, documents };
}

export function validateAnswer(value, docs) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(k => !['summary', 'questions', 'answer', 'sources'].includes(k))) throw new Error('Invalid AI result');
  const valid = (s, max) => typeof s === 'string' && s.length <= max && !/[<>@]|https?:|www\.|```|\]\s*\(|\b[\w-]+\.[a-z]{2,24}(?:[\/\s]|$)/i.test(s) && !SECRET.test(s);
  if (!valid(value.summary, 180) || !value.summary.trim() || !valid(value.answer, 450) ||
      !Array.isArray(value.questions) || value.questions.length > 2 || value.questions.some(q => !valid(q, 140)) ||
      !Array.isArray(value.sources) || value.sources.length > 2 || value.sources.some(id => !docs.some(d => d.id === id)) ||
      (value.answer && !value.sources.length)) throw new Error('Invalid AI result');
  return value;
}

export async function askModel({ env, prompt, report, title, body, comments, context, followup, fetchImpl = fetch }) {
  const url = new URL(env.ISSUE_AI_API_URL);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || !url.pathname.endsWith('/chat/completions')) throw new Error('Invalid API URL');
  const response = await fetchImpl(url.href, {
    method: 'POST', redirect: 'error', signal: AbortSignal.timeout(25000),
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env.ISSUE_AI_API_KEY}` },
    body: JSON.stringify({ model: env.ISSUE_AI_MODEL, max_tokens: 700, stream: false,
      messages: [
        { role: 'system', content: `${prompt}\n\nCurrent agreement excerpt:\n${context.policy}` },
        { role: 'user', content: JSON.stringify({ type: report.type, language: report.zh ? 'zh' : 'en', followup,
          title: clean(title).slice(0, 200), report: clean(body).slice(0, 3500),
          supplements: comments.map(c => clean(c.body)).join('\n').slice(-1200),
          documents: context.documents.map(({ id, text }) => ({ id, text })) }) },
      ],
    }),
  });
  if (!response.ok) throw new Error(`AI HTTP ${response.status}`);
  const raw = await response.text();
  if (raw.length > 32000) throw new Error('AI result too large');
  const data = JSON.parse(raw);
  const content = data.choices?.[0]?.message?.content;
  if (typeof content !== 'string') throw new Error('Invalid AI content');
  const answer = validateAnswer(JSON.parse(content.replace(/^```(?:json)?\s*|\s*```$/g, '').trim()), context.documents);
  // Optional evidence must not become a blocking requirement through AI wording.
  answer.questions = answer.questions.filter(q => !/日志|截图|录屏|附件|\blogs?\b|screenshot|recording|attachment/i.test(q));
  if (followup) answer.questions = [];
  return answer;
}

export function failureReason(error) {
  const message = error?.message ?? '';
  if (/^AI HTTP [45]\d{2}$/.test(message)) return message;
  if (['Invalid API URL', 'Invalid AI result', 'AI result too large', 'Invalid AI content'].includes(message)) return message;
  if (error?.code === 'ERR_INVALID_URL') return 'Invalid API URL';
  if (['TimeoutError', 'AbortError'].includes(error?.name)) return 'AI request timed out';
  if (error?.name === 'SyntaxError') return 'Invalid AI JSON';
  if (message === 'fetch failed') return 'AI network request failed';
  if (error?.code === 'ENOENT') return 'Missing local prompt or documentation';
  return 'Unexpected integration error';
}

function eventKey(context) {
  const p = context.payload;
  return p.comment ? `comment:${p.comment.id}:${p.action}:${p.comment.updated_at}` :
    `issue:${p.action}:${p.issue.updated_at}`;
}

export function managedComment(comments) {
  for (const comment of comments) {
    if (comment.user?.login !== BOT || comment.user?.type !== 'Bot') continue;
    const match = comment.body?.match(/<!-- venerax-triage:(\{[^\n]*\}) -->/);
    if (!match) continue;
    try {
      const state = JSON.parse(match[1]);
      if (state.v === 1 && Number.isInteger(state.calls) && state.calls >= 0 && Array.isArray(state.owned)) return { comment, state };
    } catch { /* Ignore unrelated or damaged comments. */ }
  }
  return null;
}

function render(report, state, ai = null, docs = []) {
  const zh = report.zh;
  const previous = !ai && state.ai;
  if (previous) { ai = state.ai; docs = state.references ?? []; }
  let lines = [choose(zh, '**自动初审**', '**Automatic triage**') + (ai ? choose(zh, ' · AI 辅助', ' · AI assisted') : '')];
  if (report.sensitive) lines.push(choose(zh, '已收到，将由维护者查看。请勿继续公开密钥、账号或敏感细节；本次未进行 AI 分析。', 'Received for maintainer review. Please avoid posting credentials or sensitive details; this report was not sent for AI analysis.'));
  else if (state.paused) lines.push(choose(zh, '维护者已接手，自动追问已暂停。', 'A maintainer has taken over; automatic questions are paused.'));
  else {
    if (previous) lines.push(choose(zh, '以下保留上次自动分析，新增信息等待维护者复查。', 'Previous automated analysis is retained below; new information awaits maintainer review.'));
    if (ai) lines.push(ai.summary);
    const questions = state.responded ? [] : report.missing.slice(0, 3).map(k => choose(zh, `请补充${FIELD_NAMES[k][0]}。`, `Please provide ${FIELD_NAMES[k][1]}.`));
    if (!questions.length && ai && !state.responded) questions.push(...ai.questions);
    if (ai?.answer) lines.push(ai.answer);
    if (questions.length) lines.push(questions.map((q, i) => `${i + 1}. ${q}`).join('\n'), choose(zh, '直接回复或编辑正文即可，无需重新填表。附件选填。', 'Reply here or edit the description; no need to submit again. Attachments are optional.'));
    else lines.push(state.responded ? choose(zh, '已收到补充，已回到待处理，等待维护者复查。', 'Your update is received and ready for maintainer review.') : choose(zh, '已收到，已列入待处理，等待维护者查看。', 'Received and queued for maintainer review.'));
    const sources = docs.filter(d => ai?.sources.includes(d.id));
    if (sources.length) lines.push(choose(zh, '参考当前项目文档：', 'Current project documentation: ') + sources.map((d, i) => `[${i + 1}](${d.url})`).join(' · '));
  }
  return `${lines.join('\n\n')}\n\n${MARKER}${JSON.stringify(state)} -->`;
}

async function syncLabels(github, target, issue, state, desired) {
  const current = names(issue);
  const owned = new Set(state.owned.filter(n => current.includes(n)));
  for (const name of desired) {
    if (current.includes(name)) continue;
    try { await github.rest.issues.getLabel({ ...target, name }); }
    catch (error) {
      if (error.status !== 404) throw error;
      try {
        await github.rest.issues.createLabel({ ...target, name, color: name === WAITING ? 'fbca04' : 'c5def5',
          description: name === READY ? '待维护者初审或复查 / Awaiting maintainer review' : name === WAITING ? '等待作者补充 / Waiting for author information' : 'Issue 受理分类 / Issue intake classification' });
      } catch (createError) { if (createError.status !== 422) throw createError; }
    }
    await github.rest.issues.addLabels({ ...target, labels: [name] }); owned.add(name);
  }
  for (const name of owned) {
    if (desired.includes(name)) continue;
    try { await github.rest.issues.removeLabel({ ...target, name }); }
    catch (error) { if (error.status !== 404) throw error; }
    owned.delete(name);
  }
  state.owned = [...owned];
}

function humanLabels(events, issue, report) {
  const template = events.find(e => ['labeled', 'unlabeled'].includes(e.event) && Object.values(TYPES).includes(e.label?.name));
  return new Set(events.filter(e => e.actor?.type !== 'Bot' && ['labeled', 'unlabeled'].includes(e.event) &&
    !(e === template && e.event === 'labeled' && e.actor?.login === issue.user.login && e.label?.name === TYPES[report.type]))
    .map(e => e.label.name));
}

function humanActivity(comments, events) {
  // Compare GitHub's actual records, including text for edits within one second.
  return JSON.stringify([
    comments.filter(c => c.user?.type !== 'Bot').map(c => [c.id, c.updated_at, c.body]),
    events.filter(e => e.actor?.type !== 'Bot' && ['labeled', 'unlabeled', 'assigned', 'unassigned'].includes(e.event))
      .map(e => [e.id, e.event, e.created_at, e.label?.name, e.assignee?.login]),
  ]);
}

export async function run({ github, context, env = process.env, root = ROOT, fetchImpl = fetch }) {
  const payload = context.payload;
  if (payload.issue?.pull_request || !payload.issue || payload.sender?.type === 'Bot') return;
  const target = { ...context.repo, issue_number: payload.issue.number };
  let issue = (await github.rest.issues.get(target)).data;
  if (issue.state !== 'open' || issue.locked) return;
  const comments = await github.paginate(github.rest.issues.listComments, { ...target, per_page: 100 });
  const managed = managedComment(comments);
  const author = issue.user.login;
  const command = payload.comment?.body?.trim();
  let force = false, pause = false;
  if (context.eventName === 'issue_comment' && /^\/triage (?:retry|pause)$/.test(command ?? '')) {
    let permission;
    try { permission = (await github.rest.repos.getCollaboratorPermissionLevel({ ...context.repo, username: payload.sender.login })).data.permission; }
    catch { return; }
    if (!['admin', 'maintain', 'write'].includes(permission)) return;
    force = command === '/triage retry'; pause = !force;
  } else if (context.eventName === 'issue_comment' && payload.comment?.user?.login !== author && !TRUSTED.has(payload.comment?.author_association)) return;
  if (!managed && payload.action !== 'opened' && !force) return;
  const authorComments = comments.filter(c => c.user?.type !== 'Bot' && c.user?.login === author)
    .sort((a, b) => a.updated_at.localeCompare(b.updated_at));
  const state = managed ? { ...managed.state, owned: [...managed.state.owned] } : { v: 1, calls: 0, owned: [], responded: false, paused: false, run: '' };
  const runId = String(context.runId);
  const event = eventKey(context);
  if (managed && (state.run === runId || state.event === event)) return;
  const bodyPlatform = parseReport(issue.body, issue.title).platforms.join(',');
  if (managed && state.bodyPlatform !== bodyPlatform) {
    state.platformSince = authorComments.at(-1)?.updated_at ?? '';
  }
  state.bodyPlatform = bodyPlatform;
  const report = parseReport(issue.body, issue.title, authorComments.filter(c => !state.platformSince || c.updated_at > state.platformSince));
  const supplements = comments.filter(c => c.user?.type !== 'Bot' && (c.user?.login === author || TRUSTED.has(c.author_association)) && !/^\/triage\b/.test(c.body ?? ''));
  const recent = managed ? supplements.filter(c => c.updated_at > managed.comment.created_at) : [];
  if (managed && (payload.sender?.login === author || recent.some(c => c.user?.login === author))) state.responded = true;
  const humanReply = supplements.some(c => c.user?.login !== author && TRUSTED.has(c.author_association));
  const events = await github.paginate(github.rest.issues.listEvents, { ...target, per_page: 100 });
  const manualLabels = humanLabels(events, issue, report);
  state.owned = state.owned.filter(n => !manualLabels.has(n));
  state.paused = pause || (!force && (state.paused || humanReply || issue.assignees?.length > 0 || [...manualLabels].some(n => MANAGED.has(n))));
  const privacy = report.sensitive || supplements.some(c => SECRET.test(c.body ?? ''));
  report.sensitive = privacy;
  const aiConfigured = env.ISSUE_AI_ENABLED === 'true' && env.ISSUE_AI_API_URL && env.ISSUE_AI_API_KEY && env.ISSUE_AI_MODEL;
  const eligible = aiConfigured && !privacy && !report.duplicate && !state.paused && report.type !== 'unknown' &&
    (!report.missing.length || state.responded) && (force || (state.responded ? !state.followupCall : state.calls < 1)) && payload.action !== 'deleted';
  let desired = state.paused ? state.owned.filter(n => n !== WAITING && n !== READY) : [
    ...(TYPES[report.type] ? [TYPES[report.type]] : []), ...report.platforms.map(p => `platform: ${p.toLowerCase()}`),
  ];
  // A retry may request new analysis, but does not undo a human label decision.
  const typeOverride = [...manualLabels].some(n => Object.values(TYPES).includes(n));
  const platformOverride = [...manualLabels].some(n => n.startsWith('platform:'));
  if (typeOverride) desired = desired.filter(n => !Object.values(TYPES).includes(n));
  if (platformOverride) desired = desired.filter(n => !n.startsWith('platform:'));
  if (typeOverride || platformOverride) state.owned = state.owned.filter(n =>
    !(typeOverride && Object.values(TYPES).includes(n)) && !(platformOverride && n.startsWith('platform:')));
  const queueOverridden = manualLabels.has(READY) || manualLabels.has(WAITING);
  if (!queueOverridden && (!state.paused || state.owned.includes(READY) || state.owned.includes(WAITING))) desired.push(!state.responded && !state.paused && !privacy && report.missing.length ? WAITING : READY);
  const latest = (await github.rest.issues.get(target)).data;
  if (latest.state !== 'open' || latest.locked || latest.updated_at !== issue.updated_at) return;
  await syncLabels(github, target, issue, state, desired);
  state.run = runId;
  state.event = event;
  if (eligible) { state.calls++; if (state.responded) state.followupCall = true; }
  let comment = managed?.comment;
  const publish = async body => {
    if (comment) {
      if (comment.body === body) return;
      comment = (await github.rest.issues.updateComment({ ...context.repo, comment_id: comment.id, body })).data;
    } else comment = (await github.rest.issues.createComment({ ...target, body })).data;
  };
  await publish(render(report, state));
  if (!eligible) return;
  // Reserve the call in the existing comment before spending any API credits.
  const unchanged = async () => {
    const [current, currentComments, currentEvents] = await Promise.all([
      github.rest.issues.get(target),
      github.paginate(github.rest.issues.listComments, { ...target, per_page: 100 }),
      github.paginate(github.rest.issues.listEvents, { ...target, per_page: 100 }),
    ]);
    const value = current.data;
    if (value.state !== 'open' || value.locked || value.body !== issue.body || value.title !== issue.title ||
        JSON.stringify(value.assignees) !== JSON.stringify(issue.assignees) ||
        humanActivity(currentComments, currentEvents) !== humanActivity(comments, events)) return null;
    return value;
  };
  const before = await unchanged();
  if (!before) return;
  try {
    const documents = await knowledge(report, [issue.title, ...Object.values(report.fields), ...recent.map(c => c.body)].join('\n'), `${context.repo.owner}/${context.repo.repo}`, context.sha, root);
    const prompt = await readFile(resolve(root, '.github/issue-triage-prompt.md'), 'utf8');
    const ai = await askModel({ env, prompt, report, title: issue.title, body: issue.body, comments: supplements.slice(-3), context: documents, followup: state.responded, fetchImpl });
    const after = await unchanged();
    if (!after || after.updated_at !== before.updated_at) return;
    issue = after;
    if (ai.questions.length && !state.responded && !queueOverridden) {
      await syncLabels(github, target, issue, state, [...desired.filter(n => n !== READY && n !== WAITING), WAITING]);
    }
    if (!await unchanged()) return;
    state.ai = ai;
    state.references = documents.documents.filter(d => ai.sources.includes(d.id)).map(({ id, url }) => ({ id, url }));
    await publish(render(report, state, ai, documents.documents));
  } catch (error) {
    // Never log provider responses, report text, URLs or credentials.
    console.log(`AI triage unavailable (${failureReason(error)}); rule-based intake remains active. Check the API configuration and provider status.`);
  }
}
