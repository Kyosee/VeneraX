part of '../comic_source_page.dart';

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    var result = func([]);
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

/// Two-line select setting for source options. The title sits on its own line
/// and the current value on the subtitle, so a long option value (e.g. a full
/// domain-line description) can wrap instead of squeezing the title into a
/// single vertical column of characters (#110).
class _SourceSelectSetting extends StatelessWidget {
  const _SourceSelectSetting({
    required this.title,
    required this.current,
    required this.values,
    required this.onTap,
  });

  final String title;

  final String current;

  final List<String> values;

  final void Function(int index) onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Text(current),
      trailing: const Icon(Icons.arrow_drop_down),
      onTap: () {
        var renderBox = context.findRenderObject() as RenderBox;
        var offset = renderBox.localToGlobal(Offset.zero);
        var size = renderBox.size;
        var rect = offset & size;
        showMenu(
          elevation: 3,
          color: context.brightness == Brightness.light
              ? const Color(0xFFF6F6F6)
              : const Color(0xFF1E1E1E),
          context: context,
          position: RelativeRect.fromRect(
            rect,
            Offset.zero & MediaQuery.of(context).size,
          ),
          items: [
            for (var i = 0; i < values.length; i++)
              PopupMenuItem(
                value: i,
                height: App.isMobile ? 46 : 40,
                child: Text(values[i]),
              ),
          ],
        ).then((value) {
          if (value != null) {
            onTap(value);
          }
        });
      },
    );
  }
}

class _SliverComicSource extends StatefulWidget {
  const _SliverComicSource({
    super.key,
    required this.source,
    required this.edit,
    required this.update,
    required this.delete,
    required this.onLongPress,
  });

