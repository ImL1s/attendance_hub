import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../models/weekend_tracker.dart';

// 背景任務的唯一標識符
const clockInTaskName = "com.attendance_hub.clockInTask";
const clockOutTaskName = "com.attendance_hub.clockOutTask";
const clockInitializeTaskName = "com.attendance_hub.initializeTask";
const clockStatusCheckTaskName = "com.attendance_hub.clockStatusCheckTask";

// 自動打卡通知ID
const autoClockInNotificationId = 100;
const autoClockOutNotificationId = 101;
const retryClockInNotificationId = 102;
const retryClockOutNotificationId = 103;

class BackgroundService {
  static final BackgroundService _instance = BackgroundService._internal();

  factory BackgroundService() => _instance;

  BackgroundService._internal();

  // 初始化 Workmanager 並註冊任務回調
  Future<void> init() async {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: true, // 在正式環境中設置為 false
    );

    updateSchedules();

    await Workmanager().registerPeriodicTask(
      clockStatusCheckTaskName,
      clockStatusCheckTaskName,
      frequency: const Duration(minutes: 15),
      flexInterval: const Duration(minutes: 5),
      initialDelay: const Duration(seconds: 10),
      // 30秒後開始
      existingWorkPolicy: ExistingWorkPolicy.replace,
      tag: "clock_status_check",
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );

    // 首次運行時安排初始化任務，用於設置每日自動打卡的排程
    await Workmanager().registerOneOffTask(
      clockInitializeTaskName,
      clockInitializeTaskName,
      initialDelay: const Duration(seconds: 10),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  }

  // 根據設置創建或更新自動打卡定時任務
  Future<void> updateSchedules() async {
    final prefs = await SharedPreferences.getInstance();

    // 獲取設置
    final clockInEnabled = prefs.getBool('autoClockInEnabled') ?? false;
    final clockOutEnabled = prefs.getBool('autoClockOutEnabled') ?? false;
    final clockInHour = prefs.getInt('autoClockInHour') ?? 9;
    final clockInMinute = prefs.getInt('autoClockInMinute') ?? 20;
    final clockOutHour = prefs.getInt('autoClockOutHour') ?? 18;
    final clockOutMinute = prefs.getInt('autoClockOutMinute') ?? 30;

    // 取消現有的任務
    await Workmanager().cancelByTag("clock_in");
    await Workmanager().cancelByTag("clock_out");
    await Workmanager().cancelByTag("clock_status_check");

    if (clockInEnabled) {
      // 計算下一次應該執行上班打卡的時間點
      final now = DateTime.now();
      final today = DateFormat('yyyy-MM-dd').format(now);
      DateTime clockInTime =
          DateTime(now.year, now.month, now.day, clockInHour, clockInMinute);

      // 如果今天的時間已經過了，檢查是否需要補打卡
      if (now.isAfter(clockInTime)) {
        // 檢查今天是否已經打過卡
        final hasClocked = prefs.getBool('clockedIn_$today') ?? false;
        if (!hasClocked) {
          // 檢查是否需要補打卡（在合理的時間範圍內）
          final timeDiff = now.difference(clockInTime);
          if (timeDiff.inHours <= 3) {
            // 3小時內可以補打卡
            debugPrint('BackgroundService: 檢測到錯過上班打卡，嘗試補打卡');
            await _performMissedClocking('clockIn', today, prefs);
          }
        }
        // 安排明天的
        clockInTime = clockInTime.add(const Duration(days: 1));
      }

      final initialDelay = clockInTime.difference(now);

      // 設置上班打卡的定期任務（每24小時一次）
      await Workmanager().registerOneOffTask(
        clockInTaskName,
        clockInTaskName,
        //frequency: const Duration(hours: 24),
        initialDelay: initialDelay,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        tag: "clock_in",
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
      );

      debugPrint(
          'BackgroundService: Scheduled clock-in task at $clockInHour:$clockInMinute with initial delay of ${initialDelay.inMinutes} minutes');
    }

    if (clockOutEnabled) {
      // 計算下一次應該執行下班打卡的時間點
      final now = DateTime.now();
      final today = DateFormat('yyyy-MM-dd').format(now);
      DateTime clockOutTime =
          DateTime(now.year, now.month, now.day, clockOutHour, clockOutMinute);

      // 如果今天的時間已經過了，檢查是否需要補打卡
      if (now.isAfter(clockOutTime)) {
        // 檢查今天是否已經打過卡
        final hasClocked = prefs.getBool('clockedOut_$today') ?? false;
        if (!hasClocked) {
          // 檢查是否需要補打卡（在合理的時間範圍內）
          final timeDiff = now.difference(clockOutTime);
          if (timeDiff.inHours <= 3) {
            // 3小時內可以補打卡
            debugPrint('BackgroundService: 檢測到錯過下班打卡，嘗試補打卡');
            await _performMissedClocking('clockOut', today, prefs);
          }
        }
        // 安排明天的
        clockOutTime = clockOutTime.add(const Duration(days: 1));
      }

      final initialDelay = clockOutTime.difference(now);

      // 設置下班打卡的定期任務（每24小時一次）
      await Workmanager().registerOneOffTask(
        clockOutTaskName,
        clockOutTaskName,
        //frequency: const Duration(hours: 24),
        initialDelay: initialDelay,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        tag: "clock_out",
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
      );

      debugPrint(
          'BackgroundService: Scheduled clock-out task at $clockOutHour:$clockOutMinute with initial delay of ${initialDelay.inMinutes} minutes');
    }

    // 如果啟用了任何自動打卡功能，就啟動每15分鐘狀態檢查任務
    if (clockInEnabled || clockOutEnabled) {
      await Workmanager().registerPeriodicTask(
        clockStatusCheckTaskName,
        clockStatusCheckTaskName,
        frequency: const Duration(minutes: 15),
        flexInterval: const Duration(minutes: 5),
        initialDelay: const Duration(seconds: 30),
        // 30秒後開始
        existingWorkPolicy: ExistingWorkPolicy.replace,
        tag: "clock_status_check",
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
      );
      debugPrint('BackgroundService: Scheduled status check task every minute');
    }
  }

