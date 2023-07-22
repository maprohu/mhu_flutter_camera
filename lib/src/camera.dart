import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:collection/collection.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:logger/logger.dart';
import 'package:mhu_dart_commons/commons.dart';
import 'package:mhu_dart_model/mhu_dart_model.dart';
import 'package:mhu_flutter_commons/mhu_flutter_commons.dart';
import 'package:image/image.dart' as img;

import '../proto.dart';

part 'camera.freezed.dart';

final _logger = Logger();

extension CameraTimingMsgX on CameraTimingMsg {
  int get shutterDelayMilliseconds => switch (shutterTiming) {
        CameraTimingMsg_ShutterTiming$immediate() => 0,
        CameraTimingMsg_ShutterTiming$delayHalfSecond() => 500,
        CameraTimingMsg_ShutterTiming$delayOneSecond() => 1000,
        CameraTimingMsg_ShutterTiming$customDelay(:final value) =>
          value.shutterDelayMilliseconds,
        CameraTimingMsg_ShutterTiming$notSet$() => 500,
      };
}

@freezed
class FcmRoot with _$FcmRoot {
  FcmRoot._();

  factory FcmRoot({
    required Fr<IList<CameraDescription>> availableCameras,
    required Future<IList<CameraDescription>> Function() refresh,
    required TaskQueue permissionQueue,
  }) = _FcmRoot;

  final lock = Locker(null);

  Future<Fr<CameraControllerOpt>?> acquire({
    required FcmCameraSettings settings,
    required DspReg disposers,
  }) async {
    final lockDisposers = DspImpl();
    await lock.acquire(lockDisposers);
    if (disposers.isDisposed) {
      await lockDisposers.dispose();
      return null;
    }

    final ccfwDisposers = DspImpl();
    final ccfw = fw<CameraControllerOpt>(
      CameraControllerBusy(),
      disposers: ccfwDisposers,
    );
    var currentDisposers = DspImpl();

    Future<void> recreate(FcmCameraControllerParams params) async {
      ccfw.value = CameraControllerBusy();
      await currentDisposers.dispose();
      currentDisposers = DspImpl();

      final FcmCameraControllerParams(
        :resolutionPreset,
        :cameraDescription,
        :sleeping,
      ) = params;

      if (sleeping) {
        return;
      }

      if (cameraDescription == null) {
        ccfw.value = CameraControllerMissing();
        return;
      }

      final cameraController = CameraController(
        cameraDescription,
        resolutionPreset,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21 // for Android
            : ImageFormatGroup.bgra8888, // for iOS
      );

      await permissionQueue.submit(
        cameraController.initialize,
      );

      await cameraController
          .lockCaptureOrientation(DeviceOrientation.portraitUp);

      final queueDisposers = DspImpl();
      final queue = TaskQueue(disposers: queueDisposers);

      Future<void> Function(T value) submit<T>(
        Future<void> Function(T value) action,
      ) =>
          (value) => queue.submit(() {
                return action(value);
              });

      final changeDisposers = DspImpl();

      void listenStream<T>(
        Stream<T> fr,
        Future<void> Function(T value) action,
      ) {
        fr.asyncListen(submit(action)).cancelBy(changeDisposers);
      }

      void listen<T>(
        Fr<T>? fr,
        Future<void> Function(T value) action,
      ) {
        if (fr == null) {
          return;
        }
        listenStream(fr.changes(), action);
      }

      // listenStream(
      //   settings.description.changes().tail.whereNotNull(),
      //   cameraController.setDescription,
      // );

      listen(
        settings.exposureMode,
        cameraController.setExposureMode,
      );
      listen(
        settings.exposureOffset,
        cameraController.setExposureOffset,
      );
      listen(
        settings.exposurePoint,
        cameraController.setExposurePoint,
      );
      listen(
        settings.focusMode,
        cameraController.setFocusMode,
      );
      listen(
        settings.focusPoint,
        cameraController.setFocusPoint,
      );
      listen(
        settings.flashMode,
        cameraController.setFlashMode,
      );
      listen(
        settings.zoomLevel,
        cameraController.setZoomLevel,
      );

      final bitsDisposers = DspImpl();
      ccfw.value = CameraControllerHere(
        CameraControllerBits(
          controller: cameraController,
          disposers: bitsDisposers,
        ),
      );

      currentDisposers.add(() async {
        await changeDisposers.dispose();
        await queueDisposers.dispose();
        await bitsDisposers.dispose();
        await cameraController.dispose();
      });
    }

    final latestDisposers = DspImpl();
    final latestExecutor = LatestExecutor(
      disposers: latestDisposers,
      process: recreate,
    );

    final frDisposers = DspImpl();
    frDisposers
        .fr(() {
          final sleeping = switch (appLifecycleStateSingleton()) {
            AppLifecycleState.resumed || AppLifecycleState.inactive => false,
            _ => true,
          };

          return FcmCameraControllerParams(
            sleeping: sleeping,
            resolutionPreset:
                settings.resolutionPreset?.watch() ?? ResolutionPreset.max,
            cameraDescription: settings.description(),
            // unavailable: settings.description() == null,
          );
        })
        .changes()
        .forEach(latestExecutor.submit)
        .awaitBy(frDisposers);

    disposers.add(() async {
      await frDisposers.dispose();
      await latestDisposers.dispose();
      await ccfwDisposers.dispose();
      await currentDisposers.dispose();
      await lockDisposers.dispose();
    });

    return ccfw;
  }
}

