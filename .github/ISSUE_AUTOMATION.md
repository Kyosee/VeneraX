# Issue 受理与超时处理 / Issue intake and timeouts

三个提交入口不变。新 Issue 自动分类并收到一条简短初审评论；需要补充时标记
`status: needs-info`，作者回复或编辑正文后回到 `status: triage`，由维护者复查。
日志和附件保持选填。回复直接展示内容，总结以“issue总结：”开头，不显示初审或 AI 辅助标题。
初审不决定优先级与修复结论；独立的定时规则仅处理长期无人回应的补充请求，见下文。
机器人不锁定或删除 Issue。

The three forms stay unchanged. New Issues receive one managed triage comment.
`status: needs-info` asks for missing information; an author update returns the
report to `status: triage` for maintainer review. Attachments remain optional.
Replies show their content directly, with an “Issue summary: ” prefix and no
triage or AI badge. Intake never decides priority or resolution. A separate
scheduled rule handles unanswered requests for information, as described below.
The bot never locks or deletes Issues.

## 等待补充超时 / Information timeout

每天 UTC 02:23（北京时间 10:23）检查一次，实际执行可能稍有延迟。
只检查机器人管理、仍带 `status: needs-info` 且从未收到作者回应的 Issue。

| 情况 | 处理 |
| --- | --- |
| 等待补充至少 30 天，无新活动 | 留一条提醒，不立即关闭 |
| 提醒后至少 14 天仍无回应 | 因信息不足关闭，状态原因为 `not_planned`，不标记已修复 |
| 作者回复或编辑正文 | 取消本轮关闭；正常初审流程将其返回 `status: triage`，即使暂时无法提供信息 |
| 维护者接手、人工标签、更改指派/里程碑、已有负责人或里程碑 | 豁免，不因时间关闭 |
| 功能需求 | 始终豁免，即使暂缺信息 |
| #336、#349 | 按编号永久豁免，只由仓库所有者手动关闭 |

`bug🐞` 是表单分类，不代表已确认问题。维护者确认后的人工标签或接手状态会使其豁免；
也可添加 `no-stale` 等人工标签保留 Issue。已进入待处理的 Bug 和所有功能需求都不会进入
超时流程。旧单首次符合条件也只会收到提醒，完整等满 14 天后才可能关闭。
提醒中说明信息不足不等于已修复，补充后可申请重新打开；不会自动重开或反复关闭人工重开的单。

定时处理与初审共享每个 Issue 的并发组，写入前重新读取状态。发现未被机器人记录的新活动
（包括初审事件运行失败后的正文编辑）时，从严跳过。单次最多处理 256 条可操作的 Issue，
剩余单留待后续执行。GitHub Actions 中可手动运行 **Issue information timeout**；默认
`dry_run=true`，只检查候选单，不发送提醒、不修改状态。定时运行按规则执行实际操作。

The daily check runs at 02:23 UTC, subject to GitHub scheduling delays. Only
bot-managed `status: needs-info` Issues with no author response are eligible.
After at least 30 inactive days, the bot posts one reminder. Only after another
14 days without a response can it close the Issue as `not_planned` for missing
information, never as fixed. Old Issues also receive the full reminder period.
An author reply or description edit cancels the timeout; normal intake returns
the report to `status: triage`, even when the requested information is unavailable.
Maintainer handover, human label decisions (including `no-stale`), assignment or
milestone activity exempt a report. Template bug labels alone do not confirm bugs;
confirmed reports and the ready queue are outside this cleanup. All feature
requests are exempt, including those still missing information.
Issues **#336 and #349 are always excluded by number** and stay under manual control.
Authors may request reopening after adding information. Manually reopened Issues
are exempt; the bot does not reopen them or close them again for inactivity.

