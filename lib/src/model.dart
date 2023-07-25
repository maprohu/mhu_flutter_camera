import 'package:mhu_flutter_commons/mhu_flutter_commons.dart';

import '../proto.dart';

extension CameraPbeConfigX on PfeConfig {
  PfeConfig withCamera() => rebuild((builder) {
        builder.configure(CameraTimingMsg$.customDelay).defaultValue(
              CameraTimingDelayedMsg()
                ..shutterDelayMilliseconds = 1000
                ..freeze(),
            );
      });
}
