class Cookie {
  String name;
  String value;
  String? domain;
  String? path;
  DateTime? expires;
  int? maxAge;
  bool secure;
  bool httpOnly;

  Cookie(this.name, this.value)
    : maxAge = null,
      secure = false,
      httpOnly = false;

  factory Cookie.fromSetCookieValue(String value) {
    final parts = value.split(';');
    final nameValue = parts.first.trim().split('=');
    final cookie = Cookie(
      nameValue.first.trim(),
      nameValue.length > 1 ? nameValue.sublist(1).join('=').trim() : '',
    );
    for (final part in parts.skip(1)) {
      final trimmed = part.trim();
      final lower = trimmed.toLowerCase();
      if (lower == 'secure') {
        cookie.secure = true;
      } else if (lower == 'httponly') {
        cookie.httpOnly = true;
      } else if (lower.startsWith('domain=')) {
        cookie.domain = trimmed.substring(7);
      } else if (lower.startsWith('path=')) {
        cookie.path = trimmed.substring(5);
      } else if (lower.startsWith('max-age=')) {
        cookie.maxAge = int.tryParse(trimmed.substring(8));
      } else if (lower.startsWith('expires=')) {
        cookie.expires = DateTime.tryParse(trimmed.substring(8));
      }
    }
    return cookie;
  }
}
