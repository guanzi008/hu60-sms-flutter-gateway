import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _channelName = 'hu60.sms_gateway/sms';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final service = SmsGatewayService();
  await service.initialize();
  runApp(MyApp(service: service));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.service});

  final SmsGatewayService service;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hu60 SMS Gateway',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: GatewayPage(service: service),
    );
  }
}

class GatewayPage extends StatefulWidget {
  const GatewayPage({super.key, required this.service});

  final SmsGatewayService service;

  @override
  State<GatewayPage> createState() => _GatewayPageState();
}

class _GatewayPageState extends State<GatewayPage> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _portController;
  late final TextEditingController _slotController;
  late final TextEditingController _rateLimitSecController;
  late final TextEditingController _rateLimitDailyController;
  late final TextEditingController _globalLimitController;
  late final TextEditingController _testMobileController;
  late final TextEditingController _testTextController;

  late GatewayConfig _editing;
  bool _ready = false;
  bool _sendingTest = false;
  bool _permissionBusy = false;
  SmsPermissionState _permissionState = const SmsPermissionState.unknown();
  String _localIp = '127.0.0.1';

  @override
  void initState() {
    super.initState();
    final cfg = widget.service.config;
    _editing = cfg;
    _apiKeyController = TextEditingController(text: cfg.apiKey);
    _portController = TextEditingController(text: cfg.port);
    _slotController = TextEditingController(text: cfg.slot);
    _rateLimitSecController = TextEditingController(text: cfg.rateLimitSec.toString());
    _rateLimitDailyController = TextEditingController(text: cfg.rateLimitDaily.toString());
    _globalLimitController = TextEditingController(text: cfg.globalDailyLimit.toString());
    _testMobileController = TextEditingController();
    _testTextController = TextEditingController();

    widget.service.addListener(_onServiceUpdated);
    _initialize();
  }

  @override
  void dispose() {
    widget.service.removeListener(_onServiceUpdated);
    _apiKeyController.dispose();
    _portController.dispose();
    _slotController.dispose();
    _rateLimitSecController.dispose();
    _rateLimitDailyController.dispose();
    _globalLimitController.dispose();
    _testMobileController.dispose();
    _testTextController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    await widget.service.initialize();
    _syncFormFromConfig();
    await _loadLocalIp();
    await _reloadPermissions(showSnackBar: false);
    if (mounted) {
      setState(() {
        _ready = true;
      });
    }
  }

  void _syncFormFromConfig() {
    final cfg = widget.service.config;
    _editing = cfg;
    _apiKeyController.text = cfg.apiKey;
    _portController.text = cfg.port;
    _slotController.text = cfg.slot;
    _rateLimitSecController.text = cfg.rateLimitSec.toString();
    _rateLimitDailyController.text = cfg.rateLimitDaily.toString();
    _globalLimitController.text = cfg.globalDailyLimit.toString();
  }

  void _onServiceUpdated() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _reloadPermissions({bool showSnackBar = true}) async {
    if (!Platform.isAndroid) return;
    try {
      final next = await widget.service.getPermissionState();
      if (mounted) {
        setState(() {
          _permissionState = next;
        });
      }
    } catch (e) {
      if (showSnackBar) {
        _notify('读取权限状态失败: $e');
      }
    }
  }

  Future<bool> _ensureSendPermissionForAction() async {
    if (!Platform.isAndroid) return true;

    if (_permissionState.allGranted) return true;

    setState(() {
      _permissionBusy = true;
    });
    try {
      final ok = await widget.service.requestPermissions();
      await _reloadPermissions(showSnackBar: false);
      if (!ok) {
        _notify('未授予发送短信/电话权限');
      }
      return ok;
    } catch (e) {
      _notify('权限申请失败: $e');
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _permissionBusy = false;
        });
      }
    }
  }

  Future<void> _applyConfig() async {
    final next = GatewayConfig(
      apiKey: _apiKeyController.text.trim(),
      port: _portController.text.trim().isEmpty ? '8080' : _portController.text.trim(),
      slot: _slotController.text.trim(),
      rateLimitSec: int.tryParse(_rateLimitSecController.text.trim()) ?? 30,
      rateLimitDaily: int.tryParse(_rateLimitDailyController.text.trim()) ?? 10,
      globalDailyLimit: int.tryParse(_globalLimitController.text.trim()) ?? 100,
    );
    await widget.service.saveConfig(next);
    _editing = next;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('配置已保存')),
    );
  }

  Future<void> _toggleServer() async {
    if (widget.service.running) {
      await widget.service.stop();
      return;
    }

    if (_apiKeyController.text.trim().isEmpty) {
      _notify('请先设置 API Key');
      return;
    }

    final ok = await _ensureSendPermissionForAction();
    if (!ok) {
      return;
    }

    await _applyConfig();
    try {
      await widget.service.start();
    } catch (e) {
      _notify('启动失败：$e');
    }
  }

  Future<void> _sendTestSms() async {
    final mobile = _testMobileController.text.trim();
    final text = _testTextController.text.trim();
    if (mobile.isEmpty || text.isEmpty) {
      _notify('测试发送请填写手机号与内容');
      return;
    }

    final ok = await _ensureSendPermissionForAction();
    if (!ok) return;

    setState(() {
      _sendingTest = true;
    });
    try {
      final success = await widget.service.sendSmsDirect(
        mobile: mobile,
        text: text,
        slot: _slotController.text.trim().isEmpty ? null : _slotController.text.trim(),
      );
      if (success) {
        _notify('测试发送提交成功');
      } else {
        _notify('测试发送失败');
      }
    } catch (e) {
      _notify('测试发送异常：$e');
    } finally {
      if (mounted) {
        setState(() {
          _sendingTest = false;
        });
      }
    }
  }

  Future<void> _loadLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final ips = interfaces.expand((iface) => iface.addresses).where((addr) {
        return !addr.isLoopback;
      }).map((addr) => addr.address);
      if (mounted) {
        setState(() {
          _localIp = ips.isNotEmpty ? ips.first : '127.0.0.1';
        });
      }
    } catch (_) {
      // 保留默认值
    }
  }

  Future<void> _copyRuntimeLogs() async {
    final text = widget.service.runtimeLogText;
    if (text.isEmpty) {
      _notify('运行日志为空');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _notify('运行日志已复制到剪贴板');
  }

  Future<void> _copyRequestLogs() async {
    final text = widget.service.requestLogText;
    if (text.isEmpty) {
      _notify('请求日志为空');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _notify('请求日志已复制到剪贴板');
  }

  Future<void> _clearRuntimeLogs() async {
    await widget.service.clearRuntimeLogs();
    _notify('运行日志已清空');
  }

  Future<void> _clearRequestLogs() async {
    await widget.service.clearRequestLogs();
    _notify('请求日志已清空');
  }

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hu60 SMS 网关（Flutter）'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        children: [
          _buildPermissionCard(),
          const SizedBox(height: 12),
          _buildConfigCard(),
          const SizedBox(height: 12),
          _buildControlsCard(),
          const SizedBox(height: 12),
          _buildTestCard(),
          const SizedBox(height: 12),
          _buildStatsCard(),
          const SizedBox(height: 12),
          _buildRequestLogCard(),
          const SizedBox(height: 12),
          _buildRuntimeLogCard(),
        ],
      ),
    );
  }

  Widget _buildPermissionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: const [
                Icon(Icons.shield, size: 18),
                SizedBox(width: 6),
                Text('权限管理', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _permissionChip('发送短信', _permissionState.smsGranted),
                _permissionChip('电话状态', _permissionState.phoneGranted),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _permissionBusy ? null : _ensureSendPermissionForAction,
              icon: _permissionBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.security_update_good),
              label: Text(_permissionState.allGranted ? '刷新权限状态' : '申请发送/电话权限'),
            ),
            const SizedBox(height: 8),
            Text(
              _permissionState.allGranted
                  ? '权限已满足，服务可正常发起发送'
                  : '当前权限不足，无法发送短信（服务启动/测试发送前将自动提示）',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionChip(String label, bool enabled) {
    return InputChip(
      label: Text(label),
      selected: enabled,
      avatar: Icon(enabled ? Icons.check_circle : Icons.error_outline, size: 18),
      onSelected: null,
      side: BorderSide(color: enabled ? Colors.green : Colors.redAccent),
      selectedColor: enabled ? Colors.green.withValues(alpha: 0.12) : Colors.red.withValues(alpha: 0.12),
      showCheckmark: false,
    );
  }

  Widget _buildConfigCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('配置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(labelText: 'API Key', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '监听端口', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _slotController,
                    decoration: const InputDecoration(labelText: 'SIM 插槽（空为默认）', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _rateLimitSecController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '每号间隔（秒）', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _rateLimitDailyController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '每号每日上限', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _globalLimitController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '全局每日上限', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _applyConfig,
              child: const Text('保存配置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsCard() {
    final endpoint = 'http://$_localIp:${_editing.port}/sms';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('服务控制', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _toggleServer,
                    child: Text(widget.service.running ? '停止服务' : '启动服务'),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  widget.service.running ? Icons.cloud_done : Icons.cloud_off,
                  color: widget.service.running ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(
                  widget.service.running ? '运行中' : '未启动',
                  style: TextStyle(
                    color: widget.service.running ? Colors.green : Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('POST ${endpoint}', style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 4),
            const Text('参数: apikey, mobile, text（x-www-form-urlencoded 或 application/json）', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            const Text('响应：{"code":200,"message":"SMS sent successfully"}', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            Text('上次请求: ${widget.service.stats.lastRequestTime ?? "-"}', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard() {
    final stats = widget.service.stats;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('服务统计', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('总请求：${stats.totalRequests}'),
            Text('发送成功：${stats.successRequests}'),
            Text('发送失败：${stats.failedRequests}'),
            Text('拒绝-签名错误：${stats.invalidApiKeyCount}'),
            Text('拒绝-参数错误：${stats.badRequestCount}'),
            Text('拒绝-频率限制：${stats.rateLimitCount}'),
            const SizedBox(height: 4),
            Text('路径错误：${stats.routeOrMethodRejectCount}', style: const TextStyle(color: Colors.black54)),
          ],
        ),
      ),
    );
  }

  Widget _buildTestCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('测试发送', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _testMobileController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: '测试手机号', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _testTextController,
              maxLines: 2,
              decoration: const InputDecoration(labelText: '测试短信内容', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _sendingTest ? null : _sendTestSms,
              child: Text(_sendingTest ? '测试中...' : '发送测试短信'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestLogCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('HTTP 请求日志', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    IconButton(
                      onPressed: _copyRequestLogs,
                      tooltip: '复制请求日志',
                      icon: const Icon(Icons.copy_all),
                    ),
                    IconButton(
                      onPressed: widget.service.requestLogs.isEmpty ? null : _clearRequestLogs,
                      tooltip: '清空请求日志',
                      icon: const Icon(Icons.delete_sweep),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildLogView(widget.service.requestLogs, Colors.blue),
          ],
        ),
      ),
    );
  }

  Widget _buildRuntimeLogCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('运行日志', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    IconButton(
                      onPressed: _copyRuntimeLogs,
                      tooltip: '复制运行日志',
                      icon: const Icon(Icons.copy_all),
                    ),
                    IconButton(
                      onPressed: widget.service.logs.isEmpty ? null : _clearRuntimeLogs,
                      tooltip: '清空运行日志',
                      icon: const Icon(Icons.delete_sweep),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildLogView(widget.service.logs, Colors.teal),
          ],
        ),
      ),
    );
  }

  Widget _buildLogView(List<String> logs, Color color) {
    if (logs.isEmpty) {
      return const SizedBox(
        height: 160,
        child: Center(child: Text('暂无日志', style: TextStyle(color: Colors.black54))),
      );
    }

    return SizedBox(
      height: 180,
      child: ListView.builder(
        reverse: true,
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final item = logs[index];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              item,
              style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: color.withOpacity(0.85)),
            ),
          );
        },
      ),
    );
  }
}

