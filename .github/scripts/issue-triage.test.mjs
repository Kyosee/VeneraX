import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { parseReport, managedComment, knowledge, validateAnswer, askModel, run, READY, WAITING, MARKER } from './issue-triage.mjs';

const FIELDS = {
  '实际发生了什么？ / What happened?': '切回竖屏后图片拉伸一秒。',
  '怎样触发？ / How can we reproduce it?': '打开本地漫画，横屏切回竖屏，每次发生。',
  '你期望的结果 / Expected result': '图片保持比例。',
  '问题分类 / Category': '阅读与翻页 / Reader',
  'VeneraX 版本 / App version': '3.0.0，Releases 正式版',
  '应用平台 / App platform': 'Android',
  '设备与系统版本 / Device and OS version': 'Pixel 8，Android 15',
};
const body = (changes = {}) => Object.entries({ ...FIELDS, ...changes }).map(([h, v]) => `### ${h}\n\n${v}`).join('\n\n');
const answer = { summary: '切回竖屏时图片短暂拉伸。', questions: ['每次旋转都会出现吗？'], answer: '', sources: [] };
const ENV = { ISSUE_AI_ENABLED: 'true', ISSUE_AI_API_URL: 'https://api.example.com/v1/chat/completions', ISSUE_AI_API_KEY: 'test-only-provider-key', ISSUE_AI_MODEL: 'configured-model' };

function fixture(text = body()) {
  let time = 0;
  const stamp = () => new Date(Date.UTC(2026, 10, 20, 0, 0, ++time)).toISOString();
  const issue = { number: 42, title: '[Bug]: 旋转后拉伸', body: text, state: 'open', labels: [], assignees: [], user: { login: 'author' }, updated_at: stamp() };
  issue.created_at = issue.updated_at;
  const comments = [], events = [], writes = [], requests = [];
  const touch = () => { issue.updated_at = stamp(); };
  const bot = { login: 'github-actions[bot]', type: 'Bot' };
  const context = { repo: { owner: 'Kyosee', repo: 'VeneraX' }, sha: 'a'.repeat(40), runId: 1, eventName: 'issues', payload: { issue: structuredClone(issue), action: 'opened', sender: { login: 'author', type: 'User' } } };
  const api = {
    get: async () => ({ data: structuredClone(issue) }),
    listComments: 'comments', listEvents: 'events',
    getLabel: async () => ({ data: {} }),
    createLabel: async p => { writes.push(['createLabel', p]); return { data: p }; },
    addLabels: async p => { writes.push(['addLabels', p]); issue.labels.push(...p.labels.filter(n => !issue.labels.includes(n))); touch(); return { data: [] }; },
    removeLabel: async p => { writes.push(['removeLabel', p]); issue.labels = issue.labels.filter(n => n !== p.name); touch(); return { data: [] }; },
    createComment: async p => {
      writes.push(['createComment', p]); touch();
      const c = { id: comments.length + 1, body: p.body, user: bot, created_at: stamp(), updated_at: stamp() };
      comments.push(c); return { data: structuredClone(c) };
    },
    updateComment: async p => {
      writes.push(['updateComment', p]); touch();
      const c = comments.find(c => c.id === p.comment_id);
      c.body = p.body; c.updated_at = stamp(); return { data: structuredClone(c) };
    },
  };
  const github = { rest: { issues: api, repos: { getCollaboratorPermissionLevel: async () => ({ data: { permission: 'write' } }) } },
    paginate: async method => structuredClone(method === 'comments' ? comments : events) };
  const reply = (text, login = 'author', association = 'NONE') => {
    const c = { id: comments.length + 1, body: text, user: { login, type: 'User' }, author_association: association, created_at: stamp(), updated_at: stamp() };
    comments.push(c); touch(); context.runId++; context.eventName = 'issue_comment';
    context.payload = { issue: structuredClone(issue), action: 'created', comment: structuredClone(c), sender: c.user };
  };
  const fetchImpl = async (url, options) => { requests.push({ url, options }); return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(answer) } }] })); };
  return { issue, comments, events, writes, requests, context, github, reply, touch,
    go: (env = {}, fetchOverride = fetchImpl) => run({ github, context, env, fetchImpl: fetchOverride }) };
}