  // 執行錯過的打卡
  Future<void> _performMissedClocking(
      String action, String today, SharedPreferences prefs) async {
    try {
      // 檢查基本條件
      final isWorkday = await WeekendTracker.isWorkday();
      if (!isWorkday) {
        debugPrint(
            'BackgroundService: Today is not a workday, skipping missed clock.');
        return;
      }

      final fullDayLeave = prefs.getBool('fullDayLeave_$today') ?? false;
      if (fullDayLeave) {
        debugPrint(
            'BackgroundService: Full-day leave enabled, skipping missed clock.');
        return;
      }

      final morningHalfDayLeave =
          prefs.getBool('morningHalfDayLeave_$today') ?? false;
      final afternoonHalfDayLeave =
          prefs.getBool('afternoonHalfDayLeave_$today') ?? false;

      // 檢查半天假條件
      if (action == 'clockIn' && morningHalfDayLeave) {
        debugPrint(
            'BackgroundService: Morning half-day leave enabled, skipping missed clock-in.');
        return;
      }

      if (action == 'clockOut' && afternoonHalfDayLeave) {
        debugPrint(
            'BackgroundService: Afternoon half-day leave enabled, skipping missed clock-out.');
        return;
      }

      // 獲取 webhook URL
      final webhookUrl = prefs.getString('webhookUrl');
      if (webhookUrl == null || webhookUrl.isEmpty) {
        debugPrint('BackgroundService: Webhook URL not configured');
        return;
      }

      // 執行補打卡
      final success = await _performClocking(webhookUrl, action, today, prefs);
      if (success) {
        debugPrint('BackgroundService: Missed $action completed successfully');
        // 顯示補救成功通知
        final now = DateTime.now();
        final formattedTime = DateFormat('HH:mm:ss').format(now);
        await _showRetryClockNotification(action, formattedTime);
      }
    } catch (e) {
      debugPrint('BackgroundService: Error in missed clocking: $e');
    }
  }
}

// 顯示自動打卡通知
Future<void> _showAutoClockNotification(String action, String time) async {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // 初始化設置
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  final DarwinInitializationSettings iosSettings =
      DarwinInitializationSettings();
  final InitializationSettings initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  await flutterLocalNotificationsPlugin.initialize(initSettings);

  // 通知設置
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'auto_clock_channel',
    '自動打卡通知',
    channelDescription: '自動打卡成功時發送的通知',
    importance: Importance.high,
    priority: Priority.high,
  );

  const DarwinNotificationDetails darwinDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  );

  const NotificationDetails notificationDetails = NotificationDetails(
    android: androidDetails,
    iOS: darwinDetails,
  );

  // 根據動作類型顯示不同的通知
  if (action == 'clockIn') {
    await flutterLocalNotificationsPlugin.show(
      autoClockInNotificationId,
      '自動上班打卡成功',
      '系統已於 $time 自動完成上班打卡',
      notificationDetails,
    );
  } else {
    await flutterLocalNotificationsPlugin.show(
      autoClockOutNotificationId,
      '自動下班打卡成功',
      '系統已於 $time 自動完成下班打卡',
      notificationDetails,
    );
  }
}