class SmsPermissionState {
  const SmsPermissionState({required this.smsGranted, required this.phoneGranted});

  const SmsPermissionState.unknown()
      : smsGranted = false,
        phoneGranted = false;

  final bool smsGranted;
  final bool phoneGranted;

  bool get allGranted => smsGranted && phoneGranted;

  factory SmsPermissionState.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) {
      return const SmsPermissionState.unknown();
    }

    bool parseFlag(String key) {
      final dynamic value = map[key];
      if (value is bool) return value;
      if (value is num) return value > 0;
      return value?.toString().toLowerCase() == 'true';
    }

    return SmsPermissionState(
      smsGranted: parseFlag('smsGranted'),
      phoneGranted: parseFlag('phoneGranted'),
    );
  }
}

class GatewayConfig {
  GatewayConfig({
    required this.apiKey,
    required this.port,
    required this.slot,
    required this.rateLimitSec,
    required this.rateLimitDaily,
    required this.globalDailyLimit,
  });

  final String apiKey;
  final String port;
  final String slot;
  final int rateLimitSec;
  final int rateLimitDaily;
  final int globalDailyLimit;

  static GatewayConfig defaults() => GatewayConfig(
        apiKey: '',
        port: '8080',
        slot: '',
        rateLimitSec: 30,
        rateLimitDaily: 10,
        globalDailyLimit: 100,
      );

