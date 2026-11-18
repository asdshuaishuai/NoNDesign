// Where the app keeps writable data.
//
// Two roots, deliberately separate:
//
//  * [projectsRoot] — user project files (`.ddp`). This is the folder the
//    project library lists and the file picker defaults to.
//      - desktop: `~/Documents/NoNDesign`
//      - mobile:  `<app documents>/NoNDesign` (path_provider; the platform
//        sandbox’s Documents folder — never `systemTemp`, which iOS/Android
//        may purge at any time and which is not user-visible)
//  * [dataRoot] — caches that can be re-downloaded or rebuilt (models,
//    embedding index). Kept on the previous `~/.nondesign` desktop location so
//    already-downloaded model caches stay valid; mobile falls back to the
//    system temp dir only for these *disposable* caches, never for projects.
//
// All paths are overridable for tests. Production code must not set the
// overrides; `ProjectService` accepts an explicit directory instead.
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// App data roots (see the file header for the split).
class AppPaths {
  AppPaths._();

  /// Legacy desktop cache directory name (models / embedding index).
  static const String desktopDirName = '.nondesign';

  /// Folder name used for user projects on every platform.
  static const String projectsDirName = 'NoNDesign';

  /// Desktop project directory for [home] (`~/Documents/NoNDesign`).
  ///
  /// Exposed so the rule can be asserted without creating directories in the
  /// user's real Documents folder.
  static String desktopProjectsDir(String home) => '$home/Documents/$projectsDirName';

  /// Test injection for [dataRoot] (caches only).
  static Directory? rootOverride;

  /// Test injection for [projectsRoot].
  static Directory? projectsRootOverride;

  /// Whether this host has a durable desktop home directory.
  ///
  /// Hosts that answer false (mobile, or a restricted desktop sandbox with no
  /// `$HOME`/`%USERPROFILE%`) must resolve [appDocumentsDirectory] before
  /// [stateRoot] can point at durable storage.
  static bool get hasDurableHome => _desktopHome() != null;

  /// Test injection for the platform documents directory.
  ///
  /// Production leaves this null: [appDocumentsDirectory] then asks
  /// path_provider. Tests point it at a temp dir so no platform channel is
  /// touched.
  static Directory? documentsDirectoryOverride;

  static Directory? _documentsCache;

  /// Platform “Documents” directory.
  ///
  /// iOS/Android always go through path_provider (the app sandbox documents
  /// dir). Desktop also uses it as the fallback when `$HOME` is missing, which
  /// is preferable to the system temp dir for user-visible files.
  static Future<Directory> appDocumentsDirectory() async {
    final override = documentsDirectoryOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    final cached = _documentsCache;
    if (cached != null) return cached;
    final dir = await getApplicationDocumentsDirectory();
    _documentsCache = dir;
    return dir;
  }

  /// Root for user project files; created on first use.
  ///
  /// Desktop: `$HOME/Documents/NoNDesign`. Mobile: `<documents>/NoNDesign`.
  /// Never `systemTemp` — projects must survive OS cache cleanup.
  static Future<Directory> projectsRoot() async {
    final override = projectsRootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    final Directory dir;
    if (documentsDirectoryOverride != null) {
      // Test/embedded hosts: an explicit documents directory wins on every
      // platform so unit tests never touch the real `~/Documents`.
      dir = Directory('${(await appDocumentsDirectory()).path}/$projectsDirName');
    } else if (!Platform.isIOS && !Platform.isAndroid) {
      final home = _desktopHome();
      if (home != null) {
        dir = Directory(desktopProjectsDir(home));
      } else {
        // Restricted desktop sandbox without HOME: the platform documents
        // folder is the closest user-visible location.
        dir = Directory('${(await appDocumentsDirectory()).path}/$projectsDirName');
      }
    } else {
      dir = Directory('${(await appDocumentsDirectory()).path}/$projectsDirName');
    }
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Cache root (models / embedding index); created on demand.
  ///
  /// This is *not* where projects live — see [projectsRoot]. Mobile keeps the
  /// historical temp-dir fallback for disposable caches only; call
  /// [useAppDocumentsForCaches] once the platform documents directory is known
  /// to move them to durable storage.
  static Directory dataRoot() {
    final override = rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    final dir = _platformCacheRoot();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Points [dataRoot] at `<app documents>/caches` on mobile.
  ///
  /// Batches that own the model cache may call this after initialization;
  /// until then [dataRoot] keeps the legacy temp-dir behaviour so nothing
  /// crashes mid-migration.
  static Future<Directory> useAppDocumentsForCaches() async {
    if (Platform.isIOS || Platform.isAndroid) {
      _documentsCache = await appDocumentsDirectory();
    }
    return dataRoot();
  }

  /// Subdirectory of [dataRoot] (created on demand), e.g.
  /// `dataSubdir('models/mediapipe/retrieval')`.
  static Directory dataSubdir(String relative) {
    final dir = Directory('${dataRoot().path}/$relative');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Durable app-state directory: crash snapshots, chat history, settings
  /// mirror.
  ///
  /// Desktop keeps the historical `$HOME/.nondesign` location so snapshots
  /// written by earlier versions stay readable. A desktop without a usable
  /// home (restricted sandbox) and mobile fall back to
  /// `<app documents>/NoNDesign/state`.
  ///
  /// The system temp dir is only a pre-boot placeholder for hosts whose
  /// documents folder has not been resolved yet ([hasDurableHome] is false):
  /// callers that need durability must await [appDocumentsDirectory] first —
  /// the store does this at boot.
  static String stateRoot() {
    if (!Platform.isIOS && !Platform.isAndroid) {
      final home = _desktopHome();
      if (home != null) return '$home/$desktopDirName';
    }
    final docs = documentsDirectoryOverride ?? _documentsCache;
    if (docs != null) return '${docs.path}/$projectsDirName/state';
    return '${Directory.systemTemp.path}/nondesign';
  }

  /// Subdirectory of [projectsRoot] (created on demand).
  static Future<Directory> projectsSubdir(String relative) async {
    final root = await projectsRoot();
    final dir = Directory('${root.path}/$relative');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Directory _platformCacheRoot() {
    if (Platform.isIOS || Platform.isAndroid) {
      final docs = _documentsCache;
      if (docs != null) return Directory('${docs.path}/caches');
      // Disposable caches only (never projects): the OS may clear this.
      return Directory('${Directory.systemTemp.path}/nondesign');
    }
    final home = _desktopHome();
    if (home == null) {
      // Abnormal desktop environment / restricted sandbox.
      return Directory('${Directory.systemTemp.path}/nondesign');
    }
    return Directory('$home/$desktopDirName');
  }

  static String? _desktopHome() {
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) return profile;
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return home;
  }
}