// 顯示補救打卡通知
Future<void> _showRetryClockNotification(String action, String time) async {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // 初始化設置
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  final DarwinInitializationSettings iosSettings =
      DarwinInitializationSettings();
  final InitializationSettings initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  await flutterLocalNotificationsPlugin.initialize(initSettings);

  // 通知設置
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'retry_clock_channel',
    '補救打卡通知',
    channelDescription: '補救打卡成功時發送的通知',
    importance: Importance.high,
    priority: Priority.high,
  );

  const DarwinNotificationDetails darwinDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  );

  const NotificationDetails notificationDetails = NotificationDetails(
    android: androidDetails,
    iOS: darwinDetails,
  );

  // 根據動作類型顯示不同的通知
  if (action == 'clockIn') {
    await flutterLocalNotificationsPlugin.show(
      retryClockInNotificationId,
      '補救上班打卡成功',
      '系統已於 $time 自動完成補救上班打卡',
      notificationDetails,
    );
  } else {
    await flutterLocalNotificationsPlugin.show(
      retryClockOutNotificationId,
      '補救下班打卡成功',
      '系統已於 $time 自動完成補救下班打卡',
      notificationDetails,
    );
  }
}

// 執行每分鐘狀態檢查 (全局函數)
Future<bool> _performStatusCheck(String today, SharedPreferences prefs) async {
  try {
    final now = DateTime.now();

    // 檢查是否為工作日
    final isWorkday = await WeekendTracker.isWorkday();
    if (!isWorkday) {
      debugPrint(
          'BackgroundTask: Today is not a workday, skipping status check.');
      return true;
    }

    // 檢查是否啟用了整天請假
    final fullDayLeave = prefs.getBool('fullDayLeave_$today') ?? false;
    if (fullDayLeave) {
      debugPrint(
          'BackgroundTask: Full-day leave enabled, skipping status check.');
      return true;
    }

    // 獲取設置
    final autoClockInEnabled = prefs.getBool('autoClockInEnabled') ?? false;
    final autoClockOutEnabled = prefs.getBool('autoClockOutEnabled') ?? false;
    final clockInHour = prefs.getInt('autoClockInHour') ?? 9;
    final clockInMinute = prefs.getInt('autoClockInMinute') ?? 20;
    final clockOutHour = prefs.getInt('autoClockOutHour') ?? 18;
    final clockOutMinute = prefs.getInt('autoClockOutMinute') ?? 30;

    final currentHour = now.hour;
    final currentMinute = now.minute;

    // 檢查半天假設定
    final morningHalfDayLeave =
        prefs.getBool('morningHalfDayLeave_$today') ?? false;
    final afternoonHalfDayLeave =
        prefs.getBool('afternoonHalfDayLeave_$today') ?? false;

    // 處理上午請假的自動打卡 (13:00)
    if (morningHalfDayLeave &&
        currentHour == 13 &&
        currentMinute == 0 &&
        !(prefs.getBool('clockedIn_$today') ?? false)) {
      debugPrint('BackgroundTask: 執行上午請假自動打卡 (13:00)');
      await _performMorningHalfDayClocking(today, prefs);
      return true;
    }

    // 處理下午請假的自動打卡 (13:31)
    if (afternoonHalfDayLeave &&
        currentHour == 13 &&
        currentMinute == 31 &&
        !(prefs.getBool('clockedOut_$today') ?? false)) {
      debugPrint('BackgroundTask: 執行下午請假自動打卡 (13:31)');
      await _performAfternoonHalfDayClocking(today, prefs);
      return true;
    }

    // 獲取 webhook URL
    final webhookUrl = prefs.getString('webhookUrl');
    if (webhookUrl == null || webhookUrl.isEmpty) {
      debugPrint('BackgroundTask: Webhook URL not configured');
      return true; // 不是錯誤，只是沒配置
    }

    // 檢查正常的上班打卡時間
    if (autoClockInEnabled &&
        currentHour == clockInHour &&
        currentMinute == clockInMinute &&
        !morningHalfDayLeave &&
        !(prefs.getBool('clockedIn_$today') ?? false)) {
      debugPrint('BackgroundTask: 執行定時上班打卡');
      await _performClocking(webhookUrl, 'clockIn', today, prefs);
      return true;
    }

    // 檢查正常的下班打卡時間
    if (autoClockOutEnabled &&
        currentHour == clockOutHour &&
        currentMinute == clockOutMinute &&
        !afternoonHalfDayLeave &&
        !(prefs.getBool('clockedOut_$today') ?? false)) {
      debugPrint('BackgroundTask: 執行定時下班打卡');
      await _performClocking(webhookUrl, 'clockOut', today, prefs);
      return true;
    }

    // 檢查是否需要補打卡
    await _checkAndPerformMissedClocking(
        webhookUrl,
        today,
        prefs,
        now,
        autoClockInEnabled,
        autoClockOutEnabled,
        clockInHour,
        clockInMinute,
        clockOutHour,
        clockOutMinute,
        morningHalfDayLeave,
        afternoonHalfDayLeave);

    return true;
  } catch (e) {
    debugPrint('BackgroundTask: Error in status check: $e');
    return false;
  }
}

