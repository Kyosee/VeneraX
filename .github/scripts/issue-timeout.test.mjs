import test from 'node:test';
import assert from 'node:assert/strict';
import { candidates, REMINDER, run } from './issue-timeout.mjs';
import { MARKER, parseReport, READY, WAITING } from './issue-triage.mjs';

const DAY = 24 * 60 * 60 * 1000;
const START = Date.parse('2026-09-01T00:00:00Z');
const REPO = { owner: 'Kyosee', repo: 'VeneraX' };
const BOT = { login: 'github-actions[bot]', type: 'Bot' };
const iso = time => new Date(time).toISOString();

function record(number = 42, zh = true) {
  const state = { v: 1, calls: 1, owned: ['question', WAITING], paused: false, responded: false };
  return {
    state,
    issue: { number, title: 'Backup question', state: 'open', locked: false, assignees: [], milestone: null,
      user: { login: 'author', type: 'User' }, labels: [{ name: 'question' }, { name: WAITING }],
      created_at: iso(START - 365 * DAY), updated_at: iso(START),
      body: `### What would you like to do?\n${zh ? '如何备份漫画？' : 'How do I back up my comics?'}\n\n### What have you tried?\n${zh ? '还未尝试。' : 'I have not tried yet.'}` },
    comments: [{ id: number * 10, user: BOT, created_at: iso(START), updated_at: iso(START),
      body: `${MARKER}${JSON.stringify(state)} -->` }],
    events: [],
  };
}

function triage(item, changes) {
  Object.assign(item.state, changes);
  item.comments[0].body = `${MARKER}${JSON.stringify(item.state)} -->`;
}

function reminder(item, time = START + 30 * DAY) {
  const comment = { id: item.issue.number * 10 + 1, user: BOT, body: `Please provide more information.\n\n${REMINDER}`,
    created_at: iso(time), updated_at: iso(time) };
  item.comments.push(comment);
  item.issue.updated_at = iso(time);
  return comment;
}

function fixture(items = [record()]) {
  const byNumber = new Map(items.map(item => [item.issue.number, item]));
  const f = { ...items[0], items, now: START + 30 * DAY, writes: [], queries: [], reads: 0, onGet: null };
  const getItem = params => byNumber.get(params.issue_number);
  const issues = {
    listForRepo: 'issues', listComments: 'comments', listEvents: 'events',
    get: async params => {
      f.reads++; await f.onGet?.(f.reads, getItem(params));
      return { data: structuredClone(getItem(params).issue) };
    },
    createComment: async params => {
      f.writes.push(['createComment', params]);
      const item = getItem(params);
      const comment = { id: item.issue.number * 10 + item.comments.length, user: BOT, body: params.body,
        created_at: iso(f.now), updated_at: iso(f.now) };
      item.comments.push(comment); item.issue.updated_at = iso(f.now);
      return { data: structuredClone(comment) };
    },
    update: async params => {
      f.writes.push(['update', params]);
      const item = getItem(params);
      Object.assign(item.issue, { state: params.state, state_reason: params.state_reason, updated_at: iso(f.now) });
      return { data: structuredClone(item.issue) };
    },
    updateComment: async params => {
      f.writes.push(['updateComment', params]);
      const item = items.find(item => item.comments.some(comment => comment.id === params.comment_id));
      const comment = item.comments.find(comment => comment.id === params.comment_id);
      Object.assign(comment, { body: params.body, updated_at: iso(f.now) });
      item.issue.updated_at = iso(f.now);
      return { data: structuredClone(comment) };
    },
  };
  f.github = { rest: { issues }, paginate: async (method, params) => {
    f.queries.push([method, params]);
    if (method === 'issues') return structuredClone(items.map(item => item.issue));
    return structuredClone(getItem(params)[method]);
  } };
  f.go = options => run({ github: f.github, repo: REPO, issueNumber: f.issue.number, now: f.now, dryRun: false, ...options });
  return f;
}

