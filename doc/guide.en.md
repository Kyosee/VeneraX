# VeneraX Guide

This document covers the setup steps and controls for each feature. If a setting is hard to find, use the search box at the top of the settings page.

## Contents

- [AI Translation](#ai-translation)
  - [Setup](#setup)
  - [Custom translation scripts](#custom-translation-scripts)
  - [Enabling](#enabling)
  - [Controls while reading](#controls-while-reading)
  - [Adjusting results](#adjusting-results)
  - [Performance and usage](#performance-and-usage)
  - [Things to know](#things-to-know)
- [Comic cache directory](#comic-cache-directory)
- [Collections](#collections)
  - [Creating](#creating)
  - [Chapter layout](#chapter-layout)
  - [Editing](#editing)
  - [Limitations](#limitations)
- [Non-obvious controls](#non-obvious-controls)

<!--anchor:ai-translation-->
## AI Translation

Recognizes the text on a page and draws the translation onto the image, leaving the artwork intact.

Detection and recognition run on the device; the recognized text is sent to an AI service you configure yourself. The app includes no account and no credits.

<!--anchor:translation-setup-->
### Setup

1. Settings → AI Translation.
2. "LLM providers" → add one. Pick "Google Translate" to use its free endpoint: no account, no key, nothing to fill in — just save and it works. The trade-off is that each line is translated on its own, so wording and character names may vary between pages, and quality is below an AI model. It is not an official API, so it can be rate-limited or stop working at any time — use an AI model if you need reliability.
3. For better results pick "AI model": enter the API URL and API key (some local services can leave it blank), then tap "Get models" to choose a model. Any OpenAI-compatible service works. If model fetching fails, enter the model name manually. You can add several providers and switch at any time.
4. "Test translation" → a returned translation confirms the configuration works.
5. "Translation models" → download. The text detector (~5 MB) is required; add one recognition model for the comic's language:

| Language | Size |
| --- | --- |
| Japanese (incl. vertical text) | ~460 MB |
| Chinese / Latin | ~11 MB |
| English | ~9 MB |
| Korean | ~8 MB |

With "Source language" set to "Auto detect", the detector plus any one recognition model is sufficient; the app determines each comic's language itself.

<!--anchor:translation-script-->
### Custom translation scripts

Use a script for a translation service whose request format, authentication or response does not match OpenAI, or for your own translation gateway. OpenAI-compatible services can use "AI model" directly and do not need a script. A script replaces only the text translation step; text detection and recognition models are still required.

1. Settings → AI Translation → "LLM providers" → add or edit a provider.
2. Choose "Custom translation script" as the service type. Fill in the API URL, API key and model name as your script requires. These three fields are passed to the script as parameters; unused fields can remain empty.
3. Open "Edit translation script" and define `translate(input)`. Start with the offline example below if needed, then tap "Test script".
4. Tap "Save" at the top of the editor, then also "Save" in the provider dialog, and select that provider in the list. Saving the editor or passing a test does not automatically save and activate the provider.

The function receives an object containing:

| Field | Meaning |
| --- | --- |
| `texts` | An array of input strings, possibly from one or several pages |
| `sourceLang` | Source language code, such as `en`, `ja` or `zh`. `auto` means the app has not determined the language yet; your script or service must detect it, or map it to the API's auto-detection parameter |
| `targetLang` | Target language code, such as `zh`, `zh-TW` or `en`; map language codes as required by your service |
| `glossary` | This comic's existing glossary as `{source: translation}`. The script must pass it to the service or apply it itself to keep names consistent |
| `provider` | The provider dialog's `{url, key, model}`, all strings. The app does not append URL paths or add authentication headers for your script |

Return `{texts: [...], glossary: {...}}`, with `glossary` optional, or return a plain array of strings. There must be exactly one string per input, in the same order. Glossary keys and values must also be strings; returned terms are used in later translations of the comic. Entries that are too long or resemble sentences, URLs or numbers are filtered out. Return a JavaScript object or array directly, without wrapping the result in `JSON.stringify`.

**Offline smoke test**: this makes no network request and only prefixes each input with `[test]`. It checks script execution and the result format; **it does not translate**. The test should display `[test] Hello`. Replace it before using translation while reading.

```javascript
function translate({texts}) {
    // Smoke test only; no translation or network request.
    return {texts: texts.map(text => '[test] ' + text)};
}
```

**HTTP integration example**: this assumes your service accepts `texts`, `source`, `target`, `model` and `glossary`, and returns `{"translations":[{"text":"你好"}],"glossary":{}}`. It demonstrates request and response mapping, not a ready-to-use universal API. Adapt the fields, authentication and language codes to your service's documentation, and enter the full endpoint in the provider's API URL field.

```javascript
async function translate({texts, sourceLang, targetLang, glossary, provider}) {
    const headers = {'Content-Type': 'application/json'};
    if (provider.key) headers.Authorization = 'Bearer ' + provider.key;
    const response = await Network.sendRequest(
        'POST', provider.url, headers,
        JSON.stringify({
            texts, source: sourceLang, target: targetLang,
            model: provider.model, glossary
        })
    );
    if (response.status < 200 || response.status >= 300) {
        throw new Error('HTTP ' + response.status);
    }
    const data = JSON.parse(response.body);
    // Adapt this mapping to your API's response.
    return {
        texts: data.translations.map(item => item.text),
        glossary: data.glossary || {}
    };
}
```

`Network.sendRequest(method, url, headers, data)` makes an HTTP(S) request and returns `response.status` (status code), `response.headers` (headers with array values) and `response.body` (response text). Serialize JSON request bodies and parse JSON responses yourself. Unsuccessful HTTP status codes do not automatically throw a script error; check them as in the example. Standard JavaScript, `JSON`, array operations and `async` / `await` are available. Network requests are the only supported app API; other Venera APIs, such as file, storage and UI operations, are unavailable.

- "Test script" runs the current editor code with `texts: ['Hello']`, `sourceLang: 'en'`, `targetLang: 'zh'`, an empty glossary and the provider parameters from when you opened the editor. A script with network requests really calls the service and may spend credits. Reopen the editor to test updated provider parameters.
- Tests have a 30-second timeout; normal translation calls have a 3-minute timeout. Each synchronous JavaScript execution has a limit of about 1 second. Avoid infinite loops and long synchronous computations; use asynchronous network requests.
- A missing `translate` function, syntax errors, invalid URLs, failed requests, timeouts, wrong translation counts or types, and malformed glossaries all cause failure. First use the offline example to check execution, then check HTTP status, authentication, language codes and response fields. While reading, tap the failure icon for the error and retry.
- Scripts can read the input text, glossary and provider key, and send requests to HTTP(S) addresses chosen by the script. Run only scripts you understand or trust and check their destinations. Store keys in the provider field and use `provider.key`; do not hardcode them in scripts, examples or error messages.
- Script code stays on this device and does not sync to other devices. Add and test the script separately before using the provider on another device.

<!--anchor:translation-enable-->
### Enabling

Translation is enabled per comic, with no global switch, because it spends your own credits. Two entry points:

- Comic detail page → more menu (top right) → "Enable AI translation".
- Reader → Settings → AI Translation → "Translate pages while reading".

Pages are then translated as they are reached, showing the original until each finishes. To translate in advance, use the "Pre-translate" button on the detail page; work runs in the background and progress appears on the Tasks page.

<!--anchor:translation-reading-->
### Controls while reading

- Image icon in the top bar: switch between the translation and the original for comparison, without changing the translation settings.
- Progress ring in the top bar: this page is being translated.
- Red warning icon in the top bar: this page failed; tap to see why and retry.

<!--anchor:translation-adjust-->
### Adjusting results

Long-press the "Pre-translate" button on the detail page to open:

- **Glossary**: review and correct the names and proper nouns learned for this comic. Later translations follow the corrections.
- **Re-translate**: clear this comic's translations and glossary, then translate again.

Other options:

- To redo only some chapters: select them in the chapter picker and use "Re-translate selected".
- If the translation is poorly masked: adjust "Text removal". "Smart erase" (default) reconstructs the bubble's background and screentone; "Color patch" covers the area with a solid block — faster, with harder edges.

<!--anchor:translation-performance-->
### Performance and usage

Translated text is stored, so a page normally runs OCR and an LLM request only once; re-reading does not spend more credits. Switching between "Smart erase" and "Color patch" only redraws the page from stored text, without repeating OCR or translation. "Clear translation results" frees the space and keeps the language and glossary learned per comic. Results written by the old cache format are discarded automatically after upgrading and must be translated again.

If throughput is poor or the provider returns rate-limit errors, adjust:

| Setting | Effect |
| --- | --- |
| Performance mode | "Save resources" reduces memory and heat; "Balanced" (recommended) suits most devices; "Fast" raises concurrency and battery use. The mode is device-local, so desktop values do not overwrite a phone |
| Pages per pre-translation request | Pages per request. More reduces the request count but increases per-request latency; too many can exceed the model's context |
| Translation request concurrency | Requests in flight at once. Lower it when rate-limited |
| OCR parallelism | Local recognition threads, 0 for automatic. Mobile limits concurrency automatically; the Japanese model uses one worker on mobile. Lower it if the device heats up or stutters |
| Image download concurrency | Images downloaded at once |

Most users do not need Advanced settings; changing any performance detail switches the mode to "Custom" automatically. Each text line is erased using a tight region and the translated text is kept inside its own area, reducing damage to characters and backgrounds. Complex artwork, very long sentences and unusual layouts can still need a retry or the "Color patch" fallback.

"Translation prompt" replaces the built-in prompt. The built-in one asks for natural dialogue, reuse of already-agreed character names, and a report of proper nouns new to the page — requirements that cost input tokens on every request. A small self-hosted model that cannot afford them can be given a shorter prompt, at the cost of translation quality and consistent naming across pages. When writing your own:

| Placeholder | Replaced with |
| --- | --- |
| `$target` | The target language name, e.g. "English" |

Two things must stay in the prompt or the feature stops working. First, ask the model to output only a JSON object like `{"lines":[{"id":0,"text":"translation"}]}` with each id appearing exactly once — the app uses those ids to put each translation back in its own bubble, and a reply it cannot parse fails the page. Second, if you want names to stay consistent, tell the model to reuse the renderings given in the `glossary` field and to return newly seen proper nouns in a `names` field. Clearing the field and saving restores the built-in prompt. The setting travels with your backups across devices.

<!--anchor:translation-limits-->
### Things to know

- Marked experimental: recognition and translation can both fail, most visibly on long text and unusual layouts.
- The Japanese model is large because vertical manga text currently has only one reliable recognition option.
- Inference is CPU-only, so pre-translating on mobile causes noticeable heat and battery drain. Run it while charging.

<!--anchor:cache-directory-->
## Comic cache directory

Use this to put images cached during online reading on a drive or directory with more free space. Settings → Data & Sync → Data → "Comic cache directory" → "Set": choose a folder or enter an absolute path the app can write to, such as `D:\VeneraCache`. Saving checks the path and write access and automatically creates missing folders. The setting shows the active path and adds an "After restart" path when a change is pending. Choose "Use default" to clear the input, then save to restore the default location on the next launch.

| Location | Contents |
| --- | --- |
| `<entered path>/venera-cache/cache` | Cached comic images |
| `<entered path>/venera-cache/cache.db` | The matching cache index database |

Enter the parent directory; the app appends `venera-cache/cache`, so do not append it yourself. Keep unrelated files out of the app's `venera-cache` directory. A directory with that name containing unrelated data, or cache subdirectories that are links, may be rejected. If the path is unavailable, check that it is absolute, the drive is connected, and permissions and existing files allow its use.

- **Restart required**: saving does not change the cache used by the running app. Fully quit and restart to use the new location.
- **Old cache is kept and is not moved**: the app accumulates a new cache at the new location. To free the old cache's space, use "Clear Cache" before switching and restarting.
- **Clearing uses the currently active location**: "Clear Cache" clears only the cache used by this run, without searching earlier locations or clearing the parent directory you entered. After editing the path but before restarting, it still clears the old location; after a startup fallback, it clears the default location.
- **Restore the default**: clear the path, save and restart. Old cache in the custom directory is kept.
- **Startup fallback**: if the custom path is unavailable at startup, the app shows an error and uses the default cache directory for that session. The saved custom path is kept. Fix the path or permissions and restart to try it again.
- **Image cache only**: downloaded comics, translation recognition models and other app data are not moved. Downloaded comics have a separate local comic storage path setting.
- **Device-local setting**: cache paths do not sync between devices; configure each device separately.

<!--anchor:collections-->
## Collections

Combines comics published separately — volumes, parts, seasons — into one comic for reading. A collection has one cover, one chapter list and one reading position, and a single favorite/follow entry. Members may come from different sources.

The original comics are unchanged; the collection is an additional entry point.

<!--anchor:collection-create-->
### Creating

In bulk:

1. Long-press a comic in any list to enter multi-select, then select the parts of one work.
2. Collection icon in the toolbar → "Add to collection".
3. Choose "New collection" as the target and enter a name (empty uses the first comic's title).
4. Choose a chapter layout and confirm.

Individually: long-press a comic → "Add to collection", swipe its row, or use the more menu on its detail page.

Two options are offered when adding: file the new collection into a favorite folder, and "Un-favorite the added comics" so only the collection remains in favorites.

<!--anchor:collection-layout-->
### Chapter layout

- **Merged chapters**: all members' chapters in one list. Use when each comic is a single instalment or volume.
- **Chapter tabs**: one tab per comic, each managing its own chapters. Use when each comic has multiple chapters of its own.

Either can be changed at any time; read progress and downloaded chapters are unaffected.

<!--anchor:collection-edit-->
### Editing

Collections appear in the "Collections" card on the home page, hidden while none exist. To move or hide it: Settings → Appearance → Home layout.

From the collections page, menu → "Edit":

- **Collection name**: empty uses the first comic's title.
- **Cover**: the first comic's cover, an image file, or any member's cover. A member showing "Open it once to load its cover" has no cached cover yet; open that comic once.
- **Chapter layout**.
- **Order**: drag the handle on the right. Member order is chapter order, which corrects a source that lists the parts out of sequence.
- **Members**: each member's menu renames it within the collection, opens it on its own, or removes it from the collection.

On a collection's detail page using "Chapter tabs", long-press a tab (right-click on desktop) to rename, reorder or remove that member without opening the editor.

<!--anchor:collection-limits-->
### Limitations

- Collections cannot be nested.
- Deleting a collection keeps its comics, removing only the collection and its favorite and history entries.
- A member shown in red as "Unavailable" has an uninstalled source or missing local files; remove it or restore the source.
- A collection's update time is the newest among its members.
- Collection settings and custom covers are included in backup and sync.

<!--anchor:gestures-->
## Non-obvious controls

These have no corresponding button. Long-press on mobile; most also respond to right-click on desktop.

Lists and favorites:

- Long-press a comic: open its action menu (add to collection, favorite, read later, and so on).
- Swipe a list row: quick actions.
- Long-press to enter multi-select, then act in bulk.
- Long-press empty space on the home page: rearrange or hide home sections.

Comic detail page:

- Long-press the cover: save the cover image.
- Long-press "Favorite": skip the folder panel and file it into the default folder.
- Long-press "Pre-translate": open the translation menu (pre-translate, glossary, re-translate).
- Long-press the title or a tag: copy the text.
- Long-press a chapter: enter chapter multi-select for bulk mark-as-read, download or re-translate.
- Long-press a chapter tab (collections only): rename, reorder or remove that member.