Future<FcmRoot> fcmRoot({
  required TaskQueue permissionQueue,
}) async {
  Future<IList<CameraDescription>> fetch() async =>
      (await availableCameras()).toIList();
  final camerasFw = fw(await fetch());
  return FcmRoot(
    permissionQueue: permissionQueue,
    availableCameras: camerasFw,
    refresh: () async {
      return (await fetch()).also(camerasFw.set);
    },
  );
}

@freezed
class FcmCameraSettings with _$FcmCameraSettings {
  const factory FcmCameraSettings({
    required Fr<CameraDescription?> description,
    Fr<ResolutionPreset>? resolutionPreset,
    Fr<ExposureMode>? exposureMode,
    Fr<double>? exposureOffset,
    Fr<Offset?>? exposurePoint,
    Fr<FocusMode>? focusMode,
    Fr<Offset?>? focusPoint,
    Fr<FlashMode>? flashMode,
    Fr<double>? zoomLevel,
  }) = _FcmCameraSettings;
}

CameraDescription? fcmSelectCamera({
  required Iterable<CameraDescription> cameras,
  String? name,
  CameraLensDirection? lensDirection,
}) {
  if (name != null) {
    final found = cameras.firstWhereOrNull(
      (c) => c.name == name,
    );
    if (found != null) return found;
  }

  if (lensDirection != null) {
    final found = cameras.firstWhereOrNull(
      (c) => c.lensDirection == lensDirection,
    );
    if (found != null) return found;
  }

  return cameras.firstOrNull;
}

@freezed
class FcmCameraControllerParams with _$FcmCameraControllerParams {
  const factory FcmCameraControllerParams({
    required bool sleeping,
    required ResolutionPreset resolutionPreset,
    required CameraDescription? cameraDescription,
  }) = _FcmCameraControllerParams;
}

@freezed
sealed class CameraControllerOpt with _$CameraControllerOpt {
  const factory CameraControllerOpt.missing() = CameraControllerMissing;

  const factory CameraControllerOpt.busy() = CameraControllerBusy;

  const factory CameraControllerOpt.here(CameraControllerBits controllerBits) =
      CameraControllerHere;
}

typedef CameraImageListener = void Function(CameraImage image);

@freezed
class CameraControllerBits with _$CameraControllerBits {
  CameraControllerBits._();

  factory CameraControllerBits({
    required CameraController controller,
    required DspReg disposers,
  }) = _CameraControllerBits;

  Future<void> startImageStream(CameraImageListener listener) async {
    await controller.startImageStream(listener);

    disposers.add(controller.stopImageStream);
  }