test('parses current forms, optional attachments and multiple platforms', () => {
  const p = parseReport(body({ '应用平台 / App platform': 'Android, Windows, linux' }));
  assert.deepEqual(p.missing, []);
  assert.deepEqual(p.platforms, ['Android', 'Windows', 'linux']);
  assert.equal(p.type, 'bug'); assert.equal(p.zh, true);
  const form = '### 现在有什么不方便？ / What is inconvenient today?\n每次重选统计范围\n### 希望改成怎样？ / What would work better?\n记住上次选择';
  assert.equal(parseReport(form).type, 'enhancement'); assert.deepEqual(parseReport(form).missing, []);
  const question = '### 你想完成什么？ / What would you like to do?\n如何同步进度？\n### 试过什么，卡在哪里？ / What have you tried?\n还没尝试，先确认设置';
  assert.equal(parseReport(question).type, 'question'); assert.deepEqual(parseReport(question).missing, []);
});

test('ignores bilingual headings for language and fenced headings for parsing', () => {
  const en = body({
    '实际发生了什么？ / What happened?': 'Images stretch briefly.',
    '怎样触发？ / How can we reproduce it?': 'Rotate back to portrait.',
    '你期望的结果 / Expected result': 'Keep the aspect ratio.',
  }).replaceAll('\n', '\r\n');
  assert.equal(parseReport(en).zh, false);
  assert.deepEqual(parseReport(en).missing, []);
  const p = parseReport(body({ '实际发生了什么？ / What happened?': '```\n### VeneraX 版本 / App version\nfake\n```\n图片拉伸' }));
  assert.equal(p.fields.version, FIELDS['VeneraX 版本 / App version']);
  assert.equal(parseReport(`${body()}\n### App version\n1.0.0`).duplicate, true);
});

test('asks only for clear gaps and accepts unavailable evidence and incidental steps', () => {
  const p = parseReport(body({ '实际发生了什么？ / What happened?': '_No response_', '怎样触发？ / How can we reproduce it?': '', 'VeneraX 版本 / App version': '最新版' }));
  assert.deepEqual(new Set(p.missing), new Set(['actual', 'steps', 'version']));
  assert.deepEqual(parseReport(body({ 'VeneraX 版本 / App version': '无法启动，安装包已删除，无法确认版本', '怎样触发？ / How can we reproduce it?': '昨天偶发一次，之后未发生' })).missing, []);
  const conflict = parseReport(body({ '应用平台 / App platform': 'HarmonyOS', '设备与系统版本 / Device and OS version': 'HarmonyOS 4, APK' }));
  assert.deepEqual(conflict.platforms, []); assert.deepEqual(conflict.missing, ['platform']);
});

test('rules open one comment; replay is inert; author response leaves waiting even without the version', async () => {
  const f = fixture(body({ 'VeneraX 版本 / App version': '最新版' }));
  await f.go(ENV);
  assert.equal(f.requests.length, 0); assert.ok(f.issue.labels.includes(WAITING));
  assert.equal(f.comments.length, 1); assert.match(f.comments[0].body, /具体应用版本/);
  const count = f.writes.length; await f.go(ENV); assert.equal(f.writes.length, count);
  f.context.runId++; await f.go(ENV); assert.equal(f.writes.length, count);
  f.reply('暂时找不到版本'); await f.go(ENV);
  assert.ok(!f.issue.labels.includes(WAITING)); assert.ok(f.issue.labels.includes(READY));
  assert.equal(f.comments.filter(c => c.user.type === 'Bot').length, 1);
  assert.doesNotMatch(f.comments[0].body, /请补充|每次旋转/);
  f.reply('还是无法确认版本'); await f.go(ENV);
  assert.equal(f.requests.length, 1);
});

