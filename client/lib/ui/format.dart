/// Date and time formatting in the interface language.
library;

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';

String _locale(BuildContext context) =>
    Localizations.localeOf(context).toLanguageTag();

/// "14:32".
String formatClock(BuildContext context, DateTime time) =>
    DateFormat.Hm(_locale(context)).format(time.toLocal());

/// The compact stamp in the chat list: time today, "Yesterday", the weekday
/// this week, the date beyond that.
String formatListStamp(BuildContext context, DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final today = _dateOnly(now ?? DateTime.now());
  final day = _dateOnly(local);
  final days = today.difference(day).inDays;

  if (days == 0) return formatClock(context, local);
  if (days == 1) return AppLocalizations.of(context).yesterday;
  if (days < 7) return DateFormat.E(_locale(context)).format(local);
  return DateFormat.MMMd(_locale(context)).format(local);
}

/// The label of a day separator in a conversation.
String formatDayLabel(BuildContext context, DateTime time, {DateTime? now}) {
  final l10n = AppLocalizations.of(context);
  final local = time.toLocal();
  final today = _dateOnly(now ?? DateTime.now());
  final days = today.difference(_dateOnly(local)).inDays;

  if (days == 0) return l10n.today;
  if (days == 1) return l10n.yesterday;
  if (local.year == today.year) {
    return DateFormat.MMMMd(_locale(context)).format(local);
  }
  return DateFormat.yMMMMd(_locale(context)).format(local);
}

/// A short date, for "last used" lines.
String formatDate(BuildContext context, DateTime time) =>
    DateFormat.yMMMd(_locale(context)).format(time.toLocal());

/// When someone was last seen: "at 14:05", "yesterday at 14:05",
/// "Oct 12 at 14:05".
String formatLastSeen(BuildContext context, DateTime time, {DateTime? now}) {
  final l10n = AppLocalizations.of(context);
  final local = time.toLocal();
  final days = _dateOnly(now ?? DateTime.now()).difference(_dateOnly(local)).inDays;
  final clock = formatClock(context, local);
  if (days <= 0) return l10n.lastSeenToday(clock);
  if (days == 1) return l10n.lastSeenYesterday(clock);
  return l10n.lastSeenDate(DateFormat.MMMd(_locale(context)).format(local), clock);
}

/// True when [a] and [b] fall on the same local calendar day.
bool isSameDay(DateTime a, DateTime b) =>
    _dateOnly(a.toLocal()) == _dateOnly(b.toLocal());

DateTime _dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);
