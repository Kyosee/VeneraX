import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:venera/utils/translations.dart';
import 'cbz.dart';
import 'io.dart';
import 'local_comic_scanner.dart';
import 'pdf_import.dart';
import 'venera_comics.dart';

/// Where a running comic import is, for the import dialog and the background
/// notification (issue #347).
class ImportComicProgress {
  const ImportComicProgress(
    this.message, {
    required this.done,
    required this.total,
    this.current,
  });

  /// Localized phase with its count, e.g. "Scanning folders 3/90".
  final String message;
  final int done;
  final int total;

  /// The comic, folder or file being worked on.
  final String? current;

  double? get value => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}

class ImportComic {
  final String? selectedFolder;
  final bool copyToLocal;
  final void Function(ImportComicProgress progress)? onProgress;

  const ImportComic({
    this.selectedFolder,
    this.copyToLocal = true,
    this.onProgress,
  });

  static const _scanningPhase = 'Scanning folders @done/@total';
  static const _copyingPhase = 'Copying to local storage @done/@total';
  static const _addingPhase = 'Adding to library @done/@total';
  static const _importingPhase = 'Importing @done/@total';

  void _report(
    String phase,
    int done,
    int total, {
    String? current,
    LoadingDialogController? dialog,
  }) {
    final progress = ImportComicProgress(
      phase.tlParams({'done': done, 'total': total}),
      done: done,
      total: total,
      current: current,
    );
    onProgress?.call(progress);
    dialog?.setMessage(progress.message);
    dialog?.setProgress(progress.value);
  }

  Future<bool> cbz() async {
    var file = await selectFile(ext: ['cbz', 'zip', '7z', 'cb7']);
    if (file == null) {
      return false;
    }
    return cbzFile(File(file.path));
  }