  Map<String, Object> toMap() => {
        'apiKey': apiKey,
        'port': port,
        'slot': slot,
        'rateLimitSec': rateLimitSec,
        'rateLimitDaily': rateLimitDaily,
        'globalDailyLimit': globalDailyLimit,
      };

  factory GatewayConfig.fromMap(Map<String, dynamic> map) => GatewayConfig(
        apiKey: map['apiKey']?.toString() ?? '',
        port: map['port']?.toString() ?? '8080',
        slot: map['slot']?.toString() ?? '',
        rateLimitSec: int.tryParse(map['rateLimitSec']?.toString() ?? '') ?? 30,
        rateLimitDaily: int.tryParse(map['rateLimitDaily']?.toString() ?? '') ?? 10,
        globalDailyLimit: int.tryParse(map['globalDailyLimit']?.toString() ?? '') ?? 100,
      );
}

class _RateState {
  _RateState({
    required this.date,
    required this.lastSendAt,
    required this.dailyByMobile,
    required this.globalCount,
  });

  final String date;
  final Map<String, int> lastSendAt;
  final Map<String, int> dailyByMobile;
  int globalCount;

  static String currentDate() => DateTime.now().toUtc().toIso8601String().substring(0, 10);

  static _RateState empty() => _RateState(
        date: currentDate(),
        lastSendAt: {},
        dailyByMobile: {},
        globalCount: 0,
      );