  Future<XFile>? takePicture() {
    if (disposers.isDisposed) {
      return null;
    }
    return controller.takePicture();
  }

// final _listeners = Var(IList<CameraImageListener>());
//
// late final _streamDisposers = Var(DspImpl()).also((dspVar) {
//   disposers.add(() => dspVar.value.dispose());
// });
//
// late final _queue = TaskQueue(disposers: disposers);
//
// Future<void> _startStreaming() async {
//   await controller.startImageStream(
//     (image) {
//       for (final lst in _listeners.value) {
//         lst(image);
//       }
//     },
//   );
//
//   final dsp = DspImpl();
//   dsp.add(controller.stopImageStream);
//   _streamDisposers.value = dsp;
// }
//
//
// Future<void> listenImageStream({
//   required CameraImageListener listener,
//   required Disposers disposers,
// }) {
//   return _queue.submitOrRun(() async {
//     final first = _listeners.value.isEmpty;
//
//     _listeners.value = _listeners.value.add(listener);
//
//     if (first) {
//       _startStreaming();
//     }
//
//     disposers.add(() {
//       return _queue.submit(() async {
//         _listeners.value = _listeners.value.remove(listener);
//         if (_listeners.value.isEmpty) {
//           await _streamDisposers.value.dispose();
//           _streamDisposers.value = DspImpl();
//         }
//       });
//     });
//   });
// }
}

typedef CameraNames = CachedFu<String, String, Map<String, String>, Fw<String>>;

@freezed
class CameraBits with _$CameraBits {
  CameraBits._();

  factory CameraBits({
    required FcmRoot cameras,
    // required CameraConfigMsg$Fw config,
    required CameraNames cameraNames,
    required Fw<String> selectedCameraName,
    required Fw<ResolutionPresetEnm> resolution,
    // required TaskQueue permissionQueue,
    required FlcUi ui,
  }) = _CameraBits;

  // late final selectedCameraName = config.selectedCamera$;

  // late final cameraNames = config.cameraNames$;

  final _disposers = DspImpl();

  late final Fr<CameraDescription?> selectedCameraDescription = _disposers.fr(
    () => fcmSelectCamera(
      cameras: cameras.availableCameras(),
      name: selectedCameraName(),
      lensDirection: CameraLensDirection.back,
    ),
  );

  late final selectedCameraLabel = _disposers.fr(() {
    final desc = selectedCameraDescription();
    if (desc == null) {
      return null;
    }
    return watchCameraLabelOrFacing(desc);
  });

  String? watchCameraLabel(String cameraName) {
    final labels = cameraNames();

    return labels[cameraName];
  }

  String watchCameraLabelOrFacing(CameraDescription cameraDescription) {
    return watchCameraLabel(cameraDescription.name) ??
        cameraDescription.lensDirection.label;
  }

  FcmCameraSettings cameraSettings() => FcmCameraSettings(
        description: selectedCameraDescription,
        resolutionPreset: resolution.map(flcResolutionPresetBidi.forward),
      );

  Future<Fr<CameraControllerOpt>?> acquire(DspReg disposers) => cameras.acquire(
        settings: cameraSettings(),
        disposers: disposers,
      );

// late final _pool =
//     RefCountPool<void, Fr<CameraControllerOpt>>((_, disposers) async {
//   final ccfwDisposers = DspImpl();
//   final ccfw = fw<CameraControllerOpt>(
//     CameraControllerBusy(),
//     disposers: ccfwDisposers,
//   );
//   var currentDisposers = DspImpl();
//
//   Future<void> recreate(FcmCameraControllerParams params) async {
//     ccfw.value = CameraControllerBusy();
//     await currentDisposers.dispose();
//     currentDisposers = DspImpl();
//
//     final FcmCameraControllerParams(
//       :cameraDescription,
//     ) = params;
//
//     if (cameraDescription == null) {
//       ccfw.value = CameraControllerMissing();
//       return;
//     }
//
//     final cameraController = CameraController(
//       cameraDescription,
//       ResolutionPreset.max,
//       enableAudio: false,
//       imageFormatGroup: Platform.isAndroid
//           ? ImageFormatGroup.nv21 // for Android
//           : ImageFormatGroup.bgra8888, // for iOS
//     );
//
//     await permissionQueue.submit(
//       cameraController.initialize,
//     );
//
//     final bitsDisposers = DspImpl();
//     ccfw.value = CameraControllerHere(
//       CameraControllerBits(
//         controller: cameraController,
//         disposers: bitsDisposers,
//       ),
//     );
//
//     currentDisposers.add(() async {
//       await bitsDisposers.dispose();
//       await cameraController.dispose();
//     });
//   }
//
//   final latestDisposers = DspImpl();
//   final latestExecutor = LatestExecutor(
//     disposers: latestDisposers,
//     process: recreate,
//   );
//
//   final frDisposers = DspImpl();
//   frDisposers.fr(() {
//     final params = FcmCameraControllerParams(
//       cameraDescription: selectedCameraDescription(),
//     );
//
//     latestExecutor.submit(params);
//   });
//
//   disposers.add(() async {
//     await frDisposers.dispose();
//     await latestDisposers.dispose();
//     await ccfwDisposers.dispose();
//     await currentDisposers.dispose();
//   });
//
//   return ccfw;
// });

// Future<Fr<CameraControllerOpt>> acquire(Disposers disposers) =>
//     _pool.acquire(null, disposers);
}