  Future<bool> cbzFile(File file) async {
    Map<String?, List<LocalComic>> imported = {};
    var controller = showLoadingDialog(App.rootContext, allowCancel: false);
    try {
      // importAll, not import: one archive may hold several comics (a folder of
      // per-comic archives zipped together, or one subdirectory per comic).
      var comics = await CBZ.importAll(file);
      if (comics.isEmpty) {
        App.rootContext.showMessage(message: "No valid comics found".tl);
      }
      imported[selectedFolder] = comics;
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    controller.close();
    return registerComics(imported, false);
  }

  /// Selects one file and routes it to the matching comic importer.
  Future<bool> files() async {
    var file = await selectFile(
      ext: ['cbz', 'zip', '7z', 'cb7', 'pdf', 'venera_comics'],
    );
    if (file == null) return false;
    final ext = file.path.split('.').last.toLowerCase();
    if (ext == 'pdf') return pdfFile(File(file.path));
    if (ext == 'venera_comics') {
      try {
        await importVeneraComics(File(file.path));
        return true;
      } catch (e) {
        App.rootContext.showMessage(message: e.toString());
        return false;
      }
    }
    return cbzFile(File(file.path));
  }

  Future<bool> pdfFile(File file) async {
    final controller = showLoadingDialog(
      App.rootContext,
      allowCancel: false,
      barrierDismissible: false,
      withProgress: true,
      message: 'Import Comics'.tl,
    );
    LocalComic comic;
    try {
      comic = await importPdfComic(
        file,
        localPath: LocalManager().path,
        cachePath: App.cachePath,
        onProgress: controller.setProgress,
      );
    } catch (e, s) {
      Log.error('Import PDF', e.toString(), s);
      App.rootContext.showMessage(
        message:
            (diskFullMessageKey(e) ??
                    'Unable to import PDF. The file may be damaged or require a password.')
                .tl,
      );
      return false;
    } finally {
      controller.close();
    }
    return registerComics({
      selectedFolder: [comic],
    }, false);
  }

  Future<bool> multipleCbz() async {
    var picker = DirectoryPicker();
    var dir = await picker.pickDirectory(directAccess: true);
    if (dir == null) {
      return false;
    }
    return multipleCbzFromDir(dir);
  }

  Future<bool> multipleCbzFromDir(Directory dir) async {
    var files = (await dir.list().toList()).whereType<File>().toList();
    const supportedExtensions = ['cbz', 'zip', '7z', 'cb7'];
    files.removeWhere((e) => !supportedExtensions.contains(e.extension));
    Map<String?, List<LocalComic>> imported = {};
    var controller = showLoadingDialog(App.rootContext, allowCancel: false);
    var comics = <LocalComic>[];
    for (var i = 0; i < files.length; i++) {
      _report(
        _importingPhase,
        i,
        files.length,
        current: files[i].name,
        dialog: controller,
      );
      try {
        comics.addAll(await CBZ.importAll(files[i]));
      } catch (e, s) {
        Log.error("Import Comic", e.toString(), s);
      }
    }
    if (comics.isEmpty) {
      App.rootContext.showMessage(message: "No valid comics found".tl);
    }
    imported[selectedFolder] = comics;
    controller.close();
    return registerComics(imported, false);
  }

  /// Imports every .venera_comics file found directly inside [dir]. Pairs with
  /// the per-comic export (issue #54): re-importing an export folder works.
  Future<bool> multipleVeneraComicsFromDir(Directory dir) async {
    var files = (await dir.list().toList())
        .whereType<File>()
        .where((e) => e.name.toLowerCase().endsWith('.venera_comics'))
        .toList();
    if (files.isEmpty) {
      App.rootContext.showMessage(message: "No valid comics found".tl);
      return false;
    }
    var controller = showLoadingDialog(App.rootContext, allowCancel: false);
    var total = 0;
    for (var i = 0; i < files.length; i++) {
      _report(
        _importingPhase,
        i,
        files.length,
        current: files[i].name,
        dialog: controller,
      );
      try {
        total += await importVeneraComics(files[i]);
      } catch (e, s) {
        Log.error("Import Comic", e.toString(), s);
      }
    }
    controller.close();
    App.rootContext.showMessage(
        message: "Imported @a comics".tlParams({'a': total}));
    return true;
  }

  Future<bool> ehViewer() async {
    var dbFile = await selectFile(ext: ['db']);
    final picker = DirectoryPicker();
    final comicSrc = await picker.pickDirectory();
    Map<String?, List<LocalComic>> imported = {};
    if (dbFile == null || comicSrc == null) {
      return false;
    }

    bool cancelled = false;
    var controller = showLoadingDialog(App.rootContext, onCancel: () {
      cancelled = true;
    });

    try {
      var db = openRawDatabase(dbFile.path);

      var scanned = 0;
      var total = 0;

      Future<List<LocalComic>> validateComics(List<sql.Row> comics) async {
        List<LocalComic> imported = [];
        for (var comic in comics) {
          if (cancelled) {
            return imported;
          }
          var comicDir = Directory(
              FilePath.join(comicSrc.path, comic['DIRNAME'] as String));
          String titleJP =
              comic['TITLE_JPN'] == null ? "" : comic['TITLE_JPN'] as String;
          String title = titleJP == "" ? comic['TITLE'] as String : titleJP;
          _report(
            _scanningPhase,
            scanned++,
            total,
            current: title,
            dialog: controller,
          );
          int timeStamp = comic['TIME'] as int;
          DateTime downloadTime = timeStamp != 0
              ? DateTime.fromMillisecondsSinceEpoch(timeStamp)
              : DateTime.now();
          var comicObj = await _checkSingleComic(comicDir,
              title: title,
              tags: [
                //1 >> x
                [
                  "MISC",
                  "DOUJINSHI",
                  "MANGA",
                  "ARTISTCG",
                  "GAMECG",
                  "IMAGE SET",
                  "COSPLAY",
                  "ASIAN PORN",
                  "NON-H",
                  "WESTERN",
                ][(log(comic['CATEGORY'] as int) / ln2).floor()]
              ],
              createTime: downloadTime);
          if (comicObj == null) {
            continue;
          }
          imported.add(comicObj);
        }
        return imported;
      }

      var tags = <String>[""];
      tags.addAll(db.select("""
            SELECT * FROM DOWNLOAD_LABELS LB
            ORDER BY  LB.TIME DESC;
          """).map((r) => r['LABEL'] as String).toList());

      // Query every label up front so the scan knows its total.
      final comicLists = <String, List<sql.Row>>{
        for (var tag in tags)
          tag: db.select("""
              SELECT *
              FROM DOWNLOAD_DIRNAME DN
              LEFT JOIN DOWNLOADS DL
              ON DL.GID = DN.GID
              WHERE DL.LABEL ${tag == '' ? 'IS NULL' : '= \'$tag\''} AND DL.STATE = 3
              ORDER BY DL.TIME DESC
            """).toList(),
      };
      total = comicLists.values.fold(0, (sum, list) => sum + list.length);

      for (var tag in tags) {
        if (cancelled) {
          break;
        }
        var folderName = tag == '' ? '(EhViewer)Default'.tl : '(EhViewer)$tag';
        var comicList = comicLists[tag]!;

        var validComics = await validateComics(comicList);
        imported[folderName] = validComics;
        if (validComics.isNotEmpty &&
            !LocalFavoritesManager().existsFolder(folderName)) {
          LocalFavoritesManager().createFolder(folderName);
        }
      }
      db.dispose();

      //Android specific
      var cache = FilePath.join(App.cachePath, dbFile.name);
      await File(cache).deleteIgnoreError();
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    controller.close();
    if (cancelled) return false;
    return registerComics(imported, copyToLocal);
  }

  Future<bool> directory(bool single) async {
    final picker = DirectoryPicker();
    final path = await picker.pickDirectory();
    if (path == null) {
      return false;
    }
    return directoryAt(path, single: single);
  }

  Future<bool> directoryAt(Directory path, {required bool single}) async {
    Map<String?, List<LocalComic>> imported = {selectedFolder: []};
    try {
      if (single) {
        _report(_scanningPhase, 0, 1, current: path.name);
        var result = await _checkSingleComic(path);
        if (result != null) {
          imported[selectedFolder]!.add(result);
        } else {
          App.rootContext.showMessage(message: "Invalid Comic".tl);
          return false;
        }
      } else {
        // List first so the scan can report how far it has got.
        final folders = (await path.list().toList())
            .whereType<Directory>()
            .toList();
        for (var i = 0; i < folders.length; i++) {
          _report(_scanningPhase, i, folders.length, current: folders[i].name);
          var result = await _checkSingleComic(folders[i]);
          if (result != null) {
            imported[selectedFolder]!.add(result);
          }
        }
      }
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    return registerComics(imported, copyToLocal);
  }

  /// 文件夹自动判定:返回 kind('cbz'|'single'|'multi')、guessMulti、选中的 dir。
  Future<({String kind, bool guessMulti, Directory dir})?> inspectFolder() async {
    final picker = DirectoryPicker();
    final path = await picker.pickDirectory();
    if (path == null) return null;

    var hasArchive = false;
    var hasVeneraComics = false;
    var hasSubDir = false;
    var hasImageInRoot = false;
    var hasMetaInRoot = false;
    const imgExt = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'];
    const metaFiles = ['details.json', 'comicinfo.xml', 'metadata.json'];
    const arcExt = ['cbz', 'zip', '7z', 'cb7'];

    await for (var e in path.list()) {
      final name = e.name.toLowerCase();
      if (e is Directory) {
        hasSubDir = true;
      } else if (e is File) {
        final ext = name.split('.').last;
        if (ext == 'venera_comics') hasVeneraComics = true;
        if (arcExt.contains(ext)) hasArchive = true;
        if (imgExt.contains(ext)) hasImageInRoot = true;
        if (metaFiles.contains(name)) hasMetaInRoot = true;
      }
    }

    if (hasVeneraComics) {
      return (kind: 'venera_comics', guessMulti: false, dir: path);
    }
    if (hasArchive) return (kind: 'cbz', guessMulti: false, dir: path);
    if (!hasSubDir && hasImageInRoot) {
      return (kind: 'single', guessMulti: false, dir: path);
    }
    // 含子文件夹:根目录有元数据文件或封面图 → 倾向单本(子文件夹为章节);
    // 否则倾向多本(每个子文件夹一本)。用户可在确认弹窗中改正。
    final guessMulti = !(hasMetaInRoot || hasImageInRoot);
    return (kind: guessMulti ? 'multi' : 'single', guessMulti: guessMulti, dir: path);
  }

  Future<bool> localDownloads() async {
    var localDir = LocalManager().directory;
    Map<String?, List<LocalComic>> imported = {null: []};
    bool cancelled = false;
    var controller = showLoadingDialog(App.rootContext, onCancel: () {
      cancelled = true;
    });
    try {
      if (!await localDir.exists()) {
        App.rootContext.showMessage(message: "Local path not found".tl);
        controller.close();
        return false;
      }
      final folders = (await localDir.list().toList())
          .whereType<Directory>()
          .toList();
      for (var i = 0; i < folders.length; i++) {
        if (cancelled) {
          break;
        }
        final entry = folders[i];
        _report(
          _scanningPhase,
          i,
          folders.length,
          current: entry.name,
          dialog: controller,
        );
        var stat = await entry.stat();
        var result = await _checkSingleComic(
          entry,
          createTime: stat.modified,
          useRelativePath: true,
        );
        if (result != null) {
          imported[null]!.add(result);
        }
      }
      if (!cancelled && imported[null]!.isEmpty) {
        App.rootContext.showMessage(message: "No valid comics found".tl);
      }
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    controller.close();
    if (cancelled) return false;
    return registerComics(imported, false);
  }

  //Automatically search for cover image and chapters
  Future<LocalComic?> _checkSingleComic(Directory directory,
      {String? id,
      String? title,
      String? subtitle,
      List<String>? tags,
      DateTime? createTime,
      bool useRelativePath = false}) {
    return scanLocalComicDirectory(
      directory,
      id: id,
      title: title,
      subtitle: subtitle,
      tags: tags,
      createTime: createTime,
      useRelativePath: useRelativePath,
    );
  }

  static Future<Map<String, String>> _copyDirectories(
      Map<String, dynamic> data) async {
    return overrideIO(() async {
      var toBeCopied = data['toBeCopied'] as List<String>;
      var destination = data['destination'] as String;
      Map<String, String> result = {};
      for (var dir in toBeCopied) {
        var source = Directory(dir);
        var dest = Directory("$destination/${source.name}");
        if (dest.existsSync()) {
          // The destination directory already exists, and it is not managed by the app.
          // Rename the old directory to avoid conflicts.
          Log.info("Import Comic",
              "Directory already exists: ${source.name}\nRenaming the old directory.");
          dest.renameSync(
              findValidDirectoryName(dest.parent.path, "${dest.path}_old"));
        }
        dest.createSync();
        await copyDirectory(source, dest);
        result[source.path] = dest.path;
      }
      return result;
    });
  }

  Future<Map<String?, List<LocalComic>>> _copyComicsToLocalDir(
      Map<String?, List<LocalComic>> comics) async {
    var destPath = LocalManager().path;
    Map<String?, List<LocalComic>> result = {};
    final total = comics.values
        .expand((list) => list)
        .where((c) => !c.directory.startsWith(destPath))
        .length;
    var copied = 0;
    for (var favoriteFolder in comics.keys) {
      result[favoriteFolder] = comics[favoriteFolder]!
          .where((c) => c.directory.startsWith(destPath))
          .toList();
      comics[favoriteFolder]!
          .removeWhere((c) => c.directory.startsWith(destPath));

      // One comic per isolate run, so progress can be reported between them.
      for (var c in comics[favoriteFolder]!) {
        _report(_copyingPhase, copied, total, current: c.title);
        try {
          var pathMap =
              await compute<Map<String, dynamic>, Map<String, String>>(
                  _copyDirectories, {
            'toBeCopied': [c.directory],
            'destination': destPath,
          });
          //Construct a new object since LocalComic.directory is a final String
          result[favoriteFolder]!.add(LocalComic(
            id: c.id,
            title: c.title,
            subtitle: c.subtitle,
            tags: c.tags,
            directory: pathMap[c.directory]!,
            chapters: c.chapters,
            cover: c.cover,
            comicType: c.comicType,
            downloadedChapters: c.downloadedChapters,
            createdAt: c.createdAt,
            description: c.description,
          ));
          copied++;
        } catch (e, s) {
          App.rootContext.showMessage(message: "Failed to copy comics".tl);
          Log.error("Import Comic", e.toString(), s);
          return result;
        }
      }
    }
    return result;
  }

  Future<bool> registerComics(
      Map<String?, List<LocalComic>> importedComics, bool copy) async {
    try {
      if (copy) {
        importedComics = await _copyComicsToLocalDir(importedComics);
      }
      int importedCount = 0;
      final total = importedComics.values.fold(
        0,
        (sum, list) => sum + list.length,
      );
      for (var folder in importedComics.keys) {
        for (var comic in importedComics[folder]!) {
          _report(_addingPhase, importedCount, total, current: comic.title);
          // Let the dialog repaint between comics; each add is synchronous.
          await Future<void>.delayed(Duration.zero);
          var id = LocalManager().findValidId(ComicType.local);
          LocalManager().add(comic, id);
          importedCount++;
          if (folder != null) {
            LocalFavoritesManager().addComic(
                folder,
                FavoriteItem(
                    id: id,
                    name: comic.title,
                    coverPath: comic.cover,
                    author: comic.subtitle,
                    type: comic.comicType,
                    tags: comic.tags,
                    favoriteTime: comic.createdAt));
          }
        }
      }
      App.rootContext.showMessage(
          message: "Imported @a comics".tlParams({
        'a': importedCount,
      }));
    } catch (e, s) {
      App.rootContext.showMessage(message: "Failed to register comics".tl);
      Log.error("Import Comic", e.toString(), s);
      return false;
    }
    return true;
  }
}
