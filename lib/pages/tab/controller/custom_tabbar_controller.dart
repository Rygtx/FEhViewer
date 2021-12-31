import 'package:english_words/english_words.dart';
import 'package:fehviewer/common/service/layout_service.dart';
import 'package:fehviewer/common/service/locale_service.dart';
import 'package:fehviewer/fehviewer.dart';
import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';

import 'custom_sublist_controller.dart';
import 'default_tabview_controller.dart';

final CustomProfile profileChinese = CustomProfile(
    uuid: generateUuidv4(), name: '汉语', searchText: ['l:chinese']);

/// 控制所有自定义列表
class CustomTabbarController extends DefaultTabViewController {
  CustomTabConfig? get customTabConfig => Global.profile.customTabConfig;
  set customTabConfig(CustomTabConfig? val) =>
      Global.profile = Global.profile.copyWith(customTabConfig: val);

  RxList<CustomProfile> profiles = <CustomProfile>[].obs;
  Map<String, CustomProfile> get profileMap {
    Map<String, CustomProfile> _map = {};
    for (final profile in profiles) {
      _map[profile.uuid] = profile;
    }
    return _map;
  }

  final _currProfileUuid = ''.obs;
  String get currProfileUuid => _currProfileUuid.value;
  set currProfileUuid(String val) => _currProfileUuid.value = val;

  final _index = 0.obs;
  int get index => _index.value;
  set index(int val) => _index.value = val;

  final _reorderable = false.obs;
  bool get reorderable => _reorderable.value;
  set reorderable(bool val) => _reorderable.value = val;

  Map<String, CustomSubListController> subControllerMap = {};
  CustomSubListController? get currSubController =>
      subControllerMap[currProfileUuid];

  @override
  int get maxPage => currSubController?.maxPage ?? 1;

  @override
  int get minPage => currSubController?.minPage ?? 1;

  @override
  int get curPage => currSubController?.curPage ?? 1;

  late final PageController pageController;

  final LinkScrollBarController linkScrollBarController =
      LinkScrollBarController();

  @override
  void onInit() {
    super.onInit();

    heroTag = EHRoutes.customlist;

    profiles.value = customTabConfig?.profiles ??
        [
          CustomProfile(name: 'All', uuid: generateUuidv4()),
          if (Get.find<LocaleService>().isLanguageCodeZh) profileChinese,
        ];

    ever<List<CustomProfile>>(profiles, (value) {
      customTabConfig = customTabConfig?.copyWith(profiles: value) ??
          CustomTabConfig(profiles: value);
      Global.saveProfile();
    });

    index = customTabConfig?.lastIndex ?? 0;
    ever<int>(_index, (value) {
      customTabConfig = customTabConfig?.copyWith(lastIndex: value) ??
          CustomTabConfig(lastIndex: value);
      Global.saveProfile();
    });

    if (profiles.isNotEmpty) {
      currProfileUuid = profiles[index].uuid;
    }

    for (final profile in profiles) {
      Get.lazyPut(() => CustomSubListController(), tag: profile.uuid);
    }
  }

  void onPageChanged(int index) {
    currProfileUuid = profiles[index].uuid;
    this.index = index;
  }

  @override
  Future<void> showJumpToPage() async {
    void _jump() {
      logger.d('jumpToPage');
      final String _input = pageJumpTextEditController.text.trim();

      if (_input.isEmpty) {
        showToast(L10n.of(Get.context!).input_empty);
      }

      // 数字检查
      if (!RegExp(r'(^\d+$)').hasMatch(_input)) {
        showToast(L10n.of(Get.context!).input_error);
      }

      final int _toPage = int.parse(_input) - 1;
      if (_toPage >= 0 && _toPage <= maxPage - 1) {
        FocusScope.of(Get.context!).requestFocus(FocusNode());
        currSubController?.loadFromPage(_toPage);
        Get.back();
      } else {
        showToast(L10n.of(Get.context!).page_range_error);
      }
    }

    return await showJumpDialog(jump: _jump, maxPage: maxPage);
  }

  @override
  Future<void> firstLoad() async {}

  Future<void> pressedBar() async {
    await Get.toNamed(
      EHRoutes.customProfiles,
      id: isLayoutLarge ? 1 : null,
    );
  }

  void onReorder(int oldIndex, int newIndex) {
    final _profileUuid = currProfileUuid;
    final _profile = profiles.removeAt(oldIndex);
    profiles.insert(newIndex, _profile);
    index = profiles.indexWhere((element) => element.uuid == _profileUuid);
    Future.delayed(100.milliseconds).then((_) {
      pageController.jumpToPage(index);
    });
  }

  void deleteProfile({required String uuid}) {
    final _profileUuid = currProfileUuid;

    if (_profileUuid == uuid) {
      Future.delayed(100.milliseconds).then((_) {
        pageController.jumpToPage(0);
      }).then(
          (value) => profiles.removeWhere((element) => element.uuid == uuid));
    } else {
      profiles.removeWhere((element) => element.uuid == uuid);
    }
  }
}