  Map<String, dynamic> toMap() => {
        'date': date,
        'lastSendAt': lastSendAt,
        'dailyByMobile': dailyByMobile,
        'globalCount': globalCount,
      };

  factory _RateState.fromMap(Map<String, dynamic> map) {
    final String date = map['date']?.toString() ?? currentDate();
    final rawLast = map['lastSendAt'] as Map<String, dynamic>? ?? {};
    final rawDaily = map['dailyByMobile'] as Map<String, dynamic>? ?? {};
    final last = <String, int>{};
    final daily = <String, int>{};
    for (final entry in rawLast.entries) {
      last[entry.key] = int.tryParse(entry.value.toString()) ?? 0;
    }
    for (final entry in rawDaily.entries) {
      daily[entry.key] = int.tryParse(entry.value.toString()) ?? 0;
    }
    return _RateState(
      date: date,
      lastSendAt: last,
      dailyByMobile: daily,
      globalCount: int.tryParse(map['globalCount']?.toString() ?? '') ?? 0,
    );
  }

  _RateState withSameDayOrReset() {
    final today = currentDate();
    if (date == today) {
      return this;
    }
    return _RateState.empty();
  }
}

class SmsGatewayService extends ChangeNotifier {
  SmsGatewayService();

  static const String _kKeyConfig = 'gateway_config';
  static const String _kKeyRateState = 'gateway_rate_state';
  static const String _kKeyRuntimeLogs = 'gateway_runtime_logs';
  static const String _kKeyRequestLogs = 'gateway_request_logs';
  final MethodChannel _method = const MethodChannel(_channelName);

  GatewayConfig config = GatewayConfig.defaults();
  final List<String> _logs = [];
  final List<String> _requestLogs = [];
  _RateState _rateState = _RateState.empty();
  _GatewayStats _stats = _GatewayStats.empty();
  HttpServer? _server;
  bool _initialized = false;
  bool _bootstrapping = false;
  late SharedPreferences _prefs;

