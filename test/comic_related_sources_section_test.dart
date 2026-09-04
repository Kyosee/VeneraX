import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/pages/comic_details_page/related_sources_section.dart';
import 'package:venera/utils/translations.dart';

DomainComicSourceLink _link({
  required String comicId,
  required String platformId,
  required String sourceName,
  required String status,
}) {
  return DomainComicSourceLink(
    workId: 'work',
    comicId: comicId,
    comicTitle: 'Comic',
    platformId: platformId,
    sourceComicId: '$comicId-source-id',
    sourceName: sourceName,
    comicAuthor: 'Author',
    comicStatus: 'Ongoing',
    comicCoverUri: null,
    status: status,
    linkSource: status == 'candidate' ? 'auto' : 'manual',
    confidence: status == 'candidate' ? 0.95 : 1,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);

  testWidgets('related sources stay collapsed until the summary is tapped', (
    tester,
  ) async {
    final links = [
      _link(
        comicId: 'current',
        platformId: 'remote:current_source',
        sourceName: 'Current Source',
        status: 'accepted',
      ),
      _link(
        comicId: 'linked',
        platformId: 'remote:linked_source',
        sourceName: 'Linked Source',
        status: 'accepted',
      ),
      _link(
        comicId: 'candidate',
        platformId: 'remote:candidate_source',
        sourceName: 'Candidate Source',
        status: 'candidate',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicRelatedSourcesSection(
            links: links,
            currentComicId: 'current',
            onManage: () {},
            onOpenSource: (_) {},
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('comic-related-sources-section')), findsOne);
    expect(find.byKey(const Key('comic-related-source-current')), findsNothing);
    expect(find.byKey(const Key('comic-related-source-linked')), findsNothing);
    expect(find.byIcon(Icons.expand_more_rounded), findsOne);

    await tester.tap(find.byKey(const Key('comic-related-sources-toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('comic-related-source-current')), findsOne);
    expect(find.byKey(const Key('comic-related-source-linked')), findsOne);
    expect(find.byKey(const Key('comic-related-source-candidate')), findsOne);
    expect(find.byIcon(Icons.expand_less_rounded), findsOne);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('comic-related-sources-toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('comic-related-source-current')), findsNothing);
  });

  testWidgets('linked source opens directly and manage keeps its callback', (
    tester,
  ) async {
    final current = _link(
      comicId: 'current',
      platformId: 'remote:current_source',
      sourceName: 'Current Source',
      status: 'accepted',
    );
    final linked = _link(
      comicId: 'linked',
      platformId: 'remote:linked_source',
      sourceName: 'Linked Source',
      status: 'accepted',
    );
    DomainComicSourceLink? opened;
    var manageCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicRelatedSourcesSection(
            links: [current, linked],
            currentComicId: 'current',
            onManage: () => manageCount++,
            onOpenSource: (link) => opened = link,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('comic-related-sources-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('comic-related-source-linked')));

    expect(opened, same(linked));

    await tester.tap(find.byKey(const Key('comic-related-sources-manage')));
    expect(manageCount, 1);
  });

  testWidgets('linked search result shows status and unlink instead of link', (
    tester,
  ) async {
    var unlinkCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RelatedSearchLinkActions(
              isLinked: true,
              isCurrent: false,
              onLink: () => fail('linked result must not expose link action'),
              onUnlink: () => unlinkCount++,
              unlinkKey: const Key('unlink'),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('related-search-linked-actions')), findsOne);
    expect(find.byKey(const Key('related-search-link-action')), findsNothing);
    expect(find.byIcon(Icons.link_off), findsOne);

    await tester.tap(find.byKey(const Key('unlink')));
    expect(unlinkCount, 1);
  });
}
