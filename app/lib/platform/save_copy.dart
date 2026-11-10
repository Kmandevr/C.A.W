// Saves a finished file (an export) where the user picks, copying it in chunks so a long WAV never has to fit in
// memory (#91): Android through the system's create-document picker, desktop through the file picker's path.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// Asks where to save [source] as [name] and copies it there. True when saved, false when the picker was closed.
Future<bool> saveCopyOf(File source, {required String name, required String mimeType, String? extension}) async {
  if (Platform.isAndroid) {
    final uri = await const MethodChannel('caw/files')
        .invokeMethod<String>('saveCopy', {'path': source.path, 'name': name, 'mime': mimeType});
    return uri != null;
  }
  // Desktop: the picker returns a path; the copy streams the file there.
  final saved = await FilePicker.saveFile(
    fileName: name,
    bytes: Uint8List(0),
    mimeType: mimeType,
    type: extension == null ? FileType.any : FileType.custom,
    allowedExtensions: extension == null ? null : [extension],
  );
  if (saved == null) return false;
  final path = saved.isScheme('file') ? saved.toFilePath() : saved.toString();
  await source.copy(path);
  return true;
}
