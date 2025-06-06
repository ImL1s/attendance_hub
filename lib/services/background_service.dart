import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:intl/intl.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/weekend_tracker.dart';
import 'dart:io';

// 背景任務的唯一標識符
const clockInTaskName = "com.attendance_hub.clockInTask";
const clockOutTaskName = "com.attendance_hub.clockOutTask";
const clockInitializeTaskName = "com.attendance_hub.initializeTask";

// 自動打卡通知ID
const autoClockInNotificationId = 100;
const autoClockOutNotificationId = 101;

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

    if (clockInEnabled) {
      // 計算下一次應該執行上班打卡的時間點
      final now = DateTime.now();
      DateTime clockInTime = DateTime(
        now.year, now.month, now.day, clockInHour, clockInMinute);
      
      // 如果今天的時間已經過了，安排明天的
      if (now.isAfter(clockInTime)) {
        clockInTime = clockInTime.add(const Duration(days: 1));
      }
      
      final initialDelay = clockInTime.difference(now);
      
      // 設置上班打卡的定期任務（每24小時一次）
      await Workmanager().registerPeriodicTask(
        clockInTaskName,
        clockInTaskName,
        frequency: const Duration(hours: 24),
        initialDelay: initialDelay,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        tag: "clock_in",
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
      );
      
      debugPrint('BackgroundService: Scheduled clock-in task at $clockInHour:$clockInMinute with initial delay of ${initialDelay.inMinutes} minutes');
    }

    if (clockOutEnabled) {
      // 計算下一次應該執行下班打卡的時間點
      final now = DateTime.now();
      DateTime clockOutTime = DateTime(
        now.year, now.month, now.day, clockOutHour, clockOutMinute);
      
      // 如果今天的時間已經過了，安排明天的
      if (now.isAfter(clockOutTime)) {
        clockOutTime = clockOutTime.add(const Duration(days: 1));
      }
      
      final initialDelay = clockOutTime.difference(now);
      
      // 設置下班打卡的定期任務（每24小時一次）
      await Workmanager().registerPeriodicTask(
        clockOutTaskName,
        clockOutTaskName,
        frequency: const Duration(hours: 24),
        initialDelay: initialDelay,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        tag: "clock_out",
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
      );
      
      debugPrint('BackgroundService: Scheduled clock-out task at $clockOutHour:$clockOutMinute with initial delay of ${initialDelay.inMinutes} minutes');
    }
  }
}

// 顯示自動打卡通知
Future<void> _showAutoClockNotification(String action, String time) async {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  
  // 初始化設置
  const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  final DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
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

// 全局函數，作為 Workmanager 的入口點
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

      // 檢查是否為工作日
      final isWorkday = await WeekendTracker.isWorkday();
      if (!isWorkday) {
        debugPrint('BackgroundTask: Today is not a workday, skipping auto-clock.');
        return Future.value(true);
      }
      
      // 檢查是否啟用了整天請假
      final fullDayLeave = prefs.getBool('fullDayLeave_$today') ?? false;
      if (fullDayLeave) {
        debugPrint('BackgroundTask: Full-day leave enabled, skipping auto-clock.');
        return Future.value(true);
      }
      
      // 處理半天請假的特殊打卡時間
      final now = DateTime.now();
      final currentHour = now.hour;
      final currentMinute = now.minute;
      
      final morningHalfDayLeave = prefs.getBool('morningHalfDayLeave_$today') ?? false;
      final afternoonHalfDayLeave = prefs.getBool('afternoonHalfDayLeave_$today') ?? false;
      
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
        final formattedSpecificTime = DateFormat('HH:mm:ss').format(specificTime);
        
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
          debugPrint('BackgroundTask: Morning half-day leave clock-in successful at 13:00:00');
          
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
        final formattedSpecificTime = DateFormat('HH:mm:ss').format(specificTime);
        
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
          debugPrint('BackgroundTask: Afternoon half-day leave clock-out successful at 13:31:00');
          
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

      return Future.value(true);
    } catch (e) {
      debugPrint('BackgroundTask: Error executing task: $e');
      return Future.value(false);
    }
  });
}

Future<bool> _performClocking(String webhookUrl, String action, String today, SharedPreferences prefs) async {
  try {
    final now = DateTime.now();
    
    // 檢查半天假設定
    final morningHalfDayLeave = prefs.getBool('morningHalfDayLeave_$today') ?? false;
    final afternoonHalfDayLeave = prefs.getBool('afternoonHalfDayLeave_$today') ?? false;
    
    // 如果是上班打卡且設置了上午請假，則跳過
    if (action == 'clockIn' && morningHalfDayLeave) {
      debugPrint('BackgroundTask: Morning half-day leave enabled, skipping auto clock-in.');
      return true; // 返回成功，但不執行打卡
    }
    
    // 如果是下班打卡且設置了下午請假，則跳過
    if (action == 'clockOut' && afternoonHalfDayLeave) {
      debugPrint('BackgroundTask: Afternoon half-day leave enabled, skipping auto clock-out.');
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
        final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
        
        // 初始化設置
        const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
        final DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
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
        final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
        
        // 初始化設置
        const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
        final DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
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