extension CameraValueX on CameraValue {
  double get correctedAspectRatio =>
      deviceOrientation.isLandscape ? aspectRatio : 1 / aspectRatio;
}

extension CameraControllerX on CameraController {
  Future<CameraImage?> getCurrentImage(DspReg disposers) async {
    var running = true;

    final completer = Completer<CameraImage?>();

    Future<void> stop(CameraImage? image) async {
      if (running) {
        running = false;
        await stopImageStream();
        if (!completer.isCompleted) {
          completer.complete(image);
        }
      }
    }

    startImageStream((image) async {
      await stop(image);
    });

    disposers.add(() => stop(null));

    return await completer.future;
  }

  Widget previewWidget() => cameraPreviewWidget(this);

  Future<void> processImages({
    required Future<void> Function(CameraImage cameraImage) processor,
    required DspReg disposers,
  }) async {
    var working = false;
    startImageStream((image) async {
      if (working) return;
      working = true;
      await processor(image);
      working = false;
    });
    disposers.add(stopImageStream);
  }
}

Widget cameraPreviewWidget(
  CameraController cameraController, {
  Widget Function(Widget child) wrapper = identity,
}) {
  final preview = cameraController.buildPreview();
  return flcDsp((disposers) {
    final controllerFr = cameraController.fr(disposers);
    final aspectRatioFr = disposers.fr(() => controllerFr().aspectRatio);

    return flcFrr(() {
      return Center(
        child: AspectRatio(
          aspectRatio: 1 / aspectRatioFr(),
          child: wrapper(preview),
        ),
      );
    });
  });
  // return ValueListenableBuilder(
  //   valueListenable: cameraController,
  //   builder: (context, cc, child) {
  //     return Center(
  //       child: AspectRatio(
  //         aspectRatio: 1 / cc.aspectRatio,
  //         child: cameraController.buildPreview(),
  //       ),
  //     );
  //   },
  // );
}

const double shutterButtonPadding = 24.0;
const double shutterButtonSize = 64.0;
const double shutterIconSize = 48.0;

const flcOverlayButtonSpace = SizedBox(
  height: shutterButtonPadding * 2 + shutterButtonSize,
  width: shutterButtonPadding * 2 + shutterButtonSize,
);

extension FlcWidgetX on Widget {
  Widget get withBottomOverlayButtonSpace => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          this,
          flcOverlayButtonSpace,
        ],
      );
}

Widget flcCameraOverlayButton({
  IconData icon = Icons.camera,
  VoidCallback? onPressed,
  Object? heroTag,
}) =>
    Padding(
      padding: const EdgeInsets.all(shutterButtonPadding),
      child: SizedBox(
        width: shutterButtonSize,
        height: shutterButtonSize,
        child: FloatingActionButton(
          backgroundColor: Colors.white.withOpacity(0.5),
          onPressed: onPressed,
          heroTag: heroTag,
          child: Icon(
            icon,
            size: shutterIconSize,
          ),
        ),
      ),
    );

