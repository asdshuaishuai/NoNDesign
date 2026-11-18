import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/keys.dart';
import '../core/models.dart';
import '../core/portfolio_entries.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/toast_service.dart';
import 'common.dart';
import 'hotapp_workspace.dart';
import 'three_workspace.dart';
import 'video_workspace.dart';
import 'workspace.dart';

/// 主页（用户裁决：布局固定不变，是死规矩）。
///
/// 结构只有三层：顶部品牌栏、中间「一句话 + 目标工作台」入口、下面并排
/// 作品集 / 最近项目；底部状态行。**主页不再列插件工作台，也没有「工作方式」
/// 说明卡**——目标工作台由输入卡里的选择器决定，其余入口走顶栏/⌘5–7。
class Welcome extends StatefulWidget {
  final VoidCallback onNewProject;
  final void Function(String path) onOpenPath;
  final VoidCallback onSettings;

  /// 「聊天」入口：桌面壳展开右侧聊天窄栏；手机经典主面切回聊天流。
  /// 缺省回退 `store.setView('chat')`（独立使用 Welcome 时的旧语义）。
  final VoidCallback? onOpenChat;

  /// 是否显示顶栏聊天入口。桌面主页没有右侧栏，隐藏它避免死按钮；
  /// 手机/iPad 经典 Welcome 仍显示（默认 true）。
  final bool showChatEntry;

  const Welcome({
    super.key,
    required this.onNewProject,
    required this.onOpenPath,
    required this.onSettings,
    this.onOpenChat,
    this.showChatEntry = true,
  });

