import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/following_screen.dart';
import 'package:weiyue/screens/me_screen.dart';
import 'package:weiyue/screens/profile_screen.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 登录资料补全 + 我的关注的界面测试。资料/列表数据都是构造假数据，
/// 登录态真实行为待用户真机验证。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

const _profileUser = WbUser(
  id: 777,
  screenName: '构造测试本人',
  avatar: 'https://example.com/me_large.jpg',
  verified: true,
  verifiedType: 0,
  verifiedReason: '构造认证说明',
  description: '这是构造的本人简介',
  followersCount: 123456,
  followersCountStr: '12.3万',
  friendsCount: 321,
  statusesCount: 4567,
  location: '上海',
  coverImagePhone: 'https://example.com/cover_phone.jpg',
);

/// 探活后自动补拉用的假服务：getMyProfile 返回完整资料。
class _ProfileService extends FakeWeiyueService {
  @override
  Future<WbUser> getMyProfile(String uid) async => const WbUser(
    id: 777,
    screenName: '自动补拉本人',
    description: '自动补拉的简介',
    followersCount: 100,
    friendsCount: 2,
    statusesCount: 3,
  );
}

class _FailFollowingService extends FakeWeiyueService {
  @override
  Future<({List<WbUser> users, int total})> getMyFollowing(
    String uid, {
    int page = 1,
    int count = 20,
  }) async => throw const WeiyueException('网络错误：连接超时');
}

void main() {
  group('MeScreen 资料头', () {
    testWidgets('已登录+有资料：封面/认证/简介/所在地/三项计数/我的关注齐全', (tester) async {
      await mockNetworkImagesFor(() async {
        final session = FakeSessionService(loggedIn: true)
          ..fakeProfile = _profileUser;
        await tester.pumpWidget(
          wrapWithProviders(const MeScreen(), session: session),
        );
        await _settle(tester);
        expect(find.text('构造测试本人'), findsOneWidget);
        expect(find.text('构造认证说明'), findsOneWidget);
        expect(find.text('这是构造的本人简介'), findsOneWidget);
        expect(find.text('上海'), findsOneWidget);
        // 三项计数（紧凑格式化）与标签
        expect(find.text('321'), findsOneWidget);
        expect(find.text('12.3万'), findsOneWidget);
        expect(find.text('4567'), findsOneWidget);
        expect(find.text('关注'), findsOneWidget);
        expect(find.text('粉丝'), findsOneWidget);
        expect(find.text('动态'), findsOneWidget);
        // 刷新资料入口 + 我的关注入口都在
        expect(find.byTooltip('刷新资料'), findsOneWidget);
        expect(find.text('我的关注'), findsOneWidget);
        expect(find.text('我的收藏'), findsOneWidget);
      });
    });

    testWidgets('已登录无资料：自动补拉后升级为资料头', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          wrapWithProviders(
            const MeScreen(),
            weibo: _ProfileService(),
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        expect(find.text('自动补拉本人'), findsOneWidget);
        expect(find.text('自动补拉的简介'), findsOneWidget);
      });
    });

    testWidgets('未登录：无资料头、无我的关注/我的收藏入口', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(wrapWithProviders(const MeScreen()));
        await _settle(tester);
        expect(find.text('账号登录'), findsOneWidget);
        expect(find.text('我的关注'), findsNothing);
        expect(find.text('我的收藏'), findsNothing);
        expect(find.text('这是构造的本人简介'), findsNothing);
        expect(find.byTooltip('刷新资料'), findsNothing);
      });
    });

    testWidgets('点资料头「关注」计数进关注列表', (tester) async {
      await mockNetworkImagesFor(() async {
        final session = FakeSessionService(loggedIn: true)
          ..fakeProfile = _profileUser;
        await tester.pumpWidget(
          wrapWithProviders(const MeScreen(), session: session),
        );
        await _settle(tester);
        await tester.tap(find.text('关注'));
        await _settle(tester);
        expect(find.byType(FollowingScreen), findsOneWidget);
        expect(find.text('关注博主甲'), findsOneWidget);
      });
    });
  });

  group('FollowingScreen', () {
    testWidgets('列表渲染 + 总数 + 点行进主页', (tester) async {
      await mockNetworkImagesFor(() async {
        final session = FakeSessionService(loggedIn: true)
          ..fakeProfile = _profileUser;
        await tester.pumpWidget(
          wrapWithProviders(const MeScreen(), session: session),
        );
        await _settle(tester);
        await tester.scrollUntilVisible(find.text('我的关注'), 200);
        await tester.tap(find.text('我的关注'));
        await _settle(tester);
        expect(find.byType(FollowingScreen), findsOneWidget);
        // 总数以接口返回为准（假服务 total=2）
        expect(find.text('共关注 2 人'), findsOneWidget);
        expect(find.text('关注博主甲'), findsOneWidget);
        expect(find.text('甲的简介'), findsOneWidget);
        expect(find.text('关注博主乙'), findsOneWidget);
        // 乙无简介 → 副标题回退粉丝数
        expect(find.text('粉丝 99'), findsOneWidget);

        await tester.tap(find.text('关注博主甲'));
        await _settle(tester);
        expect(find.byType(ProfileScreen), findsOneWidget);
      });
    });

    testWidgets('加载失败：错误提示 + 重试按钮', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          wrapWithProviders(
            const FollowingScreen(uid: '777'),
            weibo: _FailFollowingService(),
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        expect(find.textContaining('加载失败'), findsOneWidget);
        expect(find.text('重试'), findsOneWidget);
      });
    });
  });
}
