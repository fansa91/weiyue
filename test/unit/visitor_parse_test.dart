import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/services/visitor_service.dart';

void main() {
  const genBody =
      'gen_callback({"retcode":20000000,"msg":"succ","data":{"tid":"01AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd","new_tid":false}})';
  const incBody =
      'cross_domain({"retcode":20000000,"msg":"succ","data":{"crossdomain":1,"login_url":"","islogin":0,"uid":"","nick":"","sub":"_2A25TESTSUBVALUE9f8e7d6c5b4a","subp":"0033TESTSUBPVALUE1a2b3c4d5e"}})';

  test('genvisitor 提取 tid', () {
    expect(VisitorService.extractTid(genBody),
        '01AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd');
  });

  test('incarnate 提取 sub/subp', () {
    expect(VisitorService.extractSub(incBody), '_2A25TESTSUBVALUE9f8e7d6c5b4a');
    expect(
        VisitorService.extractSubp(incBody), '0033TESTSUBPVALUE1a2b3c4d5e');
  });

  test('异常响应返回 null', () {
    expect(VisitorService.extractTid(''), isNull);
    expect(VisitorService.extractTid('{"error":"visitor closed"}'), isNull);
    expect(VisitorService.extractSub('<html>302</html>'), isNull);
    expect(VisitorService.extractSubp('cross_domain({"data":{}})'), isNull);
  });
}
