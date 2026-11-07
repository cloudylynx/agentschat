import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'services/settings_store.dart';
import 'services/api.dart';
import 'screens/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsStore.init();

  ApiService.baseUrl = SettingsStore.serverUrl;
  ApiService.token = SettingsStore.token;

  runApp(const AgentsChatApp());
}

class AgentsChatApp extends StatefulWidget {
  const AgentsChatApp({super.key});

  @override
  State<AgentsChatApp> createState() => _AgentsChatAppState();
}

class _AgentsChatAppState extends State<AgentsChatApp> {
  ThemeMode _mode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _mode = switch (SettingsStore.themeMode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  void _setTheme(String v) {
    setState(() {
      _mode = switch (v) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    });
    SettingsStore.setThemeMode(v);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgentsChat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _mode,
      home: HomeShell(onThemeChanged: _setTheme),
    );
  }
}
