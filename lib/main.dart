import 'dart:io';
import 'dart:convert';
import 'dart:async'; // จำเป็นต้องใช้สำหรับ Timer
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart'; // <<< เพิ่มสำหรับ macOS

// --- Constants & Configuration ---
class AppColors {
  static const Color primaryColor = Color(0xFF1e376d);
  static const Color secondaryColor = Color(0xFF02b2e3);
  static const Color accentColor = Color(0xFF04a52d);
  static const Color notiColor = Color(0xFFff3b30);
  static const Color surfaceColor = Color(0xFFF8F9FA);
}

// --- Network Configuration (Anti-Bot) ---
const Map<String, String> kBrowserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept':
      'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
  'Accept-Language': 'en-US,en;q=0.9,th;q=0.8',
  'Accept-Encoding': 'gzip, deflate',
  'Connection': 'keep-alive',
  'Referer': 'http://www.konnextgroup.com/',
};

void main() {
  _setupWindowsCache();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primaryColor),
        textTheme: GoogleFonts.anuphanTextTheme(),
      ),
      home: const PortableApp(),
    ),
  );
}

void _setupWindowsCache() {
  if (Platform.isWindows) {
    debugPrint("Setting up WebView2 Cache Path...");
  }
}

class PortableApp extends StatefulWidget {
  const PortableApp({super.key});

  @override
  State<PortableApp> createState() => _PortableAppState();
}

