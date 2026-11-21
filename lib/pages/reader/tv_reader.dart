part of 'reader.dart';

final _tvArrowKeys = {
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
};

void _tvTurn(_ReaderState reader, bool forward, KeyEvent event) {
  final turned = forward ? reader.toNextPage() : reader.toPrevPage();
  if (turned || event is! KeyDownEvent) return;
  forward ? reader.toNextChapter() : reader.toPrevChapter(toLastPage: true);
}

bool _tvScrollStep(ScrollPosition position, bool forward) {
  final step = position.viewportDimension * 0.65;
  final target = (position.pixels + (forward ? step : -step)).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  if ((target - position.pixels).abs() < 0.5) return false;
  position.jumpTo(target);
  return true;
}

bool _tvPanImage(
  _ReaderState reader,
  Set<State<ComicImage>> states,
  bool down,
) {
  for (final state in states) {
    final provider = state.widget.image as ReaderImageProvider;
    if (provider.page != reader.page) continue;
    final scroll = Scrollable.maybeOf(state.context, axis: Axis.vertical);
    if (scroll != null) return _tvScrollStep(scroll.position, down);
  }
  return false;
}

Widget _tvPageImage(
  ReaderImageProvider provider,
  Size viewport,
  bool fitWidth,
  Set<State<ComicImage>> states,
) {
  final image = ComicImage(
    image: provider,
    width: fitWidth ? double.infinity : viewport.width,
    height: fitWidth ? null : viewport.height,
    fit: BoxFit.contain,
    onInit: states.add,
    onDispose: states.remove,
  );
  if (!fitWidth) return image;
  return SingleChildScrollView(
    key: ValueKey(provider.key),
    primary: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: viewport.height),
      child: Center(child: image),
    ),
  );
}

/// Keep even panoramic pages within the TV decoder's pixel and texture limits.
@visibleForTesting
ui.TargetImageSize tvDecodeSize(int width, int height) {
  final scale = math.min(
    1.0,
    math.min(
      8192 / math.max(width, height),
      math.sqrt((4 << 20) / (width * height)),
    ),
  );
  return ui.TargetImageSize(
    width: math.max(1, (width * scale).floor()),
    height: math.max(1, (height * scale).floor()),
  );
}

class _TvReaderImageProvider extends ReaderImageProvider {
  const _TvReaderImageProvider(
    super.imageKey,
    super.sourceKey,
    super.cid,
    super.eid,
    super.page, {
    super.enableResize,
    super.translationKey,
    super.legacyTranslationKey,
    super.translationConfig,
    super.translated,
    super.translationRevision,
    super.comicTitle,
    super.comicCover,
    super.chapterTitle,
  });

  @override
  String get key => '${super.key}@tv';

  @override
  ImageStreamCompleter loadImage(
    ReaderImageProvider key,
    ImageDecoderCallback decode,
  ) => super.loadImage(
    key,
    (buffer, {getTargetSize}) => decode(buffer, getTargetSize: tvDecodeSize),
  );
}
