import fs from 'node:fs/promises'
import fsSync from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import vm from 'node:vm'

class ComicSource {
  __bindData(dataPath, data) {
    this.__dataPath = dataPath
    this.__data = data && typeof data === 'object' ? data : {}
  }

  loadData(key) {
    return this.__data?.[key] ?? null
  }

  saveData(key, value) {
    this.__data = this.__data && typeof this.__data === 'object' ? this.__data : {}
    this.__data[key] = value
    this.__flushData()
  }

  deleteData(key) {
    if (this.__data && typeof this.__data === 'object') {
      delete this.__data[key]
      this.__flushData()
    }
  }

  __flushData() {
    if (!this.__dataPath) return
    try {
      fsSync.writeFileSync(this.__dataPath, JSON.stringify(this.__data))
    } catch (error) {
      console.error('[source]', 'failed to persist source data', error)
    }
  }

  loadSetting(key) {
    if (!key) return null
    if (this.__data?.settings && Object.hasOwn(this.__data.settings, key)) {
      return this.__data.settings[key]
    }
    const setting = this.settings?.[key]
    if (setting && typeof setting === 'object' && Object.hasOwn(setting, 'default')) {
      return setting.default
    }
    return null
  }
}

function Comic({
  id,
  title,
  subtitle,
  subTitle,
  cover,
  tags,
  description,
  maxPage,
  language,
  favoriteId,
  stars
}) {
  this.id = id
  this.title = title
  this.subtitle = subtitle ?? subTitle
  this.subTitle = subTitle ?? subtitle
  this.cover = cover
  this.tags = tags
  this.description = description
  this.maxPage = maxPage
  this.language = language
  this.favoriteId = favoriteId
  this.stars = stars
}

function ComicDetails({
  title,
  subtitle,
  subTitle,
  cover,
  description,
  tags,
  chapters,
  isFavorite,
  subId,
  thumbnails,
  recommend,
  commentCount,
  likesCount,
  isLiked,
  uploader,
  updateTime,
  uploadTime,
  url,
  stars,
  maxPage,
  comments
}) {
  this.title = title
  this.subtitle = subtitle ?? subTitle
  this.subTitle = subTitle ?? subtitle
  this.cover = cover
  this.description = description
  this.tags = tags
  this.chapters = chapters
  this.isFavorite = isFavorite
  this.subId = subId
  this.thumbnails = thumbnails
  this.recommend = recommend
  this.commentCount = commentCount
  this.likesCount = likesCount
  this.isLiked = isLiked
  this.uploader = uploader
  this.updateTime = updateTime
  this.uploadTime = uploadTime
  this.url = url
  this.stars = stars
  this.maxPage = maxPage
  this.comments = comments
}

function Comment({
  userName,
  avatar,
  content,
  time,
  replyCount,
  id,
  isLiked,
  score,
  voteStatus
}) {
  this.userName = userName
  this.avatar = avatar
  this.content = content
  this.time = time
  this.replyCount = replyCount
  this.id = id
  this.isLiked = isLiked
  this.score = score
  this.voteStatus = voteStatus
}

function log(level, title, content) {
  console.error('[source]', level, title, content)
}

function randomInt(min, max) {
  const floorMin = Math.ceil(Number(min) || 0)
  const floorMax = Math.floor(Number(max) || 0)
  if (floorMax <= floorMin) return floorMin
  return Math.floor(Math.random() * (floorMax - floorMin + 1)) + floorMin
}

