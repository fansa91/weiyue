import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/widgets/vote_view.dart';

import '../helpers/fakes.dart';

/// VoteView 组件测试（假服务记录调用，绝不发真实请求）：
/// 单选点投、多选勾选后提交、已投点选项撤回、未登录守卫。
class _VoteFake extends FakeWeiyueService {
  final List<List<int>> castCalls = [];
  int cancelCalls = 0;
  WbVote? nextVote;
  String? nextError;

  @override
  Future<({WbVote? vote, String? errorMsg})> setVote(
    int voteId,
    List<int> itemIds,
  ) async {
    castCalls.add(itemIds);
    return (vote: nextVote, errorMsg: nextError);
  }

  @override
  Future<({WbVote? vote, String? errorMsg})> cancelVote(int voteId) async {
    cancelCalls++;
    return (vote: nextVote, errorMsg: nextError);
  }
}

const _items = [
  WbVoteItem(id: 11, content: '火锅', partNum: 70, partRatio: 0.55),
  WbVoteItem(id: 12, content: '烧烤', partNum: 58, partRatio: 0.45),
];

const _single = WbVote(
  id: 88001,
  items: _items,
  partInfo: 128,
  minimum: 1,
  maximum: 1,
);

const _multi = WbVote(
  id: 88002,
  items: _items,
  partInfo: 128,
  multiSelect: true,
  minimum: 2,
  maximum: 2,
);

const _votedResult = WbVote(
  id: 88001,
  items: [
    WbVoteItem(id: 11, content: '火锅', partNum: 71, partRatio: 0.55, selected: true),
    WbVoteItem(id: 12, content: '烧烤', partNum: 58, partRatio: 0.45),
  ],
  partInfo: 129,
  voted: true,
  minimum: 1,
  maximum: 1,
);

Future<void> _pumpVote(
  WidgetTester tester,
  WbVote vote,
  _VoteFake fake, {
  bool loggedIn = true,
}) async {
  await tester.pumpWidget(
    wrapWithProviders(
      Scaffold(body: VoteView(vote: vote, service: fake)),
      session: FakeSessionService(loggedIn: loggedIn),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('单选：未投显示选项，点选项直接投并换成结果态', (tester) async {
    final fake = _VoteFake()..nextVote = _votedResult;
    await _pumpVote(tester, _single, fake);
    expect(find.text('火锅'), findsOneWidget);
    expect(find.textContaining('128 人参与'), findsOneWidget);
    expect(find.textContaining('票 ·'), findsNothing); // 还没结果条

    await tester.tap(find.text('烧烤'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.castCalls, [
      [12],
    ]);
    // 回执整替后进入结果态：票数/占比出现
    expect(find.textContaining('71 票'), findsOneWidget);
    expect(find.textContaining('已投票'), findsOneWidget);
  });

  testWidgets('多选：勾满 minimum 才可提交，提交传全部勾选 id', (tester) async {
    final fake = _VoteFake()
      ..nextVote = const WbVote(
        id: 88002,
        items: _items,
        partInfo: 130,
        multiSelect: true,
        voted: true,
        minimum: 2,
        maximum: 2,
      );
    await _pumpVote(tester, _multi, fake);
    final submit = find.widgetWithText(FilledButton, '投票');
    expect(submit, findsOneWidget);
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);

    await tester.tap(find.text('火锅'));
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.tap(find.text('烧烤'));
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);

    await tester.tap(submit);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.castCalls, [
      [11, 12],
    ]);
  });

  testWidgets('已投：点选项弹确认，确认后调 cancelVote 并回到未投态', (tester) async {
    final fake = _VoteFake()..nextVote = _single;
    await _pumpVote(tester, _votedResult, fake);
    expect(find.textContaining('71 票'), findsOneWidget);

    await tester.tap(find.text('火锅'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('是否撤回投票？'), findsOneWidget);

    await tester.tap(find.text('撤回'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.cancelCalls, 1);
    expect(find.textContaining('票 ·'), findsNothing); // 回到选项态
  });

  testWidgets('已结束：只展示结果，点选项不触发任何调用', (tester) async {
    final fake = _VoteFake();
    await _pumpVote(
      tester,
      const WbVote(
        id: 88003,
        items: _items,
        partInfo: 128,
        ended: true,
        minimum: 1,
        maximum: 1,
      ),
      fake,
    );
    expect(find.textContaining('已结束'), findsOneWidget);
    expect(find.textContaining('70 票'), findsOneWidget);
    await tester.tap(find.text('火锅'));
    await tester.pump();
    expect(fake.castCalls, isEmpty);
    expect(fake.cancelCalls, 0);
  });

  testWidgets('未登录：点选项只弹登录提示，不调服务', (tester) async {
    final fake = _VoteFake();
    await _pumpVote(tester, _single, fake, loggedIn: false);
    await tester.tap(find.text('火锅'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.castCalls, isEmpty);
    expect(find.text('登录后可用'), findsOneWidget);
  });
}
