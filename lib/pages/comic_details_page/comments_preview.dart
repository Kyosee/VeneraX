part of 'comic_page.dart';

class _CommentsPart extends StatefulWidget {
  const _CommentsPart({required this.comments, required this.showMore});

  final List<Comment> comments;

  final void Function() showMore;

  @override
  State<_CommentsPart> createState() => _CommentsPartState();
}

class _CommentsPartState extends State<_CommentsPart> {
  final scrollController = ScrollController();

  late List<Comment> comments;

  @override
  void initState() {
    comments = widget.comments.where((c) => !_shouldBlockComment(c)).toList();
    super.initState();
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  void _scrollBy(double delta) {
    if (!scrollController.hasClients) return;
    final target = (scrollController.position.pixels + delta).clamp(
      0.0,
      scrollController.position.maxScrollExtent,
    );
    scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (comments.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    final cardWidth = math.min(324.0, math.max(240.0, context.width - 56));
    return MultiSliver(
      children: [
        SliverLazyToBoxAdapter(
          child: _ComicSectionHeader(
            icon: Icons.forum_outlined,
            title: "Comments".tl,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (context.width >= 600) ...[
                  IconButton(
                    tooltip: "Previous".tl,
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: () => _scrollBy(-cardWidth - 8),
                  ),
                  IconButton(
                    tooltip: "Next".tl,
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: () => _scrollBy(cardWidth + 8),
                  ),
                ],
                TextButton(
                  onPressed: widget.showMore,
                  child: Text("View more".tl),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 188,
                child: MediaQuery.removePadding(
                  removeTop: true,
                  context: context,
                  child: ListView.builder(
                    controller: scrollController,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    itemCount: comments.length,
                    itemBuilder: (context, index) {
                      return _CommentWidget(
                        comment: comments[index],
                        width: cardWidth,
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }
}

class _CommentWidget extends StatelessWidget {
  const _CommentWidget({required this.comment, required this.width});

  final Comment comment;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: double.infinity,
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      width: width,
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            children: [
              if (comment.avatar != null)
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: context.colorScheme.surfaceContainer,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image(
                    image: CachedImageProvider(comment.avatar!),
                    width: 36,
                    height: 36,
                    fit: BoxFit.cover,
                  ),
                ).paddingRight(8),
              Text(comment.userName, style: ts.bold),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: RichCommentContent(
              text: comment.content,
              showImages: false,
            ).fixWidth(width - 32),
          ),
          const SizedBox(height: 4),
          if (comment.time != null)
            Text(comment.time!, style: ts.s12).toAlign(Alignment.centerLeft),
        ],
      ),
    );
  }
}
