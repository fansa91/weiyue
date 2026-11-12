import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/edit_profile_screen.dart';

import '../helpers/fakes.dart';

/// 编辑资料页组件测试（假服务记录保存表单，绝不发真实请求）：
/// 预填、昵称保存并同步会话昵称、性别选中即存、情感下拉保存。
class _EditFake extends FakeWeiyueService {
  final List<Map<String, dynamic>> basicForms = [];
  final List<String> singleCalls = [];

  static const info = ProfileBasicInfo(
    screenName: '旧昵称',
    description: '旧简介',
    gender: 'f',
    birthday: '1995-03-04',
    province: '11',
    city: '1',
    single: '1',
    provinceNames: {'11': '北京', '31': '上海'},
    cityNames: {
      '北京': {'1': '东城区', '2': '西城区'},
      '上海': {'1': '黄浦区'},
    },
  );

  @override
  Future<ProfileBasicInfo> getProfileBasicInfo() async => info;

  @override
  Future<String> updateProfileBasic(Map<String, dynamic> form) async {
    basicForms.add(form);
    return '';
  }

  @override
  Future<void> updateProfileSingle(String value) async {
    singleCalls.add(value);
  }
}

/// 记录 saveProbe 的会话替身（断言昵称保存后同步回会话）。
class _RecSession extends FakeSessionService {
  _RecSession() : super(loggedIn: true);
  String? savedScreenName;

  @override
  Future<void> saveProbe({
    String uid = '',
    String screenName = '',
    String avatar = '',
    bool? pcUnlocked,
    bool? mUnlocked,
  }) async {
    if (screenName.isNotEmpty) savedScreenName = screenName;
  }
}

Future<_RecSession> _pump(WidgetTester tester, _EditFake fake) async {
  final session = _RecSession();
  await tester.pumpWidget(
    wrapWithProviders(
      EditProfileScreen(service: fake),
      weibo: fake,
      session: session,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return session;
}

void main() {
  testWidgets('预填：昵称/简介/性别/地区来自 getBasicInfo', (tester) async {
    final fake = _EditFake();
    await _pump(tester, fake);
    expect(find.widgetWithText(TextField, '旧昵称'), findsOneWidget);
    expect(find.widgetWithText(TextField, '旧简介'), findsOneWidget);
    final female = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '女'),
    );
    expect(female.selected, isTrue);
    expect(find.text('1995-03-04'), findsOneWidget);
    // 地区行在折叠线以下，滚动后才构建
    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('北京'), findsOneWidget);
    expect(find.text('东城区'), findsOneWidget);
  });

  testWidgets('改昵称保存：表单 {screen_name} 且会话昵称同步', (tester) async {
    final fake = _EditFake();
    final session = await _pump(tester, fake);
    await tester.enterText(
      find.widgetWithText(TextField, '旧昵称'),
      '新昵称',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.basicForms, [
      {'screen_name': '新昵称'},
    ]);
    expect(session.savedScreenName, '新昵称');
  });

  testWidgets('性别选中即存：点「男」发 {gender: m}', (tester) async {
    final fake = _EditFake();
    await _pump(tester, fake);
    await tester.tap(find.widgetWithText(ChoiceChip, '男'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.basicForms, [
      {'gender': 'm'},
    ]);
  });

  testWidgets('情感状态：下拉选「恋爱中」走 updateProfileSingle(5)', (tester) async {
    final fake = _EditFake();
    await _pump(tester, fake);
    await tester.tap(find.text('单身'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('恋爱中').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.singleCalls, ['5']);
  });
}