test('waits 30 full days before a reminder and localizes both reminder languages', async () => {
  for (const zh of [true, false]) {
    const f = fixture([record(42, zh)]);
    f.now = START + 30 * DAY - 1;
    assert.equal(await f.go(), 'skip'); assert.deepEqual(f.writes, []);
    f.now++;
    assert.equal(await f.go(), 'remind');
    assert.equal(f.issue.state, 'open'); assert.equal(f.writes.length, 1);
    const body = f.writes[0][1].body;
    assert.match(body, zh ? /至少 30 天/ : /at least 30 days/);
    assert.match(body, zh ? /再过 14 天/ : /another 14 days/);
    assert.match(body, zh ? /不代表问题已经修复/ : /does not mean the problem is fixed/);
    assert.match(body, zh ? /申请重新打开/ : /request reopening/);
    assert.ok(body.endsWith(REMINDER));
  }
});

test('closes only after 14 full days from the reminder and marks lack of information, not resolution', async () => {
  for (const zh of [true, false]) {
    const item = record(42, zh); const comment = reminder(item);
    const f = fixture([item]); f.now = START + 44 * DAY - 1;
    assert.equal(await f.go(), 'skip'); assert.deepEqual(f.writes, []);
    f.now++;
    assert.equal(await f.go(), 'close');
    assert.deepEqual(f.writes[0], ['update', { ...REPO, issue_number: 42, state: 'closed', state_reason: 'not_planned' }]);
    assert.equal(f.issue.state, 'closed'); assert.equal(f.comments.length, 2);
    assert.equal(f.writes[1][0], 'updateComment'); assert.equal(f.writes[1][1].comment_id, comment.id);
    assert.match(comment.body, zh ? /信息不足.*关闭/ : /closed for lack of information/);
    assert.match(comment.body, zh ? /不代表问题已经修复/ : /does not mean the problem is fixed/);
    assert.equal(await f.go(), 'skip'); assert.equal(f.writes.length, 2);
  }
});

test('an old report receives its first reminder before any closing window begins; repeats are inert', async () => {
  const f = fixture(); f.now = START + 1000 * DAY;
  assert.equal(await f.go(), 'remind'); assert.equal(f.issue.state, 'open');
  assert.equal(await f.go(), 'skip');
  f.now += 14 * DAY - 1;
  assert.equal(await f.go(), 'skip'); assert.equal(f.writes.length, 1);
  f.now++;
  assert.equal(await f.go(), 'close'); assert.equal(f.issue.state_reason, 'not_planned');
});

test('dry-run is the default and never writes for either actionable state', async () => {
  for (const action of ['remind', 'close']) {
    const item = record();
    if (action === 'close') reminder(item);
    const f = fixture([item]); f.now = START + 44 * DAY;
    assert.equal(await run({ github: f.github, repo: REPO, issueNumber: 42, now: f.now }), action);
    assert.equal(await f.go({ dryRun: true }), action);
    assert.deepEqual(f.writes, []); assert.equal(f.issue.state, 'open');
  }
});

test('protected reports and human-owned work are exempt even when overdue', async () => {
  const cases = [
    ['#336', item => { item.issue.number = 336; }],
    ['#349', item => { item.issue.number = 349; }],
    ['locked', item => { item.issue.locked = true; }],
    ['pull request', item => { item.issue.pull_request = {}; }],
    ['closed', item => { item.issue.state = 'closed'; }],
    ['assigned', item => { item.issue.assignees = [{ login: 'maintainer' }]; }],
    ['milestone', item => { item.issue.milestone = { number: 1 }; }],
    ['ready', item => { item.issue.labels.push({ name: READY }); }],
    ['not waiting', item => { item.issue.labels = [{ name: 'question' }]; }],
    ['unmanaged', item => { item.comments = []; }],
    ['human comment marker', item => { item.comments[0].user = { login: 'someone', type: 'User' }; }],
    ['wrong bot identity', item => { item.comments[0].user = { login: 'another[bot]', type: 'Bot' }; }],
    ['paused', item => triage(item, { paused: true })],
    ['responded', item => triage(item, { responded: true })],
    ['label not bot-owned', item => triage(item, { owned: ['question'] })],
    ['human label', item => { item.events.push({ event: 'labeled', label: { name: 'question' }, actor: { login: 'maintainer', type: 'User' } }); }],
    ['human unlabel', item => { item.events.push({ event: 'unlabeled', label: { name: 'question' }, actor: { login: 'maintainer', type: 'User' } }); }],
    ['confirmed label', item => { item.issue.labels.push({ name: 'confirmed' }); }],
    ['custom label', item => { item.issue.labels.push({ name: 'keep open' }); }],
    ['previous assignment', item => { item.events.push({ event: 'unassigned', actor: { type: 'User' } }); }],
    ['previous milestone', item => { item.events.push({ event: 'demilestoned', actor: { type: 'User' } }); }],
    ['reopened', item => { item.events.push({ event: 'reopened', actor: { type: 'User' } }); }],
    ['sensitive', item => { item.issue.body += '\nAPI_KEY: sk-123456789012345678901234'; }],
    ['unknown form', item => { item.issue.body = 'Free-form report'; }],
    ['invalid timestamp', item => { item.issue.updated_at = 'unknown'; }],
  ];
  for (const [name, change] of cases) {
    for (const hasReminder of [false, true]) {
      const item = record(); if (hasReminder) reminder(item);
      change(item);
      const f = fixture([item]); f.now = START + 100 * DAY;
      assert.equal(await f.go(), 'skip', `${name}, reminder: ${hasReminder}`);
      assert.deepEqual(f.writes, [], name);
    }
  }
});

