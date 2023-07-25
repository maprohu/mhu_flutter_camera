import 'dart:io';

import 'package:mhu_dart_builder/mhu_dart_builder.dart';
import 'package:mhu_dart_commons/io.dart';

void main() async {
  await runPbLibGenerator();

  await Directory.current.run(
    'dart',
    [
      'tool/run_pbfield.dart',
    ],
  );
}
