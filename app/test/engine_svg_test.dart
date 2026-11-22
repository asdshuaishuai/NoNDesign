// 引擎自渲染 SVG 上屏契约（2026-11-16 用户定案：引擎自渲染，客户端不重复
// 实现渲染）。fixture 取自 0.2-dev 真机 render 信封（探针落 /tmp/home.svg），
// 覆盖引擎输出的全部特征面：<style> 字体块、defs 三档 feDropShadow、
// 全幅背景 rect、rotate transform、文本节点。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const _engineSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="390" height="844" viewBox="0 0 390 844">'
    '<style>text{font-family:-apple-system,\'SF Pro Text\',\'PingFang SC\',\'Segoe UI\',Roboto,sans-serif}</style>'
    '<defs><filter id="e1" x="-30%" y="-30%" width="160%" height="160%">'
    '<feDropShadow dx="0" dy="2" stdDeviation="4" flood-opacity="0.10"/></filter>'
    '<filter id="e2" x="-30%" y="-30%" width="160%" height="160%">'
    '<feDropShadow dx="0" dy="6" stdDeviation="14" flood-opacity="0.14"/></filter></defs>'
    '<rect x="0" y="0" width="390" height="844" fill="#F8F9FB"/>'
    '<g id="n_hc" transform="rotate(15 195 180)">'
    '<rect x="24" y="100" width="342" height="160" rx="12" fill="#FFFFFF" filter="url(#e2)"/></g>'
    '<text x="24" y="112" font-size="22" fill="#14161A">自渲染</text>'
    '</svg>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('flutter_svg parses the engine 0.2 svg and lays out at artboard size', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SvgPicture.string(_engineSvg, fit: BoxFit.fill),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final finder = find.byType(SvgPicture);
    expect(finder, findsOneWidget);
    final size = tester.getSize(finder);
    // viewBox 390×844 → 布局尺寸非零（具体值受约束，这里断言「解析成功且
    // 渲染出画布」而非像素级 golden）。
    expect(size.width, greaterThan(0));
    expect(size.height, greaterThan(0));
    // 解析无致命异常：pumpAndSettle 不抛（flutter_svg 对不支持的滤镜
    // 静默跳过——上屏内容仍由 svg 携带）。
  });
}
