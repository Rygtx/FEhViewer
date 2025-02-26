import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/adapter.dart';
import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fehviewer/common/service/dns_service.dart';
import 'package:fehviewer/const/const.dart';
import 'package:fehviewer/network/app_dio/proxy.dart';
import 'package:fehviewer/network/dio_interceptor/domain_fronting/domain_fronting.dart';
import 'package:fehviewer/network/dio_interceptor/eh_cookie_interceptor/eh_cookie_interceptor.dart';
import 'package:fehviewer/utils/logger.dart';
import 'package:get/get.dart' hide Response;
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

import '../api.dart';
import 'http_config.dart';

export 'http_config.dart';

typedef AppHttpAdapter = HttpProxyAdapter;

class AppDio with DioMixin implements Dio {
  AppDio({BaseOptions? options, DioHttpConfig? dioConfig}) {
    options ??= BaseOptions(
      baseUrl: dioConfig?.baseUrl ?? '',
      contentType: dioConfig?.contentType ?? Headers.formUrlEncodedContentType,
      connectTimeout: dioConfig?.connectTimeout,
      sendTimeout: dioConfig?.sendTimeout,
      receiveTimeout: dioConfig?.receiveTimeout,
      headers: <String, String>{
        'User-Agent': EHConst.CHROME_USER_AGENT,
        'Accept': EHConst.CHROME_ACCEPT,
        'Accept-Language': EHConst.CHROME_ACCEPT_LANGUAGE,
      },
    );
    this.options = options;

    logger.v('dioConfig ${dioConfig?.toString()}');

    httpClientAdapter = AppHttpAdapter(
      proxy: dioConfig?.proxy ?? '',
      skipCertificate: dioConfig?.domainFronting,
    );

    interceptors.add(DioCacheInterceptor(options: Api.cacheOption));

    // Cookie管理
    if (dioConfig?.cookiesPath?.isNotEmpty ?? false) {
      interceptors.add(CookieManager(
          PersistCookieJar(storage: FileStorage(dioConfig!.cookiesPath))));
    }

    interceptors.add(EhCookieInterceptor());

    // if (kDebugMode) {
    //   interceptors.add(LogInterceptor(
    //       responseBody: false,
    //       error: true,
    //       requestHeader: false,
    //       responseHeader: false,
    //       request: true,
    //       requestBody: true));
    // }

    interceptors.add(PrettyDioLogger(
      requestHeader: true,
      requestBody: true,
      responseHeader: true,
      responseBody: false,
      maxWidth: 120,
      // logPrint: kDebugMode ? loggerSimple.d : loggerSimpleOnlyFile.d,
      logPrint: loggerSimpleOnlyFile.d,
    ));

    // RetryInterceptor
    interceptors.add(RetryInterceptor(
      dio: this,
      logPrint: logger.v, // specify log function (optional)
      retries: 3, // retry count (optional)
      retryDelays: const [
        // set delays between retries (optional)
        Duration(seconds: 1), // wait 1 sec before first retry
        Duration(seconds: 2), // wait 2 sec before second retry
        Duration(seconds: 3), // wait 3 sec before third retry
      ],
    ));

    if (dioConfig?.interceptors?.isNotEmpty ?? false) {
      interceptors.addAll(interceptors);
    }

    if (dioConfig?.domainFronting ?? false) {
      final DnsService dnsServices = Get.find();
      final bool enableDoH = dnsServices.enableDoH;

      final customHosts = dnsServices.hostMapMerge;

      final domainFronting = DomainFronting(
        hosts: customHosts,
        dnsLookup: dnsServices.getHost,
      );

      // 允许证书错误的地址/ip
      final hostWhiteList = customHosts.values.flattened.toSet();

      // (httpClientAdapter as HttpProxyAdapter)
      //     .addOnHttpClientCreate((client) {
      //   client.badCertificateCallback =
      //       (X509Certificate cert, String host, int port) {
      //     // return hostWhiteList.contains(host);
      //     return true;
      //   };
      // });

      // 在其他插件添加完毕后再添加，以确保执行顺序正确
      domainFronting.bind(interceptors);
    }
  }