  @override
  State<Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<Welcome> {
  final _brief = TextEditingController();

  /// 副标题：一句话说清 NaN 能做什么（设计 / 3D / 视频 / 热应用），不写内部代称。
  static const _subtitle = '一句话说清你要解决的问题和受众。NaN 会先写设计文档、再落成可交互原型，'
      '也能直接做 3D 场景、代码生成的视频，以及带本地数据的热应用。';

  /// 宽屏内容列**不写死宽度**：左右留白按窗口宽的比例收缩（6%，收敛到
  /// 16–96），内容列 = 窗口宽 - 两侧留白，所以窗口变宽时内容跟着变宽、
  /// 留白始终对称；1440 下约 1267（原固定 720/1040 会在大窗口重新裂出色带）。
  static const double _wideGutterRatio = 0.06;

  /// 窄屏边距同样按比例（4.5%，收敛到 14–28），不写死 18。
  static const double _narrowGutterRatio = 0.045;

  /// 可视高度决定上下留白/段落间距：窗口矮就收紧，避免矮窗里先被留白挤爆。
  static const double _wideVerticalRatio = 0.017;
  static const double _wideSectionRatio = 0.034;

  double _wideGutter(double width) => (width * _wideGutterRatio).clamp(16.0, 96.0).toDouble();
  double _narrowGutter(double width) => (width * _narrowGutterRatio).clamp(14.0, 28.0).toDouble();

  @override
  void initState() {
    super.initState();
    // boot() already refreshes; this covers a server that came up late.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.read<AppStore>();
      if (store.serverProjects.isEmpty && !store.refreshingProjects) store.refreshProjects();
    });
  }

  @override
  void dispose() {
    _brief.dispose();
    super.dispose();
  }

  void _start(AppStore store) {
    final brief = _brief.text.trim();
    if (brief.isEmpty || store.agentBusy) return;
    if (store.settings.apiKey.trim().isEmpty) {
      widget.onSettings();
      ToastService.instance.warn('还没配置模型', '先在设置里选择服务商并填入密钥');
      return;
    }
    // 走聊天入口：目标工作台来自 store.chatWorkspaceMode（输入卡选择器），
    // 不在调用处传参——模式是持久化状态，发送时自动生效。
    store.sendChat(brief);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Scaffold(
      backgroundColor: p.bg,
      body: Stack(
        children: [
          // 整页一张连续背景：底色 + 一个全幅居中的极淡渐变 + 极轻点噪。
          // 用户验收反馈（1440 宽）：原来左右两个角落径向光斑在页面上划出
          // 两条浅色竖带、像是把主页切成了左/中/右三块——主页必须是一个整体。
          Positioned.fill(child: _backdrop(context)),
          Positioned.fill(
            child: CustomPaint(painter: _DotsPainter(p.canvasDot)),
          ),
          SafeArea(
            child: Column(
              children: [
                _brandBar(context, store),
                if (narrow)
                  Expanded(child: _narrowBody(context, store))
                else
                  Expanded(child: _wideBody(context, store)),
                _footer(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 外层 chrome（品牌栏 / 底部状态行）——主页布局是死规矩，这里保持原样。
  // ---------------------------------------------------------------------------

  /// 整页连续背景：[NonPalette.bg] 打底 + 一张全出血、居中、极淡的 accent
  /// 渐变 + 极轻点噪（[_DotsPainter]，同色系不透明度很低）。
  ///
  /// 只有一层铺满整页的渐变，横向没有边界/色带：主页在 1440 宽下是「一个整体」，
  /// 不再被左右两个角落光斑切成左/中/右三块。
  Widget _backdrop(BuildContext context) {
    final p = context.palette;
    return DecoratedBox(
      key: const ValueKey('welcome-backdrop'),
      decoration: BoxDecoration(
        color: p.bg,
        gradient: RadialGradient(
          center: const Alignment(0, -0.15),
          radius: 1.05,
          colors: [
            p.accent.withValues(alpha: 0.055),
            p.accent.withValues(alpha: 0.02),
            p.accent.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
    );
  }

  Widget _brandBar(BuildContext context, AppStore store) {
    final p = context.palette;
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          const NonLogo(size: 26),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NaN',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink)),
                Text('AI CREATION STUDIO',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, letterSpacing: 1.6, color: p.ink4)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // 聊天入口：桌面壳展开右侧窄栏；手机经典主面切回聊天流。
          // 桌面主页没有右栏（2026-11-18），入口由壳层关闭。
          if (widget.showChatEntry)
            IconAction(
              key: const ValueKey('welcome-open-chat'),
              icon: Icons.forum_outlined,
              tooltip: '聊天',
              onTap: widget.onOpenChat ?? () => store.setView('chat'),
            ),
          IconAction(
            icon: store.settings.theme == 'light' ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
            tooltip: '切换主题',
            onTap: () async {
              store.settings.theme = store.settings.theme == 'light' ? 'dark' : 'light';
              await store.saveSettings();
            },
          ),
          IconAction(icon: Icons.settings_outlined, tooltip: '设置', onTap: widget.onSettings),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final p = context.palette;
    return Container(
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text('NaN · 本地创作 · 文档、原型与作品都在你手里 · 所有操作可撤销',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, height: 1.3, color: p.ink4)),
    );
  }

  // ---------------------------------------------------------------------------
  // 宽屏（>=700）：一列内容随窗口自适应（留白/间距按比例，不写死列宽），
  // hero + 输入卡 + 下方两张卡同宽；垂直居中 + 可滚兜底逻辑保留。
  // ---------------------------------------------------------------------------

  Widget _wideBody(BuildContext context, AppStore store) {
    return LayoutBuilder(
      key: const ValueKey('welcome-wide'),
      builder: (context, constraints) {
        final gutter = _wideGutter(constraints.maxWidth);
        final vpad = (constraints.maxHeight * _wideVerticalRatio).clamp(10.0, 24.0).toDouble();
        final columnGap = (constraints.maxWidth * 0.022).clamp(18.0, 40.0).toDouble();
        final sectionGap = (constraints.maxHeight * _wideSectionRatio).clamp(18.0, 34.0).toDouble();
        final cardGap = (constraints.maxWidth * 0.01).clamp(8.0, 20.0).toDouble();
        // 版式（用户裁决 2026-11-19，验收图）：hero 文案占左侧、聊天框缩小后
        // 占右侧一块，不再是一条通栏大框。聊天框按窗口宽的比例收缩到 340–520，
        // 并强制给左侧文案留出至少 300 的阅读宽（窄窗口先压聊天框）。
        final contentWidth = constraints.maxWidth - gutter * 2;
        var composerWidth = (contentWidth * 0.38).clamp(340.0, 520.0).toDouble();
        final heroMin = 300.0;
        final composerCeiling = contentWidth - heroMin - columnGap;
        if (composerWidth > composerCeiling) composerWidth = composerCeiling;
        if (composerWidth < 300) composerWidth = 300;
        return SingleChildScrollView(
          child: ConstrainedBox(
            // 内容短于视口时仍垂直居中；内容更长时整页可滚（1024×768 与
            // 844×390 都靠这条 minHeight + 滚动兜住，不再溢出）。
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.fromLTRB(gutter, vpad, gutter, vpad),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    key: const ValueKey('welcome-hero-row'),
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 左：品牌主张 / 标题 / 副标题（整块左对齐，不再居中）。
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _hero(context, store, narrow: false),
                        ),
                      ),
                      SizedBox(width: columnGap),
                      // 右：聊天框（含左下角的工作台类型选择）。
                      SizedBox(
                        width: composerWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _briefCard(context, store),
                            const SizedBox(height: 6),
                            _briefHints(context),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: sectionGap),
                  // 作品集 / 最近项目：仍两栏并排，宽度吃满内容列（不挤在聊天框下）。
                  // 各自按内容自然高度排在顶部，不强行等高——最近项目列表长，
                  // 拉平会把作品集撑成一块空板。
                  Row(
                    key: const ValueKey('welcome-cards'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _portfolioCard(context, store)),
                      SizedBox(width: cardGap),
                      Expanded(child: _recentCard(context, store)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 窄屏（<700）：同一套内容单列排；边距同样按窗口宽比例。
  // ---------------------------------------------------------------------------

  Widget _narrowBody(BuildContext context, AppStore store) {
    final gutter = _narrowGutter(MediaQuery.sizeOf(context).width);
    return SingleChildScrollView(
      key: const ValueKey('welcome-narrow'),
      padding: EdgeInsets.fromLTRB(gutter, 10, gutter, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _hero(context, store, narrow: true),
          const SizedBox(height: 16),
          _briefCard(context, store),
          const SizedBox(height: 8),
          _briefHints(context),
          const SizedBox(height: 18),
          _portfolioCard(context, store),
          const SizedBox(height: 10),
          _recentCard(context, store),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 标题区（badge / 标题 / 副标题 / 恢复提示）
  // ---------------------------------------------------------------------------

  Widget _hero(BuildContext context, AppStore store, {required bool narrow}) {
    final p = context.palette;
    // 字号也自适应：宽屏跟着窗口宽度缓慢放大（38–52），窄屏固定 32。
    final viewportWidth = MediaQuery.sizeOf(context).width;
    // 标题现在只占左半区（右侧是聊天框）：字号按窗口宽缓增但收敛更低，
    // 避免两行标题把左侧列撑得比聊天框高很多。
    final titleSize = narrow ? 30.0 : (viewportWidth * 0.0235).clamp(32.0, 46.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: p.accentSoft,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: p.accent.withValues(alpha: 0.25)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome, size: 11, color: p.accent),
                const SizedBox(width: 5),
                Text('文档 · 原型 · 3D · 视频 · 热应用',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: p.accent)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            colors: [p.accent, p.accent2, p.danger.withValues(alpha: 0.85)],
          ).createShader(bounds),
          child: Text('把想法变成\n能用的作品',
              style: TextStyle(
                fontSize: titleSize,
                height: narrow ? 1.1 : 1.08,
                fontWeight: FontWeight.w700,
                letterSpacing: narrow ? -1.0 : -1.5,
                color: Colors.white,
              )),
        ),
        SizedBox(height: narrow ? 12 : 14),
        Text(_subtitle, style: TextStyle(fontSize: narrow ? 12.5 : 13, height: narrow ? 1.6 : 1.65, color: p.ink3)),
        if (store.recovery != null) ...[
          const SizedBox(height: 12),
          _recoveryBanner(context, store),
        ],
      ],
    );
  }

  Widget _recoveryBanner(BuildContext context, AppStore store) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: p.warn.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.warn.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Expanded(child: Text('检测到上次未保存的工作', style: TextStyle(fontSize: 11, color: p.warn))),
          TextButton(onPressed: store.restoreRecovery, child: const Text('恢复', style: TextStyle(fontSize: 11))),
          TextButton(onPressed: store.discardRecovery, child: const Text('忽略', style: TextStyle(fontSize: 11))),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 输入卡（宽窄共用）：文本框 → 目标工作台选择器 → 示例 + 开始创作。
  // ---------------------------------------------------------------------------

  Widget _briefCard(BuildContext context, AppStore store) {
    final p = context.palette;
    // 示例都是「设计」任务（先写 PRD 再出原型），只在选择设计时给；
    // 3D / 视频 / 热应用 / 自动 不摆设计示例，避免把用户带错工作台。
    final designMode =
        normalizeWorkspaceMode(store.chatWorkspaceMode) == workspaceModeDesign;
    return Container(
      key: const ValueKey('welcome-composer'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.lineStrong),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 50, offset: const Offset(0, 24))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('welcome-brief'),
            controller: _brief,
            minLines: 3,
            maxLines: 5,
            style: TextStyle(fontSize: 13, height: 1.55, color: p.ink),
            decoration: InputDecoration(
              hintText: '例如：做一个面向自由职业者的发票工具。需要登录、发票列表、新建发票、客户管理和设置；风格专业、克制，移动端优先。',
              hintStyle: TextStyle(fontSize: 13, height: 1.55, color: p.ink4),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            ),
            onSubmitted: (_) => _start(store),
          ),
          if (designMode) ...[
            const SizedBox(height: 8),
            _briefExamples(),
          ],
          const SizedBox(height: 10),
          // 左下角：这次落到哪个工作台（用户裁决 2026-11-19）。
          // 选择器独占一行（窗口窄时可以换行），下面一行是说明 + 开始创作，
          // 按钮固定在右下角——聊天框因此比旧版通栏尺寸小一圈。
          _workspaceSelector(context, store),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  _workspaceHintText(normalizeWorkspaceMode(store.chatWorkspaceMode)),
                  key: const ValueKey('welcome-workspace-hint'),
                  style: TextStyle(fontSize: 10, height: 1.3, color: p.ink4),
                ),
              ),
              const SizedBox(width: 8),
              _startButton(store),
            ],
          ),
        ],
      ),
    );
  }

  /// 设计示例（仅在「设计」工作台选中时出现）：一句话填满输入框。
  Widget _briefExamples() {
    final p = context.palette;
    return Wrap(
      spacing: 4,
      runSpacing: 6,
      children: [
        for (final example in ['电商 App', 'SaaS 仪表盘', 'AI 助手', '个人作品集'])
          InkWell(
            key: ValueKey('welcome-example-$example'),
            borderRadius: BorderRadius.circular(4),
            onTap: () => setState(() {
              _brief.text = '做一个$example：先写 PRD 与 UI 说明，再生成完整可交互原型。移动端优先，风格现代克制。';
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(4)),
              child: Text(example, style: TextStyle(fontSize: 10, color: p.ink3)),
            ),
          ),
      ],
    );
  }

  Widget _startButton(AppStore store) {
    final p = context.palette;
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      ),
      onPressed: store.agentBusy ? null : () => _start(store),
      icon: store.agentBusy
          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
          : const Icon(Icons.auto_awesome, size: 13),
      label: const Text('开始创作', style: TextStyle(fontSize: 12)),
    );
  }

  /// 目标工作台选择器：多个工作区并存，用户必须能指定这次任务落到哪个。
  /// 选择写回 `store.chatWorkspaceMode`（持久化 + 通知），发送时自动生效。
  /// 工作台类型选择（聊天框左下角）：这次任务落到哪个工作台。
  /// 选择写回 `store.chatWorkspaceMode`（持久化 + 通知），发送时自动生效。
  Widget _workspaceSelector(BuildContext context, AppStore store) {
    final selected = normalizeWorkspaceMode(store.chatWorkspaceMode);
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final mode in kWorkspaceModes) _workspaceChip(context, store, mode, mode == selected),
      ],
    );
  }

  Widget _workspaceChip(BuildContext context, AppStore store, String mode, bool selected) {
    final p = context.palette;
    return InkWell(
      key: ValueKey('welcome-workspace-$mode'),
      borderRadius: BorderRadius.circular(999),
      onTap: () async {
        await store.setChatWorkspaceMode(mode);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? p.accentSoft : p.panel.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? p.accent.withValues(alpha: 0.55) : p.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check, size: 11, color: p.accent),
              const SizedBox(width: 3),
            ],
            Text(
              workspaceModeLabel(mode),
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? p.accent : p.ink3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 选择器下方的一行说明：换选择就换句子，用户能立刻明白任务去哪。
  String _workspaceHintText(String mode) {
    switch (normalizeWorkspaceMode(mode)) {
      case workspaceModeDesign:
        return '这次先在设计工作台产出文档与原型';
      case workspaceModeThree:
        return '这次先在 3D 工作台建场景';
      case workspaceModeVideo:
        return '这次先在视频工作台做代码动画';
      case workspaceModeHotapp:
        return '这次先在热应用工作台做应用';
      default:
        return 'NaN 会按任务自己选工作台';
    }
  }

  Widget _briefHints(BuildContext context) {
    final p = context.palette;
    // 手机没有键盘：快捷键提示不显示，只留可点的动作。
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Row(
      children: [
        if (!narrow) ...[
          Text('${modCombo('⌘↵')} 开始', style: TextStyle(fontSize: 10, color: p.ink4)),
          const SizedBox(width: 10),
        ],
        InkWell(
          onTap: () => showNewProjectFlow(context),
          child: Text('空白项目', style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
        const SizedBox(width: 10),
        InkWell(
          onTap: () => openProjectFlow(context, ''),
          child: Text('打开项目', style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 下方两张卡：作品集 / 最近项目
  // ---------------------------------------------------------------------------

  /// 作品集入口卡：聚合热应用/视频/3D 三类产物，快速查看与使用。
  /// 作品集卡（用户裁决 2026-11-19）：**展开成列表**，和「最近项目」同一种
  /// 读法——标题行 + 最多 5 条产物（热应用 / 3D 场景 / 视频）+ 「查看全部」。
  ///
  /// 数据来自 [AppStore.refreshPortfolio]（与艺术架同源，只列非项目类产物；
  /// 原型项目在「最近项目」卡里，不重复）。点条目直达对应工作台。
  Widget _portfolioCard(BuildContext context, AppStore store) {
    final p = context.palette;
    final entries = store.portfolioEntries;
    return Container(
      key: const ValueKey('welcome-portfolio-card'),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('作品集', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
              const SizedBox(width: 6),
              Text('热应用 · 3D · 视频', style: TextStyle(fontSize: 10, color: p.ink4)),
              const Spacer(),
              if (store.portfolioLoading)
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.4, color: p.ink4),
                )
              else
                InkWell(
                  key: const ValueKey('welcome-portfolio-refresh'),
                  onTap: () => store.refreshPortfolio(force: true),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.refresh, size: 13, color: p.ink4),
                  ),
                ),
              const SizedBox(width: 8),
              InkWell(
                key: const ValueKey('welcome-portfolio-all'),
                onTap: () => store.setView('portfolio'),
                child: Text('查看全部…', style: TextStyle(fontSize: 10, color: p.ink4)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (store.portfolioError != null && entries.isEmpty)
            _shelfHint(context, store.portfolioError!, retryable: true)
          else if (entries.isEmpty)
            _shelfHint(context, '还没有作品。做出来的热应用、3D 场景和视频会出现在这里。')
          else
            for (final entry in entries.take(kHomePortfolioLimit))
              _shelfRow(context, store, entry),
        ],
      ),
    );
  }

  Widget _shelfHint(BuildContext context, String text, {bool retryable = false}) {
    final p = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      decoration: BoxDecoration(
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, height: 1.5, color: p.ink4)),
          ),
          if (retryable) ...[
            const SizedBox(width: 8),
            InkWell(
              key: const ValueKey('welcome-portfolio-retry'),
              onTap: () => context.read<AppStore>().refreshPortfolio(force: true),
              child: Text('重试', style: TextStyle(fontSize: 10, color: p.accent)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _shelfRow(BuildContext context, AppStore store, PortfolioEntry entry) {
    final p = context.palette;
    final icon = switch (entry.kind) {
      'hotapp' => Icons.auto_fix_high_outlined,
      'three' => Icons.view_in_ar_outlined,
      _ => Icons.movie_outlined,
    };
    return InkWell(
      // ref 才唯一：视频产物可能同名（两段都叫 frames.mp4），用标题做 Key 会撞。
      key: ValueKey('welcome-shelf-${entry.kind}-${entry.ref}'),
      borderRadius: BorderRadius.circular(8),
      // 打开契约与艺术架一致：对应工作台的开局全局 + setView。
      onTap: () => _openShelfEntry(store, entry),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 27,
              height: 27,
              decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 13, color: p.ink4),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: p.ink2)),
                  Text(
                    entry.modified == null
                        ? entry.detail
                        : '${entry.detail} · ${relativeTime(entry.modified)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: p.ink4),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 13, color: p.ink4),
          ],
        ),
      ),
    );
  }

  /// 点作品集条目 → 对应工作台（与艺术架同一打开契约）。
  void _openShelfEntry(AppStore store, PortfolioEntry entry) {
    if (entry.ref.isEmpty) return;
    switch (entry.kind) {
      case 'hotapp':
        // 该全局只写应用名（不是路径），两个取值域不得混用。
        hotAppLoadOnOpen = entry.ref;
        store.setView('plugin:hotapp');
      case 'three':
        threeLoadOnOpen = entry.ref;
        store.setView('plugin:three');
      case 'video':
        videoLoadOnOpen = entry.path ?? entry.ref;
        store.setView('plugin:video');
    }
  }

  Widget _recentCard(BuildContext context, AppStore store) {
    final p = context.palette;
    return Container(
      key: const ValueKey('welcome-recent-card'),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('最近项目', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
              const Spacer(),
              InkWell(
                onTap: () => openProjectFlow(context, ''),
                child: Text('打开…', style: TextStyle(fontSize: 10, color: p.ink4)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (store.recent.isEmpty && store.serverProjects.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                border: Border.all(color: p.line, style: BorderStyle.solid),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('还没有项目。上面输入一句话，马上开始。',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: p.ink4)),
            ),
          for (final r in store.recent.take(6))
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => openProjectFlow(context, r['path']?.toString() ?? ''),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Row(
                  children: [
                    Container(
                      width: 27,
                      height: 27,
                      decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
                      child: Icon(Icons.layers_outlined, size: 13, color: p.ink4),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r['name']?.toString() ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: p.ink2)),
                          Text(relativeTime(r['ts'] is int ? r['ts'] as int : null),
                              style: TextStyle(fontSize: 10, color: p.ink4)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 13, color: p.ink4),
                  ],
                ),
              ),
            ),
          if (store.serverProjects.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  Text('工作区与桌面', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
                  const Spacer(),
                  InkWell(
                    onTap: () => store.refreshProjects(),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(Icons.refresh, size: 13, color: p.ink4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            for (final s in store.serverProjects.take(8))
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => openProjectFlow(context, s['path']?.toString() ?? ''),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Row(
                    children: [
                      Container(
                        width: 27,
                        height: 27,
                        decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
                        child: Icon(Icons.folder_outlined, size: 13, color: p.ink4),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s['name']?.toString() ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: p.ink2)),
                            Text(
                              relativeTime(s['modified'] is num ? (s['modified'] as num).toInt() * 1000 : null),
                              style: TextStyle(fontSize: 10, color: p.ink4),
                            ),
                          ],
                        ),
                      ),
                      _sourceTag(s, p),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, size: 13, color: p.ink4),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _sourceTag(Map<String, dynamic> entry, NonPalette p) {
    final desktop = entry['source'] == 'desktop';
    // NonPalette 令牌随主题切换：硬编码的 accent.dark/品牌粉在浅色主题下
    // 「桌面」标签近乎不可读（≈1.9:1）；accent2 是品牌辅助色的主题化形态。
    final color = desktop ? p.accent2 : p.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(desktop ? '桌面' : '工作区', style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

class _DotsPainter extends CustomPainter {
  final Color color;
  _DotsPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 24.0;
    for (double x = 0; x < size.width; x += step) {
      for (double y = 0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.9, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter old) => old.color != color;
}
