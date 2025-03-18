import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';

const _timeStampKey = '_pdl_timeStamp_';

/// A pretty logger for Dio
/// it will print request/response info with a pretty format
/// and also can filter the request/response by [RequestOptions]
class PrettyDioLogger extends Interceptor {
   /// Print request [Options]
  final bool request;

  /// Print request header [Options.headers]
  final bool requestHeader;

  /// Print request data [Options.data]
  final bool requestBody;

  /// Print [Response.data]
  final bool responseBody;

  /// Print [Response.headers]
  final bool responseHeader;

  /// Print error message
  final bool error;

  /// InitialTab count to logPrint json response
  static const int kInitialTab = 1;

  /// 1 tab length
  static const String tabStep = '    ';

  /// Print compact json response
  final bool compact;

  /// Width size per logPrint
  final int maxWidth;

  /// Size in which the Uint8List will be split
  static const int chunkSize = 20;

  /// Log printer; defaults logPrint log to console.
  /// In flutter, you'd better use debugPrint.
  /// you can also write log in a file.
  final void Function(Object object) logPrint;

  /// Filter request/response by [RequestOptions]
  final bool Function(RequestOptions options, FilterArgs args)? filter;

  /// Enable logPrint
  final bool enabled;

  /// Default constructor
  PrettyDioLogger({
    this.request = true,
    this.requestHeader = true,
    this.requestBody = true,
    this.responseHeader = false,
    this.responseBody = true,
    this.error = true,
    this.maxWidth = 90,
    this.compact = true,
    this.logPrint = print,
    this.filter,
    this.enabled = true,
  });

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final extra = Map.of(options.extra);
    options.extra[_timeStampKey] = DateTime.timestamp().millisecondsSinceEpoch;

    if (!enabled ||
        (filter != null &&
            !filter!(options, FilterArgs(false, options.data)))) {
      handler.next(options);
      return;
    }

    // Collect all log statements
    final List<String> logBuffer = [];

    if (request) {
      _collectRequestHeader(options, logBuffer);
    }
    if (requestHeader) {
      _collectMapAsTable(options.queryParameters,
          header: 'Query Parameters', buffer: logBuffer);
      final requestHeaders = <String, dynamic>{};
      requestHeaders.addAll(options.headers);
      if (options.contentType != null) {
        requestHeaders['contentType'] = options.contentType?.toString();
      }
      requestHeaders['responseType'] = options.responseType.toString();
      requestHeaders['followRedirects'] = options.followRedirects;
      if (options.connectTimeout != null) {
        requestHeaders['connectTimeout'] = options.connectTimeout?.toString();
      }
      if (options.receiveTimeout != null) {
        requestHeaders['receiveTimeout'] = options.receiveTimeout?.toString();
      }
      _collectMapAsTable(requestHeaders, header: 'Headers', buffer: logBuffer);
      _collectMapAsTable(extra, header: 'Extras', buffer: logBuffer);
    }
    if (requestBody && options.method != 'GET') {
      final dynamic data = options.data;
      if (data != null) {
        if (data is Map) {
          _collectMapAsTable(options.data as Map?,
              header: 'Body', buffer: logBuffer);
        }
        if (data is FormData) {
          final formDataMap = <String, dynamic>{}
            ..addEntries(data.fields)
            ..addEntries(data.files);
          _collectMapAsTable(formDataMap,
              header: 'Form data | ${data.boundary}', buffer: logBuffer);
        } else {
          _collectBlock(data.toString(), logBuffer);
        }
      }
    }

    // Print all collected logs at once
    if (logBuffer.isNotEmpty) {
      logPrint(logBuffer.join('\n'));
    }

    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (!enabled ||
        (filter != null &&
            !filter!(
                err.requestOptions, FilterArgs(true, err.response?.data)))) {
      handler.next(err);
      return;
    }

    final triggerTime = err.requestOptions.extra[_timeStampKey];
    final List<String> logBuffer = [];

    if (error) {
      if (err.type == DioExceptionType.badResponse) {
        final uri = err.response?.requestOptions.uri;
        int diff = 0;
        if (triggerTime is int) {
          diff = DateTime.timestamp().millisecondsSinceEpoch - triggerTime;
        }
        _collectBoxed(
            header:
                'DioError ║ Status: ${err.response?.statusCode} ${err.response?.statusMessage} ║ Time: $diff ms',
            text: uri.toString(),
            buffer: logBuffer);
        if (err.response != null && err.response?.data != null) {
          logBuffer.add('╔ ${err.type.toString()}');
          _collectResponse(err.response!, logBuffer);
        }
        _collectLine('╚', '╝', logBuffer);
        logBuffer.add('');
      } else {
        _collectBoxed(
            header: 'DioError ║ ${err.type}',
            text: err.message,
            buffer: logBuffer);
      }
    }

