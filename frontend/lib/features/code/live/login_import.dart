// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Importing logins from a password manager's CSV export: Chrome (name,url,username,password,note), Safari
// (Title,URL,Username,Password,Notes,OTPAuth) and 1Password (Title,Url or Website,Username,Password,OTPAuth,…). The
// header says which; columns are found by name, in any case and order.

/// Where a CSV export came from.
enum LoginCsvFormat {
  chrome('Chrome'),
  safari('Safari'),
  onePassword('1Password'),
  other('a password manager');

  const LoginCsvFormat(this.label);
  final String label;
}

/// One row of an export: what a saved login needs.
typedef ImportedLogin = ({String title, String url, String username, String password, String? totp});

/// The rows of [text] (RFC 4180: quoted fields may hold commas, quotes as "" and line breaks).
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var i = 0;
  // A byte order mark from Excel or Numbers.
  if (text.startsWith('﻿')) i = 1;
  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    if (!(row.length == 1 && row.single.isEmpty)) rows.add(row);
    row = <String>[];
  }

  for (; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      endField();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endRow();
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

/// Which export [header] (the first row) is, or null when it has no password column.
LoginCsvFormat? csvFormatOf(List<String> header) {
  final h = [for (final c in header) c.trim().toLowerCase()];
  if (!h.contains('password')) return null;
  if (h.contains('name') && h.contains('url')) return LoginCsvFormat.chrome;
  if (h.contains('title')) {
    if (h.contains('website') || h.contains('favorite') || h.contains('archived') || h.contains('tags')) {
      return LoginCsvFormat.onePassword;
    }
    if (h.contains('url') && h.contains('notes')) return LoginCsvFormat.safari;
    return LoginCsvFormat.onePassword;
  }
  return LoginCsvFormat.other;
}

/// The logins in export [text]: its format, and one entry per row with a password and an address. Throws a
/// [FormatException] when the first row isn't a header with a password column.
({LoginCsvFormat format, List<ImportedLogin> logins, int skipped}) parseLoginCsv(String text) {
  final rows = parseCsv(text);
  if (rows.isEmpty) throw const FormatException('The file is empty.');
  final format = csvFormatOf(rows.first);
  if (format == null) {
    throw const FormatException(
      'This file has no password column. Export from Chrome, Safari or 1Password as CSV and pick that file.',
    );
  }
  final header = [for (final c in rows.first) c.trim().toLowerCase()];
  int col(List<String> names) {
    for (final n in names) {
      final i = header.indexOf(n);
      if (i >= 0) return i;
    }
    return -1;
  }

  final title = col(['name', 'title']), url = col(['url', 'website', 'login_uri', 'login url']);
  final user = col(['username', 'login', 'email', 'login_username']), pass = col(['password', 'login_password']);
  final otp = col(['otpauth', 'otp', 'totp', 'one-time password']);
  String at(List<String> r, int i) => i >= 0 && i < r.length ? r[i].trim() : '';
  final out = <ImportedLogin>[];
  var skipped = 0;
  for (final r in rows.skip(1)) {
    // Passwords keep their spaces: only the cell's own padding goes, and only around other columns.
    final password = pass >= 0 && pass < r.length ? r[pass] : '';
    final address = at(r, url);
    if (password.isEmpty || address.isEmpty) {
      skipped++;
      continue;
    }
    final code = at(r, otp);
    out.add((
      title: at(r, title),
      url: address,
      username: at(r, user),
      password: password,
      totp: code.isEmpty ? null : code,
    ));
  }
  return (format: format, logins: out, skipped: skipped);
}
