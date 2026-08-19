import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

class TranslatedComicsPage extends StatefulWidget {
  const TranslatedComicsPage({super.key});

  @override
  State<TranslatedComicsPage> createState() => _TranslatedComicsPageState();
}

class _TranslatedComicsPageState extends State<TranslatedComicsPage> {
  var keyword = '';
  final searchController = TextEditingController();

  @override
  void initState() {
    TranslationStore().addListener(_reload);
    super.initState();
  }

  @override
  void dispose() {
    TranslationStore().removeListener(_reload);
    searchController.dispose();
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() {});
  }

  List<StoredTranslationComic> get _items {
    var query = keyword.trim().toLowerCase();
    return ImageTranslationService.translatedComics.where((comic) {
      if (query.isEmpty) return true;
      var source = ComicSource.find(comic.sourceKey)?.name ?? comic.sourceKey;
      return comic.title.toLowerCase().contains(query) ||
          comic.comicId.toLowerCase().contains(query) ||
          source.toLowerCase().contains(query);
    }).toList();
  }

  Comic _asComic(StoredTranslationComic item) {
    var title = item.title.isEmpty ? item.comicId : item.title;
    var source = ComicSource.find(item.sourceKey)?.name ?? item.sourceKey;
    return Comic(
      title,
      item.cover,
      item.comicId,
      source,
      const [],
      '',
      item.sourceKey,
      null,
      null,
    );
  }

  StoredTranslationComic? _findStored(Comic comic) {
    for (var item in _items) {
      if (item.comicId == comic.id && item.sourceKey == comic.sourceKey) {
        return item;
      }
    }
    return null;
  }

  void _delete(StoredTranslationComic comic) {
    showConfirmDialog(
      context: context,
      title: 'Delete all translations for this comic?'.tl,
      content:
          'This removes every stored translation and rendered page of this comic. The original images are unaffected.'
              .tl,
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        var running = PreTranslationTaskManager.instance.runningTaskFor(
          comic.comicId,
          comic.sourceKey,
        );
        if (running != null) {
          PreTranslationTaskManager.instance.cancel(running.id);
        }
        await ImageTranslationService.instance.retranslate(
          comic.comicId,
          comic.sourceKey,
        );
        PreTranslationTaskManager.instance.resetComicStatus(
          comic.comicId,
          comic.sourceKey,
        );
        if (mounted) {
          setState(() {});
          App.rootContext.showMessage(
            message: 'Translation results cleared'.tl,
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    var stored = _items;
    var comics = stored.map(_asComic).toList();
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(title: Text('Translated Comics'.tl)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: AppSearchField(
                controller: searchController,
                onChanged: (value) => setState(() => keyword = value),
              ),
            ),
          ),
          if (comics.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  ImageTranslationService.translatedComics.isEmpty
                      ? 'No translated comics'.tl
                      : 'No matching items'.tl,
                  style: ts.s16,
                ),
              ),
            )
          else
            SliverGridComics(
              comics: comics,
              enableHero: false,
              badgeBuilder: (comic) {
                var item = _findStored(comic);
                return item == null
                    ? null
                    : '@count chapters'.tlParams({'count': item.chapterCount});
              },
              onTap: (comic, _) {
                var item = _findStored(comic);
                if (item != null) openTranslatedChaptersPage(context, item);
              },
              menuBuilder: (comic) {
                var item = _findStored(comic);
                if (item == null) return const [];
                return [
                  MenuEntry(
                    icon: Icons.delete_outline_rounded,
                    text: 'Delete all translations'.tl,
                    color: context.colorScheme.error,
                    onClick: () => _delete(item),
                  ),
                ];
              },
            ),
        ],
      ),
    );
  }
}