  List<String> get logs => List.unmodifiable(_logs);
  List<String> get requestLogs => List.unmodifiable(_requestLogs);
  String get runtimeLogText => _logs.reversed.join('\n');
  String get requestLogText => _requestLogs.reversed.join('\n');
  _GatewayStats get stats => _stats.clone();
  bool get running => _server != null;

  Future<void> initialize() async {
    if (_initialized) return;
    if (_bootstrapping) {
      while (_bootstrapping) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      return;
    }
    _bootstrapping = true;
    try {
      _prefs = await SharedPreferences.getInstance();
      await _loadConfigFromStorage();
      await _loadRateState();
      await _loadLogsFromStorage();
      _appendLog('配置加载完成');
      _initialized = true;
    } finally {
      _bootstrapping = false;
    }
  }

  Future<bool> sendSmsDirect({
    required String mobile,
    required String text,
    String? slot,
  }) async {
    final ok = await _method.invokeMethod<bool>(
      'sendSms',
      {'mobile': mobile, 'text': text, 'slot': slot},
    );
    return ok == true;
  }

  Future<SmsPermissionState> getPermissionState() async {
    final map = await _method.invokeMapMethod<String, dynamic>('getSmsPermissionStatus');
    return SmsPermissionState.fromMap(map);
  }

  Future<bool> requestPermissions() async {
    final map = await _method.invokeMapMethod<String, dynamic>('requestSmsPermissions');
    return SmsPermissionState.fromMap(map).allGranted;
  }

  Future<void> _loadConfigFromStorage() async {
    final raw = _prefs.getString(_kKeyConfig);
    if (raw == null) {
      config = GatewayConfig.defaults();
      return;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      config = GatewayConfig.fromMap(map);
    } catch (_) {
      config = GatewayConfig.defaults();
    }
  }

  Future<void> saveConfig(GatewayConfig next) async {
    config = next;
    await _prefs.setString(_kKeyConfig, jsonEncode(config.toMap()));
    _appendLog('配置已更新');
    notifyListeners();
  }

  Future<void> _loadRateState() async {
    final raw = _prefs.getString(_kKeyRateState);
    if (raw == null) {
      _rateState = _RateState.empty();
      return;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _rateState = _RateState.fromMap(map).withSameDayOrReset();
    } catch (_) {
      _rateState = _RateState.empty();
    }
  }

  Future<void> _persistRateState() async {
    await _prefs.setString(_kKeyRateState, jsonEncode(_rateState.toMap()));
  }

  Future<void> _loadLogsFromStorage() async {
    final runtime = _prefs.getStringList(_kKeyRuntimeLogs);
    final request = _prefs.getStringList(_kKeyRequestLogs);
    if (runtime != null) {
      _logs.clear();
      _logs.addAll(runtime);
    }
    if (request != null) {
      _requestLogs.clear();
      _requestLogs.addAll(request);
    }
    while (_logs.length > 200) {
      _logs.removeLast();
    }
    while (_requestLogs.length > 400) {
      _requestLogs.removeLast();
    }
    notifyListeners();
  }

  Future<void> _persistLogs() async {
    await _prefs.setStringList(_kKeyRuntimeLogs, _logs);
    await _prefs.setStringList(_kKeyRequestLogs, _requestLogs);
  }

  Future<void> clearRuntimeLogs() async {
    _logs.clear();
    await _prefs.setStringList(_kKeyRuntimeLogs, _logs);
    notifyListeners();
  }

  Future<void> clearRequestLogs() async {
    _requestLogs.clear();
    await _prefs.setStringList(_kKeyRequestLogs, _requestLogs);
    notifyListeners();
  }

  bool _constantTimeEquals(String a, String b) {
    final av = a.codeUnits;
    final bv = b.codeUnits;
    if (av.length != bv.length) return false;
    var diff = 0;
    for (var i = 0; i < av.length; i++) {
      diff |= av[i] ^ bv[i];
    }
    return diff == 0;
  }

  Future<void> start() async {
    if (_server != null) return;
    final port = int.tryParse(config.port) ?? 8080;
    final address = InternetAddress.anyIPv4;
    _server = await HttpServer.bind(address, port);
    _appendLog('服务已启动: http://0.0.0.0:$port/sms');
    notifyListeners();
    _server!.listen((req) async {
      await _handleRequest(req);
    }, onError: (error, st) {
      _appendLog('服务监听错误: $error');
    });
  }