  final ComicSource source;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  /// Long-pressing a card enters sort mode.
  final VoidCallback onLongPress;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends State<_SliverComicSource> {
  ComicSource get source => widget.source;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    var manager = ComicSourceManager();
    var newVersion = manager.availableUpdates[source.key];
    bool hasUpdate =
        newVersion != null &&
        ComicSourcePage._isNewer(newVersion, source.version);
    var provenanceText = _provenanceText();
    var newerElsewhere = manager.newerElsewhereFor(source.key);
    String? newerHint;
    if (newerElsewhere != null) {
      final lib = ComicSourceLibraryManager.find(newerElsewhere.libraryId);
      if (lib != null) {
        newerHint = "Newer version @v in @lib".tlParams({
          "v": newerElsewhere.version,
          "lib": lib.name,
        });
      }
    }

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: context.colorScheme.outlineVariant.toOpacity(0.5),
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () {
                setState(() {
                  _expanded = !_expanded;
                });
              },
              onLongPress: widget.onLongPress,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            source.name,
                            style: ts.s18,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _actionButton(
                          icon: Icons.edit_note,
                          tooltip: "Edit".tl,
                          onPressed: () => widget.edit(source),
                        ),
                        _actionButton(
                          icon: Icons.update,
                          tooltip: "Update".tl,
                          onPressed: () => widget.update(source),
                          highlight: hasUpdate,
                        ),
                        if (_offeringLibraries().length > 1)
                          _actionButton(
                            icon: Icons.account_tree_outlined,
                            tooltip: "Update from another library".tl,
                            onPressed: _showLibraryPicker,
                          ),
                        _actionButton(
                          icon: Icons.delete_outline,
                          tooltip: "Delete".tl,
                          onPressed: () => widget.delete(source),
                          color: context.colorScheme.error,
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          color: context.colorScheme.outline,
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _versionChip(source.version),
                          if (hasUpdate) _updateChip(newVersion),
                          if (provenanceText != null)
                            _infoChip(
                              icon: Icons.inventory_2_outlined,
                              text: provenanceText,
                              color: context.colorScheme.outline,
                            ),
                          if (newerHint != null)
                            _infoChip(
                              icon: Icons.upgrade,
                              text: newerHint,
                              color: context.colorScheme.tertiary,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              Container(
                height: 0.6,
                color: context.colorScheme.outlineVariant.toOpacity(0.5),
              ),
              ...buildSourceSettings(),
              ..._buildAccount(),
              const SizedBox(height: 4),
            ],
          ],
        ),
      ),
    );
  }

  Widget _versionChip(String version) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(version, style: const TextStyle(fontSize: 13)),
    );
  }

  Widget _updateChip(String newVersion) {
    return Tooltip(
      message: newVersion,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: context.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.arrow_upward,
              size: 12,
              color: context.colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 2),
            Text(
              "New Version".tl,
              style: TextStyle(
                fontSize: 13,
                color: context.colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoChip({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.toOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width - 80,
            ),
            child: Text(
              text,
              style: ts.s12.copyWith(color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
    bool highlight = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          icon,
          size: 22,
          color: highlight
              ? context.colorScheme.primary
              : color ?? context.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// Libraries currently recorded as offering this source key (provenance).
  List<ComicSourceLibrary> _offeringLibraries() {
    final prov = ComicSourceManager().provenanceFor(source.key);
    if (prov == null) {
      return [];
    }
    return prov.libraryIds
        .map((id) => ComicSourceLibraryManager.find(id))
        .whereType<ComicSourceLibrary>()
        .toList();
  }

  /// Lets the user pick which library to (re)install this source from when more
  /// than one offers it. Each library's offered version is fetched up front and
  /// shown in the list. The chosen library's version/URL is written through to
  /// the update state so the existing update flow installs that variant. Since
  /// switching variants reinstalls the script and wipes the source's local data
  /// (login/cookies), it is gated behind an explicit confirmation.
  void _showLibraryPicker() async {
    final libraries = _offeringLibraries();
    if (libraries.isEmpty) return;

    // Fetch every offering library's catalog in parallel and resolve this
    // source's version + download URL there, so the picker can show the version
    // each library carries and the pick needs no second fetch.
    final controller = showLoadingDialog(
      App.rootContext,
      barrierDismissible: true,
      allowCancel: true,
    );
    final resolved = <String, ({String version, String? url})>{};
    await Future.wait(
      libraries.map((lib) async {
        try {
          var res = await fetchSourceText(lib.url)
              .timeout(const Duration(seconds: 20));
          var list = jsonDecode(res.data!) as List;
          for (var entry in list) {
            if (entry['key']?.toString() == source.key) {
              final v = entry['version']?.toString();
              if (v == null) break;
              resolved[lib.id] = (
                version: v,
                url: _resolveSourceDownloadUrl(
                  url: entry['url']?.toString(),
                  fileName: entry['fileName']?.toString(),
                  listUrl: lib.url,
                ),
              );
              break;
            }
          }
        } catch (e) {
          Log.error("Switch source library", "${lib.name}: $e");
        }
      }),
    );
    controller.close();
    if (!mounted) return;

    ComicSourceLibrary? chosen;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Update from another library".tl,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final lib in libraries)
                Builder(
                  builder: (context) {
                    final entry = resolved[lib.id];
                    final host = Uri.tryParse(lib.url)?.host ?? lib.url;
                    final subtitle = entry != null
                        ? "$host · v${entry.version}"
                        : "$host · ${"Unavailable".tl}";
                    return ListTile(
                      title: Text(lib.name),
                      subtitle: Text(subtitle),
                      trailing: entry != null
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: context
                                    .colorScheme
                                    .secondaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text("v${entry.version}", style: ts.s12),
                            )
                          : null,
                      enabled: entry != null,
                      onTap: entry == null
                          ? null
                          : () {
                              chosen = lib;
                              context.pop();
                            },
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
    if (chosen == null) return;
    final library = chosen!;
    final entry = resolved[library.id];
    final version = entry?.version;
    final downloadUrl = entry?.url;
    if (version == null || downloadUrl == null) {
      App.rootContext.showMessage(
        message: "This library no longer offers this source".tl,
      );
      return;
    }

    showConfirmDialog(
      context: App.rootContext,
      title: "Switch source library".tl,
      content:
          "Reinstall '@n' from @lib (v@v)? This replaces the installed script "
                  "and clears its login and local data."
              .tlParams({
                "n": source.name,
                "lib": library.name,
                "v": version,
              }),
      onConfirm: () {
        // Defer the destructive purge: register it to run inside the update
        // task ONLY after the new script downloads successfully, so a failed
        // switch leaves the existing session/local data intact.
        ComicSourceUpdateTaskManager.pendingDataPurge.add(source.key);
        // Write through winner state so the standard update flow targets the
        // chosen library's variant, and re-stamp the origin.
        final manager = ComicSourceManager();
        manager.setUpdateUrl(source.key, downloadUrl);
        manager.replaceAvailableUpdates({
          ...manager.availableUpdates,
          source.key: version,
        });
        final prov = manager.provenanceFor(source.key) ?? SourceProvenance();
        prov.originId = library.id;
        prov.updateLibraryId = library.id;
        if (!prov.libraryIds.contains(library.id)) {
          prov.libraryIds.add(library.id);
        }
        manager.updateProvenance(source.key, prov);
        widget.update(source);
      },
    );
  }

  /// Builds the origin/provenance line: "From [library]" plus "and N more"
  /// when several libraries offer this source. Returns null when no provenance
  /// is recorded (e.g. a sideloaded source).
  String? _provenanceText() {
    final prov = ComicSourceManager().provenanceFor(source.key);
    if (prov == null) {
      return null;
    }
    if (prov.originId != null) {
      final origin = ComicSourceLibraryManager.find(prov.originId!);
      if (origin == null) {
        // Origin library was removed; the source still works via its own URL.
        return "Source library removed".tl;
      }
      final others = prov.libraryIds.where((id) => id != prov.originId).length;
      if (others > 0) {
        return "From @lib and @n more".tlParams({
          "lib": origin.name,
          "n": others,
        });
      }
      return "From @lib".tlParams({"lib": origin.name});
    }
    if (prov.libraryIds.isNotEmpty) {
      final names = prov.libraryIds
          .map((id) => ComicSourceLibraryManager.find(id)?.name)
          .whereType<String>()
          .toList();
      if (names.isNotEmpty) {
        return "Provided by @libs".tlParams({"libs": names.join("、")});
      }
    }
    return null;
  }

  Iterable<Widget> buildSourceSettings() sync* {
    // Try to get dynamic settings first (for getters), fall back to cached settings
    var settingsMap = source.getSettingsDynamic() ?? source.settings;

    if (settingsMap == null) {
      return;
    } else if (source.data['settings'] == null) {
      source.data['settings'] = {};
    }
    for (var item in settingsMap.entries) {
      var key = item.key;
      String type = item.value['type'];
      try {
        if (type == "select") {
          var current = source.data['settings'][key];
          if (current == null) {
            var d = item.value['default'];
            for (var option in item.value['options']) {
              if (option['value'] == d) {
                current = option['text'] ?? option['value'];
                break;
              }
            }
          } else {
            current =
                item.value['options'].firstWhere(
                  (e) => e['value'] == current,
                )['text'] ??
                current;
          }
          yield _SourceSelectSetting(
            title: (item.value['title'] as String).ts(source.key),
            current: (current as String).ts(source.key),
            values: (item.value['options'] as List)
                .map<String>(
                  (e) => ((e['text'] ?? e['value']) as String).ts(source.key),
                )
                .toList(),
            onTap: (i) {
              source.data['settings'][key] = item.value['options'][i]['value'];
              source.saveData();
              setState(() {});
            },
          );
        } else if (type == "switch") {
          var current = source.data['settings'][key] ?? item.value['default'];
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                source.data['settings'][key] = v;
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "input") {
          var current =
              source.data['settings'][key] ?? item.value['default'] ?? '';
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                showInputDialog(
                  context: context,
                  title: (item.value['title'] as String).ts(source.key),
                  initialValue: current,
                  inputValidator: item.value['validator'] == null
                      ? null
                      : RegExp(item.value['validator']),
                  onConfirm: (value) {
                    source.data['settings'][key] = value;
                    source.saveData();
                    setState(() {});
                    return null;
                  },
                );
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(setting: item, sourceKey: source.key);
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  final _reLogin = <String, bool>{};

  Iterable<Widget> _buildAccount() sync* {
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.arrow_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          if (!mounted) return;
          source.saveData();
          setState(() {});
        },
      );
    }
    if (logged) {
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List) {
        bool loading = _reLogin[source.key] == true;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            if (source.data["account"] == null) {
              context.showMessage(message: "No data".tl);
              return;
            }
            setState(() {
              _reLogin[source.key] = true;
            });
            final List account = source.data["account"];
            var res = await source.account!.login!(account[0], account[1]);
            if (!mounted) return;
            if (res.error) {
              context.showMessage(message: res.errorMessage!);
            } else {
              context.showMessage(message: "Success".tl);
            }
            setState(() {
              _reLogin[source.key] = false;
            });
          },
          trailing: loading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: () {
          source.data["account"] = null;
          source.account?.logout();
          source.saveData();
          ComicSourceManager().notifyStateChange();
          setState(() {});
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}
