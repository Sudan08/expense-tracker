import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// The nightly "anything to fill in?" reminder.
///
/// **Why local, not push.** There is no always-on component in this
/// architecture — plan section 14 is explicit that the honest offering is a
/// digest after a sync, not a live alert. A local notification keeps that
/// honesty and needs no Firebase project, no device-token table, and no
/// credentials on the worker for what is one nudge a day to one phone.
///
/// **What it can and cannot say.** The text is fixed at scheduling time, so
/// it reports the counts as of the last time the app was open, not as of
/// right now. That is a real limitation and the copy admits it rather than
/// implying a live number: [_body] says "as of your last check". The
/// reminder is rescheduled on every app resume, so in practice the numbers
/// are rarely more than a day old.
///
/// **Why 22:00, and why the worker runs at 21:30.** The evening sync
/// refreshes ledger_gaps half an hour before this fires, so the list you sit
/// down to is tonight's rather than this morning's. See
/// worker/src/expense_tracker/scheduling/.
class DailyReminder {
  DailyReminder(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  static const _channelId = 'daily_reminder';
  static const _notificationId = 1001;

  /// 22:00 in Kathmandu, matching invariant 2's "displayed Asia/Kathmandu".
  /// Pinned to the zone rather than the handset's current one so the
  /// reminder doesn't drift to a strange hour of the Nepali day while
  /// travelling — the ledger it is about is denominated in Kathmandu days.
  static const _hour = 22;
  static const _minute = 0;
  static const _zone = 'Asia/Kathmandu';

  static bool _tzReady = false;

  static Future<DailyReminder> initialize() async {
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation(_zone));
      _tzReady = true;
    }

    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          // Asked for explicitly in requestPermissions() below, at a moment
          // the user can connect to something they did, rather than during
          // a cold start before they've seen the app.
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    return DailyReminder(plugin);
  }

  /// Ask for notification permission. Android 13+ requires POST_NOTIFICATIONS
  /// at runtime; below that the manifest entry is enough and this is a no-op.
  /// Returns false if the user said no, in which case scheduling silently
  /// does nothing — the app keeps working, it just doesn't nag.
  Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? false;
    }
    if (Platform.isIOS) {
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await ios?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    }
    return false;
  }

  /// (Re)schedule tonight's reminder with the counts the app can currently
  /// see. Safe to call as often as you like: the same notification id is
  /// reused, so this replaces rather than accumulates.
  Future<void> schedule({required int openGaps, required int needsReview}) async {
    await _plugin.zonedSchedule(
      _notificationId,
      _title(openGaps),
      _body(openGaps: openGaps, needsReview: needsReview),
      _nextInstanceOfTenPm(),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Daily reminder',
          channelDescription: 'A nightly nudge to fill in anything the pipeline could not see.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      // Inexact on purpose. An exact alarm needs SCHEDULE_EXACT_ALARM, which
      // Android 14 gates behind a settings screen and reserves for alarms
      // and timers — a reminder that lands a few minutes either side of ten
      // is not one, and asking for that permission for this would be
      // overreach.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      // Repeat daily at the same wall-clock time.
      matchDateTimeComponents: DateTimeComponents.time,
      payload: openGaps > 0 ? '/data-health' : '/add',
    );
  }

  Future<void> cancel() => _plugin.cancel(_notificationId);

  /// Where tapping the notification should land. Read once at startup,
  /// because a tap that launched the app from cold is only reported here.
  Future<String?> launchRoute() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details?.notificationResponse?.payload;
  }

  static tz.TZDateTime _nextInstanceOfTenPm() {
    final now = tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(tz.local, now.year, now.month, now.day, _hour, _minute);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    return next;
  }

  static String _title(int openGaps) => openGaps > 0
      ? 'Something is missing from your ledger'
      : 'Anything to add today?';

  static String _body({required int openGaps, required int needsReview}) {
    final parts = <String>[
      if (openGaps > 0) '$openGaps gap${openGaps == 1 ? '' : 's'} to fill from your bank app',
      if (needsReview > 0) '$needsReview to categorise',
    ];
    if (parts.isEmpty) {
      return 'Nothing outstanding as of your last check. Tap to add a cash spend.';
    }
    return '${parts.join(' · ')} (as of your last check).';
  }
}

/// Built once and reused. Held in a provider so the widget tree can
/// reschedule on resume without threading the instance through by hand.
final dailyReminderProvider = FutureProvider<DailyReminder>((ref) {
  return DailyReminder.initialize();
});