// 執行上午請假打卡 (13:00) - 全局函數
Future<void> _performMorningHalfDayClocking(
    String today, SharedPreferences prefs) async {
  try {
    final webhookUrl = prefs.getString('webhookUrl');
    if (webhookUrl == null || webhookUrl.isEmpty) {
      debugPrint(
          'BackgroundTask: Webhook URL not configured for morning half-day leave');
      return;
    }

    final response = await http.post(
      Uri.parse(webhookUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'action': 'clockIn',
        'timestamp': '$today 13:00:00',
        'source': 'morning_half_day_leave_status_check'
      }),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      await prefs.setBool('clockedIn_$today', true);
      await prefs.setString('clockInTime_$today', '13:00:00');
      debugPrint(
          'BackgroundTask: Morning half-day leave clock-in successful at 13:00:00');

      // 顯示通知
      await _showAutoClockNotification('clockIn', '13:00:00');
    }
  } catch (e) {
    debugPrint('BackgroundTask: Error in morning half-day leave clocking: $e');
  }
}

// 執行下午請假打卡 (13:31) - 全局函數
Future<void> _performAfternoonHalfDayClocking(
    String today, SharedPreferences prefs) async {
  try {
    final webhookUrl = prefs.getString('webhookUrl');
    if (webhookUrl == null || webhookUrl.isEmpty) {
      debugPrint(
          'BackgroundTask: Webhook URL not configured for afternoon half-day leave');
      return;
    }

    final response = await http.post(
      Uri.parse(webhookUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'action': 'clockOut',
        'timestamp': '$today 13:31:00',
        'source': 'afternoon_half_day_leave_status_check'
      }),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      await prefs.setBool('clockedOut_$today', true);
      await prefs.setString('clockOutTime_$today', '13:31:00');
      debugPrint(
          'BackgroundTask: Afternoon half-day leave clock-out successful at 13:31:00');

      // 顯示通知
      await _showAutoClockNotification('clockOut', '13:31:00');
    }
  } catch (e) {
    debugPrint(
        'BackgroundTask: Error in afternoon half-day leave clocking: $e');
  }
}

// 檢查並執行補打卡 - 全局函數
Future<void> _checkAndPerformMissedClocking(
  String webhookUrl,
  String today,
  SharedPreferences prefs,
  DateTime now,
  bool autoClockInEnabled,
  bool autoClockOutEnabled,
  int clockInHour,
  int clockInMinute,
  int clockOutHour,
  int clockOutMinute,
  bool morningHalfDayLeave,
  bool afternoonHalfDayLeave,
) async {
  try {
    // 計算原定打卡時間
    final scheduledClockIn =
        DateTime(now.year, now.month, now.day, clockInHour, clockInMinute);
    final scheduledClockOut =
        DateTime(now.year, now.month, now.day, clockOutHour, clockOutMinute);

    // 檢查上班補打卡
    if (autoClockInEnabled &&
        !morningHalfDayLeave &&
        !(prefs.getBool('clockedIn_$today') ?? false) &&
        now.isAfter(scheduledClockIn)) {
      final timeDiff = now.difference(scheduledClockIn);
      if (timeDiff.inHours <= 3) {
        debugPrint('BackgroundTask: 檢測到錯過上班打卡，執行補打卡');
        final success =
            await _performClocking(webhookUrl, 'clockIn', today, prefs);
        if (success) {
          final formattedTime = DateFormat('HH:mm:ss').format(now);
          await _showRetryClockNotification('clockIn', formattedTime);
        }
      }
    }

    // 檢查下班補打卡
    if (autoClockOutEnabled &&
        !afternoonHalfDayLeave &&
        !(prefs.getBool('clockedOut_$today') ?? false) &&
        now.isAfter(scheduledClockOut)) {
      final timeDiff = now.difference(scheduledClockOut);
      if (timeDiff.inHours <= 3) {
        debugPrint('BackgroundTask: 檢測到錯過下班打卡，執行補打卡');
        final success =
            await _performClocking(webhookUrl, 'clockOut', today, prefs);
        if (success) {
          final formattedTime = DateFormat('HH:mm:ss').format(now);
          await _showRetryClockNotification('clockOut', formattedTime);
        }
      }
    }
  } catch (e) {
    debugPrint('BackgroundTask: Error in missed clocking check: $e');
  }
}

