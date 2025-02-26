import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:executor/executor.dart';
import 'package:fehviewer/common/global.dart';
import 'package:fehviewer/common/service/controller_tag_service.dart';
import 'package:fehviewer/common/service/ehconfig_service.dart';
import 'package:fehviewer/component/exception/error.dart';
import 'package:fehviewer/component/quene_task/quene_task.dart';
import 'package:fehviewer/models/base/eh_models.dart';
import 'package:fehviewer/network/api.dart';
import 'package:fehviewer/network/request.dart';
import 'package:fehviewer/pages/gallery/controller/gallery_page_controller.dart';
import 'package:fehviewer/pages/tab/controller/download_view_controller.dart';
import 'package:fehviewer/store/db/entity/gallery_image_task.dart';
import 'package:fehviewer/store/db/entity/gallery_task.dart';
import 'package:fehviewer/utils/logger.dart';
import 'package:fehviewer/utils/saf_helper.dart';
import 'package:fehviewer/utils/toast.dart';
import 'package:fehviewer/utils/utility.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_storage/shared_storage.dart' as ss;
import 'package:sprintf/sprintf.dart' as sp;

import 'cache_controller.dart';
import 'download_state.dart';

const int _kDefNameLen = 4;

Future<String> get defDownloadPath async => GetPlatform.isAndroid
    ? await getAndroidDefaultDownloadPath()
    : (GetPlatform.isWindows
        ? path.join((await getDownloadsDirectory())!.path, 'fehviewer')
        : path.join(Global.appDocPath, 'Download'));

Future<String> getAndroidDefaultDownloadPath() async {
  final downloadPath = path.join(Global.extStorePath, 'Download');

  final dir = Directory(downloadPath);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return downloadPath;
}

class TaskStatus {
  const TaskStatus(this.value);
  final int value;

  static TaskStatus from(int value) => TaskStatus(value);

  static const undefined = TaskStatus(0);
  static const enqueued = TaskStatus(1);
  static const running = TaskStatus(2);
  static const complete = TaskStatus(3);
  static const failed = TaskStatus(4);
  static const canceled = TaskStatus(5);
  static const paused = TaskStatus(6);

  @override
  bool operator ==(Object o) {
    if (identical(this, o)) {
      return true;
    }

    return o is TaskStatus && o.value == value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    return 'TaskStatus{value: $value}';
  }
}

class DownloadController extends GetxController {
  final DownloadState dState = DownloadState();

  final EhConfigService ehConfigService = Get.find();
  final CacheController cacheController = Get.find();

  @override
  void onInit() {
    super.onInit();
    // logger.d(
    //     'DownloadController onInit multiDownload:${ehConfigService.multiDownload}');
    dState.executor = Executor(concurrency: ehConfigService.multiDownload);
    asyncInit();
  }

  @override
  void onClose() {
    _cancelDownloadStateChkTimer();
    super.onClose();
  }

  Future<void> asyncInit() async {
    await updateCustomDownloadPath();
    allowMediaScan(ehConfigService.allowMediaScan);
    initGalleryTasks();
  }

  Future<void> updateCustomDownloadPath() async {
    final customDownloadPath = ehConfigService.downloadLocatino;
    logger.d('customDownloadPath:$customDownloadPath');
    if (!GetPlatform.isAndroid ||
        customDownloadPath.isEmpty ||
        customDownloadPath.isContentUri) {
      return;
    }

    final uri = safMakeUriString(path: customDownloadPath, isTreeUri: true);
    ehConfigService.downloadLocatino = uri;
    restoreGalleryTasks();

    logger.d('updateCustomDownloadPath $uri');
  }

  /// 切换允许媒体扫描
  Future<void> allowMediaScan(bool allow) async {
    final downloadPath = await _getGalleryDownloadPath();

    final pathList = <String>[];

    logger.v('allowMediaScan $pathList');

    pathList.add(downloadPath);

    for (final dirPath in pathList) {
      logger.v('media path: $dirPath');
      if (dirPath.isContentUri) {
        // SAF 方式
        if (allow) {
          final file = await ss.findFile(Uri.parse(dirPath), '.nomedia');
          if (file != null) {
            logger.d('delete: ${file.uri}');
            await ss.delete(file.uri);
          }
        } else {
          final file = await ss.findFile(Uri.parse(dirPath), '.nomedia');
          if (file == null) {
            final result = await ss.createFileAsString(
              Uri.parse(dirPath),
              mimeType: '',
              displayName: '.nomedia',
              content: '',
            );
            logger.d('create nomedia result: ${result?.uri}');
          }
        }
      } else {
        // 文件路径方式
        final File noMediaFile = File(path.join(dirPath, '.nomedia'));

        if (allow && await noMediaFile.exists()) {
          logger.d('delete $noMediaFile');
          noMediaFile.delete(recursive: true);
        } else if (!allow && !await noMediaFile.exists()) {
          logger.d('create $noMediaFile');
          noMediaFile.create(recursive: true);
        }
      }
    }
  }

