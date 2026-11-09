import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A shipped pack, from `assets/pets/<id>/pack.json`.
PetPack diskPack(String id) =>
    PetPack.parse(jsonDecode(File('assets/pets/$id/pack.json').readAsStringSync()) as Map<String, Object?>);

final deepy = diskPack('deepy-whale');
final girl = diskPack('whale-girl');

/// Decodes [anims] of [pack] (default: every animation it may play in a test).
Future<void> warmSheets(WidgetTester tester, PetPack pack, [Iterable<PetAnimation>? anims]) async {
  final all = anims ?? pack.animations.values;
  PetSheets.enabled = true;
  PetSheets.instance.pin(pack, pack.animFor(PetStateName.idle));
  await tester.runAsync(() async {
    for (final anim in all) {
      final image = await PetSheets.instance.load(pack, anim, rootBundle);
      image.dispose();
    }
  });
}