// 全局函數，作為 Workmanager 的入口點
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      Logger().d('BackgroundTask: Task started: $taskName');
      final prefs = await SharedPreferences.getInstance();
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

      // 檢查是否為工作日
      final isWorkday = await WeekendTracker.isWorkday();
      if (!isWorkday) {
        debugPrint(
            'BackgroundTask: Today is not a workday, skipping auto-clock.');
        return Future.value(true);
      }

      // 檢查是否啟用了整天請假
      final fullDayLeave = prefs.getBool('fullDayLeave_$today') ?? false;
      if (fullDayLeave) {
        debugPrint(
            'BackgroundTask: Full-day leave enabled, skipping auto-clock.');
        return Future.value(true);
      }

      // 處理半天請假的特殊打卡時間
      final now = DateTime.now();
      final currentHour = now.hour;
      final currentMinute = now.minute;

      final morningHalfDayLeave =
          prefs.getBool('morningHalfDayLeave_$today') ?? false;
      final afternoonHalfDayLeave =
          prefs.getBool('afternoonHalfDayLeave_$today') ?? false;

      // 上午請假的自動打卡（13:00）
      if (morningHalfDayLeave && currentHour == 13 && currentMinute == 0) {
        // 檢查今天是否已經打卡
        if (prefs.getBool('clockedIn_$today') ?? false) {
          debugPrint('BackgroundTask: Already clocked in today');
          return Future.value(true);
        }

        // 獲取 webhook URL
        final webhookUrl = prefs.getString('webhookUrl');
        if (webhookUrl == null || webhookUrl.isEmpty) {
          debugPrint('BackgroundTask: Webhook URL not configured');
          return Future.value(false);
        }

        // 執行半天假特殊打卡（固定13:00）
        final specificTime = DateTime(now.year, now.month, now.day, 13, 0);

        final response = await http.post(
          Uri.parse(webhookUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'action': 'clockIn',
            'timestamp': '$today 13:00:00',
            'source': 'morning_half_day_leave_service'
          }),
        );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          await prefs.setBool('clockedIn_$today', true);
          await prefs.setString('clockInTime_$today', '13:00:00');
          debugPrint(
              'BackgroundTask: Morning half-day leave clock-in successful at 13:00:00');

          // 顯示通知
          await _showAutoClockNotification('clockIn', '13:00:00');
          return Future.value(true);
        }
      }

      // 下午請假的自動打卡（13:31）
      if (afternoonHalfDayLeave && currentHour == 13 && currentMinute == 31) {
        // 檢查今天是否已經打卡
        if (prefs.getBool('clockedOut_$today') ?? false) {
          debugPrint('BackgroundTask: Already clocked out today');
          return Future.value(true);
        }

        // 獲取 webhook URL
        final webhookUrl = prefs.getString('webhookUrl');
        if (webhookUrl == null || webhookUrl.isEmpty) {
          debugPrint('BackgroundTask: Webhook URL not configured');
          return Future.value(false);
        }

        // 執行半天假特殊打卡（固定13:31）
        final specificTime = DateTime(now.year, now.month, now.day, 13, 31);

        final response = await http.post(
          Uri.parse(webhookUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'action': 'clockOut',
            'timestamp': '$today 13:31:00',
            'source': 'afternoon_half_day_leave_service'
          }),
        );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          await prefs.setBool('clockedOut_$today', true);
          await prefs.setString('clockOutTime_$today', '13:31:00');
          debugPrint(
              'BackgroundTask: Afternoon half-day leave clock-out successful at 13:31:00');

          // 顯示通知
          await _showAutoClockNotification('clockOut', '13:31:00');
          return Future.value(true);
        }
      }

      if (taskName == clockInitializeTaskName) {
        // 初始化任務，用於設置每日自動打卡的排程
        await BackgroundService().updateSchedules();
        return Future.value(true);
      }

      // 獲取 webhook URL
      final webhookUrl = prefs.getString('webhookUrl');
      if (webhookUrl == null || webhookUrl.isEmpty) {
        debugPrint('BackgroundTask: Webhook URL not configured');
        return Future.value(false);
      }

      // 處理上班打卡任務
      if (taskName == clockInTaskName) {
        // 檢查今天是否已經打卡
        if (prefs.getBool('clockedIn_$today') ?? false) {
          debugPrint('BackgroundTask: Already clocked in today');
          return Future.value(true);
        }

        // 執行上班打卡
        return await _performClocking(webhookUrl, 'clockIn', today, prefs);
      }

      // 處理下班打卡任務
      if (taskName == clockOutTaskName) {
        // 檢查今天是否已經打卡
        if (prefs.getBool('clockedOut_$today') ?? false) {
          debugPrint('BackgroundTask: Already clocked out today');
          return Future.value(true);
        }

        // 執行下班打卡
        return await _performClocking(webhookUrl, 'clockOut', today, prefs);
      }

      // 處理每分鐘狀態檢查任務
      if (taskName == clockStatusCheckTaskName) {
        return await _performStatusCheck(today, prefs);
      }

      return Future.value(true);
    } catch (e) {
      debugPrint('BackgroundTask: Error executing task: $e');
      return Future.value(false);
    }
  });
}

