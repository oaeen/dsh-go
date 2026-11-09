import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/files/files_page.dart';
import 'package:dsh_app/ui/forum/forum_home_page.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../search/support.dart';
import '../shell/golden_harness.dart';

FeatureItem item(String id) => featureSections.expand((section) => section.items).singleWhere((item) => item.id == id);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('论坛有原生入口，文件标题一致，搜索使用返回结果的 action', () {
    final forum = item('forum');
    expect(forum.title, '论坛');
    expect(forum.native!(null), isA<ForumHomePage>());
    expect(forum.web, isNull);
    final files = item('files');
    expect(files.title, '文件');
    expect(files.native!('s1'), isA<WorkspaceFilesPage>());
    expect(item('search').action, isNotNull);
    expect(item('search').native, isNull);
  });

  test('只有引擎语音和网页版保留 web 入口', () {
    final webIds = featureSections
        .expand((section) => section.items)
        .where((item) => item.web != null)
        .map((item) => item.id)
        .toSet();
    expect(webIds, {'voice-input', 'web'});
  });

  testWidgets('搜索对话 action 返回首页并选中对应对话', (tester) async {
    usePhoneSurface(tester);
    final backend = FakeContentSearch();
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [
          sessionsProvider.overrideWith(() => SearchSessions(sampleSearchSessions())),
          sessionContentSearchProvider.overrideWithValue(backend),
          currentSessionProvider.overrideWith(() => FakeCurrentSession('s1')),
        ],
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => item('search').action!(context, ref, 's1'),
                child: const Text('搜索对话'),
              ),
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    await tester.tap(find.text('搜索对话'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionSearchPage), findsOneWidget);
    expect(container.read(currentSessionProvider), 's1');
    await tester.enterText(find.byType(TextField), '登录');
    await tester.pump(SessionSearchController.debounce);
    await tester.pumpAndSettle();
    final result = find.ancestor(of: find.text('登录页加上记住密码'), matching: find.byType(SearchResultTile));
    expect(result, findsOneWidget);
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(container.read(currentSessionProvider), 's2');
    expect(find.byType(SessionSearchPage), findsNothing);
    expect(find.text('搜索对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