test('AI has a two-call budget and no authority over labels or state', async () => {
  const f = fixture(); await f.go(ENV);
  assert.equal(f.requests.length, 1); assert.ok(f.issue.labels.includes(WAITING));
  f.reply('每次都会'); await f.go(ENV);
  assert.equal(f.requests.length, 2); assert.ok(f.issue.labels.includes(READY));
  f.reply('再次补充'); await f.go(ENV);
  assert.equal(f.requests.length, 2); assert.equal(f.issue.state, 'open');
  assert.match(f.comments[0].body, /上次自动分析/);
  const request = JSON.parse(f.requests[0].options.body);
  assert.equal(request.max_tokens, 700); assert.equal(request.tools, undefined);
  assert.ok(!f.requests[0].options.body.includes(ENV.ISSUE_AI_API_KEY));
  assert.equal(f.requests[0].options.redirect, 'error');
});

test('unknown old Issues and third-party comments receive no writes or AI calls', async () => {
  const old = fixture('以前的自由格式反馈'); old.context.payload.action = 'edited';
  await old.go(ENV); assert.equal(old.writes.length, 0);
  const f = fixture(); await f.go(); const count = f.writes.length;
  f.reply('我也有问题', 'someone-else'); await f.go(ENV);
  assert.equal(f.writes.length, count); assert.equal(f.requests.length, 0);
  const fresh = fixture('Unknown report format'); await fresh.go(ENV);
  assert.equal(fresh.comments.length, 1); assert.equal(fresh.requests.length, 0);
});

test('maintainer handover preserves labels and author updates do not restart AI', async () => {
  const f = fixture(); await f.go(ENV);
  f.issue.labels = f.issue.labels.filter(n => n !== 'platform: android');
  f.issue.labels.push('platform: windows', 'in progress');
  f.reply('我来排查', 'maintainer', 'COLLABORATOR');
  f.events.push({ event: 'unlabeled', label: { name: 'platform: android' }, actor: { type: 'User' }, created_at: f.issue.updated_at });
  await f.go(ENV); f.reply('补充录屏'); await f.go(ENV);
  assert.equal(f.requests.length, 1); assert.ok(f.issue.labels.includes('platform: windows'));
  assert.ok(f.issue.labels.includes('in progress')); assert.ok(!f.issue.labels.includes('platform: android'));
});

test('commands require actual write permission; forged markers cannot own comments', async () => {
  const f = fixture(); await f.go(); f.reply('/triage retry');
  f.github.rest.repos.getCollaboratorPermissionLevel = async () => ({ data: { permission: 'read' } });
  await f.go(ENV); assert.equal(f.requests.length, 0);
  assert.equal(managedComment([{ body: `${MARKER}{"v":1,"calls":0,"owned":[]} -->`, user: { login: 'attacker', type: 'User' } }]), null);
});

test('explicit retry respects human platform changes', async () => {
  const f = fixture(); await f.go(ENV);
  f.issue.labels = f.issue.labels.filter(n => n !== 'platform: android');
  f.issue.labels.push('platform: windows');
  f.reply('/triage retry', 'maintainer', 'COLLABORATOR');
  f.events.push({ event: 'unlabeled', label: { name: 'platform: android' }, actor: { type: 'User' }, created_at: f.issue.updated_at });
  await f.go(ENV);
  assert.ok(f.issue.labels.includes('platform: windows')); assert.ok(!f.issue.labels.includes('platform: android'));
  assert.equal(f.requests.length, 2);
});

