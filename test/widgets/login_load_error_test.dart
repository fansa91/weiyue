import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/screens/login_screen.dart';

void main() {
  testWidgets('登录加载失败面板：显示原因文本，两个恢复按钮可点', (tester) async {
    var retried = 0;
    var direct = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginLoadErrorView(
            message: '页面加载失败：net::ERR_CLEARTEXT_NOT_PERMITTED（https://m.weibo.cn/）',
            onRetry: () => retried++,
            onDirectLogin: () => direct++,
          ),
        ),
      ),
    );

    expect(find.textContaining('ERR_CLEARTEXT_NOT_PERMITTED'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
    expect(find.text('换直达登录页'), findsOneWidget);

    await tester.tap(find.text('重新加载'));
    await tester.tap(find.text('换直达登录页'));
    expect(retried, 1);
    expect(direct, 1);
  });
}
