import 'package:mhu_dart_builder/mhu_dart_builder.dart';
import 'package:mhu_flutter_camera/src/generated/mhu_flutter_camera.pblib.dart';

void main() async {
  await runPbFieldGenerator(
    lib: mhuFlutterCameraLib,
  );
}
