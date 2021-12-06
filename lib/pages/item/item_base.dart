import 'package:fehviewer/common/service/ehconfig_service.dart';
import 'package:fehviewer/models/base/eh_models.dart';
import 'package:fehviewer/utils/utility.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:keframe/frame_separate_widget.dart';
import 'package:waterfall_flow/waterfall_flow.dart';

import 'gallery_item.dart';

const double tagBoxHeight = 18;

class TagListViewBox extends StatelessWidget {
  const TagListViewBox({Key? key, this.simpleTags}) : super(key: key);

  final List<SimpleTag>? simpleTags;

  @override
  Widget build(BuildContext context) {
    final EhConfigService _ehConfigService = Get.find();
    return simpleTags != null && simpleTags!.isNotEmpty
        ? Obx(() => SizedBox(
              height: tagBoxHeight,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children:
                    List<Widget>.from(simpleTags!.map((SimpleTag _simpleTag) {
                  final String? _text = _ehConfigService.isTagTranslat
                      ? _simpleTag.translat
                      : _simpleTag.text;
                  return FrameSeparateWidget(
                    placeHolder: const TagItem(text: ''),
                    index: -1,
                    child: TagItem(
                      text: _text,
                      color: ColorsUtil.getTagColor(_simpleTag.color),
                      backgrondColor:
                          ColorsUtil.getTagColor(_simpleTag.backgrondColor),
                    ),
                  ).paddingOnly(right: 4.0);
                }).toList()), //要显示的子控件集合
              ),
            ))
        : Container();
  }
}

class TagWaterfallFlowViewBox extends StatelessWidget {
  const TagWaterfallFlowViewBox(
      {Key? key,
      this.simpleTags,
      this.crossAxisCount = 2,
      this.splitFrame = false})
      : super(key: key);

  final List<SimpleTag>? simpleTags;
  final int crossAxisCount;
  final bool splitFrame;

  @override
  Widget build(BuildContext context) {
    final EhConfigService _ehConfigService = Get.find();
    if (simpleTags == null || (simpleTags?.isEmpty ?? true)) {
      return const SizedBox.shrink();
    }

    ScrollController controller = ScrollController();

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: crossAxisCount * 22,
        child: WaterfallFlow.builder(
          shrinkWrap: true,
          controller: controller,
          primary: false,
          scrollDirection: Axis.horizontal,
          gridDelegate: SliverWaterfallFlowDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 4.0,
            mainAxisSpacing: 4.0,
          ),
          itemCount: simpleTags?.length ?? 0,
          itemBuilder: (BuildContext context, int index) {
            return Obx(
              () {
                final _simpleTag = simpleTags![index];
                final String? _text = _ehConfigService.isTagTranslat
                    ? _simpleTag.translat
                    : _simpleTag.text;
                Widget _item = TagItem(
                  text: _text,
                  color: ColorsUtil.getTagColor(_simpleTag.color),
                  backgrondColor:
                      ColorsUtil.getTagColor(_simpleTag.backgrondColor),
                );

                if (splitFrame) {
                  _item = FrameSeparateWidget(
                    placeHolder: const TagItem(text: '..'),
                    index: -1,
                    child: _item,
                  );
                }

                return _item;
              },
            );
          },
        ),
      ),
    );
  }
}

class PlaceHolderLine extends StatelessWidget {
  const PlaceHolderLine({Key? key, this.width}) : super(key: key);
  final double? width;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          color: CupertinoDynamicColor.resolve(
              CupertinoColors.systemGrey5, context),
          height: 16,
        ),
      ).paddingSymmetric(vertical: 4, horizontal: 4),
    );
  }
}