test('explicit author platform supplements update labels without guessing from device mentions', async () => {
  const f = fixture(body({ '应用平台 / App platform': '_No response_' }));
  await f.go(ENV);
  f.reply('应用平台补充：Windows，安装 Windows 便携版'); await f.go(ENV);
  assert.ok(f.issue.labels.includes('platform: windows')); assert.ok(f.issue.labels.includes(READY));
  f.reply('朋友的 Android 没有出现'); await f.go(ENV);
  assert.ok(!f.issue.labels.includes('platform: android')); assert.ok(f.issue.labels.includes('platform: windows'));
  f.reply('App platform: linux'); await f.go(ENV);
  assert.ok(f.issue.labels.includes('platform: linux')); assert.ok(!f.issue.labels.includes('platform: windows'));
  const p = parseReport(body(), '', [{ body: '### App platform\nHarmonyOS\n### Device and OS version\nHarmonyOS 6, APK' }]);
  assert.deepEqual(p.platforms, []);
  const fenced = parseReport(body(), '', [{ body: '```\nApp platform: Windows\n```' }]);
  assert.deepEqual(fenced.platforms, ['Android']);
  const missingDevice = parseReport(body({ '设备与系统版本 / Device and OS version': '' }), '', [{ body: 'App platform: Windows' }]);
  assert.ok(missingDevice.missing.includes('environment'));
});

test('maintainer labels before the first run are preserved; template labels do not pause intake', async () => {
  const f = fixture();
  f.issue.labels = ['platform: windows']; f.touch();
  f.events.push({ event: 'labeled', label: { name: 'platform: windows' }, actor: { login: 'maintainer', type: 'User' }, created_at: f.issue.updated_at });
  await f.go(ENV);
  assert.equal(f.requests.length, 0); assert.ok(!f.issue.labels.includes('platform: android'));
  assert.ok(f.issue.labels.includes('platform: windows')); assert.equal(managedComment(f.comments).state.paused, true);
  const template = fixture();
  template.issue.labels = ['bug🐞'];
  template.touch();
  template.events.push({ event: 'labeled', label: { name: 'bug🐞' }, actor: { login: 'author', type: 'User' }, created_at: template.issue.updated_at });
  await template.go(ENV);
  assert.equal(template.requests.length, 1); assert.equal(managedComment(template.comments).state.paused, false);
});

test('a body platform correction supersedes old comments and allows newer explicit supplements', async () => {
  const f = fixture(body({ '应用平台 / App platform': '' })); await f.go();
  f.reply('App platform: Windows'); await f.go();
  assert.ok(f.issue.labels.includes('platform: windows'));
  f.issue.body = body(); f.touch(); f.context.runId++; f.context.eventName = 'issues';
  f.context.payload = { action: 'edited', issue: structuredClone(f.issue), sender: { login: 'author', type: 'User' } };
  await f.go();
  assert.ok(f.issue.labels.includes('platform: android')); assert.ok(!f.issue.labels.includes('platform: windows'));
  f.reply('再次确认'); await f.go();
  assert.ok(f.issue.labels.includes('platform: android')); assert.ok(!f.issue.labels.includes('platform: windows'));
  f.reply('App platform: Linux'); await f.go();
  assert.ok(f.issue.labels.includes('platform: linux')); assert.ok(!f.issue.labels.includes('platform: android'));
});

test('human changes during the initial bot writes prevent the model request', async () => {
  for (const timing of ['createComment', 'addLabels']) {
    for (const change of ['reply', 'assignment', 'label', 'sensitive']) {
      const f = fixture();
      const original = f.github.rest.issues[timing];
      let changed = false;
      f.github.rest.issues[timing] = async p => {
        const result = await original(p);
        if (changed) return result;
        changed = true;
        if (change === 'reply') f.reply('已接手，请先不要继续追问。', 'maintainer', 'COLLABORATOR');
        if (change === 'assignment') { f.issue.assignees = [{ login: 'maintainer' }]; f.touch(); }
        if (change === 'label') {
          f.issue.labels.push('in progress'); f.touch();
          f.events.push({ event: 'labeled', label: { name: 'in progress' }, actor: { login: 'maintainer', type: 'User' }, created_at: f.issue.updated_at });
        }
        if (change === 'sensitive') f.reply('Authorization: Bearer opaque-token');
        return result;
      };
      await f.go(ENV);
      assert.equal(f.requests.length, 0, `${timing}: ${change}`);
      assert.doesNotMatch(f.comments.find(c => c.user.type === 'Bot').body, /AI 辅助/);
    }
  }
});