function json(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`)
}

function fail(error) {
  json({ ok: false, error: error instanceof Error ? error.message : String(error) })
  process.exitCode = 1
}

function normalizeHeaders(headers) {
  return Object.fromEntries(headers.entries())
}

async function sendRequest(method, url, headers = {}, data = null) {
  const response = await fetch(url, {
    method,
    headers,
    body: data ?? undefined
  })
  return {
    status: response.status,
    headers: normalizeHeaders(response.headers),
    body: await response.text()
  }
}

const cookieStore = new Map()

const Network = {
  sendRequest,
  get: (url, headers) => sendRequest('GET', url, headers),
  post: (url, headers, data) => sendRequest('POST', url, headers, data),
  put: (url, headers, data) => sendRequest('PUT', url, headers, data),
  patch: (url, headers, data) => sendRequest('PATCH', url, headers, data),
  delete: (url, headers) => sendRequest('DELETE', url, headers),
  getCookies: (url) => cookieStore.get(cookieOrigin(url)) ?? [],
  setCookies: (url, cookies = []) => {
    cookieStore.set(cookieOrigin(url), Array.isArray(cookies) ? cookies : [])
  }
}

const Convert = {
  encodeUtf8: (value) => new TextEncoder().encode(String(value ?? '')),
  decodeUtf8: (value) => new TextDecoder().decode(toUint8Array(value)),
  encodeBase64: (value) => Buffer.from(toUint8Array(value)).toString('base64'),
  decodeBase64: (value) => Uint8Array.from(Buffer.from(String(value ?? ''), 'base64')),
  md5: (value) => digest('md5', value),
  sha1: (value) => digest('sha1', value),
  sha256: (value) => digest('sha256', value),
  sha512: (value) => digest('sha512', value),
  hmac: (key, value, hash) => Uint8Array.from(crypto.createHmac(hash, toUint8Array(key)).update(toUint8Array(value)).digest()),
  hmacString: (key, value, hash) =>
    crypto.createHmac(hash, toUint8Array(key)).update(toUint8Array(value)).digest('hex'),
  decryptAesEcb: (value, key) => aesEcb(value, key, false),
  encryptAesEcb: (value, key) => aesEcb(value, key, true),
  decryptAesCbc: (value, key, iv) => aesCbc(value, key, iv, false),
  encryptAesCbc: (value, key, iv) => aesCbc(value, key, iv, true),
  hexEncode: (value) => Buffer.from(toUint8Array(value)).toString('hex')
}

function toUint8Array(value) {
  if (value instanceof Uint8Array) return value
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
  if (value instanceof ArrayBuffer) return new Uint8Array(value)
  if (Object.prototype.toString.call(value) === '[object ArrayBuffer]') return new Uint8Array(value)
  if (Array.isArray(value)) return Uint8Array.from(value)
  return new TextEncoder().encode(String(value ?? ''))
}

function digest(algorithm, value) {
  return Uint8Array.from(crypto.createHash(algorithm).update(toUint8Array(value)).digest())
}

function aesCbc(value, key, iv, encrypt) {
  const keyBytes = Buffer.from(toUint8Array(key))
  const ivBytes = Buffer.from(toUint8Array(iv))
  const algorithm = `aes-${keyBytes.length * 8}-cbc`
  const cipher = encrypt
    ? crypto.createCipheriv(algorithm, keyBytes, ivBytes)
    : crypto.createDecipheriv(algorithm, keyBytes, ivBytes)
  cipher.setAutoPadding(false)
  return Uint8Array.from(Buffer.concat([cipher.update(Buffer.from(toUint8Array(value))), cipher.final()]))
}

function aesEcb(value, key, encrypt) {
  const keyBytes = Buffer.from(toUint8Array(key))
  const algorithm = `aes-${keyBytes.length * 8}-ecb`
  const cipher = encrypt
    ? crypto.createCipheriv(algorithm, keyBytes, null)
    : crypto.createDecipheriv(algorithm, keyBytes, null)
  cipher.setAutoPadding(false)
  return Uint8Array.from(Buffer.concat([cipher.update(Buffer.from(toUint8Array(value))), cipher.final()]))
}

const voidTags = new Set([
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr'
])
const rawTextTags = new Set(['script', 'style', 'textarea', 'title'])

class HtmlDocument {
  constructor(html) {
    this.root = parseHtml(String(html ?? ''))
  }

  querySelector(query) {
    return this.querySelectorAll(query)[0] ?? null
  }

  querySelectorAll(query) {
    return querySelectorAll(this.root, query, false).map((node) => new HtmlElement(node))
  }

  getElementById(id) {
    const target = String(id)
    const node = descendants(this.root).find((item) => item.attributes.id === target)
    return node ? new HtmlElement(node) : null
  }

  dispose() {}
}

class HtmlElement {
  constructor(node) {
    this.node = node
  }

  get text() {
    return textContent(this.node)
  }

  get attributes() {
    return { ...this.node.attributes }
  }

  get innerHTML() {
    return this.node.children.map(serializeNode).join('')
  }

  get parent() {
    return this.node.parent?.type === 'element' ? new HtmlElement(this.node.parent) : null
  }

  get classNames() {
    return splitClasses(this.node.attributes.class)
  }

  get id() {
    return this.node.attributes.id ?? null
  }

  get localName() {
    return this.node.tagName
  }

  get children() {
    return this.node.children
      .filter((child) => child.type === 'element')
      .map((child) => new HtmlElement(child))
  }

  get nodes() {
    return this.node.children.map((child) => new HtmlNode(child))
  }

  get previousElementSibling() {
    const sibling = elementSibling(this.node, -1)
    return sibling ? new HtmlElement(sibling) : null
  }

  get nextElementSibling() {
    const sibling = elementSibling(this.node, 1)
    return sibling ? new HtmlElement(sibling) : null
  }

  querySelector(query) {
    return this.querySelectorAll(query)[0] ?? null
  }

  querySelectorAll(query) {
    return querySelectorAll(this.node, query, false).map((node) => new HtmlElement(node))
  }
}

class HtmlNode {
  constructor(node) {
    this.node = node
  }

  get text() {
    return textContent(this.node)
  }

  get type() {
    return this.node.type
  }

  toElement() {
    return this.node.type === 'element' ? new HtmlElement(this.node) : null
  }
}

function createNode(type, values = {}) {
  return {
    type,
    tagName: values.tagName ?? '',
    attributes: values.attributes ?? {},
    value: values.value ?? '',
    children: [],
    parent: null
  }
}

function parseHtml(html) {
  const root = createNode('document')
  const stack = [root]
  let index = 0

  while (index < html.length) {
    const parent = stack[stack.length - 1]
    if (rawTextTags.has(parent.tagName)) {
      const close = html.toLowerCase().indexOf(`</${parent.tagName}`, index)
      const end = close === -1 ? html.length : close
      appendNode(parent, createNode('text', { value: html.slice(index, end) }))
      index = end
      if (close === -1) break
    }

    if (html.startsWith('<!--', index)) {
      const end = html.indexOf('-->', index + 4)
      const valueEnd = end === -1 ? html.length : end
      appendNode(parent, createNode('comment', { value: html.slice(index + 4, valueEnd) }))
      index = end === -1 ? html.length : end + 3
      continue
    }

    if (html[index] !== '<') {
      const next = html.indexOf('<', index)
      const end = next === -1 ? html.length : next
      appendNode(parent, createNode('text', { value: html.slice(index, end) }))
      index = end
      continue
    }

    const tagEnd = findTagEnd(html, index + 1)
    if (tagEnd === -1) {
      appendNode(parent, createNode('text', { value: html.slice(index) }))
      break
    }

    const rawTag = html.slice(index + 1, tagEnd).trim()
    index = tagEnd + 1
    if (!rawTag || rawTag.startsWith('!') || rawTag.startsWith('?')) continue

    if (rawTag.startsWith('/')) {
      closeTag(stack, rawTag.slice(1).trim().split(/\s+/)[0]?.toLowerCase())
      continue
    }

    const selfClosing = rawTag.endsWith('/')
    const body = selfClosing ? rawTag.slice(0, -1).trim() : rawTag
    const tagName = body.split(/\s+/, 1)[0]?.toLowerCase()
    if (!tagName) continue

    const attrText = body.slice(tagName.length)
    const node = createNode('element', {
      tagName,
      attributes: parseAttributes(attrText)
    })
    appendNode(parent, node)
    if (!selfClosing && !voidTags.has(tagName)) stack.push(node)
  }

  return root
}

function appendNode(parent, node) {
  if (!node.value && node.type === 'text') return
  node.parent = parent
  parent.children.push(node)
}

function findTagEnd(html, start) {
  let quote = null
  for (let index = start; index < html.length; index += 1) {
    const char = html[index]
    if (quote) {
      if (char === quote) quote = null
    } else if (char === '"' || char === "'") {
      quote = char
    } else if (char === '>') {
      return index
    }
  }
  return -1
}

function closeTag(stack, tagName) {
  if (!tagName) return
  for (let index = stack.length - 1; index > 0; index -= 1) {
    if (stack[index].tagName === tagName) {
      stack.length = index
      return
    }
  }
}

function parseAttributes(input) {
  const attrs = {}
  const pattern = /([^\s"'<>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g
  let match
  while ((match = pattern.exec(input)) !== null) {
    attrs[match[1].toLowerCase()] = decodeEntities(match[2] ?? match[3] ?? match[4] ?? '')
  }
  return attrs
}

function querySelectorAll(root, selector) {
  const groups = splitSelectorGroups(selector).map(parseSelector).filter((group) => group.length > 0)
  const results = []
  const seen = new Set()
  for (const group of groups) {
    for (const node of selectGroup(root, group)) {
      if (!seen.has(node)) {
        seen.add(node)
        results.push(node)
      }
    }
  }
  return results
}

function selectGroup(root, parts) {
  let current = [root]
  for (const part of parts) {
    const next = []
    for (const node of current) {
      const candidates = part.combinator === '>' ? elementChildren(node) : descendants(node)
      for (const candidate of candidates) {
        if (matchesSimple(candidate, part.simple)) next.push(candidate)
      }
    }
    current = next
  }
  return current
}

function splitSelectorGroups(selector) {
  const groups = []
  let current = ''
  let bracketDepth = 0
  let quote = null
  for (const char of String(selector ?? '')) {
    if (quote) {
      if (char === quote) quote = null
      current += char
      continue
    }
    if (char === '"' || char === "'") {
      quote = char
    } else if (char === '[') {
      bracketDepth += 1
    } else if (char === ']') {
      bracketDepth -= 1
    } else if (char === ',' && bracketDepth === 0) {
      groups.push(current.trim())
      current = ''
      continue
    }
    current += char
  }
  if (current.trim()) groups.push(current.trim())
  return groups
}

function parseSelector(selector) {
  const parts = []
  let index = 0
  let combinator = ' '
  while (index < selector.length) {
    while (selector[index] === ' ') index += 1
    if (selector[index] === '>') {
      combinator = '>'
      index += 1
      continue
    }

    const start = index
    let bracketDepth = 0
    let quote = null
    while (index < selector.length) {
      const char = selector[index]
      if (quote) {
        if (char === quote) quote = null
      } else if (char === '"' || char === "'") {
        quote = char
      } else if (char === '[') {
        bracketDepth += 1
      } else if (char === ']') {
        bracketDepth -= 1
      } else if (bracketDepth === 0 && (char === ' ' || char === '>')) {
        break
      }
      index += 1
    }

    const raw = selector.slice(start, index).trim()
    if (raw) {
      parts.push({ combinator, simple: parseSimpleSelector(raw) })
      combinator = ' '
    }
  }
  return parts
}

function parseSimpleSelector(raw) {
  const attrs = []
  const attrPattern = /\[([^\]=~|^$*\s]+)\s*(?:([*^$~|]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\]]*)))?\]/g
  const clean = raw.replace(attrPattern, (_, name, operator, quotedA, quotedB, bare) => {
    attrs.push({
      name: String(name).toLowerCase(),
      operator: operator ?? 'exists',
      value: stripQuotes(String(quotedA ?? quotedB ?? bare ?? '').trim())
    })
    return ''
  })
  const nth = clean.match(/:nth-child\((\d+)\)/)
  const withoutPseudo = clean.replace(/:nth-child\(\d+\)/g, '')
  const tag = withoutPseudo.match(/^[a-zA-Z][\w-]*|\*/)
  const id = withoutPseudo.match(/#([\w-]+)/)
  const classes = [...withoutPseudo.matchAll(/\.([\w-]+)/g)].map((match) => match[1])
  return {
    tag: tag && tag[0] !== '*' ? tag[0].toLowerCase() : null,
    id: id?.[1] ?? null,
    classes,
    attrs,
    nthChild: nth ? Number(nth[1]) : null
  }
}

function matchesSimple(node, simple) {
  if (node.type !== 'element') return false
  if (simple.tag && node.tagName !== simple.tag) return false
  if (simple.id && node.attributes.id !== simple.id) return false
  const classes = splitClasses(node.attributes.class)
  if (simple.classes.some((className) => !classes.includes(className))) return false
  if (simple.nthChild && elementIndex(node) !== simple.nthChild) return false
  return simple.attrs.every((attr) => matchesAttribute(node.attributes[attr.name], attr))
}

function matchesAttribute(value, attr) {
  if (attr.operator === 'exists') return value != null
  if (value == null) return false
  const actual = String(value)
  const expected = attr.value
  switch (attr.operator) {
    case '=':
      return actual === expected
    case '*=':
      return actual.includes(expected)
    case '^=':
      return actual.startsWith(expected)
    case '$=':
      return actual.endsWith(expected)
    case '~=':
      return actual.split(/\s+/).includes(expected)
    case '|=':
      return actual === expected || actual.startsWith(`${expected}-`)
    default:
      return false
  }
}

function stripQuotes(value) {
  return value.replace(/^['"]|['"]$/g, '')
}

function descendants(node) {
  const result = []
  for (const child of node.children) {
    if (child.type === 'element') {
      result.push(child)
      result.push(...descendants(child))
    }
  }
  return result
}

function elementChildren(node) {
  return node.children.filter((child) => child.type === 'element')
}

function splitClasses(value) {
  return String(value ?? '')
    .split(/\s+/)
    .filter(Boolean)
}

function elementIndex(node) {
  if (!node.parent) return 0
  return elementChildren(node.parent).indexOf(node) + 1
}

function elementSibling(node, direction) {
  if (!node.parent) return null
  const siblings = elementChildren(node.parent)
  const index = siblings.indexOf(node)
  return siblings[index + direction] ?? null
}

function textContent(node) {
  if (node.type === 'text' || node.type === 'comment') return decodeEntities(node.value)
  return node.children.map(textContent).join('')
}

function serializeNode(node) {
  if (node.type === 'text') return escapeText(node.value)
  if (node.type === 'comment') return `<!--${node.value}-->`
  if (node.type !== 'element') return node.children.map(serializeNode).join('')
  const attrs = Object.entries(node.attributes)
    .map(([key, value]) => (value === '' ? key : `${key}="${escapeAttr(value)}"`))
    .join(' ')
  const open = attrs ? `<${node.tagName} ${attrs}>` : `<${node.tagName}>`
  if (voidTags.has(node.tagName)) return open
  return `${open}${node.children.map(serializeNode).join('')}</${node.tagName}>`
}

function decodeEntities(value) {
  return String(value)
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCodePoint(Number.parseInt(code, 16)))
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
}

function escapeText(value) {
  return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function escapeAttr(value) {
  return escapeText(value).replace(/"/g, '&quot;')
}

function cookieOrigin(url) {
  try {
    return new URL(url).origin
  } catch {
    return String(url)
  }
}

function createContext() {
  const sandbox = {
    Comic,
    ComicDetails,
    Comment,
    ComicSource,
    Convert,
    HtmlDocument,
    HtmlElement,
    HtmlNode,
    log,
    Network,
    randomInt,
    URL,
    URLSearchParams,
    TextDecoder,
    TextEncoder,
    atob,
    btoa,
    fetch,
    setTimeout,
    clearTimeout,
    console: {
      log: (...args) => console.error('[source]', ...args),
      warn: (...args) => console.error('[source]', ...args),
      error: (...args) => console.error('[source]', ...args)
    }
  }
  sandbox.globalThis = sandbox
  return vm.createContext(sandbox)
}

async function loadSource(sourcePath, { runInit = true } = {}) {
  const code = await fs.readFile(sourcePath, 'utf8')
  const match = code.match(/\bclass\s+([A-Za-z_$][\w$]*)\s+extends\s+ComicSource\b/)
  if (!match) {
    throw new Error('source must define class extends ComicSource')
  }

  const context = createContext()
  const script = new vm.Script(`${code}\nglobalThis.__SourceClass = ${match[1]};`, {
    filename: sourcePath
  })
  script.runInContext(context, { timeout: 5000 })
  const SourceClass = context.__SourceClass
  const source = new SourceClass()
  source.__bindData(dataPathForSource(sourcePath), await readSourceData(sourcePath))
  if (runInit && typeof source.init === 'function') {
    await source.init()
  }
  return source
}

function dataPathForSource(sourcePath) {
  return path.join(path.dirname(sourcePath), `${path.basename(sourcePath, '.js')}.data`)
}

async function readSourceData(sourcePath) {
  try {
    const text = await fs.readFile(dataPathForSource(sourcePath), 'utf8')
    const data = JSON.parse(text)
    return data && typeof data === 'object' ? data : {}
  } catch {
    return {}
  }
}

function text(value) {
  if (value == null) return null
  return String(value)
}

function normalizeComic(item, index) {
  const raw = item && typeof item === 'object' ? item : { value: item }
  const title = text(raw.title ?? raw.name ?? raw.label ?? raw.id ?? `Comic ${index + 1}`) ?? ''
  const id = text(raw.id ?? raw.comicId ?? raw.url ?? raw.link ?? title) ?? title
  const tags = Array.isArray(raw.tags)
    ? raw.tags.map((tag) => String(tag))
    : raw.tag
      ? [String(raw.tag)]
      : []

  return {
    id,
    title,
    subtitle: text(raw.subtitle ?? raw.subTitle ?? raw.description ?? raw.author),
    cover: text(raw.cover ?? raw.coverUrl ?? raw.thumbnail ?? raw.pic ?? raw.image),
    url: text(raw.url ?? raw.link),
    tags,
    raw
  }
}

async function search(source, keyword, page) {
  if (typeof source.search?.load === 'function') {
    const result = await source.search.load(keyword, [], page)
    return normalizeSearchResult(result)
  }
  if (typeof source.search?.loadNext === 'function') {
    const result = await source.search.loadNext(keyword, [], null)
    return normalizeSearchResult(result)
  }
  throw new Error('source does not implement search.load')
}

async function comicInfo(source, comicId) {
  if (typeof source.comic?.loadInfo !== 'function') {
    throw new Error('source does not implement comic.loadInfo')
  }
  const result = await source.comic.loadInfo(comicId)
  return normalizeComicInfo(result, comicId)
}

async function comicPages(source, comicId, episodeId) {
  if (typeof source.comic?.loadEp !== 'function') {
    throw new Error('source does not implement comic.loadEp')
  }
  const result = await source.comic.loadEp(comicId, episodeId)
  const images = Array.isArray(result?.images)
    ? result.images
    : Array.isArray(result?.pages)
      ? result.pages
      : Array.isArray(result?.data)
        ? result.data
        : Array.isArray(result)
          ? result
          : []

  return {
    images: images.map((image) => String(image)).filter(Boolean)
  }
}

function sourceManifest(source) {
  return {
    explore_pages: normalizeExplorePages(source.explore),
    category: normalizeCategory(source.category)
  }
}

function normalizeExplorePages(value) {
  if (!Array.isArray(value)) return []
  return value
    .map((page, index) => {
      const raw = page && typeof page === 'object' ? page : { title: page }
      return {
        title: text(raw.title ?? raw.name ?? raw.label ?? `Page ${index + 1}`) ?? `Page ${index + 1}`,
        page_type: text(raw.type)
      }
    })
    .filter((page) => page.title)
}

function normalizeCategory(value) {
  if (!value || typeof value !== 'object') return null
  const parts = Array.isArray(value.parts)
    ? value.parts
    : Array.isArray(value.categories)
      ? [{ name: value.title ?? value.name, categories: value.categories, categoryParams: value.categoryParams }]
      : []
  const normalizedParts = parts.map(normalizeCategoryPart).filter((part) => part.items.length > 0)
  if (normalizedParts.length === 0) return null
  return {
    key: text(value.key ?? value.title ?? value.name),
    title: text(value.title ?? value.name ?? value.key ?? '分类') ?? '分类',
    parts: normalizedParts
  }
}

function normalizeCategoryPart(part, index) {
  const raw = part && typeof part === 'object' ? part : { name: `分类 ${index + 1}` }
  const categories = normalizeCategoryItems(raw.categories ?? raw.items ?? raw.values)
  const params = normalizeStringList(raw.categoryParams ?? raw.params ?? raw.parameters)
  return {
    title: text(raw.name ?? raw.title ?? raw.label ?? `分类 ${index + 1}`) ?? `分类 ${index + 1}`,
    item_type: text(raw.itemType ?? raw.type),
    items: categories.map((item, itemIndex) => ({
      label: item.label,
      param: item.param ?? params[itemIndex] ?? null
    }))
  }
}

function normalizeCategoryItems(value) {
  if (Array.isArray(value)) {
    return value
      .map((item) => {
        if (item && typeof item === 'object') {
          const label = text(item.label ?? item.title ?? item.name ?? item.text ?? item.value ?? item.id)
          return label ? { label, param: text(item.param ?? item.value ?? item.id) } : null
        }
        const label = text(item)
        return label ? { label, param: null } : null
      })
      .filter(Boolean)
  }
  if (value && typeof value === 'object') {
    return Object.entries(value).map(([key, label]) => ({
      label: text(label) ?? key,
      param: key
    }))
  }
  return []
}

function normalizeStringList(value) {
  if (Array.isArray(value)) return value.map((item) => String(item)).filter(Boolean)
  if (value && typeof value === 'object') return Object.keys(value)
  return []
}

function normalizeSearchResult(result) {
  const comics = Array.isArray(result?.comics)
    ? result.comics
    : Array.isArray(result?.data)
      ? result.data
      : Array.isArray(result)
        ? result
        : []

  return {
    max_page: result?.maxPage ?? result?.max_page ?? null,
    next: result?.next ?? null,
    comics: comics.map(normalizeComic)
  }
}

function normalizeComicInfo(result, fallbackId) {
  const raw = result && typeof result === 'object' ? result : { value: result }
  const title = text(raw.title ?? raw.name ?? raw.label ?? fallbackId) ?? fallbackId
  return {
    id: text(raw.id ?? raw.comicId ?? fallbackId) ?? fallbackId,
    title,
    subtitle: text(raw.subtitle ?? raw.subTitle ?? raw.author),
    cover: text(raw.cover ?? raw.coverUrl ?? raw.thumbnail ?? raw.pic ?? raw.image),
    description: text(raw.description ?? raw.introduction ?? raw.summary),
    tags: normalizeTags(raw.tags ?? raw.categories),
    episodes: normalizeEpisodes(raw.episodes ?? raw.eps ?? raw.chapters ?? raw.chapter),
    raw
  }
}

function normalizeTags(value) {
  if (!Array.isArray(value)) return []
  return value.map((item) => String(item)).filter(Boolean)
}

function normalizeEpisodes(value) {
  const items = flattenEpisodes(value)
  return items.map(({ value: item, idHint }, index) => {
    const raw = item && typeof item === 'object' ? item : { title: item }
    const title = text(raw.title ?? raw.name ?? raw.label ?? raw.id ?? `EP ${index + 1}`) ?? `EP ${index + 1}`
    return {
      id: text(raw.id ?? raw.epId ?? raw.chapterId ?? raw.url ?? idHint ?? title) ?? title,
      title
    }
  })
}

function flattenEpisodes(value) {
  if (Array.isArray(value)) return value.map((item) => ({ value: item, idHint: null }))
  if (!value || typeof value !== 'object') return []
  return Object.entries(value).flatMap(([key, item]) => {
    if (Array.isArray(item)) return item.map((child) => ({ value: child, idHint: key }))
    if (item && typeof item === 'object') {
      if (isEpisodeObject(item)) return [{ value: { id: key, ...item }, idHint: key }]
      return flattenEpisodes(item)
    }
    return [{ value: { id: key, title: item }, idHint: key }]
  })
}

function isEpisodeObject(value) {
  return ['title', 'name', 'label', 'id', 'epId', 'chapterId', 'url'].some((key) =>
    Object.hasOwn(value, key)
  )
}

async function main() {
  const [action, sourcePath, first = '', second = '1'] = process.argv.slice(2)
  const source = await loadSource(sourcePath, { runInit: action !== 'manifest' })
  let data
  if (action === 'manifest') {
    data = sourceManifest(source)
  } else if (action === 'search') {
    data = await search(source, first, Number.parseInt(second, 10) || 1)
  } else if (action === 'info') {
    data = await comicInfo(source, first)
  } else if (action === 'pages') {
    data = await comicPages(source, first, second)
  } else {
    throw new Error(`unsupported runtime action: ${action}`)
  }
  json({ ok: true, data })
}

main().catch(fail)