Widget cameraShutterWidget({
  required void Function() takePicture,
  required Fr<CameraTimingMsg> shutterTiming,
  required TickerProvider tickerProvider,
  required DspReg disposers,
}) {
  final _timer = fw<double?>(null);

  final _shooting = fr(() => _timer() != null);

  var latestDisposers = DspImpl();
  disposers.add(() => latestDisposers.dispose());

  void _shutterClicked(TickerProvider tickers) {
    final shutterDelayMilliseconds =
        shutterTiming.read().shutterDelayMilliseconds;

    if (shutterDelayMilliseconds <= 0) {
      _timer.value = 0;
      takePicture();
    } else {
      _timer.value = 1;

      late final Ticker ticker;

      latestDisposers = DspImpl()..add(() => ticker.dispose());

      ticker = tickers.createTicker(
        (elapsed) {
          final time = 1 - elapsed.inMilliseconds / shutterDelayMilliseconds;
          _timer.value = time;
          if (time <= 0) {
            latestDisposers.dispose();
            try {
              takePicture();
            } catch (e, st) {
              _logger.e(e, st);
              rethrow;
            }
          }
        },
      )..start();
    }
  }

  late final shootingWidget = Container(
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.5),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.all(8.0),
      child: Text(
        'Hold still!',
        style: TextStyle(
          color: Colors.white,
        ),
      ),
    ),
  );

  return Stack(
    fit: StackFit.expand,
    children: [
      flcFrr(() {
        final shooting = _shooting();

        if (shooting) return nullWidget;

        final button = flcCameraOverlayButton(
          onPressed: () {
            _shutterClicked(tickerProvider);
          },
        );

        return SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: button,
          ),
        );
      }),
      flcFrr(() {
        final time = _timer();

        if (time == null) {
          return nullWidget;
        }

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 150.0,
                width: 150.0,
                child: CircularProgressIndicator(
                  value: time,
                  strokeWidth: 20,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(32.0),
                child: shootingWidget,
              ),
            ],
          ),
        );
      }),
    ],
  );
}

List<Widget> cameraBottomMenu({
  required CameraBits cameraBits,
  required Popper popper,
}) {
  final ui = cameraBits.ui;

  void _renameCamera(
    String label,
    CameraDescription camera,
  ) {
    stringEditorDialog(
      ui: ui,
      title: const Text('Rename Camera'),
      initialValue: label,
      onSubmit: (value) {
        cameraBits.cameraNames.update(
          (m) => m[camera.name] = value,
        );
      },
    );
  }

  void _selectCamera() {
    ui.showBottomSheet(
      (completer) => flcFrr(
        () {
          final cameraDescription = cameraBits.selectedCameraDescription();
          return flcBottomMenu([
            ...cameraBits.cameras.availableCameras().map((c) {
              return RadioListTile(
                value: c.name,
                groupValue: cameraDescription?.name,
                onChanged: (value) {
                  value?.let(cameraBits.selectedCameraName.set);
                },
                title: flcFrr(
                  () => Text(
                    cameraBits.watchCameraLabelOrFacing(c),
                  ),
                ),
              );
            }),
            if (cameraDescription != null)
              () {
                final label =
                    cameraBits.watchCameraLabelOrFacing(cameraDescription);
                return TextButton(
                  onPressed: () {
                    _renameCamera(
                      label,
                      cameraDescription,
                    );
                  },
                  child: Text(
                    'Rename Camera: $label',
                    textAlign: TextAlign.center,
                  ),
                );
              }(),
          ]);
        },
      ),
      modalBarrierColor: Colors.black.withOpacity(0),
    );
  }

  return [
    TextButton(
      onPressed: () {
        popper.pop();
        _selectCamera();
      },
      child: flcFrr(
        () => Text(
          'Camera: ${cameraBits.selectedCameraLabel() ?? '<none>'}',
          textAlign: TextAlign.center,
        ),
      ),
    ),
    TextButton(
      onPressed: () {
        popper.pop();
        flcShowResolutionMenu(
          ui: ui,
          resolution: cameraBits.resolution,
        );
      },
      child: 'Camera Resolution'.txt,
    )
  ];
}

extension CameraImageX on CameraImage {
  CmnDimensionsMsg get dimensions => CmnDimensionsMsg()
    ..width = width
    ..height = height
    ..freeze();

  Size get size => Size(
        width.toDouble(),
        height.toDouble(),
      );

  int fixRotation() {
    final sizeBeforeRotate = size;
    final sizeAfterRotate = size.portrait;
    return sizeBeforeRotate == sizeAfterRotate ? 0 : 90;
  }

  Future<Uint8List> toJpegRotate() {
    return toJpeg(rotate: fixRotation());
  }

  img.Image toImgImage() {
    switch (format.group) {
      case ImageFormatGroup.bgra8888:
        return img.Image.fromBytes(
          width: width,
          height: height,
          bytes: planes[0].bytes.buffer,
          order: img.ChannelOrder.bgra,
        );

      case ImageFormatGroup.nv21:
        return decodeYUV420SP(this);

      default:
        throw format;
    }
  }

