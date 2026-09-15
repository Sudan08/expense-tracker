/// Plan section 14: freshness tracks the laptop, not real time, so this
/// label needs to be prominent and honest ("last synced 6 days ago"), never
/// implying the data is live.
String timeAgo(DateTime from) {
  final diff = DateTime.now().toUtc().difference(from.toUtc());
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  final weeks = diff.inDays ~/ 7;
  if (diff.inDays < 30) return '${weeks}w ago';
  final months = diff.inDays ~/ 30;
  return '${months}mo ago';
}
