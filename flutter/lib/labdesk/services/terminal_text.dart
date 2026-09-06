// A PTY is a terminal, so what comes back is display bytes: colour codes,
// cursor moves, title sets and carriage returns mixed into the text. None of
// that survives into a list of output lines, so it is removed before parsing.
/// Written by a framed command as its last line, carrying the shell's exit
/// status.
///
/// A PTY is a byte stream with a prompt at either end, not a request and a
/// response, so without this there is no way to tell a finished command from
/// one still arriving, or a failed one from a silent shell.
const kLabDeskEndMarker = 'LABDESK_END';

final _osc = RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)');
final _csi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
final _esc = RegExp(r'\x1B[ -/]*[0-~]');

/// Terminal output with its escape sequences and carriage returns removed.
String stripAnsi(String s) => s
    .replaceAll(_osc, '')
    .replaceAll(_csi, '')
    .replaceAll(_esc, '')
    .replaceAll('\r', '');

final _marker = RegExp('${RegExp.escape(kLabDeskEndMarker)}=(-?\\d+)');

/// Appends the end marker to an arbitrary command, in the syntax of the shell
/// the peer's terminal service actually starts.
class CommandFramer {
  CommandFramer._();

  /// On Windows the terminal service prefers PowerShell (pwsh, then Windows
  /// PowerShell) and only falls back to cmd.exe when neither exists, so the
  /// marker is written in PowerShell syntax: $? is a boolean there, so the
  /// exit status is spelled out rather than read off $?.
  static String frame(String command, String platform) {
    if (platform.toLowerCase().contains('win')) {
      return '$command; Write-Output (\'$kLabDeskEndMarker=\''
          ' + \$(if (\$?) { 0 } else { 1 }))';
    }
    return '$command; echo "$kLabDeskEndMarker=\$?"';
  }
}

/// Turns the raw stream a framed command produced back into its output.
class CommandOutput {
  CommandOutput._();

  /// Everything the command printed, without the shell's echo of the command
  /// itself or the marker line, plus the exit status the marker carried.
  ///
  /// A null exit code means no marker arrived: the command is still running,
  /// or the shell died before reporting.
  static ({List<String> lines, int? exitCode}) parse(
      String raw, String command) {
    final text = stripAnsi(raw);
    final match = _marker.firstMatch(text);
    final exitCode = match == null ? null : int.tryParse(match.group(1)!);

    // Anything after the marker is the next prompt, not output.
    final body = match == null ? text : text.substring(0, match.start);

    final lines = <String>[];
    for (final line in body.split('\n')) {
      // The PTY echoes what was typed, prompt and all, before running it.
      if (command.isNotEmpty && line.contains(command)) continue;
      if (line.contains(kLabDeskEndMarker)) continue;
      lines.add(line);
    }
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return (lines: lines, exitCode: exitCode);
  }
}
