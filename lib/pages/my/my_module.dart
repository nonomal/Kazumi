import 'dart:io';
import 'package:kazumi/pages/settings/danmaku_settings.dart';
import 'package:kazumi/pages/my/my_page.dart';
import 'package:kazumi/pages/about/about_module.dart';
import 'package:kazumi/pages/plugin_editor/plugin_module.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/history/history_module.dart';

class MyModule extends Module {
  @override
  void routes(r) {
    r.child("/", child: (_) => const MyPage());
    r.child("/danmaku",
        child: (_) => const DanmakuSettingsPage(),
        transition: Platform.isWindows || Platform.isLinux || Platform.isMacOS
            ? TransitionType.noTransition
            : TransitionType.leftToRight);
    r.module("/about", module: AboutModule());
    r.module("/plugin", module: PluginModule());
    r.module("/history", module: HistoryModule());
  }
}