test('feature requests stay open with an enhancement label or a valid enhancement form without that label', async () => {
  for (const source of ['label', 'form']) {
    for (const hasReminder of [false, true]) {
      const item = record(); if (hasReminder) reminder(item);
      if (source === 'label') {
        item.issue.labels.push({ name: 'enhancement🚀' });
        triage(item, { owned: [...item.state.owned, 'enhancement🚀'] });
      } else {
        item.issue.body = '### What is inconvenient today?\nI choose the same backup folder repeatedly.\n\n### What would work better?\nRemember the last folder.';
        const report = parseReport(item.issue.body, item.issue.title);
        assert.equal(report.type, 'enhancement'); assert.deepEqual(report.missing, []);
        assert.ok(!item.issue.labels.some(label => label.name === 'enhancement🚀'));
      }
      const f = fixture([item]); f.now = START + 100 * DAY;
      assert.equal(await f.go(), 'skip', `${source}, reminder: ${hasReminder}`);
      assert.deepEqual(f.writes, []); assert.equal(f.issue.state, 'open');
    }
  }
});

test('the author and every trusted maintainer association cancel pending actions without waiting for triage', async () => {
  for (const [login, association] of [['author', 'NONE'], ['maintainer', 'OWNER'], ['maintainer', 'MEMBER'], ['maintainer', 'COLLABORATOR']]) {
    for (const hasReminder of [false, true]) {
      const item = record(); if (hasReminder) reminder(item);
      item.comments.push({ id: 999, user: { login, type: 'User' }, author_association: association,
        body: 'I cannot provide more information yet.', created_at: iso(START + 31 * DAY), updated_at: iso(START + 31 * DAY) });
      const f = fixture([item]); f.now = START + 60 * DAY;
      assert.equal(await f.go(), 'skip', `${login}/${association}`); assert.deepEqual(f.writes, []);
    }
  }
});

test('a body edit cancels pending actions even when its triage workflow never ran', async () => {
  for (const hasReminder of [false, true]) {
    const item = record(); if (hasReminder) reminder(item);
    item.issue.body += '\nAdditional details from the author.';
    item.issue.updated_at = iso(START + 31 * DAY);
    const f = fixture([item]); f.now = START + 60 * DAY;
    assert.equal(await f.go(), 'skip'); assert.deepEqual(f.writes, []);
  }
});

test('forged reminder markers cannot start the close countdown', async () => {
  for (const user of [{ login: 'outsider', type: 'User' }, { login: 'github-actions[bot]', type: 'User' }, { login: 'other[bot]', type: 'Bot' }]) {
    const item = record();
    item.comments.push({ id: 999, user, body: REMINDER, created_at: iso(START - 30 * DAY), updated_at: iso(START - 30 * DAY) });
    const f = fixture([item]);
    assert.equal(await f.go(), 'remind'); assert.equal(f.issue.state, 'open');
    assert.deepEqual(f.writes.map(([action]) => action), ['createComment']);
  }
});

