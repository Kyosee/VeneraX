# VeneraX Guide

This document covers the setup steps and controls for each feature. If a setting is hard to find, use the search box at the top of the settings page.

## Contents

- [AI Translation](#ai-translation)
  - [Setup](#setup)
  - [Enabling](#enabling)
  - [Controls while reading](#controls-while-reading)
  - [Adjusting results](#adjusting-results)
  - [Performance and usage](#performance-and-usage)
  - [Things to know](#things-to-know)
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

1. Settings → Reading → expand "AI Translation (experimental)".
2. "LLM providers" → add one with its API URL, API Key and Model. Any OpenAI-compatible service works; add several and switch at any time.
3. "Test translation" → a returned translation confirms the configuration works.
4. "Translation models" → download. The text detector (~5 MB) is required; add one recognition model for the comic's language:

| Language | Size |
| --- | --- |
| Japanese (incl. vertical text) | ~460 MB |
| Chinese / Latin | ~11 MB |
| English | ~9 MB |
| Korean | ~8 MB |

With "Source language" set to "Auto detect", the detector plus any one recognition model is sufficient; the app determines each comic's language itself.

<!--anchor:translation-enable-->
### Enabling

Translation is enabled per comic, with no global switch, because it spends your own credits. Two entry points:

- Comic detail page → more menu (top right) → "Enable AI translation".
- Reader → Settings → "Translate pages while reading".

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

Translations are stored, so each page is translated once and re-reading issues no further requests. "Clear translation results" frees the space and keeps the language and glossary learned per comic.

If throughput is poor or the provider returns rate-limit errors, adjust:

| Setting | Effect |
| --- | --- |
| Pages per pre-translation request | Pages per request. More reduces the request count but increases per-request latency; too many can exceed the model's context |
| Translation request concurrency | Requests in flight at once. Lower it when rate-limited |
| OCR parallelism | Local recognition threads, 0 for automatic. Lower it if the device heats up or stutters |
| Image download concurrency | Images downloaded at once |

<!--anchor:translation-limits-->
### Things to know

- Marked experimental: recognition and translation can both fail, most visibly on long text and unusual layouts.
- The Japanese model is large because vertical manga text currently has only one reliable recognition option.
- Inference is CPU-only, so pre-translating on mobile causes noticeable heat and battery drain. Run it while charging.

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
