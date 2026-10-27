part of 'components.dart';

class ComicDescription extends StatelessWidget {
  const ComicDescription({
    super.key,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.enableTranslate,
    this.badge,
    this.maxLines = 2,
    this.tags,
    this.rating,
    this.updateText,
    this.statusText,
    this.progressText,
    this.pagesText,
    this.showTitle = true,
    this.showDescription = true,
    this.onTapAuthor,
    this.onTapTag,
    this.enableLongPressCopy = false,
  });

  final String title;
  final String subtitle;
  final String description;
  final String? badge;
  final List<String>? tags;
  final int maxLines;
  final bool enableTranslate;
  final double? rating;
  final String? updateText;
  final String? statusText;
  final String? progressText;
  final String? pagesText;
  final bool showTitle;

  /// Off on the detail page, which renders the full description on its own.
  final bool showDescription;
  final void Function(String author, String? namespace)? onTapAuthor;
  final void Function(String tag, String namespace)? onTapTag;

  /// Whether long-pressing an info/tag value copies it to the clipboard.
  /// Enabled on the comic detail page; disabled on list tiles so a long press
  /// over the tag area triggers the tile's own context menu instead (issue #79).
  final bool enableLongPressCopy;

  @override
  Widget build(BuildContext context) {
    final descriptionParts = _descriptionParts();
    final source = _clean(badge) ?? _derivedSource(descriptionParts);
    final update = _clean(updateText) ?? _updateTextFromTags();
    final progress = _clean(progressText);
    final authorItems = _authorItems();
    final authors = authorItems.isEmpty
        ? null
        : authorItems.map((e) => e.label).join(", ");
    final languageItems = _languageItems();
    final tagItems = _tagItems();
    final tagText = _tagText(tagItems);
    final status = _clean(statusText) ?? _statusText();
    final pages = _clean(pagesText) ?? _pagesText();
    final fallbackDescription = _fallbackDescription(
      update,
      progress,
      source,
      descriptionParts,
    );
    final rows = <Widget>[
      if (authors != null && onTapAuthor != null)
        _actionRow(
          context,
          "Authors".tl,
          authorItems
              .map(
                (item) => _InfoAction(
                  text: item.label,
                  onTap: () => onTapAuthor!(item.value, item.namespace),
                ),
              )
              .toList(),
          Colors.lightBlue,
        )
      else if (authors != null)
        _infoRow(context, "Authors".tl, authors, Colors.lightBlue),
      // Ahead of update/source/tags on purpose: only the first few rows survive
      // the height budget below, and page count is what a reader filters on.
      if (pages != null) _infoRow(context, "Pages".tl, pages, Colors.teal),
      // High in the list for the same reason: a fixed-height tile draws only
      // its first few rows, and language is worth a slot there (issue #288).
      if (languageItems.isNotEmpty && onTapTag != null)
        _actionRow(
          context,
          "Language".tl,
          languageItems
              .map(
                (item) => _InfoAction(
                  text: item.label,
                  onTap: () => onTapTag!(item.value, item.namespace ?? ''),
                ),
              )
              .toList(),
          Colors.indigo,
        )
      else if (languageItems.isNotEmpty)
        _infoRow(
          context,
          "Language".tl,
          _tagText(languageItems)!,
          Colors.indigo,
        ),
      if (update != null) _infoRow(context, "Update".tl, update, Colors.cyan),
      if (source != null) _infoRow(context, "Source".tl, source, Colors.cyan),
      if (tagItems.isNotEmpty && onTapTag != null)
        _actionRow(
          context,
          "Tags".tl,
          tagItems
              .map(
                (item) => _InfoAction(
                  text: item.label,
                  onTap: () => onTapTag!(item.value, item.namespace ?? ''),
                ),
              )
              .toList(),
          Colors.pinkAccent,
        )
      else if (tagText != null)
        _infoRow(context, "Tags".tl, tagText, Colors.pinkAccent),
      if (status != null) _infoRow(context, "Status".tl, status, Colors.purple),
      if (progress != null)
        _infoRow(context, "Progress".tl, progress, Colors.green),
      if (showDescription && fallbackDescription != null)
        _infoRow(context, "Description".tl, fallbackDescription, Colors.orange),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final visibleRows = _visibleRowCount(
          constraints.maxHeight,
          rating != null,
          totalRows: rows.length,
          extraRows: languageItems.isEmpty ? 0 : 1,
        );
        return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.start,
          children: [
            if (showTitle) ...[
              Text(
                title.trim(),
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
                maxLines: rows.isEmpty ? maxLines : 1,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
              ),
              const SizedBox(height: 4),
            ],
            if (rating != null) ...[
              StarRating(value: rating!, size: 15),
              const SizedBox(height: 2),
            ],
            if (rows.isNotEmpty)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: rows.take(visibleRows).toList(),
              ),
          ],
        );
      },
    );
  }

  /// Rows the tile can draw. [extraRows] widens the cap for rows added after
  /// these numbers were tuned, so the language row costs no existing one
  /// (issue #288).
  ///
  /// An unbounded height means the host scrolls (the detail page) rather than
  /// clipping, so every row is drawn there; only a fixed-height tile has to
  /// choose.
  int _visibleRowCount(
    double maxHeight,
    bool hasRating, {
    required int totalRows,
    int extraRows = 0,
  }) {
    if (maxHeight.isInfinite) {
      return totalRows;
    }
    final reservedHeight = (showTitle ? 24 : 0) + (hasRating ? 20 : 0);
    final count = ((maxHeight - reservedHeight) / 21).floor();
    return math.max(1, math.min(5 + extraRows, count));
  }

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    context.showMessage(message: "Copied".tl);
  }

  Widget _infoRow(
    BuildContext context,
    String label,
    String value,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: color.toOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.colorScheme.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: () {
              final valueText = Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: context.colorScheme.onSurfaceVariant,
                ),
              );
              if (!enableLongPressCopy) {
                return valueText;
              }
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: () => _copy(context, value),
                child: valueText,
              );
            }(),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(
    BuildContext context,
    String label,
    List<_InfoAction> actions,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: color.toOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.colorScheme.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Wrap(
              spacing: 0,
              runSpacing: 2,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: actions[i].onTap,
                    onLongPress: enableLongPressCopy
                        ? () => _copy(context, actions[i].text)
                        : null,
                    child: Text(
                      actions[i].text,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.colorScheme.primary,
                      ),
                    ).paddingHorizontal(2),
                  ),
                  if (i != actions.length - 1)
                    Text(
                      " / ",
                      style: TextStyle(
                        fontSize: 12,
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _clean(String? value) {
    final result = value?.replaceAll("\n", " ").trim();
    return result == null ||
            result.isEmpty ||
            result == "Unknown" ||
            result.startsWith("Unknown:")
        ? null
        : result;
  }

  String? _tagText(List<_DescriptionTag> rawTags) {
    if (rawTags.isEmpty) {
      return null;
    }
    return rawTags.map((tag) => tag.label).join(" / ");
  }

  /// Language tags, shown in a row of their own (issue #288).
  List<_DescriptionTag> _languageItems() {
    return _tagItemsWithNamespace(_languageNamespaces);
  }

  /// Content tags, minus language ones — those get their own row.
  List<_DescriptionTag> _tagItems() {
    final rawTags = tags
        ?.map((e) => e.replaceAll("\n", " ").trim())
        .where(
          (e) =>
              e.removeAllBlank != "" &&
              !_isMetadataTag(e) &&
              !_isLanguageTag(e) &&
              _clean(e.split(':').last) != null,
        )
        .toList();
    if (rawTags == null || rawTags.isEmpty) {
      return const [];
    }
    final enableTranslate =
        App.locale.languageCode == 'zh' && this.enableTranslate;
    return rawTags.map((tag) {
      final index = tag.indexOf(':');
      final namespace = index == -1 ? null : tag.substring(0, index);
      final value = index == -1 ? tag : tag.substring(index + 1);
      return _DescriptionTag(
        namespace: namespace,
        value: value,
        label: enableTranslate
            ? TagsTranslation.translateTag(tag)
            : tag.split(':').last,
      );
    }).toList();
  }

  List<_DescriptionTag> _authorItems() {
    final author = _clean(subtitle);
    if (author != null) {
      return author
          .split(RegExp(r"[|,]"))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .map(
            (e) => _DescriptionTag(
              namespace: _namespaceForValue(e, _authorNamespaces),
              value: e,
              label: e,
            ),
          )
          .toList();
    }
    return _tagItemsWithNamespace(_authorNamespaces);
  }

  String? _statusText() {
    return _tagsWithNamespace(_statusNamespaces).firstOrNull;
  }

  /// Page count from a `pages:` style tag, for sources that report it that way
  /// instead of through [Comic.maxPage].
  String? _pagesText() {
    return _tagsWithNamespace(_pagesNamespaces).firstOrNull;
  }

  String? _updateTextFromTags() {
    return _tagsWithNamespace(
      _updateNamespaces,
    ).where(_looksLikeDate).firstOrNull;
  }

  List<String> _tagsWithNamespace(Set<String> namespaces) {
    return _tagItemsWithNamespace(namespaces).map((e) => e.label).toList();
  }

  List<_DescriptionTag> _tagItemsWithNamespace(Set<String> namespaces) {
    return tags
            ?.map((e) => e.replaceAll("\n", " ").trim())
            .where((e) => e.contains(':'))
            .map((e) {
              final index = e.indexOf(':');
              final namespace = _normalizeNamespace(e.substring(0, index));
              final value = _clean(e.substring(index + 1));
              if (value == null || !namespaces.contains(namespace)) {
                return null;
              }
              return _DescriptionTag(
                namespace: e.substring(0, index),
                value: value,
                label: enableTranslate && App.locale.languageCode == 'zh'
                    ? TagsTranslation.translateTag(e)
                    : value,
              );
            })
            .whereType<_DescriptionTag>()
            .toList() ??
        const [];
  }

  String? _namespaceForValue(String value, Set<String> namespaces) {
    for (final tag in tags ?? const <String>[]) {
      final index = tag.indexOf(':');
      if (index == -1) {
        continue;
      }
      final namespace = tag.substring(0, index);
      final tagValue = _clean(tag.substring(index + 1));
      if (tagValue == value &&
          namespaces.contains(_normalizeNamespace(namespace))) {
        return namespace;
      }
    }
    return null;
  }

  bool _isLanguageTag(String tag) {
    final index = tag.indexOf(':');
    if (index <= 0) return false;
    return _languageNamespaces.contains(
      _normalizeNamespace(tag.substring(0, index)),
    );
  }

  bool _isMetadataTag(String tag) {
    if (!tag.contains(':')) {
      final value = _clean(tag);
      return value == null || _looksLikeDate(value) || _looksLikeStatus(value);
    }
    final index = tag.indexOf(':');
    final namespace = _normalizeNamespace(tag.substring(0, index));
    final value = _clean(tag.substring(index + 1));
    return _metadataNamespaces.contains(namespace) ||
        value == null ||
        _looksLikeDate(value) ||
        _looksLikeStatus(value);
  }

  String _normalizeNamespace(String value) {
    return value.trim().toLowerCase().replaceAll(' ', '');
  }

  static const _authorNamespaces = {
    'author',
    'artist',
    'authors',
    'artists',
    'creator',
    '原作',
    '作者',
    '作家',
    '作画',
    '作畫',
    '漫畫',
    '漫画',
    '著者',
    '绘师',
    '繪師',
  };

  static const _statusNamespaces = {
    'status',
    'state',
    'serialization',
    '連載',
    '连载',
    '狀態',
    '状态',
  };

  static const _updateNamespaces = {
    'date',
    'lastupdate',
    'time',
    'update',
    'updated',
    '更新',
    '最後更新',
    '最后更新',
    '時間',
    '时间',
    '日期',
  };

  static const _pagesNamespaces = {'page', 'pages', '頁數', '页数'};

  static const _languageNamespaces = {
    'language',
    'languages',
    'lang',
    '語言',
    '语言',
  };

  // 'language' is deliberately absent here: nothing renders metadata rows for
  // it, so listing it made language tags vanish rather than move (issue #288).
  static const _metadataNamespaces = {
    ..._authorNamespaces,
    ..._statusNamespaces,
    ..._updateNamespaces,
    ..._pagesNamespaces,
    'source',
    'uploader',
    '來源',
    '来源',
    '上傳者',
    '上传者',
  };

  String? _derivedSource(List<String> parts) {
    if (parts.length != 2 || !_looksLikeDate(parts.first)) {
      return null;
    }
    return _clean(parts.last);
  }

  String? _fallbackDescription(
    String? update,
    String? progress,
    String? source,
    List<String> parts,
  ) {
    final value = _clean(description);
    if (value == null || value == update || value == progress) {
      return null;
    }
    if (_isMetadataDescription(parts, source)) {
      return null;
    }
    return value.replaceAll("|", " / ");
  }

  List<String> _descriptionParts() {
    return description
        .split("|")
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  bool _looksLikeDate(String value) {
    return RegExp(r"^\d{4}[-/]\d{1,2}[-/]\d{1,2}").hasMatch(value) ||
        RegExp(r"^\d{4}").hasMatch(value);
  }

  bool _looksLikeStatus(String value) {
    final normalized = value.trim().toLowerCase();
    return const {
      'completed',
      'complete',
      'ongoing',
      'serializing',
      '連載',
      '連載中',
      '连载',
      '连载中',
      '完結',
      '完结',
      '已完結',
      '已完结',
      '休載',
      '休载',
    }.contains(normalized);
  }

  bool _isMetadataDescription(List<String> parts, String? source) {
    if (parts.length != 2 || !_looksLikeDate(parts.first)) {
      return false;
    }
    final descriptionSource = _clean(parts.last);
    return source == null ||
        descriptionSource == null ||
        descriptionSource == source;
  }
}

class _DescriptionTag {
  const _DescriptionTag({
    required this.value,
    required this.label,
    this.namespace,
  });

  final String? namespace;
  final String value;
  final String label;
}

class _InfoAction {
  const _InfoAction({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;
}