class _PortableAppState extends State<PortableApp>
    with TickerProviderStateMixin {
  // --- Controllers ---
  InAppWebViewController? webViewController;
  late AnimationController _loadingController;
  late AnimationController _menuController;
  Timer? _menuAutoCloseTimer; // >>> เพิ่มตัวแปร Timer
  Timer? _autoUpdateTimer; // >>> เพิ่มปิดออโต้อัพเดท

  // --- State Variables ---
  String localAppVersion = "";
  String localContentVersion = "";
  bool isPageLoading = true;
  bool isUpdating = false;
  bool fileExists = true;
  bool isMenuOpen = false;

  // --- Update State ---
  bool isUpdateAvailable = false;
  bool hasCheckedUpdate = false;
  Map<String, dynamic>? cachedUpdateData;
  bool _hasAppUp = false;
  bool _hasContUp = false;

  // --- Progress ---
  double downloadProgress = 0.0;
  int webProgress = 0;

  @override
  void initState() {
    super.initState();
    _loadingController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
    _menuController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _initApp();
  }

  @override
  void dispose() {
    _menuAutoCloseTimer?.cancel(); // >>> อย่าลืม Cancel Timer เมื่อปิดแอป
    _autoUpdateTimer?.cancel(); // >>> หยุดตัวเช็คอัพเดททันทีที่ปิดแอป
    _loadingController.dispose();
    _menuController.dispose();
    super.dispose();
  }

  Future<void> _initApp() async {
    await _loadLocalVersions();
    await _checkFileExistence();
    await _restoreUpdateState();
  }

  // --- ปรับปรุงจุดที่ 1: การจัดการ Path ให้เป็น Async เพื่อรองรับ macOS ---
  Future<String> _getBasePath() async {
    if (Platform.isWindows) {
      return p.dirname(Platform.resolvedExecutable);
    }
    final dir = await getApplicationSupportDirectory();
    return dir.path;
  }

  Future<File> _getUpdateCacheFile() async {
    return File(p.join(await _getDataPath(), 'update_cache.json'));
  }

  String _getTempPath() => p.join(
    Platform.environment['TEMP'] ?? Directory.systemTemp.path,
    'app_reader_temp',
  );

  Future<String> _getHtmlPath() async =>
      p.join(await _getBasePath(), 'contents');
  Future<String> _getDataPath() async => p.join(await _getBasePath(), 'data');

  Future<WebUri> _getWebUri() async {
    final htmlDir = await _getHtmlPath();
    final usb = p.join(htmlDir, 'index.html');
    return File(usb).existsSync()
        ? WebUri(Uri.file(usb).toString())
        : WebUri(Uri.file(p.join(_getTempPath(), 'index.html')).toString());
  }

  Future<void> _restoreUpdateState() async {
    final cacheFile = await _getUpdateCacheFile();
    if (await cacheFile.exists()) {
      try {
        final content = await cacheFile.readAsString();
        final decoded = jsonDecode(content);

        // อ่านข้อมูลจากก้อน 'data' ตามโครงสร้างใหม่ที่เราเพิ่งแก้
        final serverData = decoded['data'];

        if (serverData != null) {
          // ในฟังก์ชัน _restoreUpdateState
          bool appUp = _isNewerVersion(
            serverData['app_version'] ?? localAppVersion,
            localAppVersion,
          );
          bool contUp = _isNewerVersion(
            serverData['content_version'] ?? localContentVersion,
            localContentVersion,
          );

          if (appUp || contUp) {
            setState(() {
              isUpdateAvailable = true;
              cachedUpdateData = serverData;
              _hasAppUp = appUp;
              _hasContUp = contUp;
            });
          }
        }
      } catch (_) {}
    }
  }

  // ฟังก์ชันสำหรับเช็คว่าเวอร์ชันใหม่ (v1) สูงกว่าเวอร์ชันปัจจุบัน (v2) หรือไม่
  bool _isNewerVersion(String v1, String v2) {
    try {
      List<int> v1Nums = v1.split('.').map(int.parse).toList();
      List<int> v2Nums = v2.split('.').map(int.parse).toList();

      for (int i = 0; i < v1Nums.length; i++) {
        if (i >= v2Nums.length) return true;
        if (v1Nums[i] > v2Nums[i]) return true;
        if (v1Nums[i] < v2Nums[i]) return false;
      }
    } catch (_) {}
    return false;
  }

  Future<void> _loadLocalVersions() async {
    try {
      final dataDir = await _getDataPath();
      if (!await Directory(dataDir).exists()) {
        await Directory(dataDir).create(recursive: true);
      }

      final appInfo = await PackageInfo.fromPlatform();
      localAppVersion = appInfo.version;

      final appFile = File(p.join(dataDir, 'version.txt'));
      if (!await appFile.exists() ||
          (await appFile.readAsString()).trim() != localAppVersion) {
        await appFile.writeAsString(localAppVersion);
      }

      final contFile = File(p.join(dataDir, 'content_version.txt'));
      if (await contFile.exists()) {
        localContentVersion = (await contFile.readAsString()).trim();
      } else {
        localContentVersion = "1.0.0";
        await contFile.writeAsString("1.0.0");
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _checkFileExistence() async {
    final htmlDir = await _getHtmlPath();
    if (mounted) {
      setState(
        () => fileExists = File(p.join(htmlDir, 'index.html')).existsSync(),
      );
    }
  }

  // --- Update Logic (ปรับปรุงใหม่: เช็คแค่วันละครั้งเพื่อลดภาระ Server) ---
  Future<void> _checkUpdateAutomatically({bool isManual = false}) async {
    try {
      final cacheFile = await _getUpdateCacheFile();

      // 1. ตรวจสอบเงื่อนไข "เวลา" (ยกเว้นกดเช็คเอง)
      if (!isManual) {
        if (await cacheFile.exists()) {
          final content = await cacheFile.readAsString();
          final cacheJson = jsonDecode(content);

          // ตรวจสอบว่าเคยบันทึกเวลาไว้ไหม
          if (cacheJson['last_checked'] != null) {
            final lastCheck = DateTime.tryParse(cacheJson['last_checked']);
            if (lastCheck != null) {
              final diff = DateTime.now().difference(lastCheck);
              // ถ้าเช็คไปเมื่อไม่เกิน 24 ชั่วโมง ให้ข้ามการต่อ Server ไปเลย
              if (diff.inHours < 24) {
                debugPrint(
                  "Skip: เพิ่งเช็คไปเมื่อ ${diff.inHours} ชม. ที่แล้ว",
                );
                return;
              }
            }
          }
        }

        if (isUpdateAvailable) return;
      }

      // 2. ถ้าเข้าเงื่อนไข (หรือกด Manual) ให้แสดงข้อความและยิง Request
      if (isManual && isUpdateAvailable && cachedUpdateData != null) {
        _showModernDialog(
          child: _buildUpdateDialogContent(
            cachedUpdateData!,
            _hasAppUp,
            _hasContUp,
          ),
        );
        return;
      }
      if (isManual) _showMessage("กำลังตรวจสอบการอัปเดต...");

      final response = await http
          .get(
            Uri.parse(
              'http://www.konnextgroup.com/testweb/appupdates/tcg/tcgar2025/ar2025version.json',
            ),
            headers: kBrowserHeaders,
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        if ((response.headers['content-type'] ?? '').contains('text/html')) {
          if (isManual && mounted) _showMessage("Server Busy (Bot Protection)");
          return;
        }

        final serverData = jsonDecode(utf8.decode(response.bodyBytes));

        // --- ส่วนสำคัญ: เตรียมข้อมูลที่จะเซฟลง Cache (รวมเวลาล่าสุด) ---
        final dataToCache = {
          'last_checked': DateTime.now()
              .toIso8601String(), // บันทึกเวลาที่คุยกับ server
          'data': serverData, // ข้อมูลเวอร์ชันจาก server
        };
        await cacheFile.writeAsString(jsonEncode(dataToCache));
        // -------------------------------------------------------

        // เช็คเฉพาะถ้าเลขเวอร์ชันจาก Server "สูงกว่า" ในเครื่องเท่านั้น
        bool appUp = _isNewerVersion(
          serverData['app_version'] ?? localAppVersion,
          localAppVersion,
        );

        bool contUp = _isNewerVersion(
          serverData['content_version'] ?? localContentVersion,
          localContentVersion,
        );

        if (appUp || contUp) {
          if (mounted) {
            setState(() {
              isUpdateAvailable = true;
              cachedUpdateData = serverData;
              _hasAppUp = appUp;
              _hasContUp = contUp;
            });
            if (isManual) {
              _showModernDialog(
                child: _buildUpdateDialogContent(serverData, appUp, contUp),
              );
            }
          }
        } else {
          if (mounted) {
            setState(() {
              isUpdateAvailable = false;
              cachedUpdateData = null;
            });
            if (isManual) _showNoUpdateDialog();
          }
        }
      } else if (isManual && mounted) {
        _showMessage("เชื่อมต่อไม่ได้ (Code: ${response.statusCode})");
      }
      if (!isManual) hasCheckedUpdate = true;
    } catch (e) {
      if (isManual && mounted) _showMessage("ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้");
    }
  }

  Future<bool> _checkFileExists(String url) async {
    try {
      final r = await http
          .head(Uri.parse(url), headers: kBrowserHeaders)
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _updateProcess(
    String url,
    String newVersion,
    bool isAppUpdate,
  ) async {
    // 1. ตั้งค่าสถานะเริ่มต้น
    setState(() {
      isUpdating = true;
      downloadProgress = 0.0;
    });

    // 2. หยุดการทำงานของ WebView และล้างหน้าจอ (ป้องกัน File Not Found)
    try {
      await webViewController?.stopLoading();
      await webViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri("about:blank")),
      );
    } catch (e) {
      debugPrint("WebView cleanup ignored: $e");
    }

    // 3. ให้เวลาระบบ Render UI "กำลังอัปเดต" สักครู่ก่อนเริ่มโหลดไฟล์
    await Future.delayed(const Duration(milliseconds: 500));

    final tempDir = _getTempPath();
    final zipPath = p.join(tempDir, p.basename(url));

    try {
      // ล้างไฟล์เก่าใน Temp
      if (Directory(tempDir).existsSync()) {
        Directory(tempDir).deleteSync(recursive: true);
      }
      Directory(tempDir).createSync(recursive: true);

      // --- เริ่มการดาวน์โหลด ---
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(url))
        ..headers.addAll(kBrowserHeaders);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200)
        throw Exception("Server returned ${response.statusCode}");

      final total = response.contentLength ?? 1;
      int received = 0;
      final bytes =
          <
            int
          >[]; // ใช้ List เก็บ bytes แทนการเปิด Sink ทันทีเพื่อความเร็วบน USB

      final completer = Completer<void>();
      response.stream.listen(
        (chunk) {
          bytes.addAll(chunk);
          received += chunk.length;
          if (mounted) {
            setState(() {
              // ช่วงแรก 0.0 - 0.7 คือการดาวน์โหลด
              downloadProgress = (received / total) * 0.7;
            });
          }
        },
        onDone: () => completer.complete(),
        onError: (e) => completer.completeError(e),
        cancelOnError: true,
      );

      await completer.future;
      client.close();

      // เขียนไฟล์ลง Temp
      await File(zipPath).writeAsBytes(bytes);

      // --- เริ่มการแตกไฟล์ ---
      if (mounted) setState(() => downloadProgress = 0.75);

      final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
      for (final file in archive) {
        final fPath = p.join(tempDir, file.name);
        if (file.isFile) {
          File(fPath)
            ..createSync(recursive: true)
            ..writeAsBytesSync(file.content as List<int>);
        } else {
          Directory(fPath).createSync(recursive: true);
        }
      }

      if (mounted) setState(() => downloadProgress = 1.0);

      // บันทึกเวอร์ชันเนื้อหา (ถ้าเป็นการอัปเดตเนื้อหา)
      if (!isAppUpdate) {
        final dataDir = await _getDataPath();
        await File(
          p.join(dataDir, 'content_version.txt'),
        ).writeAsString(newVersion);
      }

      // --- รัน Batch เพื่อ Restart (ใช้ Logic เดิมที่ถูกต้อง) ---
      if (Platform.isWindows) {
        final exePath = Platform.resolvedExecutable;
        final exeName = p.basename(exePath);
        final exeDir = p.dirname(exePath);

        final bat =
            '''
@echo off
setlocal
title System Update
mode con: cols=60 lines=10
color 0B
echo ============================================
echo      UPDATE IN PROGRESS, PLEASE WAIT...
echo ============================================
echo.
echo [1/3] Closing application...
timeout /t 3 /nobreak >nul
taskkill /F /IM "$exeName" /T >nul 2>&1

echo [2/3] Applying updates to $exeDir...
echo --------------------------------------------
robocopy "$tempDir" "$exeDir " /E /R:1 /W:1 /MT:8 /XF *.zip /V
echo --------------------------------------------

echo [3/3] Restarting system...
timeout /t 2 /nobreak >nul
start "" "$exePath"
del "%~f0" & exit
''';

        final batFile = File(p.join(exeDir, 'update.bat'));
        await batFile.writeAsString(bat);
        await Process.start('cmd.exe', [
          '/c',
          'update.bat',
        ], mode: ProcessStartMode.detached);
        exit(0);
      }
    } catch (e) {
      if (mounted) {
        setState(() => isUpdating = false);
        _showMessage("ไม่สามารถดาวน์โหลดได้: $e");
      }
    }
  }

  // --- UI Builders ---
  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: GoogleFonts.anuphan(color: Colors.white)),
        backgroundColor: Colors.grey[900],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _showModernDialog({required Widget child}) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "",
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, a1, a2) => Container(),
      transitionBuilder: (ctx, a1, a2, w) => ScaleTransition(
        scale: CurvedAnimation(parent: a1, curve: Curves.easeOut),
        child: FadeTransition(
          opacity: a1,
          child: Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  void _showAboutDialog() {
    _showModernDialog(child: _buildAboutContent());
  }

  void _showNoUpdateDialog() {
    _showModernDialog(
      child: SizedBox(
        width: 340,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                size: 64,
                color: AppColors.accentColor,
              ),
              const SizedBox(height: 16),
              Text(
                "ยังไม่มีอัปเดตใหม่",
                style: GoogleFonts.anuphan(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primaryColor,
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: Text("ตกลง", style: GoogleFonts.anuphan()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(
    String label,
    String value, {
    bool hasUpdate = false,
    VoidCallback? onUpdate,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: GoogleFonts.anuphan(color: Colors.grey[600])),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: GoogleFonts.anuphan(
                  fontWeight: FontWeight.bold,
                  color: hasUpdate ? Colors.grey[400] : AppColors.primaryColor,
                ),
              ),
              if (hasUpdate) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 28,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.secondaryColor.withValues(
                        alpha: 0.1,
                      ),
                      foregroundColor: AppColors.secondaryColor,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      elevation: 0,
                    ),
                    onPressed: onUpdate,
                    icon: const Icon(Icons.download_rounded, size: 14),
                    label: Text(
                      "อัปเดต",
                      style: GoogleFonts.anuphan(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAboutContent() {
    return SizedBox(
      width: 380,
      child: Padding(
        padding: const EdgeInsetsGeometry.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsetsGeometry.all(5),
              child: const Icon(
                Icons.info_rounded,
                size: 48,
                color: AppColors.secondaryColor,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "TCG FlipBook Reader",
              style: GoogleFonts.anuphan(
                fontWeight: FontWeight.bold,
                color: AppColors.primaryColor,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 10),
            _infoRow(
              "เวอร์ชันโปรแกรม",
              localAppVersion,
              hasUpdate: _hasAppUp,
              onUpdate: () {
                Navigator.pop(context);
                if (cachedUpdateData != null) {
                  _showModernDialog(
                    child: _buildUpdateDialogContent(
                      cachedUpdateData!,
                      _hasAppUp,
                      _hasContUp,
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 1),
            _infoRow(
              "เวอร์ชันข้อมูล",
              localContentVersion,
              hasUpdate: _hasContUp,
              onUpdate: () {
                Navigator.pop(context);
                if (cachedUpdateData != null) {
                  _showModernDialog(
                    child: _buildUpdateDialogContent(
                      cachedUpdateData!,
                      _hasAppUp,
                      _hasContUp,
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 10),
            Text(
              "This program is licensed for use solely by the organization that owns this content. Unauthorized access, reproduction, or modification is prohibited.\n© 2026, Developed by Konnext Group, All Rights Reserved",
              style: GoogleFonts.anuphan(fontSize: 11, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primaryColor,
                  foregroundColor: const Color.fromARGB(255, 255, 255, 255),
                ),
                onPressed: () => Navigator.pop(context),
                child: Text(
                  "ปิด",
                  style: GoogleFonts.anuphan(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdateDialogContent(
    Map<String, dynamic> data,
    bool appUp,
    bool contUp,
  ) {
    return DefaultTabController(
      length: 2,
      initialIndex: appUp ? 0 : 1,
      child: SizedBox(
        width: 400,
        height: 400,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: AppColors.primaryColor,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.system_update_rounded,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        "มีอัปเดตใหม่",
                        style: GoogleFonts.anuphan(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: TabBar(
                      indicator: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      indicatorSize: TabBarIndicatorSize.tab,
                      labelColor: AppColors.primaryColor,
                      unselectedLabelColor: Colors.white70,
                      dividerColor: Colors.transparent,
                      tabs: [
                        Tab(
                          child: Text(
                            "โปรแกรม",
                            style: GoogleFonts.anuphan(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Tab(
                          child: Text(
                            "ข้อมูล",
                            style: GoogleFonts.anuphan(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildUpdateTab(
                    localAppVersion,
                    data['app_version'],
                    data['app_download_url'],
                    data['app_changelog'],
                    appUp,
                    true,
                  ),
                  _buildUpdateTab(
                    localContentVersion,
                    data['content_version'],
                    data['content_download_url'],
                    data['content_changelog'],
                    contUp,
                    false,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdateTab(
    String cur,
    String next,
    String url,
    String? log,
    bool hasUp,
    bool isApp,
  ) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _verChip(cur, Colors.grey),
              const Icon(Icons.arrow_right_alt_rounded, color: Colors.grey),
              _verChip(next, hasUp ? AppColors.secondaryColor : Colors.grey),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceColor,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SingleChildScrollView(
                child: Text(
                  hasUp ? (log ?? "ไม่มีรายละเอียด") : "เป็นเวอร์ชันล่าสุดแล้ว",
                  style: GoogleFonts.anuphan(
                    fontSize: 14,
                    color: Colors.grey[800],
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (hasUp)
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      "ไว้ทีหลัง",
                      style: GoogleFonts.anuphan(color: Colors.grey),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: _buildDownloadBtn(url, next, isApp)),
              ],
            )
          else
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  "ปิด",
                  style: GoogleFonts.anuphan(color: Colors.grey),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _verChip(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: c.withValues(alpha: 0.5)),
    ),
    child: Text(
      t,
      style: GoogleFonts.anuphan(
        color: c,
        fontWeight: FontWeight.bold,
        fontSize: 12,
      ),
    ),
  );

  Widget _buildDownloadBtn(String url, String next, bool isApp) {
    return FutureBuilder<bool>(
      future: _checkFileExists(url),
      builder: (c, s) {
        bool ready = s.data ?? false;
        bool loading = s.connectionState == ConnectionState.waiting;
        return FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: ready ? AppColors.primaryColor : Colors.grey[400],
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          onPressed: (ready && !isUpdating)
              ? () {
                  Navigator.pop(context);
                  _updateProcess(url, next, isApp);
                }
              : null,
          icon: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : const Icon(Icons.download_rounded, size: 18),
          label: Text(
            loading ? "ตรวจสอบ..." : (ready ? "อัปเดตเลย" : "ไม่พบไฟล์"),
            style: GoogleFonts.anuphan(fontWeight: FontWeight.bold),
          ),
        );
      },
    );
  }

  // --- Main Build ---

  // >>>>>> ส่วนที่แก้ไข: Auto Close Timer <<<<<<
  void _toggleMenu() {
    setState(() {
      isMenuOpen = !isMenuOpen;
      if (isMenuOpen) {
        _menuController.forward();
        _startMenuTimer(); // เริ่มนับถอยหลังเมื่อเปิด
      } else {
        _menuController.reverse();
        _cancelMenuTimer(); // ยกเลิกเมื่อปิด
      }
    });
  }

  void _startMenuTimer() {
    _cancelMenuTimer(); // เคลียร์ของเก่าก่อนเสมอ
    _menuAutoCloseTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && isMenuOpen) {
        setState(() {
          isMenuOpen = false;
          _menuController.reverse();
        });
      }
    });
  }

  void _cancelMenuTimer() {
    _menuAutoCloseTimer?.cancel();
    _menuAutoCloseTimer = null;
  }
  // >>>>>> -------------------------------- <<<<<<

  Widget _buildMenu() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _animItem(
          3,
          FloatingActionButton.small(
            heroTag: 'about',
            backgroundColor: Colors.white,
            tooltip: "เกี่ยวกับแอปพลิเคชัน",
            onPressed: () => _showAboutDialog(),
            child: const Icon(
              Icons.info_outline_rounded,
              color: Colors.black87,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _animItem(
          2,
          Stack(
            clipBehavior: Clip.none,
            children: [
              FloatingActionButton.small(
                heroTag: 'sync',
                backgroundColor: Colors.white,
                tooltip: "ตรวจสอบการอัปเดต",
                onPressed: () {
                  _checkUpdateAutomatically(isManual: true);
                  _toggleMenu();
                },
                child: Icon(
                  Icons.cloud_sync_rounded,
                  color: isUpdateAvailable
                      ? AppColors.primaryColor
                      : Colors.black87,
                ),
              ),
              if (isUpdateAvailable)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: AppColors.notiColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _animItem(
          1,
          FloatingActionButton.small(
            heroTag: 'home',
            backgroundColor: Colors.white,
            tooltip: "กลับไปหน้าเลือกภาษา",
            onPressed: () async {
              final uri = await _getWebUri();
              webViewController?.loadUrl(urlRequest: URLRequest(url: uri));
              _toggleMenu();
            },
            child: const Icon(Icons.home_outlined, color: Colors.black87),
          ),
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          heroTag: 'menu',
          backgroundColor: AppColors.primaryColor,
          shape: const CircleBorder(),
          onPressed: _toggleMenu,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              RotationTransition(
                turns: Tween(begin: 0.0, end: 0.0).animate(
                  CurvedAnimation(
                    parent: _menuController,
                    curve: Curves.elasticOut,
                  ),
                ),
                child: Icon(
                  isMenuOpen ? Icons.menu_open : Icons.menu_rounded,
                  size: 28,
                  color: Colors.white,
                ),
              ),
              if (isUpdateAvailable && !isMenuOpen)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: AppColors.notiColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.primaryColor,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _animItem(int idx, Widget child) {
    final start = (3 - idx) * 0.1;
    final fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _menuController,
        curve: Interval(start, start + 0.5, curve: Curves.easeOut),
      ),
    );
    final slide = Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(
      CurvedAnimation(
        parent: _menuController,
        curve: Interval(start, start + 0.5, curve: Curves.easeOutCubic),
      ),
    );
    return ScaleTransition(
      scale: fade,
      child: SlideTransition(
        position: slide,
        child: FadeTransition(opacity: fade, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 800),
            child: (!fileExists && !isUpdating)
                ? Center(
                    child: Text(
                      "ไม่พบเนื้อหาหรือไฟล์ข้อมูลมีปัญหา\nกรุณาอัปเดตเนื้อหาแล้วเปิดแอปพลิเคชันใหม่อีกครั้ง\nหรือหากยังพบปัญหากรุณาติดต่อผู้ประสานงานของคุณ",
                      style: GoogleFonts.anuphan(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  )
                : Stack(
                    children: [
                      // --- ปรับปรุงจุดที่ 2: ใช้ FutureBuilder ห่อ WebView ---
                      FutureBuilder<WebUri>(
                        future: _getWebUri(),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return Container(color: Colors.black);
                          }
                          return InAppWebView(
                            initialUrlRequest: URLRequest(url: snapshot.data),
                            initialSettings: InAppWebViewSettings(
                              allowFileAccessFromFileURLs: true,
                              allowUniversalAccessFromFileURLs: true,
                              transparentBackground: true,
                              useOnDownloadStart: true,
                            ),

                            onWebViewCreated: (c) => webViewController = c,
                            shouldOverrideUrlLoading:
                                (controller, navigationAction) async {
                                  final uri = navigationAction.request.url;
                                  if (uri != null &&
                                      uri.path.toLowerCase().endsWith('.pdf')) {
                                    await InAppBrowser.openWithSystemBrowser(
                                      url: uri,
                                    );
                                    return NavigationActionPolicy.CANCEL;
                                  }
                                  return NavigationActionPolicy.ALLOW;
                                },
                            onProgressChanged: (c, p) {
                              if (mounted) setState(() => webProgress = p);
                              if (p == 100) {
                                if (isPageLoading) {
                                  setState(() => isPageLoading = false);
                                }
                                if (!hasCheckedUpdate) {
                                  // ของเดิม: ใช้ Future.delayed (คุมไม่ได้)
                                  // Future.delayed(const Duration(seconds: 2), ... );

                                  // ✅ ของใหม่: ใช้ Timer (สั่งหยุดได้)
                                  _autoUpdateTimer
                                      ?.cancel(); // เคลียร์ของเก่าถ้ามี
                                  _autoUpdateTimer = Timer(
                                    const Duration(seconds: 60),
                                    () {
                                      if (mounted) {
                                        _checkUpdateAutomatically(
                                          isManual: false,
                                        );
                                      }
                                    },
                                  );
                                }
                              }
                            },
                          );
                        },
                      ),
                      IgnorePointer(
                        ignoring: !isPageLoading,
                        child: AnimatedOpacity(
                          opacity: isPageLoading ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeInOut,
                          child: Container(
                            color: Colors.black,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  RotationTransition(
                                    turns: _loadingController,
                                    child: const Icon(
                                      Icons.donut_large,
                                      size: 40,
                                      color: Colors.white,
                                    ),
                                  ),

                                  const SizedBox(height: 24),
                                  Text(
                                    "กำลังเปิดแอปพลิเคชัน...",
                                    style: GoogleFonts.anuphan(
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  SizedBox(
                                    width: 200,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: LinearProgressIndicator(
                                        value: webProgress / 100.0,
                                        backgroundColor: Colors.white10,
                                        valueColor:
                                            const AlwaysStoppedAnimation(
                                              AppColors.secondaryColor,
                                            ),
                                        minHeight: 4,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          // ภายใน Stack ในฟังก์ชัน build
          Stack(
            children: [
              // WebView และส่วนอื่นๆ ...
              if (isUpdating)
                Container(
                  key: const ValueKey(
                    'UpdateOverlay',
                  ), // เพิ่ม Key เพื่อให้ Flutter มั่นใจว่าต้องวาดใหม่
                  color: Colors.black,
                  width: double.infinity,
                  height: double.infinity,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.system_update_alt_rounded,
                          size: 50,
                          color: AppColors.secondaryColor,
                        ),
                        const SizedBox(height: 32),
                        Text(
                          "กำลังดาวน์โหลดอัปเดตใหม่... กรุณารอสักครู่",
                          textAlign: TextAlign.center, // เพิ่มบรรทัดนี้
                          style: GoogleFonts.anuphan(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          "อย่าปิดแอปพลิเคชั่นจนกว่าการดาวน์โหลดจะเสร็จสมบูรณ์\nโปรแกรมจะรีสตาร์ทอัตโนมัติเมื่อพร้อมใช้งาน\nหากโปรแกรมไม่เปิดใหม่ กรุณาเปิดแอปพลิเคชันใหม่ด้วยตนเอง",
                          textAlign: TextAlign.center, // เพิ่มบรรทัดนี้
                          style: GoogleFonts.anuphan(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 48),
                        SizedBox(
                          width: 320,
                          child: Column(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: LinearProgressIndicator(
                                  value: downloadProgress,
                                  minHeight: 15,
                                  backgroundColor: Colors.white10,
                                  valueColor: const AlwaysStoppedAnimation(
                                    AppColors.secondaryColor,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                "${(downloadProgress * 100).toStringAsFixed(0)}%",
                                style: GoogleFonts.anuphan(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),

          if (!isUpdating)
            Positioned(bottom: 30, right: 30, child: _buildMenu()),
        ],
      ),
    );
  }
}