Future<bool> _performClocking(String webhookUrl, String action, String today,
    SharedPreferences prefs) async {
  try {
    final now = DateTime.now();

    // 檢查半天假設定
    final morningHalfDayLeave =
        prefs.getBool('morningHalfDayLeave_$today') ?? false;
    final afternoonHalfDayLeave =
        prefs.getBool('afternoonHalfDayLeave_$today') ?? false;

    // 如果是上班打卡且設置了上午請假，則跳過
    if (action == 'clockIn' && morningHalfDayLeave) {
      debugPrint(
          'BackgroundTask: Morning half-day leave enabled, skipping auto clock-in.');
      return true; // 返回成功，但不執行打卡
    }

    // 如果是下班打卡且設置了下午請假，則跳過
    if (action == 'clockOut' && afternoonHalfDayLeave) {
      debugPrint(
          'BackgroundTask: Afternoon half-day leave enabled, skipping auto clock-out.');
      return true; // 返回成功，但不執行打卡
    }

    final formattedTime = DateFormat('HH:mm:ss').format(now);

    final response = await http.post(
      Uri.parse(webhookUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'action': action,
        'timestamp': now.toIso8601String(),
        'source': 'background_service'
      }),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      // 成功打卡，設置標記
      if (action == 'clockIn') {
        // 標記今天已經上班打卡
        await prefs.setBool('clockedIn_$today', true);
        await prefs.setString('clockInTime_$today', formattedTime);
        debugPrint('BackgroundTask: Clock-in successful at $formattedTime');

        // 初始化通知插件
        final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
            FlutterLocalNotificationsPlugin();

        // 初始化設置
        const AndroidInitializationSettings androidSettings =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        final DarwinInitializationSettings iosSettings =
            DarwinInitializationSettings();
        final InitializationSettings initSettings = InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        );

        await flutterLocalNotificationsPlugin.initialize(initSettings);

        // 顯示通知
        await _showAutoClockNotification(action, formattedTime);
      } else {
        // 標記今天已經下班打卡
        await prefs.setBool('clockedOut_$today', true);
        await prefs.setString('clockOutTime_$today', formattedTime);
        debugPrint('BackgroundTask: Clock-out successful at $formattedTime');

        // 初始化通知插件
        final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
            FlutterLocalNotificationsPlugin();

        // 初始化設置
        const AndroidInitializationSettings androidSettings =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        final DarwinInitializationSettings iosSettings =
            DarwinInitializationSettings();
        final InitializationSettings initSettings = InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        );

        await flutterLocalNotificationsPlugin.initialize(initSettings);

        // 顯示通知
        await _showAutoClockNotification(action, formattedTime);
      }
      return true;
    } else {
      debugPrint('BackgroundTask: Webhook failed: ${response.body}');
      return false;
    }
  } catch (e) {
    debugPrint('BackgroundTask: Error triggering webhook: $e');
    return false;
  }
}