Each Issue shares intake's concurrency group and is rechecked before writes.
Unaccounted activity, including edits whose event workflow failed, causes a skip.
At most 256 actionable Issues are handled per run, with the rest left for later
runs. A manual **Issue information timeout** run defaults to `dry_run=true`, which
only lists pending actions. Scheduled runs perform reminders and closures.

可打开 [流程预览页](issue-flow-preview.html) 查看各场景；下载后用浏览器打开即可，无需联网。
Download the [flow preview](issue-flow-preview.html) and open it locally in a browser; it works offline.

## 配置 API / Configure the API

打开仓库 **Settings → Secrets and variables → Actions**。
Open the repository's **Settings → Secrets and variables → Actions**.

| 位置 / Location | 名称 / Name | 内容 / Value |
| --- | --- | --- |
| Secrets | `ISSUE_AI_API_URL` | 完整 HTTPS 地址，以 `/chat/completions` 或 `/responses` 结尾 / Full HTTPS Chat Completions or Responses endpoint |
| Secrets | `ISSUE_AI_API_KEY` | 模型服务的 API Key，不带 `Bearer ` / Provider API key, without `Bearer ` |
| Variables | `ISSUE_AI_MODEL` | 服务商实际支持的模型 ID / Exact model ID offered by the provider |
| Variables | `ISSUE_AI_ENABLED` | `true` 启用；`false` 或留空仅运行固定规则 / `true` enables AI; otherwise only fixed rules run |

按地址自动选择协议，无需额外开关。填写服务商支持的完整端点，不能只填域名或 `/v1`。
两种方式均使用同一份提示词与安全校验，要求模型返回 JSON，且使用非流式响应。

The URL selects the protocol automatically; no extra setting is needed. Supply the
provider's full endpoint, not just a host or `/v1`. Both protocols share the prompt
and output validation and require a non-streaming JSON answer from the model.

| 协议 / Protocol | 地址示例 / Example URL | 请求与返回 / Request and response |
| --- | --- | --- |
| Chat Completions | `https://api.example.com/v1/chat/completions` | `messages`、`max_tokens` → `choices[0].message.content` |
| Responses | `https://api.example.com/v1/responses` | `input`、`max_output_tokens`、`store: false` → `output` 中已完成的 assistant `output_text` / Completed assistant text in `output` |

仅处理最终文本，不执行模型工具调用；未完成、拒答或格式无效时回退固定规则。
不自动切换另一端点重试。Anthropic Messages 等其他原生协议仍需兼容端点。
填 Key 后不会立即调用，也不会扫描历史 Issue；新建的 Issue 才自动受理。

Only final text is used; model tool calls are never executed. Incomplete, refused
or invalid output falls back to fixed rules without retrying another endpoint.
Other native protocols, such as Anthropic Messages, need a compatible endpoint.
Adding a key does not call the model or backfill old Issues.

基础标签与评论使用 Actions 自动提供的 `GITHUB_TOKEN`，无需额外 PAT。
启用仓库 Actions 即可；组织限制写权限时，由管理员允许此工作流的 `issues: write`。
API 未配置、超时、限流或输出无效时，保留规则初审，不阻止用户反馈。

Labels and comments use the built-in `GITHUB_TOKEN`; no PAT is needed. Enable
Actions and allow the workflow's `issues: write` permission under applicable
organization policies. Missing configuration, timeouts, rate limits or invalid
AI output fall back to rule-based intake.

## 提示词与数据 / Prompt and data

默认提示词在 [issue-triage-prompt.md](issue-triage-prompt.md)，**公开可见**，无需另外填写。
它约束回复范围、语言、简洁程度及权限，并遵守项目用户协议与免责声明的原则。
AI 跟随正文叙述的主要语言，不让双语标题、选项或代码日志干扰，也不限于中英文。
固定受理文案提供中文/英文两套。不要把 Key、私有地址或账户资料写进提示词。