  /// 下载画廊
  Future<void> downloadGallery({
    required String url,
    required int fileCount,
    required String title,
    int? gid,
    String? token,
    String? coverUrl,
    double? rating,
    String? category,
    String? uploader,
    bool downloadOri = false,
  }) async {
    int _gid = 0;
    String _token = '';
    if (gid == null || token == null) {
      final RegExpMatch _match =
          RegExp(r'/g/(\d+)/([0-9a-f]{10})/?').firstMatch(url)!;
      _gid = int.parse(_match.group(1)!);
      _token = _match.group(2)!;
    }

    // 先查询任务是否已存在
    final GalleryTask? _oriTask =
        await isarHelper.findGalleryTaskByGid(gid ?? -1);
    if (_oriTask != null) {
      showToast('Download task existed');
      logger.i('$gid 任务已存在');
      logger.d('${_oriTask.toString()} ');
      return;
    }

    final String _galleryDirName = path.join(
        '$gid - ${path.split(title).join('_').replaceAll(RegExp(r'[/:*"<>|,?]'), '_')}');
    String _dirPath;
    try {
      _dirPath = await _getGalleryDownloadPath(dirName: _galleryDirName);
    } catch (err, stack) {
      logger.e('创建目录失败', err, stack);
      showToast('创建目录失败, $err');
      return;
    }

    logger.d('downloadPath:$_dirPath');

    // 登记主任务表
    final GalleryTask galleryTask = GalleryTask(
      gid: gid ?? _gid,
      token: token ?? _token,
      url: url,
      title: title,
      fileCount: fileCount,
      dirPath: _dirPath,
      status: TaskStatus.enqueued.value,
      addTime: DateTime.now().millisecondsSinceEpoch,
      coverUrl: coverUrl,
      rating: rating,
      category: category,
      uploader: uploader,
      downloadOrigImage: downloadOri,
    );

    logger.d('add NewTask ${galleryTask.toString()}');
    isarHelper.putGalleryTask(galleryTask, replaceOnConflict: false);
    dState.galleryTaskMap[galleryTask.gid] = galleryTask;
    downloadViewAnimateListAdd();
    showToast('${galleryTask.gid} Download task start');

    _addGalleryTask(
      galleryTask,
      fCount: Get.find<GalleryPageController>(tag: pageCtrlTag)
          .gState
          .firstPageImage
          .length,
    );
  }

  void downloadViewAnimateListAdd() {
    if (Get.isRegistered<DownloadViewController>()) {
      Get.find<DownloadViewController>().animateGalleryListAddTask();
    }
  }

  /// 更新任务为已完成
  Future<GalleryTask?> galleryTaskComplete(int gid) async {
    if (dState.galleryTaskMap[gid]?.status == TaskStatus.complete.value) {
      return null;
    }
    logger.d('更新任务为已完成');
    _cancelDownloadStateChkTimer(gid: gid);
    if (!((dState.taskCancelTokens[gid]?.isCancelled) ?? true)) {
      dState.taskCancelTokens[gid]?.cancel();
    }

    final galleryTask = await galleryTaskUpdateStatus(gid, TaskStatus.complete);

    // 写入一个任务信息文件 帮助恢复任务用
    _writeTaskInfoFile(galleryTask);

    return galleryTask;
  }

  // 写入元数据文件
  Future<void> _writeTaskInfoFile(GalleryTask? galleryTask) async {
    if (galleryTask == null) {
      return;
    }

    final imageTaskList =
        (await isarHelper.findImageTaskAllByGid(galleryTask.gid))
            .map((e) => e.copyWith(imageUrl: ''))
            .toList();

    String jsonImageTaskList = jsonEncode(imageTaskList);
    String jsonGalleryTask = jsonEncode(galleryTask.copyWith(dirPath: ''));
    logger.d('_writeTaskInfoFile:\n$jsonGalleryTask\n$jsonImageTaskList');

    final dirPath = galleryTask.realDirPath;
    if (dirPath == null || dirPath.isEmpty) {
      return;
    }

    final info = '$jsonGalleryTask\n$jsonImageTaskList';
    final infoBytes = Uint8List.fromList(utf8.encode(info));

    if (dirPath.isContentUri) {
      // SAF
      final infoDomFile = await ss.findFile(Uri.parse(dirPath), '.info');
      if (infoDomFile?.name != null) {
        await ss.delete(Uri.parse('$dirPath%2F.info'));
      }
      await ss.createFileAsBytes(
        Uri.parse(dirPath),
        mimeType: '',
        displayName: '.info',
        bytes: infoBytes,
      );
    } else {
      final File _infoFile = File(path.join(dirPath, '.info'));
      _infoFile.writeAsString(info);
    }
  }

  /// 暂停任务
  Future<GalleryTask?> galleryTaskPaused(int gid, {bool silent = false}) async {
    _cancelDownloadStateChkTimer(gid: gid);
    logger.v('${dState.cancelTokenMap[gid]?.isCancelled}');
    if (!((dState.cancelTokenMap[gid]?.isCancelled) ?? true)) {
      dState.cancelTokenMap[gid]?.cancel();
    }
    if (silent) {
      return null;
    }

    return galleryTaskUpdateStatus(gid, TaskStatus.paused);
  }

  /// 恢复任务
  Future<void> galleryTaskResume(int gid) async {
    final GalleryTask? galleryTask = await isarHelper.findGalleryTaskByGid(gid);
    if (galleryTask != null) {
      logger.d('恢复任务 $gid');
      _addGalleryTask(galleryTask);
    }
  }

  /// 重下任务
  Future<void> galleryTaskRestart(int gid) async {
    isarHelper.removeImageTask(gid);

    final GalleryTask? galleryTask = await isarHelper.findGalleryTaskByGid(gid);
    if (galleryTask != null) {
      logger.d('重下任务 $gid ${galleryTask.url}');
      cacheController.clearDioCache(
          path: '${Api.getBaseUrl()}${galleryTask.url}');
      final _reTask = galleryTask.copyWith(completCount: 0);
      dState.galleryTaskMap[gid] = _reTask;
      _addGalleryTask(_reTask);
    }
  }

  /// 更新任务进度
  GalleryTask? galleryTaskUpdate(int gid,
      {int? countComplet, String? coverImg}) {
    logger.v('galleryTaskCountUpdate gid:$gid count:$countComplet');
    dState.curComplete[gid] = countComplet ?? 0;

    if (!dState.galleryTaskMap.containsKey(gid)) {
      return null;
    }

    dState.galleryTaskMap[gid] = dState.galleryTaskMap[gid]!.copyWith(
      completCount: countComplet,
      coverImage: coverImg,
    );

    return dState.galleryTaskMap[gid];
  }

  /// 更新任务状态
  Future<GalleryTask?> galleryTaskUpdateStatus(
      int gid, TaskStatus status) async {
    if (dState.galleryTaskMap.containsKey(gid) &&
        dState.galleryTaskMap[gid] != null) {
      dState.galleryTaskMap[gid] =
          dState.galleryTaskMap[gid]!.copyWith(status: status.value);
      logger.v('set $gid status $status');

      final _task = dState.galleryTaskMap[gid];
      if (_task != null) {
        isarHelper.putGalleryTask(_task);
      }
    }

    return dState.galleryTaskMap[gid];
  }

  /// 根据gid获取任务
  Future<List<GalleryImageTask>> getImageTasks(int gid) async {
    final List<GalleryImageTask> tasks =
        await isarHelper.findImageTaskAllByGid(gid);
    return tasks;
  }

  /// 移除任务
  Future<void> removeDownloadGalleryTask({
    required int gid,
    bool shouldDeleteContent = true,
  }) async {
    // 删除文件
    final GalleryTask? _task = dState.galleryTaskMap[gid];
    if (_task == null) {
      return;
    }
    String? dirpath = _task.realDirPath;
    logger.d('dirPath: $dirpath');
    if (dirpath != null && shouldDeleteContent) {
      if (dirpath.isContentUri) {
        // SAF
        await ss.delete(Uri.parse(dirpath));
      } else {
        final dir = Directory(dirpath);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    }

    if (!((dState.cancelTokenMap[_task.gid]?.isCancelled) ?? true)) {
      dState.cancelTokenMap[_task.gid]?.cancel();
    }

    // 删除数据库记录
    isarHelper.removeImageTask(_task.gid);
    isarHelper.removeGalleryTask(_task.gid);

    dState.galleryTaskMap.remove(gid);
  }

  void resetConcurrency() {
    // 取消所有任务
    for (final ct in dState.cancelTokenMap.values) {
      if (!ct.isCancelled) {
        ct.cancel();
      }
    }
    _cancelDownloadStateChkTimer();
    logger.d('reset multiDownload ${ehConfigService.multiDownload}');
    dState.executor = Executor(concurrency: ehConfigService.multiDownload);

    // 重新加入
    initGalleryTasks();
  }

  void _addAllImages(int gid, List<GalleryImage> galleryImages) {
    for (final GalleryImage _image in galleryImages) {
      final int? index = dState.downloadMap[gid]
          ?.indexWhere((GalleryImage e) => e.ser == _image.ser);
      if (index != null && index != -1) {
        dState.downloadMap[gid]?[index] = _image;
      } else {
        dState.downloadMap[gid]?.add(_image);
      }
    }
  }

  // 添加任务队列
  void _addGalleryTask(
    GalleryTask galleryTask, {
    int? fCount,
    List<GalleryImage>? images,
  }) {
    dState.taskCancelTokens[galleryTask.gid] = TaskCancelToken();
    dState.queueTask.add(
      ({name}) {
        logger.d('excue $name');
        _startImageTask(
          galleryTask: galleryTask,
          fCount: fCount,
          images: images,
        );
      },
      taskName: '${galleryTask.gid}',
    );
  }

  // 取消下载任务定时器
  void _cancelDownloadStateChkTimer({int? gid}) {
    if (gid != null) {
      dState.downloadSpeeds.remove(gid);
      dState.noSpeed.remove(gid);
      dState.chkTimers[gid]?.cancel();
    } else {
      for (final Timer? timer in dState.chkTimers.values) {
        timer?.cancel();
      }
      dState.downloadSpeeds.clear();
      dState.noSpeed.clear();
    }
  }

  // 根据ser获取image信息
  Future<GalleryImage?> _checkAndGetImages(
    int gid,
    int itemSer,
    int filecount,
    int firstPageCount,
    String? url, {
    CancelToken? cancelToken,
  }) async {
    GalleryImage? tImage = _getImageObj(gid, itemSer);

    if (tImage == null && url != null) {
      loggerSimple.v('ser:$itemSer 所在页尚未获取， 开始获取');
      final images = await _fetchImages(
        ser: itemSer,
        fileCount: filecount,
        firstPageCount: firstPageCount,
        url: url,
        cancelToken: cancelToken,
      );
      loggerSimple.v('images.length: ${images.length}');
      _addAllImages(gid, images);
      tImage = _getImageObj(gid, itemSer);
    }

    return tImage;
  }

  /// 下载图片流程控制
  Future<void> _downloadImageFlow(
    GalleryImage image,
    GalleryImageTask? imageTask,
    int gid,
    String downloadParentPath,
    int maxSer, {
    bool downloadOrigImage = false, // 下载原图
    bool reDownload = false,
    CancelToken? cancelToken,
    ValueChanged<String>? onDownloadCompleteWithFileName,
  }) async {
    loggerSimple.v('${image.ser} start');
    if (reDownload) {
      logger.v('${image.ser} redownload ');
    }

    late String _targetImageUrl;
    late GalleryImage _uptImage;
    String fileNameWithoutExtension = '';

    // 存在imageTask的 用原url下载
    final bool useOldUrl = imageTask != null &&
        imageTask.imageUrl != null &&
        (imageTask.imageUrl?.isNotEmpty ?? false);

    final String? imageUrlFromTask = imageTask?.imageUrl;

    // 使用原有url下载
    if (useOldUrl && !reDownload && imageUrlFromTask != null) {
      logger.v('使用原有url下载 ${image.ser} DL $imageUrlFromTask');

      _targetImageUrl = imageUrlFromTask;
      _uptImage = image;
      if (imageTask.filePath != null && imageTask.filePath!.isNotEmpty) {
        fileNameWithoutExtension =
            path.basenameWithoutExtension(imageTask.filePath!);
      } else {
        fileNameWithoutExtension = _genFileNameWithoutExtension(image, maxSer);
      }
    } else if (image.href != null) {
      logger.v('获取新的图片url');
      if (reDownload) {
        logger.d(
            '重下载 ${image.ser}, 清除缓存 ${image.href} , sourceId:${imageTask?.sourceId}');
        cacheController.clearDioCache(path: image.href ?? '');
      }

      // 否则先请求解析html
      final GalleryImage imageFetched = await _fetchImageInfo(
        image.href!,
        itemSer: image.ser,
        image: image,
        gid: gid,
        cancelToken: cancelToken,
        changeSource: reDownload,
        sourceId: imageTask?.sourceId,
      );

      if (imageFetched.imageUrl == null) {
        throw EhError(error: 'get imageUrl error');
      }

      // 目标下载地址
      _targetImageUrl = downloadOrigImage
          ? imageFetched.originImageUrl ?? imageFetched.imageUrl!
          : imageFetched.imageUrl!;
      _uptImage = imageFetched;

      logger.v(
          'downloadOrigImage:$downloadOrigImage\nDownload _targetImageUrl:$_targetImageUrl');

      fileNameWithoutExtension =
          _genFileNameWithoutExtension(imageFetched, maxSer);
      logger.v('fileNameWithoutExtension:$fileNameWithoutExtension');

      _addAllImages(gid, [imageFetched]);
      await _putImageTask(gid, imageFetched, status: TaskStatus.running.value);

      if (reDownload) {
        logger.v('${imageFetched.href}\n${imageFetched.imageUrl} ');
      }
    } else {
      throw EhError(error: 'get image url error');
    }

    // 定义下载进度回调
    final ProgressCallback _progressCallback = (int count, int total) {
      dState.downloadCounts['${gid}_${image.ser}'] = count;
    };

    try {
      // 下载图片
      await _downloadToPath(
        _targetImageUrl,
        downloadParentPath,
        fileNameWithoutExtension,
        cancelToken: cancelToken,
        onDownloadCompleteWithFileName: (fileName) {
          onDownloadCompleteWithFileName?.call(fileName);
          _putImageTask(
            gid,
            _uptImage,
            fileName: fileName,
            status: TaskStatus.complete.value,
          );
        },
        progressCallback: _progressCallback,
      );
    } on DioError catch (e) {
      if (e.type == DioErrorType.response && e.response?.statusCode == 403) {
        logger.d('403 $gid.${image.ser}下载链接已经失效 需要更新 ${image.href}');
        final GalleryImage imageFetched = await _fetchImageInfo(
          image.href!,
          itemSer: image.ser,
          image: image,
          gid: gid,
          cancelToken: cancelToken,
          sourceId: _uptImage.sourceId,
          changeSource: true,
        );

        _targetImageUrl = ehConfigService.downloadOrigImage
            ? imageFetched.originImageUrl ?? imageFetched.imageUrl!
            : imageFetched.imageUrl!;

        logger.d('重下载 _targetImageUrl:$_targetImageUrl');

        _addAllImages(gid, [imageFetched]);
        await _putImageTask(gid, imageFetched,
            status: TaskStatus.running.value);

        await _downloadToPath(
          _targetImageUrl,
          downloadParentPath,
          fileNameWithoutExtension,
          cancelToken: cancelToken,
          onDownloadCompleteWithFileName: (fileName) {
            onDownloadCompleteWithFileName?.call(fileName);
            _putImageTask(
              gid,
              imageFetched,
              fileName: fileName,
              status: TaskStatus.complete.value,
            );
          },
          progressCallback: _progressCallback,
        );
      }
    }
  }

  // 下载文件到指定路径
  Future _downloadToPath(
    String url,
    String parentPath,
    String fileNameWithoutExtension, {
    CancelToken? cancelToken,
    ValueChanged<String>? onDownloadCompleteWithFileName,
    ProgressCallback? progressCallback,
  }) async {
    // 根据url读取缓存 存在的话直接将缓存写文件
    try {
      final filePath = await Api.saveImageFromExtendedCache(
        imageUrl: url,
        parentPath: parentPath,
        fileNameWithoutExtension: fileNameWithoutExtension,
      );
      if (filePath != null) {
        logger.d('从缓存读取文件 $filePath');
        onDownloadCompleteWithFileName?.call(path.basename(filePath));
        return;
      }
    } catch (e) {
      logger.e('$e');
    }

    // 缓存不存在的话下载
    late dynamic savePath;
    late String realSaveFullPath;
    if (parentPath.isContentUri) {
      // temp save path ,临时下载路径，完成后再复制到SAF路径
      savePath = path.join(
        (await getTemporaryDirectory()).path,
        'temp_download',
        '${generateUuidv4()}_$fileNameWithoutExtension',
      );
      logger.v('SAF temp savePath:$savePath');
    } else {
      logger.v('非SAF savePath:$parentPath');
      savePath = (Headers headers) {
        logger.v('headers:\n$headers');
        final contentDisposition = headers.value('content-disposition');
        logger.v('contentDisposition $contentDisposition');
        final filename =
            contentDisposition?.split(RegExp(r"filename(=|\*=UTF-8'')")).last ??
                '';
        final fileNameDecode = Uri.decodeFull(filename).replaceAll('/', '_');
        logger.v(
            'fileNameDecode: $fileNameDecode, fileBaseNameNotExt: $fileNameWithoutExtension');
        late String ext;
        if (fileNameDecode.isEmpty) {
          ext = path.extension(url);
        } else {
          ext = path.extension(fileNameDecode);
        }

        realSaveFullPath =
            path.join(parentPath, '$fileNameWithoutExtension$ext');
        return realSaveFullPath;
      };
    }

    // 下载文件
    await ehDownload(
      url: url,
      savePath: savePath,
      cancelToken: cancelToken,
      onDownloadComplete: () async {
        logger.v('onDownloadComplete');

        if (parentPath.isContentUri && savePath is String) {
          // read file
          final File file = File(savePath);
          final bytes = await file.readAsBytes();
          // SAF write file
          final mimeType =
              lookupMimeType(file.path, headerBytes: bytes.take(8).toList());
          logger.v('mimeType $mimeType');
          final ext = mimeType?.split('/').last ?? 'jpg';
          final fileName = '$fileNameWithoutExtension.$ext';
          await ss.createFileAsBytes(
            Uri.parse(parentPath),
            mimeType: mimeType ?? '',
            displayName: fileName,
            bytes: bytes,
          );
          // delete temp file
          await file.delete();

          onDownloadCompleteWithFileName?.call(fileName);
        } else {
          logger.v('normal realSaveFullPath $realSaveFullPath');
          onDownloadCompleteWithFileName?.call(path.basename(realSaveFullPath));
        }
      },
      progressCallback: progressCallback,
    );
  }

  // 获取第一页的预览图数量
  Future<int> _fetchFirstPageCount(
    String url, {
    CancelToken? cancelToken,
  }) async {
    final List<GalleryImage> _moreImageList = await getGalleryImage(
      url,
      page: 0,
      cancelToken: cancelToken,
      refresh: true, // 刷新画廊后加载缩略图不能从缓存读取，否则在改变每页数量后加载画廊会出错
    );
    return _moreImageList.length;
  }

  Future<GalleryImage> _fetchImageInfo(
    String href, {
    required int itemSer,
    required GalleryImage image,
    required int gid,
    bool changeSource = false,
    String? sourceId,
    CancelToken? cancelToken,
  }) async {
    final String? _sourceId = changeSource ? sourceId : '';

    final GalleryImage? _image = await fetchImageInfo(
      href,
      refresh: changeSource,
      sourceId: _sourceId,
      cancelToken: cancelToken,
    );

    logger.v('_image from fetch ${_image?.toJson()}');

    if (_image == null) {
      return image;
    }

    final GalleryImage _imageCopyWith = image.copyWith(
      sourceId: _image.sourceId,
      imageUrl: _image.imageUrl,
      imageWidth: _image.imageWidth,
      imageHeight: _image.imageHeight,
      originImageUrl: _image.originImageUrl,
      filename: _image.filename,
    );

    return _imageCopyWith;
  }

  Future<List<GalleryImage>> _fetchImages({
    required int ser,
    required int fileCount,
    required String url,
    bool isRefresh = false,
    required int firstPageCount,
    CancelToken? cancelToken,
  }) async {
    logger.v('firstPageCount $firstPageCount');
    final int page = (ser - 1) ~/ firstPageCount;
    logger.v('ser:$ser 所在页码为$page');

    final List<GalleryImage> _moreImageList = await getGalleryImage(
      url,
      page: page,
      cancelToken: cancelToken,
      refresh: isRefresh, // 刷新画廊后加载缩略图不能从缓存读取，否则在改变每页数量后加载画廊会出错
    );

    return _moreImageList;
  }

  // 暂停所有任务
  void _galleryTaskPausedAll() {
    for (final _task in dState.galleryTasks) {
      if (_task.status != TaskStatus.complete.value) {
        galleryTaskPaused(_task.gid);
        _updateDownloadView(['DownloadGalleryItem_${_task.gid}']);
      }
    }
  }

  // 生成文件名
  String _genFileNameWithoutExtension(GalleryImage galleryImage, int maxSer) {
    final String _fileNameWithoutExtension = '$maxSer'.length > _kDefNameLen
        ? sp.sprintf('%0${'$maxSer'.length}d', [galleryImage.ser])
        : sp.sprintf('%0${_kDefNameLen}d', [galleryImage.ser]);
    return _fileNameWithoutExtension;
  }

  /// 获取下载路径
  Future<String> _getGalleryDownloadPath({String dirName = ''}) async {
    late final String saveDirPath;
    late final Directory savedDir;

    if (ehConfigService.downloadLocatino.isNotEmpty) {
      // 自定义路径
      logger.v('自定义下载路径');
      saveDirPath = path.join(ehConfigService.downloadLocatino, dirName);
      savedDir = Directory(saveDirPath);
    } else if (!GetPlatform.isIOS) {
      saveDirPath = path.join(await defDownloadPath, dirName);
      savedDir = Directory(saveDirPath);
      logger.d('无自定义下载路径, 使用默认路径 $saveDirPath');
    } else {
      logger.d('iOS');
      // iOS 记录的为相对路径 不记录doc的实际路径
      saveDirPath = path.join('Download', dirName);
      savedDir = Directory(path.join(Global.appDocPath, saveDirPath));
    }

    if (dirName.isEmpty) {
      return saveDirPath;
    }

    if (saveDirPath.isContentUri) {
      final galleryDirUrl = '${ehConfigService.downloadLocatino}%2F$dirName';
      final uri = Uri.parse(galleryDirUrl);
      final exists = await ss.exists(uri) ?? false;

      if (exists) {
        return galleryDirUrl;
      }

      final parentUri = Uri.parse(ehConfigService.downloadLocatino);
      try {
        final result = await ss.createDirectory(parentUri, dirName);
        if (result != null) {
          return result.uri.toString();
        } else {
          showToast('createDirectory failed');
          throw Exception('createDirectory failed');
        }
      } catch (e, s) {
        logger.e('create Directory failed', e, s);
        showToast('create Directory failed, $galleryDirUrl');
        rethrow;
      }
    } else {
      // 判断下载路径是否存在
      final bool hasExisted = savedDir.existsSync();
      // 不存在就新建路径
      if (!hasExisted) {
        savedDir.createSync(recursive: true);
      }
      return saveDirPath;
    }
  }

  GalleryImage? _getImageObj(int gid, int ser) {
    return dState.downloadMap[gid]
        ?.firstWhereOrNull((element) => element.ser == ser);
  }

  int _initDownloadMapByGid(int gid, {List<GalleryImage>? images}) {
    dState.downloadMap[gid] = images ?? [];
    return dState.downloadMap[gid]?.length ?? 0;
  }

  // 根据gid初始化下载任务计时器
  void _initDownloadStateChkTimer(int gid) {
    // 每隔[kPeriodSeconds]时间， 执行一次
    dState.chkTimers[gid] = Timer.periodic(
      const Duration(seconds: kPeriodSeconds),
      (Timer timer) {
        final _task = dState.galleryTaskMap[gid];
        if (_task != null && _task.fileCount == _task.completCount) {
          galleryTaskComplete(gid);
          return;
        }

        if (dState.galleryTaskMap[gid]?.status == TaskStatus.running.value) {
          _totalDownloadSpeed(
            gid,
            maxCount: kMaxCount,
            checkMaxCount: kCheckMaxCount,
            periodSeconds: kPeriodSeconds,
          );
        }
      },
    );
  }

  // 初始化任务列表
  Future<void> initGalleryTasks() async {
    await downloadTaskMigration();
    final _tasks = await isarHelper.findAllGalleryTasks();

    // 添加到map中
    for (final _task in _tasks) {
      dState.galleryTaskMap[_task.gid] = _task;
    }

    // 继续未完成的任务
    for (final task in _tasks) {
      if (task.status == TaskStatus.running.value) {
        logger.d('继续未完成的任务');
        _addGalleryTask(task);
      }
    }
  }

  Future<void> downloadTaskMigration() async {
    final isMigrationed = hiveHelper.getDownloadTaskMigration();
    logger.v('downloadTaskMigration $isMigrationed');
    if (!isMigrationed) {
      logger.d('start download task Migration');
      await restoreGalleryTasks();
      hiveHelper.setDownloadTaskMigration(true);
    }
  }

  // 从当前下载目录恢复下载列表数据
  Future<void> restoreGalleryTasks({bool init = false}) async {
    final String _currentDownloadPath = await _getGalleryDownloadPath();
    logger.d('_currentDownloadPath: $_currentDownloadPath');
    final directory = Directory(GetPlatform.isIOS
        ? path.join(Global.appDocPath, _currentDownloadPath)
        : _currentDownloadPath);
    await for (final fs in directory.list()) {
      final infoFile = File(path.join(fs.path, '.info'));
      if (fs is Directory && infoFile.existsSync()) {
        logger.d('infoFile: ${infoFile.path}');
        final info = infoFile.readAsStringSync();
        final infoList = info
            .split('\n')
            .where((element) => element.trim().isNotEmpty)
            .toList();
        if (infoList.length < 2) {
          continue;
        }

        final taskJsonString = infoList[0];
        final imageJsonString = infoList[1];

        try {
          final galleryTask = GalleryTask.fromJson(
                  jsonDecode(taskJsonString) as Map<String, dynamic>)
              .copyWith(dirPath: fs.path);
          final galleryImageTaskList = <GalleryImageTask>[];

          final imageList = jsonDecode(imageJsonString) as List<dynamic>;
          for (final img in imageList) {
            final galleryImageTask =
                GalleryImageTask.fromJson(img as Map<String, dynamic>);
            galleryImageTaskList.add(galleryImageTask);
          }

          await isarHelper.putAllImageTask(galleryImageTaskList);
          await isarHelper.putGalleryTask(galleryTask);
        } catch (e, stack) {
          logger.e('$e\n$stack');
          continue;
        }
      }
    }

    if (init) {
      onInit();
      resetDownloadViewAnimationKey();
    }
  }

  Future<void> rebuildGalleryTasks() async {
    final _tasks = await isarHelper.findAllGalleryTasks();

    _tasks.forEach((task) => _writeTaskInfoFile(task));
  }

  /// 开始下载
  Future<void> _startImageTask({
    required GalleryTask galleryTask,
    int? fCount,
    List<GalleryImage>? images,
  }) async {
    // logger.d('_startImageTask ${galleryTask.gid} ${galleryTask.title}');

    // logger.d('${galleryTask.toString()} ');

    // 如果完成数等于文件数 那么更新状态为完成
    if (galleryTask.completCount == galleryTask.fileCount) {
      logger.d('complete ${galleryTask.gid}  ${galleryTask.title}');

      await galleryTaskComplete(galleryTask.gid);
      _updateDownloadView(['DownloadGalleryItem_${galleryTask.gid}']);
    }

    // 初始化下载计时控制
    _initDownloadStateChkTimer(galleryTask.gid);

    final List<GalleryImageTask> imageTasksOri =
        await isarHelper.findImageTaskAllByGid(galleryTask.gid);

    final completeCount = imageTasksOri
        .where((element) => element.status == TaskStatus.complete.value)
        .length;

    await isarHelper
        .putGalleryTask(galleryTask.copyWith(completCount: completeCount));

    if (completeCount == galleryTask.fileCount) {
      logger.d('complete ${galleryTask.gid}  ${galleryTask.title}');
      await galleryTaskComplete(galleryTask.gid);
      _updateDownloadView(['DownloadGalleryItem_${galleryTask.gid}']);
      return;
    }

    logger.v(
        '${imageTasksOri.where((element) => element.status != TaskStatus.complete.value).map((e) => e.toString()).join('\n')} ');

    // 初始化下载Map
    final initCount = _initDownloadMapByGid(galleryTask.gid, images: images);
    logger.v('initCount: $initCount');

    final putCount = await _updateImageTasksByGid(galleryTask.gid);
    logger.v('putCount: $putCount');

    galleryTaskUpdateStatus(galleryTask.gid, TaskStatus.running);

    final CancelToken _cancelToken = CancelToken();
    dState.cancelTokenMap[galleryTask.gid] = _cancelToken;

    logger.v('filecount:${galleryTask.fileCount} url:${galleryTask.url}');

    if (galleryTask.realDirPath == null) {
      return;
    }

    final String downloadParentPath = galleryTask.realDirPath!;

    final List<int> _completeSerList = imageTasksOri
        .where((element) => element.status == TaskStatus.complete.value)
        .map((e) => e.ser)
        .toList();

    final int _maxCompleteSer =
        _completeSerList.isNotEmpty ? _completeSerList.reduce(max) : 0;

    logger.v('_maxCompleteSer:$_maxCompleteSer');

    // 循环进行下载图片
    for (int index = 0; index < galleryTask.fileCount; index++) {
      final itemSer = index + 1;

      final _oriImageTask =
          imageTasksOri.firstWhereOrNull((element) => element.ser == itemSer);
      if (_oriImageTask?.status == TaskStatus.complete.value) {
        continue;
      }

      logger.v('ser:$itemSer/${imageTasksOri.length}');

      if (fCount == null || fCount < 1) {
        fCount = await _fetchFirstPageCount(galleryTask.url!,
            cancelToken: _cancelToken);
      }

      dState.executor.scheduleTask(() async {
        final GalleryImage? tImage = await _checkAndGetImages(galleryTask.gid,
            itemSer, galleryTask.fileCount, fCount!, galleryTask.url);

        if (tImage != null) {
          final int maxSer = galleryTask.fileCount + 1;

          logger.v(
              'itemSer, _maxCompleteSer + 1: $itemSer, ${_maxCompleteSer + 1}');

          try {
            await _downloadImageFlow(
              tImage,
              _oriImageTask,
              galleryTask.gid,
              downloadParentPath,
              maxSer,
              downloadOrigImage: galleryTask.downloadOrigImage ?? false,
              cancelToken: _cancelToken,
              reDownload: itemSer > 1 && itemSer < _maxCompleteSer + 2,
              onDownloadCompleteWithFileName: (String fileName) =>
                  _onDownloadComplete(fileName, galleryTask.gid, itemSer),
            );
          } on DioError catch (e) {
            // 忽略 [DioErrorType.cancel]
            if (!CancelToken.isCancel(e)) {
              rethrow;
            }

            // loggerSimple.d('$itemSer Cancel');
          } on EhError catch (e) {
            if (e.type == EhErrorType.image509) {
              show509Toast();
              _galleryTaskPausedAll();
              dState.executor.close();
              resetConcurrency();
            }
            rethrow;
          } catch (e) {
            rethrow;
          }
        }
      });
    }
  }

  // 下载完成回调
  Future _onDownloadComplete(String fileName, int gid, int itemSer) async {
    logger.v('********** $itemSer complete $fileName');

    // final task = await isarHelper.findImageTaskAllByGidSer(gid, itemSer);
    // logger.d('task is null: ${task == null}');

    // 下载完成 更新数据库明细
    // logger.v('下载完成 更新数据库明细');
    await isarHelper.updateImageTaskStatus(
      gid,
      itemSer,
      TaskStatus.complete.value,
    );

    // 更新ui
    final List<GalleryImageTask> listComplete = await isarHelper
        .finaAllImageTaskByGidAndStatus(gid, TaskStatus.complete.value);

    logger.v(
        'listComplete:  ${listComplete.length}: ${listComplete.map((e) => e.ser).join(',')}');

    final GalleryTask? _task = galleryTaskUpdate(
      gid,
      countComplet: listComplete.length,
      coverImg: itemSer == 1 ? fileName : null,
    );
    if (_task?.fileCount == listComplete.length) {
      galleryTaskComplete(gid);
    }

    if (_task != null) {
      await isarHelper.putGalleryTask(_task);
    }
    _updateDownloadView(['DownloadGalleryItem_$gid']);
  }

  /// 自动重试检查
  /// [kRetryThresholdTime] 速度没有变化, 重试该任务
  void _totalDownloadSpeed(
    int gid, {
    int maxCount = 3,
    int checkMaxCount = 10,
    int periodSeconds = 1,
  }) {
    final int totCurCount = dState.downloadCounts.entries
        .where((element) => element.key.startsWith('${gid}_'))
        .map((e) => e.value)
        .sum;

    dState.lastCounts[gid]?.add(totCurCount);

    dState.lastCounts.putIfAbsent(gid, () => [0]);
    final List<int> lastCounts = dState.lastCounts[gid] ?? [0];
    final List<int> lastCountsTopCheck = lastCounts.reversed
        .toList()
        .sublist(0, min(lastCounts.length, checkMaxCount));

    logger
        .v('${lastCountsTopCheck.join(',')}\n${lastCounts.reversed.join(',')}');

    final speedCheck =
        (max(totCurCount - lastCountsTopCheck.reversed.first, 0) /
                (lastCountsTopCheck.length * periodSeconds))
            .round();

    logger.v(
        'speedCheck:${renderSize(speedCheck)}\n${lastCountsTopCheck.join(',')}');

    // 用速度检查是否需要重试
    if (speedCheck == 0) {
      if (dState.noSpeed[gid] != null) {
        dState.noSpeed[gid] = dState.noSpeed[gid]! + 1;
      } else {
        dState.noSpeed[gid] = 1;
      }

      if ((dState.noSpeed[gid] ?? 0) > kRetryThresholdTime) {
        logger.d('$gid retry = ' + DateTime.now().toString());
        Future<void>(() => galleryTaskPaused(gid, silent: true))
            .then((_) => Future.delayed(const Duration(microseconds: 1000)))
            .then((_) => galleryTaskResume(gid));
      }
    }

    // 显示的速度
    final List<int> lastCountsTopShow = lastCounts.reversed
        .toList()
        .sublist(0, min(lastCounts.length, maxCount));
    final speedShow = (max(totCurCount - lastCountsTopShow.reversed.first, 0) /
            (lastCountsTopShow.length * periodSeconds))
        .round();
    logger.v(
        'speedShow:${renderSize(speedShow)}\n${lastCountsTopShow.join(',')}');
    dState.downloadSpeeds[gid] = renderSize(speedShow);
    _updateDownloadView(['DownloadGalleryItem_$gid']);
  }

  void _updateDownloadView([List<Object>? ids]) {
    if (Get.isRegistered<DownloadViewController>()) {
      Get.find<DownloadViewController>().update(ids);
    }
  }

  void resetDownloadViewAnimationKey() {
    if (Get.isRegistered<DownloadViewController>()) {
      Get.find<DownloadViewController>().animatedGalleryListKey =
          GlobalKey<AnimatedListState>();
    }
  }

  Future _putImageTask(
    int gid,
    GalleryImage images, {
    String? fileName,
    int? status,
  }) async {
    final GalleryImageTask _imageTask = GalleryImageTask(
      gid: gid,
      token: '',
      href: images.href,
      ser: images.ser,
      imageUrl: images.imageUrl,
      sourceId: images.sourceId,
      filePath: fileName,
      status: status,
    );

    await isarHelper.putImageTask(_imageTask);
  }

  Future<int> _updateImageTasksByGid(int gid,
      {List<GalleryImage>? images}) async {
    // 插入所有任务明细
    final List<GalleryImageTask>? _galleryImageTasks =
        (images ?? dState.downloadMap[gid])
            ?.map((GalleryImage e) => GalleryImageTask(
                  gid: gid,
                  token: '',
                  href: e.href,
                  ser: e.ser,
                  imageUrl: e.imageUrl,
                  sourceId: e.sourceId,
                ))
            .toList();

    if (_galleryImageTasks != null) {
      logger.v('插入所有任务明细 $gid ${_galleryImageTasks.length}');
      await isarHelper.putAllImageTask(_galleryImageTasks);
    }

    return _galleryImageTasks?.length ?? 0;
  }
}