    // Print all collected logs at once
    if (logBuffer.isNotEmpty) {
      logPrint(logBuffer.join('\n'));
    }

    handler.next(err);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (!enabled ||
        (filter != null &&
            !filter!(
                response.requestOptions, FilterArgs(true, response.data)))) {
      handler.next(response);
      return;
    }

    final triggerTime = response.requestOptions.extra[_timeStampKey];
    final List<String> logBuffer = [];

    int diff = 0;
    if (triggerTime is int) {
      diff = DateTime.timestamp().millisecondsSinceEpoch - triggerTime;
    }
    _collectResponseHeader(response, diff, logBuffer);
    if (responseHeader) {
      final responseHeaders = <String, String>{};
      response.headers
          .forEach((k, list) => responseHeaders[k] = list.toString());
      _collectMapAsTable(responseHeaders, header: 'Headers', buffer: logBuffer);
    }

    if (responseBody) {
      logBuffer.add('╔ Body');
      logBuffer.add('║');
      _collectResponse(response, logBuffer);
      logBuffer.add('║');
      _collectLine('╚', '╝', logBuffer);
    }

    // Print all collected logs at once
    if (logBuffer.isNotEmpty) {
      logPrint(logBuffer.join('\n'));
    }

    handler.next(response);
  }

  void _collectBoxed(
      {String? header, String? text, required List<String> buffer}) {
    buffer.add('');
    buffer.add('╔╣ $header');
    buffer.add('║  $text');
    _collectLine('╚', '╝', buffer);
  }

  void _collectResponse(Response response, List<String> buffer) {
    if (response.data != null) {
      if (response.data is Map) {
        _collectPrettyMap(response.data as Map, buffer: buffer);
      } else if (response.data is Uint8List) {
        buffer.add('║${_indent()}[');
        _collectUint8List(response.data as Uint8List, buffer: buffer);
        buffer.add('║${_indent()}]');
      } else if (response.data is List) {
        buffer.add('║${_indent()}[');
        _collectList(response.data as List, buffer: buffer);
        buffer.add('║${_indent()}]');
      } else {
        _collectBlock(response.data.toString(), buffer);
      }
    }
  }

  void _collectResponseHeader(
      Response response, int responseTime, List<String> buffer) {
    final uri = response.requestOptions.uri;
    final method = response.requestOptions.method;
    _collectBoxed(
        header:
            'Response ║ $method ║ Status: ${response.statusCode} ${response.statusMessage}  ║ Time: $responseTime ms',
        text: uri.toString(),
        buffer: buffer);
  }

  void _collectRequestHeader(RequestOptions options, List<String> buffer) {
    final uri = options.uri;
    final method = options.method;
    _collectBoxed(
        header: 'Request ║ $method ', text: uri.toString(), buffer: buffer);
  }

  void _collectLine([String pre = '', String suf = '╝', List<String>? buffer]) {
    if (buffer != null) {
      buffer.add('$pre${'═' * maxWidth}$suf');
    }
  }

  void _collectKV(String? key, Object? v, List<String> buffer) {
    final pre = '╟ $key: ';
    final msg = v.toString();

    if (pre.length + msg.length > maxWidth) {
      buffer.add(pre);
      _collectBlock(msg, buffer);
    } else {
      buffer.add('$pre$msg');
    }
  }

  void _collectBlock(String msg, List<String> buffer) {
    final lines = (msg.length / maxWidth).ceil();
    for (var i = 0; i < lines; ++i) {
      buffer.add((i >= 0 ? '║ ' : '') +
          msg.substring(i * maxWidth,
              math.min<int>(i * maxWidth + maxWidth, msg.length)));
    }
  }

  String _indent([int tabCount = kInitialTab]) => tabStep * tabCount;

  void _collectPrettyMap(
    Map data, {
    int initialTab = kInitialTab,
    bool isListItem = false,
    bool isLast = false,
    required List<String> buffer,
  }) {
    var tabs = initialTab;
    final isRoot = tabs == kInitialTab;
    final initialIndent = _indent(tabs);
    tabs++;

    if (isRoot || isListItem) buffer.add('║$initialIndent{');

    for (var index = 0; index < data.length; index++) {
      final isLast = index == data.length - 1;
      final key = '"${data.keys.elementAt(index)}"';
      dynamic value = data[data.keys.elementAt(index)];
      if (value is String) {
        value = '"${value.toString().replaceAll(RegExp(r'([\r\n])+'), " ")}"';
      }
      if (value is Map) {
        if (compact && _canFlattenMap(value)) {
          buffer.add('║${_indent(tabs)} $key: $value${!isLast ? ',' : ''}');
        } else {
          buffer.add('║${_indent(tabs)} $key: {');
          _collectPrettyMap(value, initialTab: tabs, buffer: buffer);
        }
      } else if (value is List) {
        if (compact && _canFlattenList(value)) {
          buffer.add('║${_indent(tabs)} $key: ${value.toString()}');
        } else {
          buffer.add('║${_indent(tabs)} $key: [');
          _collectList(value, tabs: tabs, buffer: buffer);
          buffer.add('║${_indent(tabs)} ]${isLast ? '' : ','}');
        }
      } else {
        final msg = value.toString().replaceAll('\n', '');
        final indent = _indent(tabs);
        final linWidth = maxWidth - indent.length;
        if (msg.length + indent.length > linWidth) {
          final lines = (msg.length / linWidth).ceil();
          for (var i = 0; i < lines; ++i) {
            final multilineKey = i == 0 ? "$key:" : "";
            buffer.add(
                '║${_indent(tabs)} $multilineKey ${msg.substring(i * linWidth, math.min<int>(i * linWidth + linWidth, msg.length))}');
          }
        } else {
          buffer.add('║${_indent(tabs)} $key: $msg${!isLast ? ',' : ''}');
        }
      }
    }

    buffer.add('║$initialIndent}${isListItem && !isLast ? ',' : ''}');
  }

  void _collectList(List list,
      {int tabs = kInitialTab, required List<String> buffer}) {
    for (var i = 0; i < list.length; i++) {
      final element = list[i];
      final isLast = i == list.length - 1;
      if (element is Map) {
        if (compact && _canFlattenMap(element)) {
          buffer.add('║${_indent(tabs)}  $element${!isLast ? ',' : ''}');
        } else {
          _collectPrettyMap(
            element,
            initialTab: tabs + 1,
            isListItem: true,
            isLast: isLast,
            buffer: buffer,
          );
        }
      } else {
        buffer.add('║${_indent(tabs + 2)} $element${isLast ? '' : ','}');
      }
    }
  }

  void _collectUint8List(Uint8List list,
      {int tabs = kInitialTab, required List<String> buffer}) {
    var chunks = [];
    for (var i = 0; i < list.length; i += chunkSize) {
      chunks.add(
        list.sublist(
            i, i + chunkSize > list.length ? list.length : i + chunkSize),
      );
    }
    for (var element in chunks) {
      buffer.add('║${_indent(tabs)} ${element.join(", ")}');
    }
  }

  bool _canFlattenMap(Map map) {
    return map.values
            .where((dynamic val) => val is Map || val is List)
            .isEmpty &&
        map.toString().length < maxWidth;
  }

  bool _canFlattenList(List list) {
    return list.length < 10 && list.toString().length < maxWidth;
  }

  void _collectMapAsTable(Map? map,
      {String? header, required List<String> buffer}) {
    if (map == null || map.isEmpty) return;
    buffer.add('╔ $header ');
    for (final entry in map.entries) {
      _collectKV(entry.key.toString(), entry.value, buffer);
    }
    _collectLine('╚', '╝', buffer);
  }
}

/// Filter arguments
class FilterArgs {
  /// If the filter is for a request or response
  final bool isResponse;

  /// if the [isResponse] is false, the data is the [RequestOptions.data]
  /// if the [isResponse] is true, the data is the [Response.data]
  final dynamic data;

  /// Returns true if the data is a string
  bool get hasStringData => data is String;

  /// Returns true if the data is a map
  bool get hasMapData => data is Map;

  /// Returns true if the data is a list
  bool get hasListData => data is List;

  /// Returns true if the data is a Uint8List
  bool get hasUint8ListData => data is Uint8List;

  /// Returns true if the data is a json data
  bool get hasJsonData => hasMapData || hasListData;

  /// Default constructor
  const FilterArgs(this.isResponse, this.data);
}
