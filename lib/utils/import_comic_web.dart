import 'package:venera/foundation/local.dart';

class ImportComic {
  final String? selectedFolder;
  final bool copyToLocal;

  const ImportComic({this.selectedFolder, this.copyToLocal = true});

  Future<bool> cbz() async => false;

  Future<bool> multipleCbz() async => false;

  Future<bool> ehViewer() async => false;

  Future<bool> directory(bool single) async => false;

  Future<bool> localDownloads() async => false;

  Future<bool> registerComics(
    Map<String?, List<LocalComic>> importedComics,
    bool copy,
  ) async {
    return false;
  }
}