  /// DioMixin 没有实现下载
  /// 从 [DioForNative] 复制过来的
  @override
  Future<Response> download(
    String urlPath,
    savePath, {
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    String lengthHeader = Headers.contentLengthHeader,
    data,
    Options? options,
  }) async {
    // We set the `responseType` to [ResponseType.STREAM] to retrieve the
    // response stream.
    options ??= DioMixin.checkOptions('GET', options);

    // Receive data with stream.
    options.responseType = ResponseType.stream;
    Response<ResponseBody> response;
    try {
      response = await request<ResponseBody>(
        urlPath,
        data: data,
        options: options,
        queryParameters: queryParameters,
        cancelToken: cancelToken ?? CancelToken(),
      );
    } on DioError catch (e) {
      if (e.type == DioErrorType.response) {
        if (e.response!.requestOptions.receiveDataWhenStatusError == true) {
          var res = await transformer.transformResponse(
            e.response!.requestOptions..responseType = ResponseType.json,
            e.response!.data as ResponseBody,
          );
          e.response!.data = res;
        } else {
          e.response!.data = null;
        }
      }
      rethrow;
    }

    response.headers = Headers.fromMap(response.data!.headers);

    File file;
    if (savePath is Function) {
      assert(savePath is String Function(Headers),
          'savePath callback type must be `String Function(HttpHeaders)`');

      // Add real uri and redirect information to headers
      response.headers
        ..add('redirects', response.redirects.length.toString())
        ..add('uri', response.realUri.toString());

      file = File(savePath(response.headers) as String);
    } else {
      file = File(savePath.toString());
    }

    //If directory (or file) doesn't exist yet, the entire method fails
    file.createSync(recursive: true);

    // Shouldn't call file.writeAsBytesSync(list, flush: flush),
    // because it can write all bytes by once. Consider that the
    // file with a very big size(up 1G), it will be expensive in memory.
    var raf = file.openSync(mode: FileMode.write);

    //Create a Completer to notify the success/error state.
    var completer = Completer<Response>();
    var future = completer.future;
    var received = 0;

    // Stream<Uint8List>
    var stream = response.data!.stream;
    var compressed = false;
    var total = 0;
    var contentEncoding = response.headers.value(Headers.contentEncodingHeader);
    if (contentEncoding != null) {
      compressed = ['gzip', 'deflate', 'compress'].contains(contentEncoding);
    }
    if (lengthHeader == Headers.contentLengthHeader && compressed) {
      total = -1;
    } else {
      total = int.parse(response.headers.value(lengthHeader) ?? '-1');
    }

    late StreamSubscription subscription;
    Future? asyncWrite;
    var closed = false;
    Future _closeAndDelete() async {
      if (!closed) {
        closed = true;
        await asyncWrite;
        await raf.close();
        if (deleteOnError) await file.delete();
      }
    }

    subscription = stream.listen(
      (data) {
        subscription.pause();
        // Write file asynchronously
        asyncWrite = raf.writeFrom(data).then((_raf) {
          // Notify progress
          received += data.length;

          onReceiveProgress?.call(received, total);

          raf = _raf;
          if (cancelToken == null || !cancelToken.isCancelled) {
            subscription.resume();
          }
        }).catchError((err, StackTrace stackTrace) async {
          try {
            await subscription.cancel();
          } finally {
            completer.completeError(DioMixin.assureDioError(
              err,
              response.requestOptions,
            ));
          }
        });
      },
      onDone: () async {
        try {
          await asyncWrite;
          closed = true;
          await raf.close();
          completer.complete(response);
        } catch (e) {
          completer.completeError(DioMixin.assureDioError(
            e,
            response.requestOptions,
          ));
        }
      },
      onError: (e) async {
        try {
          await _closeAndDelete();
        } finally {
          completer.completeError(DioMixin.assureDioError(
            e,
            response.requestOptions,
          ));
        }
      },
      cancelOnError: true,
    );
    // ignore: unawaited_futures
    cancelToken?.whenCancel.then((_) async {
      await subscription.cancel();
      await _closeAndDelete();
    });

    if (response.requestOptions.receiveTimeout > 0) {
      future = future
          .timeout(Duration(
        milliseconds: response.requestOptions.receiveTimeout,
      ))
          .catchError((Object err) async {
        await subscription.cancel();
        await _closeAndDelete();
        if (err is TimeoutException) {
          throw DioError(
            requestOptions: response.requestOptions,
            error:
                'Receiving data timeout[${response.requestOptions.receiveTimeout}ms]',
            type: DioErrorType.receiveTimeout,
          );
        } else {
          throw err;
        }
      });
    }
    return DioMixin.listenCancelForAsyncTask(cancelToken, future);
  }

  @override
  Future<Response> downloadUri(
    Uri uri,
    savePath, {
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    lengthHeader = Headers.contentLengthHeader,
    data,
    Options? options,
  }) {
    return download(
      uri.toString(),
      savePath,
      onReceiveProgress: onReceiveProgress,
      lengthHeader: lengthHeader,
      deleteOnError: deleteOnError,
      cancelToken: cancelToken,
      data: data,
      options: options,
    );
  }
}

extension DefaultHttpClientAdapterExt on DefaultHttpClientAdapter {
  void addOnHttpClientCreate(void Function(HttpClient client) onCreate) {
    final old = onHttpClientCreate;
    onHttpClientCreate = (client) {
      old?.call(client);
      onCreate(client);
    };
  }
}