The default [prompt](issue-triage-prompt.md) is **public** and works without extra
configuration. It defines scope, language, brevity and permissions consistently
with the project's User Agreement and Disclaimer. Never put credentials or private
account details in the prompt. AI follows the main narrative language, including
languages beyond Chinese and English; bilingual headings, choices and code/log
blocks do not determine it. Fixed intake messages are available in Chinese and English.

开启 AI 后，公开 Issue 标题、限长正文、少量作者/维护者补充会发给所配置服务商。
发送前移除链接、提及及 HTML。检测到常见密钥、邮箱、带标签的电话/账号、私人用户目录、
明确源名称/地址字段或安全问题时，本次不发给 AI，提醒编辑公开原文并转人工；同时清除
机器人评论和状态标记中缓存的旧 AI 答案。模型输出也经过同类检测。
检测不能覆盖所有写法，且不会替用户修改原文或撤回已发给服务商的数据；提交者仍需自行脱敏。
机器人不下载附件，不自动打开用户链接，不上传仓库密钥或读取私人应用数据。

When enabled, the configured provider receives bounded public Issue text and a few
author/maintainer updates. Links, mentions and HTML are removed. Recognizable
credentials, emails, labeled phone/account details, private user paths, explicit
source-name/address fields and security reports bypass AI for that update. The bot
asks the author to edit the public text and removes cached AI replies from both its
comment and state marker. Model output uses the same checks. Detection cannot cover
every spelling, edit the original report or retract data already sent to a provider;
users must redact their own reports. Attachments and user links are not fetched.
Repository secrets and private application files are not read into model messages.

明确属于第三方源站、账号、脚本自身的问题，初审只提示支持范围；维护者确认后可说明原因并关闭。
“源管理崩溃”“JS 引擎报错”“WebDAV 同步失败”仍可能是应用缺陷，不能按关键词自动拒绝。

Reports clearly about third-party sites, accounts or scripts receive a scope reminder;
a maintainer may explain and close them after review. Source-management crashes,
JS-engine errors and WebDAV sync failures may still be app defects; keywords alone
never cause automatic rejection or closure.

可信上下文来自当前默认分支的 README 协议与基本信息、`doc/guide.zh.md` 或
`doc/guide.en.md`。本地按关键词选最多 3 段相关内容，输出引用指向实际读取的提交。
README 中的编号条款按段落检索，避免长章节开头挤掉真正相关的说明；上下文总预算不变。
没有依据时交人工；默认分支文档不等于用户安装版本。首版不做全仓库代码分析或重复单自动判定。

Context comes from the default branch's README policy/project information and the
Chinese or English app guide. Local keyword matching selects at most three
excerpts; citations point to the inspected commit. Missing evidence goes to a
maintainer. Numbered README clauses are searched individually so relevant content
is not lost behind a long section introduction, without increasing the context budget.
Default-branch docs do not necessarily describe the installed release.
The initial version does not analyze the full codebase or automatically decide duplicates.

## 用量与人工接管 / Usage and handover

- 默认每单最多 2 次模型调用：初答及作者补充后的复查；固定缺项清楚时先不用 AI。
  最多 700 输出 token，25 秒超时；文档片段合计不超过 3,000 字符、协议片段
  1,300 字符、正文 3,500 字符、补充 1,200 字符；另带最多 600 字符的正文语言样本。
  Responses 的输出上限包含推理 token，宜选适合简短回答的模型。
  字符上限不是精确 token 或费用承诺。
- 提供商仍可能对失败请求计费。请在服务商后台设置额度；关闭 `ISSUE_AI_ENABLED`
  可立即阻止后续 AI 调用，保留基本受理。Actions 和模型服务各按自己的规则计费。
- 自动 AI 调用前检查滚动 24 小时新单数：同一作者第 4 条或全仓第 21 条起，保留规则受理、暂不调用 AI。
  包含当前单和已关闭单，不含 PR；查询失败或最近 100 条仍不足以判断时也降级，不消耗该单调用次数。
  限流不拦截提交，也不永久暂停；有写权限的 `/triage retry` 可显式允许一次调用，但不能绕过隐私检查。
  这只是批量开单节流，不是所有历史单补充、重试或总费用的硬上限，仍须设置服务商额度。
