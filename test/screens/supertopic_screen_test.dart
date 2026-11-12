import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/super_topic_screen.dart';

import '../helpers/fakes.dart';

/// 超话页组件测试（假服务，绝不发真实请求）：
/// 关注/取关/签到按钮态来自 extend 状态，写动作调对应服务方法，
/// 帖子流渲染；未登录点关注走登录守卫。
class _SuperFake extends FakeWeiyueService {
  SuperTopicState state = const SuperTopicState();
  int followCalls = 0;
  int unfollowCalls = 0;
  int checkinCalls = 0;

  @override
  Future<SuperTopicState> getSuperTopicState(String pageId) async => state;

  @override
  Future<ContainerPage> getSuperTopicStatuses(
    String pageId, {
    int page = 1,
  }) async =>
      ContainerPage(
        statuses: page == 1 ? [makeStatus(id: 's1', text: '超话里的帖子')] : [],
        total: 1,
        nextPage: 0,
      );

  @override
  Future<String> followSuperTopic(String pageId) async {
    followCalls++;
    return '已关注';
  }

  @override
  Future<String> unfollowSuperTopic(String pageId) async {
    unfollowCalls++;
    return '关注';
  }

  @override
  Future<({String title, String subTitle})> checkinSuperTopic(
    String pageId,
  ) async {
    checkinCalls++;
    return (title: '签到成功', subTitle: '已连续签到 3 天');
  }
}

Future<void> _pump(WidgetTester tester, _SuperFake fake) async {
  await tester.pumpWidget(
    wrapWithProviders(
      const SuperTopicScreen(pageId: '100808abcdef0123', title: '测试'),
      weibo: fake,
      session: FakeSessionService(loggedIn: true),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('页头：未关注显示关注+签到，点关注后变已关注', (tester) async {
    final fake = _SuperFake();
    await _pump(tester, fake);
    expect(find.text('超话里的帖子'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '关注'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '签到'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '关注'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.followCalls, 1);
    expect(find.widgetWithText(OutlinedButton, '已关注'), findsOneWidget);
  });

  testWidgets('签到：点签到弹成功标题，按钮变已签到且不可再点', (tester) async {
    final fake = _SuperFake();
    await _pump(tester, fake);
    await tester.tap(find.widgetWithText(FilledButton, '签到'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fake.checkinCalls, 1);
    expect(find.text('签到成功'), findsOneWidget);
    expect(find.text('已连续签到 3 天'), findsOneWidget);

    await tester.tap(find.text('我知道了'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已签到'), findsOneWidget);
  });

  testWidgets('已关注+已签到初态：按钮文案来自状态，取关要先确认', (tester) async {
    final fake = _SuperFake()
      ..state = const SuperTopicState(
        isFollowed: true,
        followBtnText: '已关注',
        isChecked: true,
      );
    await _pump(tester, fake);
    expect(find.widgetWithText(OutlinedButton, '已关注'), findsOneWidget);
    expect(find.text('已签到'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '已关注'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('确定不再关注此超话？'), findsOneWidget);
    expect(fake.unfollowCalls, 0);

    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.unfollowCalls, 1);
  });
}
