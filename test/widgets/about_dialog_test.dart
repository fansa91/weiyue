import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:weiyue/widgets/about_dialog.dart';

PackageInfo _fakeInfo({String version = '9.9.9', String buildNumber = '42'}) {
  return PackageInfo(
    appName: '微阅',
    packageName: 'com.weiyue.app',
    version: version,
    buildNumber: buildNumber,
  );
}

void main() {
  testWidgets('关于对话框：显示注入的版本号与构建号', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeiyueAboutDialog(infoLoader: () async => _fakeInfo()),
        ),
      ),
    );
    // FutureBuilder 首帧未完成时不应出现假版本号。
    expect(find.textContaining('版本 9.9.9'), findsNothing);
    await tester.pump();
    expect(find.text('关于微阅'), findsOneWidget);
    expect(find.textContaining('版本 9.9.9'), findsOneWidget);
    expect(find.textContaining('构建 42'), findsOneWidget);
  });

  testWidgets('关于对话框：构建号为空时只显示版本', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeiyueAboutDialog(
            infoLoader: () async => _fakeInfo(version: '0.1.5', buildNumber: ''),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('版本 0.1.5'), findsOneWidget);
    expect(find.textContaining('构建'), findsNothing);
  });
}