  Future<void> stop() async {
    final server = _server;
    if (server == null) return;
    await server.close(force: true);
    _server = null;
    _appendLog('服务已停止');
    notifyListeners();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final client = _resolveClientIp(request);
    final method = request.method.toUpperCase();
    final path = request.uri.path;
    _stats.totalRequests += 1;
    _stats.lastRequestTime = DateTime.now().toIso8601String().substring(11, 19);

    if (path != '/sms') {
      const message = 'Not Found';
      _appendRequestLog(
        clientIp: client,
        method: method,
        path: path,
        status: 404,
        code: 404,
        message: message,
      );
      await _jsonResponse(request.response, 404, 404, message);
      return;
    }

    if (method != 'POST') {
      const message = 'Method Not Allowed';
      _appendRequestLog(
        clientIp: client,
        method: method,
        path: path,
        status: 405,
        code: 405,
        message: message,
      );
      await _jsonResponse(request.response, 405, 405, message);
      return;
    }

    final body = await utf8.decoder.bind(request).join();
    final contentType = request.headers.contentType?.mimeType ?? '';
    final params = _parseParams(body, contentType);
    final reqApiKey = params['apikey']?.trim() ?? '';
    final mobile = params['mobile']?.trim() ?? '';
    final text = params['text']?.trim() ?? '';

    if (reqApiKey.isEmpty || mobile.isEmpty || text.isEmpty) {
      const message = 'Missing required field: apikey / mobile / text';
      _appendRequestLog(
        clientIp: client,
        method: method,
        path: path,
        status: 400,
        code: 400,
        message: message,
        mobile: mobile,
      );
      await _jsonResponse(request.response, 400, 400, message);
      return;
    }

    if (!_constantTimeEquals(reqApiKey, config.apiKey)) {
      const message = 'Invalid API Key';
      _appendRequestLog(
        clientIp: client,
        method: method,
        path: path,
        status: 403,
        code: 403,
        message: message,
        mobile: mobile,
      );
      await _jsonResponse(request.response, 403, 403, message);
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rateLimitMessage = _checkRateLimit(mobile, now);
    if (rateLimitMessage != null) {
      _appendRequestLog(
        clientIp: client,
        method: method,
        path: path,
        status: 429,
        code: 429,
        message: rateLimitMessage,
        mobile: mobile,
      );
      await _jsonResponse(request.response, 429, 429, rateLimitMessage);
      return;
    }

    try {
      final ok = await _method.invokeMethod<bool>(
        'sendSms',
        {'mobile': mobile, 'text': text, 'slot': config.slot.isEmpty ? null : config.slot},
      );
      if (ok != true) throw Exception('Method returned false');

      _appendLog('发送成功 => $mobile');
      _appendRequestLog(
        clientIp: client,
        method: method,
        path: path,
        status: 200,
        code: 200,
        message: 'SMS sent successfully',
        mobile: mobile,
      );
      await _jsonResponse(request.response, 200, 200, 'SMS sent successfully');
    } on PlatformException catch (e) {
      final message = '发送失败: ${e.message ?? e.code}';
      _appendLog('发送失败 => $mobile：${e.code} ${e.message}');
      _appendRequestLog(
        clientIp: client,
        method: method,
        path: path,
        status: 500,
        code: 500,
        message: message,
        mobile: mobile,
      );
      await _jsonResponse(request.response, 500, 500, message);
    } catch (e) {
      final message = '发送失败: $e';
      _appendLog('发送失败 => $mobile：$e');
      _appendRequestLog(
        clientIp: client,
        method: method,
        path: path,
        status: 500,
        code: 500,
        message: message,
        mobile: mobile,
      );
      await _jsonResponse(request.response, 500, 500, message);
    }
  }

  String _resolveClientIp(HttpRequest request) {
    final xff = request.headers.value('x-forwarded-for');
    if (xff != null && xff.isNotEmpty) {
      return xff.split(',').first.trim();
    }
    return request.connectionInfo?.remoteAddress.address ?? 'unknown';
  }

  String _parseRateLimitMessage(int sec, int total) {
    return '触发频率限制: 同一手机号今日已达 $total 条';
  }

  String _maskMobileForLog(String mobile) {
    if (mobile.isEmpty) return '-';
    if (mobile.length <= 4) return '*' * mobile.length;
    return '${mobile.substring(0, 3)}***${mobile.substring(mobile.length - 2)}';
  }

  void _appendRequestLog({
    required String clientIp,
    required String method,
    required String path,
    required int status,
    required int code,
    required String message,
    String mobile = '',
  }) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    final text = '[REQ $time] $clientIp $method $path mobile=${_maskMobileForLog(mobile)} status=$status code=$code msg=$message';
    _requestLogs.insert(0, text);
    while (_requestLogs.length > 400) {
      _requestLogs.removeLast();
    }
    if (status == 200) {
      _stats.successRequests += 1;
    } else {
      _stats.failedRequests += 1;
    }
    if (status == 400) {
      _stats.badRequestCount += 1;
    } else if (status == 403) {
      _stats.invalidApiKeyCount += 1;
    } else if (status == 404 || status == 405) {
      _stats.routeOrMethodRejectCount += 1;
    } else if (status == 429) {
      _stats.rateLimitCount += 1;
    }
    _persistLogs().then((_) {}, onError: (_) {});
    notifyListeners();
  }

