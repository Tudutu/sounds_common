import 'package:intl/intl.dart';
import 'package:logger/logger.dart' hide AnsiColor;

import 'ansi_color.dart';
import 'enum_helper.dart';
import 'stack_trace_impl.dart';

/// Logging class
class Log extends Logger {
  static Log? _self;
  static late String _localPath;

  /// The default log level.
  static Level loggingLevel = Level.info;

  Log._internal(String currentWorkingDirectory)
      : super(printer: MyLogPrinter(currentWorkingDirectory));

  ///
  void debug(String message, {dynamic error, StackTrace? stackTrace}) {
    autoInit();
    Log.d(message, error: error, stackTrace: stackTrace);
  }

  ///
  void info(String message, {dynamic error, StackTrace? stackTrace}) {
    autoInit();
    Log.i(message, error: error, stackTrace: stackTrace);
  }

  ///
  void warn(String message, {dynamic error, StackTrace? stackTrace}) {
    autoInit();
    Log.w(message, error: error, stackTrace: stackTrace);
  }

  ///
  void error(String message, {dynamic error, StackTrace? stackTrace}) {
    autoInit();
    Log.e(message, error: error, stackTrace: stackTrace);
  }

  ///
  void color(String message, AnsiColor color,
      {dynamic error, StackTrace? stackTrace}) {
    autoInit();
    Log.i(color.apply(message), error: error, stackTrace: stackTrace);
  }

  ///
  factory Log.color(String message, AnsiColor color,
      {dynamic error, StackTrace? stackTrace}) {
    autoInit();
    _self!.d(color.apply(message), error, stackTrace);
    return _self!;
  }

  static final _recentLogs = <String, DateTime>{};

  ///
  factory Log.d(String message,
      {dynamic error,
      StackTrace? stackTrace,
      bool supressDuplicates = false}) {
    autoInit();
    var suppress = false;

    if (supressDuplicates) {
      var lastLogged = _recentLogs[message];
      if (lastLogged != null &&
          lastLogged.add(Duration(milliseconds: 100)).isAfter(DateTime.now())) {
        suppress = true;
      }
      _recentLogs[message] = DateTime.now();
    }
    if (!suppress) _self!.d(message, error, stackTrace);
    return _self!;
  }

  ///
  factory Log.i(String message, {dynamic error, StackTrace? stackTrace}) {
    autoInit();
    _self!.i(message, error, stackTrace);
    return _self!;
  }

  ///
  factory Log.w(String message, {dynamic error, StackTrace? stackTrace}) {
    autoInit();
    _self!.w(message, error, stackTrace);
    return _self!;
  }

  ///
  factory Log.e(String message, {dynamic error, StackTrace? stackTrace}) {
    autoInit();
    _self!.e(message, error, stackTrace);
    return _self!;
  }

  ///
  static void autoInit() {
    if (_self == null) {
      init('.');
    }
  }

  ///
  static void init(String currentWorkingDirectory) {
    _self = Log._internal(currentWorkingDirectory);

    var frames = StackTraceImpl();

    for (var frame in frames.frames) {
      _localPath = frame.sourceFile.path
          .substring(frame.sourceFile.path.lastIndexOf('/'));
      break;
    }
  }
}

///
class MyLogPrinter extends LogPrinter {
  ///
  bool colors = true;

  ///
  String currentWorkingDirectory;

  ///
  MyLogPrinter(this.currentWorkingDirectory);

  @override
  List<String> log(LogEvent event) {
    var output = <String>[];
    if (EnumHelper.getIndexOf(Level.values, Log.loggingLevel) >
        EnumHelper.getIndexOf(Level.values, event.level)) {
      // don't log events where the log level is set higher
      return output;
    }
    var formatter = DateFormat('dd HH:mm:ss.');
    var now = DateTime.now();
    var formattedDate = formatter.format(now) + now.millisecond.toString();

    var frames = StackTraceImpl();
    var i = 0;
    var depth = 0;
    for (var frame in frames.frames) {
      i++;
      var path2 = frame.sourceFile.path;
      if (!path2.contains(Log._localPath) && !path2.contains('logger.dart')) {
        depth = i - 1;
        break;
      }
    }

    output.add(color(
        event.level,
        '$formattedDate ${EnumHelper.getName(event.level)} '
        '${StackTraceImpl(skipFrames: depth).formatStackTrace(methodCount: 1)} '
        '::: ${event.message}'));

    if (event.error != null) {
      output.add(color(event.level, '${event.error}'));
    }

    if (event.stackTrace != null) {
      if (event.stackTrace.runtimeType == StackTraceImpl) {
        var st = event.stackTrace as StackTraceImpl;
        output.add(color(event.level, '$st'));
      } else {
        output.add(color(event.level, '${event.stackTrace}'));
      }
    }
    return output;
  }

  ///
  String color(Level level, String line) {
    var result = '';

    switch (level) {
      case Level.debug:
        result += grey(line, level: 0.75);
        break;
      case Level.verbose:
        result += grey(line, level: 0.50);
        break;
      case Level.info:
        result += line;
        break;
      case Level.warning:
        result += orange(line);
        break;
      case Level.error:
        result += red(line);
        break;
      case Level.wtf:
        result += red(line, bgcolor: AnsiColor.yellow);
        break;
      case Level.nothing:
        result += line;
        break;
    }

    return result;
  }
}
