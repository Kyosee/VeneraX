# VeneraX Guide

Where things are and how to tap them. If you can't find a setting, open Settings and use the search box at the top.

## AI Translation {#ai-translation}

Reads the text on a page and draws the translation onto the image, keeping the artwork. **Finding and recognizing the text happens on your device; the recognized lines are sent to an AI service you configure yourself.** The app ships no account and no credits — it uses yours.

### One-time setup

1. Settings → Reading → expand "AI Translation (experimental)".
2. Tap "LLM providers" → add one with its API URL, API Key and Model. Any OpenAI-compatible service works. Add several and switch anytime.
3. Tap "Test translation". A returned translation means it works; an error tells you what to fix.
4. Tap "Translation models" → download. The text detector (~5 MB) is always required; then one recognition model for the comic's language:
   - Japanese (vertical manga text) ~460 MB
   - Chinese / Latin ~11 MB
   - English ~9 MB
   - Korean ~8 MB

Models come from HuggingFace. If that is unreachable, switch "Model download source" to hf-mirror.com.

With "Source language" left on "Auto detect", the detector plus any one recognition model is enough — the app works out what language each comic is in.

### Start translating

Translation is enabled **per comic**, not globally, because it spends your credits.

- On a comic's detail page, open the more menu (top right) → "Enable AI translation".
- Or in the reader → Settings → "Translate pages while reading".

From then on each page is translated as you reach it, showing the original until it's done.

To translate ahead: the detail page gains a "Pre-translate" button. Tap it, pick chapters, and the work runs in the background — progress is on the Tasks page.

### While reading

- Image icon in the top bar: switch between "Show original" and "Show translated" to compare, without turning the feature off.
- Spinner in the top bar: this page is being translated.
- Red exclamation mark: this page failed. Tap it to see why and retry.

### When the result is wrong

- **Long-press the "Pre-translate" button** on the detail page:
  - "Glossary": view and correct the names and proper nouns learned for this comic. Later pages follow your corrections.
  - "Re-translate": clear this comic's translations and glossary, then translate again.
- To redo only a few chapters: select them in the chapter picker and use "Re-translate selected".
- If the lettering looks badly covered, change "Text removal". "Smart erase" (default) reconstructs the bubble's background and screentone; "Color patch" pastes a solid block — faster, cruder.

### Saving credits and speeding up

Translated pages are stored, so a page is translated once and re-reading costs nothing. "Clear translation results" frees the space and keeps the language and glossary learned per comic.

If it is slow, or your provider rate-limits you, adjust:

- "Pages per pre-translation request": how many pages go into one request. More pages means fewer requests but slower turnaround, and too many can exceed the model's context.
- "Translation request concurrency": how many requests run at once. Lower it if you get rate-limited.
- "OCR parallelism": local recognition threads, 0 means auto. Lower it if the device heats up or stutters.
- "Image download concurrency".

### Notes

- This is marked experimental: recognition and translation can both get things wrong, especially long text and unusual layouts.
- The Japanese model is large because vertical manga text currently has only one reliable recognition option.
- Inference is CPU-only, so pre-translating on a phone heats it up and drains the battery. Run it while charging.

## Collections {#collections}

Read several comics that are really one story as a single comic: volumes, parts, seasons. A collection has one cover, one chapter list, one reading position — and one favorite/follow entry. **Members can come from different sources, mixed freely.**

The original comics stay where they are; the collection is just another way in.

### Create one

The easiest route is in bulk:

1. In any list, enter multi-select (long-press a comic) and tick the comics that belong together.
2. Tap the collection icon in the toolbar → "Add to collection".
3. Choose "New collection" as the target and enter a name (leave empty to use the first comic's title).
4. Pick a chapter layout (below) and confirm.

One at a time also works: long-press a comic → "Add to collection", or swipe its row, or use the more menu on its detail page.

Two extra options when adding: file the new collection into a favorite folder, and "Un-favorite the added comics" so only the collection is left in your favorites instead of every part.

### Two chapter layouts

- **Merged chapters**: every member's chapters in one list. Use it when each comic is a single instalment or volume.
- **Chapter tabs**: one tab per comic, each with its own chapters. Use it when each comic has many chapters of its own.

You can switch anytime — read progress and downloaded chapters survive the change.

### Adjust a collection

Collections live in the "Collections" card on the home page (hidden while you have none). To move or hide that card: Settings → Appearance → Home layout.

From the collections page, menu → "Edit":

- **Collection name**: empty means the first comic's title.
- **Cover**: the first comic's cover, an image file, or any member's cover. A member showing "Open it once to load its cover" hasn't had its cover cached yet — open that comic once.
- **Chapter layout**.
- **Order**: drag the handle on the right. **Member order is chapter order**, so this is the fix for a source that lists part 3 before part 1.
- **Members**: the menu on each row renames it inside the collection ("Display name"), opens it on its own ("Details"), or takes it out ("Remove from collection").

On a collection's detail page in "Chapter tabs" layout, **long-press a tab** (right-click on desktop) to rename, move or remove that member without going back to the editor.

### Notes

- A collection cannot be put inside another collection.
- Deleting a collection keeps the comics; it only removes the collection and its favorite/history entries.
- A member shown in red as "Unavailable" means its source isn't installed or its local files are gone. Remove it or restore the source.
- A collection's update time is the newest among its members.
- Collection settings and custom covers travel with backup and sync.

## Hidden gestures {#gestures}

These have no visible button but are worth knowing. Long-press on touch; most also respond to right-click on desktop.

Lists and favorites:

- Long-press a comic: open its action menu (add to collection, favorite, read later, and so on).
- Swipe a row sideways: quick actions.
- Long-press to enter multi-select, then act on many at once.
- Long-press empty space on the home page: rearrange or hide the home sections.

Comic detail page:

- Long-press the cover: save the cover image.
- Long-press "Favorite": skip the folder panel and file it into the default folder.
- Long-press "Pre-translate": open the translation menu (pre-translate / glossary / re-translate).
- Long-press the title or a tag: copy the text.
- Long-press a chapter: enter chapter multi-select for bulk mark-as-read, download or re-translate.
- Long-press a chapter tab (collections only): rename, reorder or remove that member.
