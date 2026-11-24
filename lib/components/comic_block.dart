part of 'components.dart';

/// Splits a comic title into the fragments offered as keyword choices, cutting
/// on commas and bracketed groups.
List<String> _splitText(String text) {
  var words = <String>[];
  var buffer = StringBuffer();
  var inBracket = false;
  String? prevBracket;
  for (var i = 0; i < text.length; i++) {
    var c = text[i];
    if (c == '[' || c == '(') {
      if (inBracket) {
        buffer.write(c);
      } else {
        if (buffer.isNotEmpty) {
          words.add(buffer.toString().trim());
          buffer.clear();
        }
        inBracket = true;
        prevBracket = c;
      }
    } else if (c == ']' || c == ')') {
      if (prevBracket == '[' && c == ']' || prevBracket == '(' && c == ')') {
        if (buffer.isNotEmpty) {
          words.add(buffer.toString().trim());
          buffer.clear();
        }
        inBracket = false;
      } else {
        buffer.write(c);
      }
    } else if (c == ',') {
      if (inBracket) {
        buffer.write(c);
      } else {
        words.add(buffer.toString().trim());
        buffer.clear();
      }
    } else {
      buffer.write(c);
    }
  }
  if (buffer.isNotEmpty) {
    words.add(buffer.toString().trim());
  }
  words.removeWhere((element) => element == "");
  return words.toSet().toList();
}

/// Lets the user turn a comic's own words and tags into blocklist entries.
///
/// Title fragments go to the keyword list (substring-matched against
/// title/subtitle/description) and tags go to the tag list, so a tag pick can
/// never accidentally hide comics whose *title* happens to contain that word.
/// Shared by the list long-press menu and the comic detail page, where the full
/// tag set is always available.
void showBlockDialog({
  required String title,
  String? subtitle,
  required List<String> tags,
  VoidCallback? onBlocked,
}) {
  var words = [
    ..._splitText(title),
    if (subtitle != null && subtitle.isNotEmpty) subtitle,
  ];
  var selectedWords = <String>[];
  var selectedTags = <String>[];
  showDialog(
    context: App.rootContext,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          Widget section(
            String title,
            List<String> items,
            List<String> picked, {
            bool translate = false,
          }) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: ts.s12.bold),
                const SizedBox(height: 8),
                Wrap(
                  runSpacing: 8,
                  spacing: 8,
                  children: [
                    for (var item in items)
                      OptionChip(
                        // Only tags have translations; a title fragment must be
                        // shown as-is. Picking a tag stores its value half (the
                        // part after the namespace), so the entry also matches
                        // comics that carry the tag without a namespace.
                        text: translate
                            ? item
                                .split(':')
                                .last
                                .translateTagIfNeed
                            : item,
                        isSelected: picked.contains(item),
                        onTap: () {
                          setState(() {
                            if (!picked.remove(item)) {
                              picked.add(item);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ],
            );
          }

          return ContentDialog(
            title: 'Block'.tl,
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.min(400, context.height - 136),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (words.isNotEmpty)
                      section('Keyword'.tl, words, selectedWords),
                    if (words.isNotEmpty && tags.isNotEmpty)
                      const SizedBox(height: 16),
                    if (tags.isNotEmpty)
                      section('Tags'.tl, tags, selectedTags, translate: true),
                    if (words.isEmpty && tags.isEmpty)
                      Text('No tags available'.tl),
                  ],
                ),
              ).paddingHorizontal(16),
            ),
            actions: [
              Button.filled(
                onPressed: () {
                  context.pop();
                  if (selectedWords.isEmpty && selectedTags.isEmpty) {
                    return;
                  }
                  for (var word in selectedWords) {
                    if (!appdata.settings['blockedWords'].contains(word)) {
                      appdata.settings['blockedWords'].add(word);
                    }
                  }
                  for (var tag in selectedTags) {
                    // Store the value half: detail pages hand over
                    // `namespace:value` tags, but list items often carry the
                    // bare value, and the entry has to match both.
                    var entry = tag.contains(':')
                        ? tag.split(':').sublist(1).join(':')
                        : tag;
                    if (entry.isEmpty) continue;
                    if (!appdata.settings['blockedTags'].contains(entry)) {
                      appdata.settings['blockedTags'].add(entry);
                    }
                  }
                  appdata.saveData();
                  App.rootContext.showMessage(message: 'Blocked'.tl);
                  onBlocked?.call();
                },
                child: Text('Block'.tl),
              ),
            ],
          );
        },
      );
    },
  );
}

String? isBlocked(Comic item) =>
    matchingBlockedWords(item).firstOrNull ?? blockedTagOf(item.tags);

Iterable<String> matchingBlockedWords(Comic item) sync* {
  for (final word in appdata.settings['blockedWords']) {
    if (word is! String || word.isEmpty) continue;
    if (item.title.contains(word) ||
        (item.subtitle?.contains(word) ?? false) ||
        item.description.contains(word) ||
        (item.tags?.any((tag) =>
            tag == word || (tag.contains(':') && tag.split(':')[1] == word)) ?? false)) {
      yield word;
    }
  }
}

/// The first entry of the tag blocklist matched by [tags], or null.
///
/// Unlike the title word list, matching is a substring test and also runs on the
/// localized tag text, since users type what they see on screen. A bare entry is
/// compared against the value half of `namespace:value`, which is the form the
/// block dialog stores; an entry typed with a namespace is compared whole, for
/// users who want to pin a rule to one namespace.
String? blockedTagOf(List<String>? tags) => matchingBlockedTags(tags).firstOrNull;

Iterable<String> matchingBlockedTags(List<String>? tags) sync* {
  if (tags == null || tags.isEmpty) return;
  var blocked = appdata.settings['blockedTags'];
  if (blocked is! List || blocked.isEmpty) return;
  // Comparable forms of each tag, built once instead of per blocklist entry.
  var whole = <String>[]; // raw tag, for namespace-qualified entries
  var plain = <String>[]; // value half + localized text, for bare entries
  for (var tag in tags) {
    if (tag.isEmpty) continue;
    whole.add(tag.toLowerCase());
    var value = tag.contains(':') ? tag.split(':').sublist(1).join(':') : tag;
    plain.add(value.toLowerCase());
    var localized = TagsTranslation.translateTag(tag).toLowerCase();
    if (localized != value.toLowerCase()) {
      plain.add(localized);
    }
  }
  for (var entry in blocked) {
    if (entry is! String || entry.isEmpty) continue;
    var needle = entry.toLowerCase();
    for (var candidate in entry.contains(':') ? whole : plain) {
      if (candidate.contains(needle)) {
        yield entry;
        break;
      }
    }
  }
}