test('the second inspection catches changes before taking its comments snapshot', async () => {
  for (const change of ['assignment', 'edit', 'reply']) {
    for (const hasReminder of [false, true]) {
      const item = record(); if (hasReminder) reminder(item);
      const f = fixture([item]); f.now = START + 60 * DAY;
      const paginate = f.github.paginate;
      let inspections = 0;
      f.github.paginate = async (method, params) => {
        if (method === 'comments' && ++inspections === 2) {
          if (change === 'assignment') item.issue.assignees = [{ login: 'maintainer' }];
          if (change === 'edit') item.issue.body += '\nNew details';
          if (change === 'reply') item.comments.push({ user: { login: 'author', type: 'User' }, body: 'More details' });
          item.issue.updated_at = iso(f.now);
        }
        return paginate(method, params);
      };
      assert.equal(await f.go(), 'skip', change); assert.equal(inspections, 2); assert.deepEqual(f.writes, []);
    }
  }
});

for (const [change, during] of [['edit', 'comments'], ['edit', 'events'], ['reply', 'events'], ['unlabel', 'events'], ['assignment', 'events']]) {
  for (const hasReminder of [true, false]) {
    test(`pagination activity cancels ${hasReminder ? 'closing' : 'reminding'}: ${change} during ${during}`, async () => {
      const item = record(); if (hasReminder) reminder(item);
      const f = fixture([item]); f.now = START + 60 * DAY;
      const paginate = f.github.paginate;
      let inspection = 0, changed = false;
      f.github.paginate = async (method, params) => {
        if (method === 'comments') inspection++;
        const result = await paginate(method, params);
        if (inspection === 2 && method === during && !changed) {
          changed = true;
          if (change === 'edit') item.issue.body += '\nNew details from the author.';
          if (change === 'reply') item.comments.push({ user: { login: 'author', type: 'User' }, body: 'More details',
            created_at: iso(f.now), updated_at: iso(f.now) });
          if (change === 'unlabel') item.issue.labels = item.issue.labels.filter(label => label.name !== WAITING);
          if (change === 'assignment') item.issue.assignees = [{ login: 'maintainer' }];
          item.issue.updated_at = iso(f.now);
        }
        return result;
      };
      assert.equal(await f.go(), 'skip');
      assert.equal(changed, true); assert.deepEqual(f.writes, []);
    });
  }
}

test('failed reads fail closed before any mutation', async () => {
  for (const failure of ['initial issue read', 'issue refresh', 'second inspection refresh', 'comments', 'events']) {
    const f = fixture();
    if (failure !== 'comments' && failure !== 'events') {
      f.onGet = () => {
        const inspections = f.queries.filter(([method]) => method === 'comments').length;
        if (failure === 'initial issue read' || inspections >= (failure === 'issue refresh' ? 1 : 2)) throw new Error('Read unavailable');
      };
    } else {
      const paginate = f.github.paginate;
      f.github.paginate = async (method, params) => {
        if (method === failure) throw new Error('Read unavailable');
        return paginate(method, params);
      };
    }
    await assert.rejects(f.go(), /Read unavailable/); assert.deepEqual(f.writes, []);
  }
});

test('candidate selection returns only actions due now, excluding protected, paused and recent reports', async () => {
  const items = Array.from({ length: 7 }, (_, i) => record(40 + i));
  reminder(items[1]);
  reminder(items[2], START + 43 * DAY);
  triage(items[3], { paused: true });
  items[4].issue.updated_at = items[4].comments[0].updated_at = iso(START + 24 * DAY);
  items[5].issue.labels.push({ name: 'confirmed' });
  items[6].comments = [];
  items.unshift(record(336), record(349));
  const f = fixture(items); f.now = START + 44 * DAY;
  assert.deepEqual(await candidates({ github: f.github, repo: REPO, now: f.now }), [40, 41]);
  assert.deepEqual(f.queries[0], ['issues', { ...REPO, state: 'open', labels: WAITING, sort: 'updated', direction: 'asc', per_page: 100 }]);
  assert.deepEqual(f.writes, []);
});

test('the 256-candidate limit counts actionable reports rather than earlier exempt reports', async () => {
  const excluded = Array.from({ length: 260 }, (_, i) => {
    const item = record(1000 + i); triage(item, { paused: true }); return item;
  });
  const actionable = Array.from({ length: 260 }, (_, i) => record(2000 + i));
  const f = fixture([...excluded, ...actionable]);
  assert.deepEqual(await candidates({ github: f.github, repo: REPO, now: f.now }), actionable.slice(0, 256).map(item => item.issue.number));
  assert.deepEqual(f.writes, []);
});
