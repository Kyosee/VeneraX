part of 'reader.dart';

class ReaderWithLoading extends StatefulWidget {
  const ReaderWithLoading({
    super.key,
    required this.id,
    required this.sourceKey,
    this.initialEp,
    this.initialPage,
  });

  final String id;

  final String sourceKey;

  final int? initialEp;

  final int? initialPage;

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps> {
  final ComicStateRepository _comicStateRepository =
      const ComicStateRepository();

  @override
  Widget buildContent(BuildContext context, ReaderProps data) {
    return Reader(
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      history: data.history,
      initialChapter: widget.initialEp ?? data.history.ep,
      initialPage: widget.initialPage ?? data.history.page,
      initialChapterGroup: data.history.group,
      author: data.author,
      tags: data.tags,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData() async {
    var state = _comicStateRepository.load(widget.sourceKey, widget.id);
    var comicSource = ComicSource.find(widget.sourceKey);
    var history = state.history;
    if (comicSource == null) {
      var localComic = state.localComic;
      if (localComic == null) {
        return Res.error("comic not found");
      }
      _comicStateRepository.mirrorLocalComic(localComic);
      return Res(
        ReaderProps(
          type: state.identity.type,
          cid: widget.id,
          name: localComic.title,
          chapters: localComic.chapters,
          history:
              history ?? History.fromModel(model: localComic, ep: 0, page: 0),
          author: localComic.subtitle,
          tags: localComic.tags,
        ),
      );
    } else {
      var comic = await comicSource.loadComicInfo!(widget.id);
      if (comic.error) {
        return Res.fromErrorRes(comic);
      }
      _comicStateRepository.mirrorComicDetails(comic.data);
      return Res(
        ReaderProps(
          type: state.identity.type,
          cid: widget.id,
          name: comic.data.title,
          chapters: comic.data.chapters,
          history:
              history ?? History.fromModel(model: comic.data, ep: 0, page: 0),
          author: comic.data.findAuthor() ?? "",
          tags: comic.data.plainTags,
        ),
      );
    }
  }
}

class ReaderProps {
  final ComicType type;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  final History history;

  final String author;

  final List<String> tags;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
  });
}
