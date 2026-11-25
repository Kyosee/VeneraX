import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { parseReport, managedComment, knowledge, validateAnswer, askModel, failureReason, run, READY, WAITING, MARKER } from './issue-triage.mjs';

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
  const comments = [], events = [], writes = [], requests = [], intakeQueries = [], recentIssues = [issue];
  const touch = () => { issue.updated_at = stamp(); };
  const bot = { login: 'github-actions[bot]', type: 'Bot' };
  const context = { repo: { owner: 'Kyosee', repo: 'VeneraX' }, sha: 'a'.repeat(40), runId: 1, eventName: 'issues', payload: { issue: structuredClone(issue), action: 'opened', sender: { login: 'author', type: 'User' } } };
  const api = {
    get: async () => ({ data: structuredClone(issue) }),
    listForRepo: async p => { intakeQueries.push(p); return { data: structuredClone(recentIssues) }; },
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
  return { issue, comments, events, writes, requests, context, github, reply, touch, intakeQueries, recentIssues,
    go: (env = {}, fetchOverride = fetchImpl) => run({ github, context, env, fetchImpl: fetchOverride, now: Date.parse(issue.updated_at) }) };
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

test('reply language follows narrative, ignoring titles, code and form choices', async () => {
  const english = body({
    '实际发生了什么？ / What happened?': 'Images stretch briefly.\n```log\n中文日志，图片被拉伸，重复很多次\n```',
    '怎样触发？ / How can we reproduce it?': 'Rotate back to portrait.',
    '你期望的结果 / Expected result': 'Keep the aspect ratio.',
  });
  assert.equal(parseReport(english, '图片拉伸的问题反馈').zh, false);
  const flutterLogs = english.replace('Images stretch briefly.', 'Images stretch briefly.\n' + 'I/flutter (123): 读取失败请重试\n'.repeat(8));
  assert.equal(parseReport(flutterLogs).zh, false);
  assert.doesNotMatch(parseReport(flutterLogs).languageSample, /读取失败/);
  const chinese = body({
    '实际发生了什么？ / What happened?': '图片拉伸\n```\n' + 'A lengthy English log entry. '.repeat(50) + '\n```',
    '怎样触发？ / How can we reproduce it?': '_No response_',
  });
  assert.equal(parseReport(chinese, 'An English title').zh, true);
  assert.equal(parseReport(body({
    '实际发生了什么？ / What happened?': '...', '怎样触发？ / How can we reproduce it?': '...',
    '你期望的结果 / Expected result': '希望图片保持原来的比例',
  }), 'English title').zh, true);
  const japanese = '### What would you like to do?\n画像を保存するにはどうすればいいですか？\n### What have you tried?\nまだ試していません。';
  assert.equal(parseReport(japanese, '中文标题').zh, false);
  for (const [text, expected] of [[english, 'Images stretch briefly.'], [japanese, '画像を保存']]) {
    const f = fixture(text); await f.go(ENV);
    assert.match(f.comments[0].body, /^Issue summary: /);
    assert.doesNotMatch(f.comments[0].body, /自动初审|Automatic triage|AI 辅助|AI assisted/);
    const rules = fixture(text); await rules.go();
    assert.match(rules.comments[0].body, /^Received and queued for maintainer review\./);
    const messages = JSON.parse(f.requests[0].options.body).messages;
    const request = JSON.parse(messages[1].content);
    assert.equal(request.language, 'auto'); assert.ok(request.language_sample.includes(expected));
    assert.doesNotMatch(request.language_sample, /中文日志/);
    assert.match(messages[0].content, /language_sample/);
  }
});

test('explicit private and source details bypass AI, including short and formatted fields', async () => {
  const details = ['password: 123456', '密码：12345678', '**账号**：alice', '{"api_key":"abc"}',
    '{"password":\n"private-password"}', 'Cookie:\nsession=private-cookie',
    'Login failed (password: private-password)', '登录失败（password: private-password）', 'db_password=short',
    'Contact: reader@example.org', '电话：+86 138 0013 8000', 'C:\\Users\\alice\\AppData\\Local',
    '/home/alice/.config/app', '**源名称**：私人漫画站', 'Source URL: https://private.example.org',
    '身份证号：110101199001010011'];
  for (const detail of details) {
    const f = fixture(`${body()}\n${detail}`); await f.go(ENV);
    assert.equal(f.requests.length, 0, detail); assert.equal(f.intakeQueries.length, 0);
    assert.match(f.comments[0].body, /编辑.*原文/); assert.ok(!f.comments[0].body.includes(detail));
    assert.equal(f.issue.state, 'open');
    assert.throws(() => validateAnswer({ ...answer, summary: detail }, []), /Invalid AI result/, detail);
  }
  for (const detail of ['源管理页面崩溃，JS 引擎执行失败，WebDAV 同步失败。',
    'Source name: [redacted]', '账号：未填写', '密码：***', '电话：未填写',
    'Source URL: [removed]', 'C:\\Users\\<redacted>\\AppData', 'Pixel 8 Android 15 version 3.0.0']) {
    assert.equal(parseReport(`${body()}\n${detail}`).sensitive, false, detail);
  }
});

test('sensitive supplements and cached replies are withheld even on an authorized retry', async () => {
  for (const author of ['author', 'maintainer']) {
    const f = fixture(); await f.go(ENV);
    const cached = managedComment(f.comments);
    cached.state.ai.summary = '账号：old-private-account';
    f.comments[0].body = `${MARKER}${JSON.stringify(cached.state)} -->`;
    f.reply('邮箱：reader@example.org', author, author === 'author' ? 'NONE' : 'COLLABORATOR');
    await f.go(ENV);
    assert.equal(f.requests.length, 1);
    assert.doesNotMatch(f.comments[0].body, /old-private-account|reader@example|issue总结：/);
    assert.equal(managedComment(f.comments).state.ai, undefined);
    assert.equal(managedComment(f.comments).state.references, undefined);
    f.reply('/triage retry', 'maintainer', 'COLLABORATOR'); await f.go(ENV);
    assert.equal(f.requests.length, 1);
  }
});

test('automatic AI throttles new issues by author and repository without spending a call', async () => {
  for (const [authorCount, totalCount, allowed] of [[3, 3, true], [4, 4, false], [1, 20, true], [1, 21, false]]) {
    const f = fixture();
    for (let i = 1; i < totalCount; i++) f.recentIssues.push({ number: 100 + i, created_at: f.issue.created_at,
      state: 'closed', user: { login: i < authorCount ? 'author' : `other-${i}` } });
    await f.go(ENV);
    assert.equal(f.requests.length, allowed ? 1 : 0, `${authorCount}/${totalCount}`);
    assert.equal(f.intakeQueries.length, 1);
    assert.deepEqual(f.intakeQueries[0], { ...f.context.repo, state: 'all', sort: 'created', direction: 'desc', per_page: 100 });
    if (!allowed) {
      assert.equal(managedComment(f.comments).state.calls, 0);
      assert.equal(managedComment(f.comments).state.paused, false);
      assert.ok(f.issue.labels.includes(READY));
      f.reply('更多补充'); await f.go(ENV);
      assert.equal(managedComment(f.comments).state.followupCall, undefined);
      assert.equal(f.requests.length, 0);
      f.reply('/triage retry', 'maintainer', 'COLLABORATOR'); await f.go(ENV);
      assert.equal(f.requests.length, 1);
      assert.equal(f.intakeQueries.length, 2);
    }
  }
});

test('intake counting excludes PRs and old issues; uncertain counts fail closed', async () => {
  const allowed = fixture();
  for (let i = 0; i < 25; i++) allowed.recentIssues.push({ number: 100 + i, user: { login: 'author' },
    created_at: allowed.issue.created_at, pull_request: {} });
  allowed.recentIssues.push({ number: 200, user: { login: 'author' }, created_at: '2026-11-18T00:00:00Z' });
  await allowed.go(ENV); assert.equal(allowed.requests.length, 1);
  for (const mode of ['error', 'full', 'malformed', 'missing-current']) {
    const f = fixture();
    if (mode === 'error') f.github.rest.issues.listForRepo = async () => { throw new Error('private error'); };
    if (mode === 'full') for (let i = 1; i < 100; i++) f.recentIssues.push({ number: 100 + i,
      user: { login: 'author' }, created_at: f.issue.created_at, pull_request: {} });
    if (mode === 'malformed') f.recentIssues.push({ number: 201 });
    if (mode === 'missing-current') f.recentIssues.splice(0);
    await f.go(ENV);
    assert.equal(f.requests.length, 0, mode); assert.equal(managedComment(f.comments).state.calls, 0);
    assert.equal(f.comments.length, 1); assert.ok(f.issue.labels.includes(READY));
  }
  const incomplete = fixture(body({ 'VeneraX 版本 / App version': '' }));
  await incomplete.go(ENV); assert.equal(incomplete.intakeQueries.length, 0);
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
  assert.match(f.comments[0].body, /^1\. 请补充/);
  assert.doesNotMatch(f.comments[0].body, /自动初审|Automatic triage|AI 辅助|AI assisted/);
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
  assert.ok(f.comments[0].body.startsWith(`issue总结：${answer.summary}`));
  assert.doesNotMatch(f.comments[0].body, /自动初审|Automatic triage|AI 辅助|AI assisted/);
  assert.equal(f.requests.length, 1); assert.ok(f.issue.labels.includes(WAITING));
  f.reply('每次都会'); await f.go(ENV);
  assert.equal(f.requests.length, 2); assert.ok(f.issue.labels.includes(READY));
  f.reply('再次补充'); await f.go(ENV);
  assert.equal(f.requests.length, 2); assert.equal(f.issue.state, 'open');
  assert.match(f.comments[0].body, /上次自动分析/);
  assert.ok(f.comments[0].body.includes(`issue总结：${answer.summary}`));
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
      assert.doesNotMatch(f.comments.find(c => c.user.type === 'Bot').body, /issue总结：/);
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
  assert.doesNotMatch(f.comments[0].body, /issue总结：/);
});

test('a bot-only Issue timestamp update does not discard a valid AI reply', async () => {
  const f = fixture();
  await f.go(ENV, async () => {
    f.touch();
    return Response.json({ choices: [{ message: { content: JSON.stringify(answer) } }] });
  });
  assert.match(f.comments[0].body, /issue总结：/);
});

test('label changes during a request discard AI output even before timeline events appear', async () => {
  const f = fixture();
  await f.go(ENV, async () => {
    f.issue.labels.push('in progress');
    return Response.json({ choices: [{ message: { content: JSON.stringify(answer) } }] });
  });
  assert.doesNotMatch(f.comments[0].body, /issue总结：/);
  assert.ok(f.issue.labels.includes('in progress'));
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

test('English backup questions retrieve the relevant numbered paragraph instead of a section prefix', async () => {
  const text = 'Before changing devices, I want to know whether an exported VeneraX app-data backup includes downloaded comic image files. What should I keep separately?';
  const ctx = await knowledge({ zh: false }, text, 'Kyosee/VeneraX', 'a'.repeat(40));
  const backup = ctx.documents.find(d => d.text.includes('An application data backup is not a backup of downloaded images.'));
  assert.ok(backup, 'The actual backup scope must reach the model');
  assert.ok(backup.text.includes('Comic images should be handled separately'));
  const line = Number(backup.url.match(/#L(\d+)$/)[1]);
  const readme = await readFile(new URL('../../README_EN.md', import.meta.url), 'utf8');
  assert.ok(readme.split(/\r?\n/)[line - 1].includes('Importing, restoring or synchronizing'));
  assert.ok(ctx.documents.reduce((n, d) => n + d.text.length, 0) <= 3000);
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

test('failure diagnostics identify actionable causes without exposing error details', async t => {
  assert.equal(failureReason(new Error('AI HTTP 401')), 'AI HTTP 401');
  assert.equal(failureReason(new Error('AI HTTP 401\nprivate provider message')), 'Unexpected integration error');
  assert.equal(failureReason(new Error('Invalid API URL')), 'Invalid API URL');
  assert.equal(failureReason({ code: 'ERR_INVALID_URL', message: 'private URL' }), 'Invalid API URL');
  assert.equal(failureReason(new SyntaxError('private model content')), 'Invalid AI JSON');
  assert.equal(failureReason(new DOMException('private diagnostic', 'TimeoutError')), 'AI request timed out');
  assert.equal(failureReason(new Error('Authorization: Bearer secret')), 'Unexpected integration error');
  const logs = [];
  t.mock.method(console, 'log', message => logs.push(message));
  const f = fixture();
  await f.go(ENV, async () => new Response('private provider diagnostic', { status: 429 }));
  assert.equal(logs.length, 1);
  assert.match(logs[0], /AI HTTP 429/);
  assert.doesNotMatch(logs[0], /private provider diagnostic|test-only-provider-key/);
});

test('both protocols send the same bounded context and publish a cited answer', async () => {
  const value = { ...answer, questions: [], answer: '请先核对项目指南中的说明。', sources: ['D1'] };
  const text = JSON.stringify(value);
  let expectedMessages;
  for (const endpoint of ['chat/completions', 'responses']) {
    for (const slash of ['', '/']) {
      const f = fixture();
      await f.go({ ...ENV, ISSUE_AI_API_URL: `https://api.example.com/custom/v1/${endpoint}${slash}` }, async (url, options) => {
        assert.equal(url, `https://api.example.com/custom/v1/${endpoint}`);
        assert.equal(options.method, 'POST'); assert.equal(options.redirect, 'error');
        assert.equal(options.headers.Authorization, `Bearer ${ENV.ISSUE_AI_API_KEY}`);
        assert.ok(options.signal instanceof AbortSignal);
        const request = JSON.parse(options.body);
        assert.equal(request.model, ENV.ISSUE_AI_MODEL); assert.equal(request.stream, false);
        assert.equal(request.tools, undefined); assert.ok(!options.body.includes(ENV.ISSUE_AI_API_KEY));
        const messages = request.messages ?? request.input;
        expectedMessages ??= messages;
        assert.deepEqual(messages, expectedMessages);
        assert.equal(messages[0].role, 'system'); assert.match(messages[0].content, /Current agreement excerpt/);
        assert.equal(messages[1].role, 'user');
        assert.ok(JSON.parse(messages[1].content).documents.length > 0);
        if (endpoint === 'chat/completions') {
          assert.equal(request.max_tokens, 700); assert.equal(request.input, undefined);
          assert.equal(request.max_output_tokens, undefined);
          return Response.json({ choices: [{ finish_reason: 'stop', message: { content: text } }] });
        }
        assert.equal(request.max_output_tokens, 700); assert.equal(request.store, false);
        assert.equal(request.messages, undefined); assert.equal(request.max_tokens, undefined);
        return Response.json({ status: 'completed', output: [
          { type: 'reasoning', summary: [{ type: 'summary_text', text: 'Private reasoning' }] },
          { type: 'function_call', name: 'unrequested_tool', arguments: 'Never execute this' },
          { type: 'message', role: 'assistant', status: 'completed', phase: 'commentary', content: [{ type: 'output_text', text: 'Intermediate commentary' }] },
          { type: 'message', role: 'assistant', status: 'completed', phase: 'final_answer', content: [
            { type: 'output_text', text: text.slice(0, 20) }, { type: 'output_text', text: text.slice(20) },
          ] },
        ] });
      });
      assert.match(f.comments[0].body, /issue总结：/);
      assert.match(f.comments[0].body, /参考当前项目文档/);
      assert.equal(managedComment(f.comments).state.ai.answer, value.answer);
      assert.doesNotMatch(f.comments[0].body, /Private reasoning|Never execute this|Intermediate commentary/);
      assert.ok(f.issue.labels.includes(READY)); assert.equal(f.issue.state, 'open');
    }
  }
});

test('Responses follow-up shares the call budget and updates one bot comment', async () => {
  const f = fixture();
  let calls = 0;
  const response = async () => {
    calls++;
    return Response.json({ status: 'completed', output: [{
      type: 'message', role: 'assistant', status: 'completed',
      content: [{ type: 'output_text', text: JSON.stringify(answer) }],
    }] });
  };
  const env = { ...ENV, ISSUE_AI_API_URL: 'https://api.example.com/v1/responses' };
  await f.go(env, response); assert.ok(f.issue.labels.includes(WAITING));
  f.reply('每次都会'); await f.go(env, response);
  assert.ok(f.issue.labels.includes(READY)); assert.ok(!f.issue.labels.includes(WAITING));
  assert.deepEqual(managedComment(f.comments).state.ai.questions, []);
  f.reply('还有补充'); await f.go(env, response);
  assert.equal(calls, 2); assert.equal(f.comments.filter(c => c.user.type === 'Bot').length, 1);
});

test('Responses rejects incomplete, refused, non-text and invalid outputs', async () => {
  const message = { type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: JSON.stringify(answer) }] };
  const complete = { status: 'completed', output: [message] };
  const args = { env: { ...ENV, ISSUE_AI_API_URL: 'https://api.example.com/v1/responses' },
    prompt: 'Return JSON.', report: parseReport(body()), title: 'Test', body: body(), comments: [], context: { policy: '', documents: [] } };
  for (const status of ['incomplete', 'failed', 'cancelled', 'queued', 'in_progress', undefined]) {
    await assert.rejects(askModel({ ...args, fetchImpl: async () => Response.json({ ...complete, status }) }), /AI response incomplete/);
  }
  for (const data of [null, [], { status: 'completed' }, { ...complete, output: [] },
    { ...complete, output: [{ type: 'function_call', arguments: JSON.stringify(answer) }] },
    { ...complete, output: [{ ...message, status: 'incomplete' }] },
    { ...complete, output: [{ ...message, phase: 'commentary' }] },
    { ...complete, output: [{ ...message, phase: 'unknown' }] },
    { ...complete, output: [{ ...message, role: 'user' }] },
    { ...complete, output: [{ ...message, content: [{ type: 'refusal', refusal: 'Cannot answer' }] }] },
    { ...complete, output: [{ ...message, content: [{ type: 'output_text', text: 42 }] }] },
    { ...complete, output: [{ ...message, content: {} }] },
  ]) {
    await assert.rejects(askModel({ ...args, fetchImpl: async () => Response.json(data) }), /Invalid AI content/);
  }
  await assert.rejects(askModel({ ...args, fetchImpl: async () => Response.json({ ...complete, output: [{ ...message,
    content: [{ type: 'output_text', text: JSON.stringify({ ...answer, sources: ['D9'] }) }],
  }] }) }), /Invalid AI result/);
  for (const endpoint of ['chat/completions', 'responses']) {
    for (const suffix of ['?api_key=private', '#private']) {
      await assert.rejects(askModel({ env: { ...ENV, ISSUE_AI_API_URL: `https://api.example.com/v1/${endpoint}${suffix}` } }), /Invalid API URL/);
    }
  }
  for (const url of ['https://api.example.com/v1', 'https://api.example.com/v1/response', 'https://user:private@api.example.com/v1/responses']) {
    await assert.rejects(askModel({ env: { ...ENV, ISSUE_AI_API_URL: url } }), /Invalid API URL/);
  }
});

test('both protocols safely fall back on incomplete or refused output without exposing provider details', async t => {
  const logs = [];
  t.mock.method(console, 'log', message => logs.push(message));
  const message = { content: JSON.stringify(answer) };
  const cases = [
    ['responses', { status: 'incomplete', incomplete_details: { reason: 'private provider detail' }, output: [] }, 'AI response incomplete'],
    ['chat/completions', { choices: [{ finish_reason: 'length', message }] }, 'AI response incomplete'],
    ['chat/completions', { choices: [{ finish_reason: null, message }] }, 'AI response incomplete'],
    ['chat/completions', { choices: [{ finish_reason: 'stop', message: { ...message, refusal: 'private provider detail' } }] }, 'Invalid AI content'],
  ];
  for (const [endpoint, data] of cases) {
    const f = fixture();
    await f.go({ ...ENV, ISSUE_AI_API_URL: `https://api.example.com/v1/${endpoint}` }, async () => Response.json(data));
    assert.ok(f.issue.labels.includes(READY)); assert.equal(f.comments.length, 1);
    assert.doesNotMatch(f.comments[0].body, /issue总结：|private provider detail/);
  }
  assert.equal(logs.length, cases.length);
  assert.ok(logs.every((log, i) => log.includes(cases[i][2])));
  assert.ok(logs.every(log => !/private provider detail|test-only-provider-key/.test(log)));
});