- 维护者回复、指派或更改受管理标签后，停止自动追问及覆盖分类。
  有仓库写权限的维护者可评论 `/triage pause` 暂停、`/triage retry` 显式重审。
  重审可超出默认次数并产生一次费用，不要用机器人循环发此命令。
- 作者已回应就回待处理，即使说“暂时无法提供”。机器人的等待状态不代表确认了 Bug。
  已有评论会更新，编辑评论不保证发送通知，请在 Issues 列表筛选队列标签。

- At most two model calls per Issue by default: initial response and one follow-up.
  Clear required-field gaps are handled without AI. Responses have a 700-token cap
  and 25-second timeout; context has the character limits listed above, including a
  600-character narrative sample for language detection. The Responses
  cap includes reasoning tokens, so choose a model suited to concise answers.
- Providers may charge failed requests. Set a provider-side budget. Disabling
  `ISSUE_AI_ENABLED` stops future AI calls while preserving intake. Actions and the
  model provider apply their own billing rules.
- Before automatic AI calls, count new Issues in a rolling 24-hour window. From
  the author's fourth or the repository's twenty-first Issue, keep fixed intake
  without calling AI. Count the current and closed Issues, exclude PRs. Failed or
  incomplete queries (at most 100 records) also defer AI without spending the
  per-Issue call budget or permanently pausing intake. A writer's explicit retry
  permits one call beyond this throttle but never bypasses privacy checks. This is
  not a hard daily call or billing cap covering old-Issue updates and manual retries.
- Maintainer replies, assignment or managed-label changes stop automatic questioning
  and classification overrides. Repository writers can use `/triage pause` or
  `/triage retry`; retry explicitly permits another potentially billable call.
- Author updates return to triage even if information is unavailable. Intake status
  does not confirm a bug. Comment edits may not notify users; use queue labels.

## 验证 / Validation

```sh
node --test .github/scripts/issue-triage.test.mjs .github/scripts/issue-timeout.test.mjs
```

测试模拟 GitHub 和模型接口，不调用真实收费 API。部署后可查看 Actions 的
**Issue triage** 运行记录。失败日志仅记录固定错误类别或 HTTP 状态，不输出模型响应、Issue 原文或凭据。
`Invalid API URL` 表示地址格式不符；`AI HTTP 401/403` 检查 Key 与权限，
`AI HTTP 404` 检查接口路径与模型，`AI HTTP 429` 检查服务商额度/限流；
`Invalid AI JSON/content/result` 表示返回内容不符合协议或安全校验；`AI response incomplete`
表示模型未完成输出（可能达到 token 上限），可检查服务商状态或改用适合简短回答的模型。
`AI triage skipped` 表示处理期间反馈发生变化，已丢弃过时分析；日志会注明发生阶段。
`AI triage deferred` 表示近期新单限流或无法可靠计数，本次只做规则受理。
修正配置后，有写权限的维护者可在原单评论 `/triage retry` 验证。

Tests mock GitHub and model requests without using a paid API. After deployment,
inspect the **Issue triage** Actions runs. Failures log only fixed error categories
or HTTP status codes, without provider responses, Issue text or credentials.
Check the endpoint format for `Invalid API URL`, credentials/permissions for
HTTP 401/403, path/model for 404, and provider quota/rate limits for 429. Invalid
AI JSON/content/result means protocol or output validation failed. `AI response incomplete`
means generation did not finish, possibly due to the token cap; check the provider
status or use a model suited to concise answers. `AI triage skipped` identifies the
stage where Issue changes caused stale analysis to be discarded. `AI triage deferred`
means recent-intake throttling or uncertain counts kept this run on fixed rules. After fixing configuration, a
repository writer can comment `/triage retry` on the same Issue.