  Future<Uint8List> toJpeg({
    required int rotate,
  }) async {
    switch (format.group) {
      case ImageFormatGroup.jpeg:
        return planes[0].bytes;

      case ImageFormatGroup.bgra8888:
        final image = toImgImage();

        return (await image.toJpeg(rotate: rotate)).outputBytes!;

      case ImageFormatGroup.nv21:
        final image = toImgImage();

        return (await image.toJpeg(rotate: rotate)).outputBytes!;

      default:
        throw format;
    }
  }
}

extension ImgImageX on img.Image {
  Future<img.Command> toJpeg({
    required int rotate,
  }) async {
    final cmd = img.Command()..image(this);
    if (rotate != 0) {
      cmd.copyRotate(angle: rotate);
    }
    cmd..encodeJpg();

    return await cmd.executeThread();
  }
}

extension ImgCommandX on img.Command {
  void fixRotation(CameraImage cameraImage) {
    final rotate = cameraImage.fixRotation();
    if (rotate != 0) {
      copyRotate(angle: rotate);
    }
  }
}

void flcShowResolutionMenu({
  required FlcUi ui,
  required Fw<ResolutionPresetEnm> resolution,
}) {
  ui.showBottomSheet(
    (popper) => flcFrr(
      () {
        final groupValue = resolution();
        return flcBottomMenu([
          ...ResolutionPresetEnm.values.map((r) {
            return RadioListTile(
              value: r,
              groupValue: groupValue,
              onChanged: (value) {
                if (value != null) {
                  resolution.value = value;
                }
              },
              title: r.label.txt,
            );
          }),
        ]);
      },
    ),
  );
}

final flcResolutionPresetBidi = BiDi.protobufEnumByIndex(
  ResolutionPresetEnm.values,
  ResolutionPreset.values,
);

img.Image decodeYUV420SP(CameraImage image) {
  final int width = image.width;
  final int height = image.height;

  Uint8List yuv420sp = image.planes[0].bytes;
  //int total = width * height;
  //Uint8List rgb = Uint8List(total);
  final outImg =
      img.Image(width: width, height: height); // default numChannels is 3

  final int frameSize = width * height;

  for (int j = 0, yp = 0; j < height; j++) {
    int uvp = frameSize + (j >> 1) * width, u = 0, v = 0;
    for (int i = 0; i < width; i++, yp++) {
      int y = (0xff & yuv420sp[yp]) - 16;
      if (y < 0) y = 0;
      if ((i & 1) == 0) {
        v = (0xff & yuv420sp[uvp++]) - 128;
        u = (0xff & yuv420sp[uvp++]) - 128;
      }
      int y1192 = 1192 * y;
      int r = (y1192 + 1634 * v);
      int g = (y1192 - 833 * v - 400 * u);
      int b = (y1192 + 2066 * u);

      if (r < 0) {
        r = 0;
      } else if (r > 262143) {
        r = 262143;
      }
      if (g < 0) {
        g = 0;
      } else if (g > 262143) {
        g = 262143;
      }
      if (b < 0) {
        b = 0;
      } else if (b > 262143) {
        b = 262143;
      }

      // I don't know how these r, g, b values are defined, I'm just copying what you had bellow and
      // getting their 8-bit values.
      outImg.setPixelRgb(i, j, ((r << 6) & 0xff0000) >> 16,
          ((g >> 2) & 0xff00) >> 8, (b >> 10) & 0xff);

      /*rgb[yp] = 0xff000000 |
            ((r << 6) & 0xff0000) |
            ((g >> 2) & 0xff00) |
            ((b >> 10) & 0xff);*/
    }
  }
  return outImg;
}

// https://github.com/flutter/flutter/issues/115925

// Future<void> startCameraControllerImageStream({
//   required CameraController controller,
//   required void Function(CameraImage image) listener,
//   int skipFrameCount = 1,
// }) async {
//   await controller.startImageStream((image) {
//     if (skipFrameCount > 0) {
//       skipFrameCount--;
//       return;
//     }
//
//     listener(image);
//   });
// }
//
// void usage() async {
//   final CameraController cameraController = ...
//
//   await cameraController.initialize();
//   await startCameraControllerImageStream(
//     controller: cameraController,
//     listener: (image) {
//       // process stream, the first frame will be skipped
//     },
//   );
// }