  String? _checkRateLimit(String mobile, int nowSec) {
    _rateState = _rateState.withSameDayOrReset();

    final last = _rateState.lastSendAt[mobile];
    if (last != null && nowSec - last < config.rateLimitSec) {
      return '触发频率限制: 同一手机号发送间隔小于 ${config.rateLimitSec} 秒';
    }

    final daily = _rateState.dailyByMobile[mobile] ?? 0;
    if (daily >= config.rateLimitDaily) {
      return '触发频率限制: 同一手机号今日已达 ${config.rateLimitDaily} 条';
    }

    if (config.globalDailyLimit > 0 && _rateState.globalCount >= config.globalDailyLimit) {
      return '触发频率限制: 今日全局发送已达上限 ${config.globalDailyLimit} 条';
    }

    _rateState.lastSendAt[mobile] = nowSec;
    _rateState.dailyByMobile[mobile] = daily + 1;
    _rateState.globalCount += 1;
    _persistRateState();
    return null;
  }

  Map<String, String> _parseParams(String body, String contentType) {
    if (body.isEmpty) return {};

    if (contentType.contains('json')) {
      try {
        final dynamic decoded = jsonDecode(body);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value.toString()));
        }
      } catch (_) {
        // fall back below
      }
    }

    try {
      final uri = Uri(query: body);
      return uri.queryParameters;
    } catch (_) {
      try {
        return Uri.splitQueryString(body);
      } catch (_) {
        return {};
      }
    }
  }

  Future<void> _jsonResponse(HttpResponse response, int status, int code, String message) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({'code': code, 'message': message}));
    await response.close();
    notifyListeners();
  }

  void _appendLog(String text) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    _logs.insert(0, '[$time] $text');
    while (_logs.length > 200) {
      _logs.removeLast();
    }
    _persistLogs().then((_) {}, onError: (_) {});
    notifyListeners();
  }
}

class _GatewayStats {
  _GatewayStats({
    required this.totalRequests,
    required this.successRequests,
    required this.failedRequests,
    required this.invalidApiKeyCount,
    required this.badRequestCount,
    required this.rateLimitCount,
    required this.routeOrMethodRejectCount,
    required this.lastRequestTime,
  });

  int totalRequests;
  int successRequests;
  int failedRequests;
  int invalidApiKeyCount;
  int badRequestCount;
  int rateLimitCount;
  int routeOrMethodRejectCount;
  String? lastRequestTime;

  factory _GatewayStats.empty() => _GatewayStats(
        totalRequests: 0,
        successRequests: 0,
        failedRequests: 0,
        invalidApiKeyCount: 0,
        badRequestCount: 0,
        rateLimitCount: 0,
        routeOrMethodRejectCount: 0,
        lastRequestTime: null,
      );

  _GatewayStats clone() {
    return _GatewayStats(
      totalRequests: totalRequests,
      successRequests: successRequests,
      failedRequests: failedRequests,
      invalidApiKeyCount: invalidApiKeyCount,
      badRequestCount: badRequestCount,
      rateLimitCount: rateLimitCount,
      routeOrMethodRejectCount: routeOrMethodRejectCount,
      lastRequestTime: lastRequestTime,
    );
  }
}