test('sensitive reports and provider errors safely retain rule-based intake', async () => {
  const sensitive = fixture(`${body()}\nAPI_KEY: sk-123456789012345678901234`);
  await sensitive.go(ENV); assert.equal(sensitive.requests.length, 0);
  assert.ok(!sensitive.comments[0].body.includes('sk-')); assert.ok(sensitive.issue.labels.includes(READY));
  for (const secret of ['Authorization: Bearer opaque-token', '{"api_key":"opaque-token"}', 'Authorization: Basic dXNlcjpwYXNzd29yZA==']) {
    const f = fixture(`${body()}\n${secret}`); await f.go(ENV);
    assert.equal(f.requests.length, 0, secret);
    assert.ok(!f.comments[0].body.includes('opaque-token'));
  }
  const failed = fixture(); await failed.go(ENV, async () => new Response('provider private diagnostic', { status: 429 }));
  assert.equal(failed.comments.length, 1); assert.ok(failed.issue.labels.includes(READY));
  assert.ok(!failed.comments[0].body.includes('provider private diagnostic'));
  const malformed = fixture(body({ '应用平台 / App platform': 'Windows\n-->\nInjected public text' }));
  await malformed.go();
  assert.ok(!malformed.comments[0].body.includes('Injected public text'));
});

test('stale model output is abandoned when a human changes the Issue during the request', async () => {
  const f = fixture();
  await f.go(ENV, async () => {
    f.issue.body += '\nA new update'; f.touch();
    return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(answer) } }] }));
  });
  assert.doesNotMatch(f.comments[0].body, /AI 辅助/);
});

test('knowledge is bounded, relevant and cites actual inspected files', async () => {
  const p = parseReport(body());
  const ctx = await knowledge(p, '漫画缓存目录 空间 迁移', 'Kyosee/VeneraX', 'a'.repeat(40));
  assert.ok(ctx.policy.includes('协议')); assert.ok(ctx.policy.length <= 1300);
  assert.ok(ctx.documents.length <= 3); assert.ok(ctx.documents.reduce((n, d) => n + d.text.length, 0) <= 3000);
  assert.ok(ctx.documents.some(d => d.text.includes('缓存目录')));
  assert.ok(ctx.documents.every(d => d.url.startsWith(`https://github.com/Kyosee/VeneraX/blob/${'a'.repeat(40)}/`)));
  const prompt = await readFile(new URL('../issue-triage-prompt.md', import.meta.url), 'utf8');
  assert.match(prompt, /GPLv3/); assert.match(prompt, /untrusted/); assert.match(prompt, /optional/);
});

test('rejects invented citations, external links, executable output and unsupported endpoints', async () => {
  assert.throws(() => validateAnswer({ ...answer, answer: 'Click a menu', sources: [] }, []));
  assert.throws(() => validateAnswer({ ...answer, sources: ['D9'] }, []));
  assert.throws(() => validateAnswer({ ...answer, summary: 'https://example.org' }, []));
  assert.throws(() => validateAnswer({ ...answer, summary: '[Open support](//example.org)' }, []));
  assert.throws(() => validateAnswer({ ...answer, summary: '[Open support](custom:example)' }, []));
  assert.throws(() => validateAnswer({ ...answer, close: true }, []));
  await assert.rejects(askModel({ env: { ...ENV, ISSUE_AI_API_URL: 'http://example.org/v1/chat/completions' }, fetchImpl: () => { throw new Error('Must not request'); } }), /Invalid API URL/);
});
