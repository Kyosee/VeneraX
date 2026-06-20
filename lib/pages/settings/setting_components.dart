part of 'settings_page.dart';

class _SwitchSetting extends StatefulWidget {
  const _SwitchSetting({
    required this.title,
    required this.settingKey,
    this.onChanged,
    this.subtitle,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
    this.enabled = true,
  });

  final String title;

  final String settingKey;

  final VoidCallback? onChanged;

  final String? subtitle;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  final bool enabled;

  @override
  State<_SwitchSetting> createState() => _SwitchSettingState();
}

class _SwitchSettingState extends State<_SwitchSetting> {
  @override
  Widget build(BuildContext context) {
    var value = widget.comicId != null
        ? appdata.settings.getReaderSetting(
            widget.comicId!,
            widget.comicSource!,
            widget.settingKey,
          )
        : widget.useDeviceSettings
        ? appdata.settings.getDeviceReaderSetting(widget.settingKey)
        : appdata.settings[widget.settingKey];

    assert(value is bool);

    return ListTile(
      title: Text(widget.title),
      subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
      trailing: Switch(
        value: value,
        onChanged: widget.enabled
            ? (value) {
          setState(() {
            if (widget.comicId != null) {
              appdata.settings.setReaderSetting(
                widget.comicId!,
                widget.comicSource!,
                widget.settingKey,
                value,
              );
            } else if (widget.useDeviceSettings) {
              appdata.settings.setDeviceReaderSetting(widget.settingKey, value);
            } else {
              appdata.settings[widget.settingKey] = value;
            }
          });
          appdata.saveData().then((_) {
            widget.onChanged?.call();
          });
        }
            : null,
      ),
    );
  }
}

class _PageTurnModeSetting extends StatefulWidget {
  const _PageTurnModeSetting({
    this.onChanged,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final void Function(String key)? onChanged;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<_PageTurnModeSetting> createState() => _PageTurnModeSettingState();
}

class _PageTurnModeSettingState extends State<_PageTurnModeSetting> {
  dynamic _read(String key) {
    if (widget.comicId != null) {
      return appdata.settings.getReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        key,
      );
    } else if (widget.useDeviceSettings) {
      return appdata.settings.getDeviceReaderSetting(key);
    } else {
      return appdata.settings[key];
    }
  }

  void _write(String key, dynamic value) {
    if (widget.comicId != null) {
      appdata.settings.setReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        key,
        value,
      );
    } else if (widget.useDeviceSettings) {
      appdata.settings.setDeviceReaderSetting(key, value);
    } else {
      appdata.settings[key] = value;
    }
  }
  @override
  Widget build(BuildContext context) {
    final enabled = _read('enableTapToTurnPages') == true;
    final reverse = _read('reverseTapToTurnPages') == true;
    final current = !enabled
        ? 'off'
        : reverse
            ? 'reverse'
            : 'normal';
    final options = {
      'off': "Off".tl,
      'normal': "Tap to turn Pages".tl,
      'reverse': "Reverse tap to turn Pages".tl,
    };

    void apply(String mode) {
      switch (mode) {
        case 'off':
          _write('enableTapToTurnPages', false);
        case 'normal':
          _write('enableTapToTurnPages', true);
          _write('reverseTapToTurnPages', false);
        case 'reverse':
          _write('enableTapToTurnPages', true);
          _write('reverseTapToTurnPages', true);
      }
      setState(() {});
      appdata.saveData().then((_) {
        widget.onChanged?.call('enableTapToTurnPages');
        widget.onChanged?.call('reverseTapToTurnPages');
      });
    }

    return ListTile(
      title: Text("Page turn mode".tl),
      trailing: Select(
        current: options[current],
        values: options.values.toList(),
        minWidth: 64,
        onTap: (index) => apply(options.keys.elementAt(index)),
      ),
    );
  }
}

class SelectSetting extends StatelessWidget {
  const SelectSetting({
    super.key,
    required this.title,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 450) {
            return _DoubleLineSelectSettings(
              title: title,
              settingKey: settingKey,
              optionTranslation: optionTranslation,
              onChanged: onChanged,
              help: help,
              comicId: comicId,
              comicSource: comicSource,
              useDeviceSettings: useDeviceSettings,
            );
          } else {
            return _EndSelectorSelectSetting(
              title: title,
              settingKey: settingKey,
              optionTranslation: optionTranslation,
              onChanged: onChanged,
              help: help,
              comicId: comicId,
              comicSource: comicSource,
              useDeviceSettings: useDeviceSettings,
            );
          }
        },
      ),
    );
  }
}

class _DoubleLineSelectSettings extends StatefulWidget {
  const _DoubleLineSelectSettings({
    required this.title,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<_DoubleLineSelectSettings> createState() =>
      _DoubleLineSelectSettingsState();
}

class _DoubleLineSelectSettingsState extends State<_DoubleLineSelectSettings> {
  @override
  Widget build(BuildContext context) {
    var value = widget.comicId != null
        ? appdata.settings.getReaderSetting(
            widget.comicId!,
            widget.comicSource!,
            widget.settingKey,
          )
        : widget.useDeviceSettings
        ? appdata.settings.getDeviceReaderSetting(widget.settingKey)
        : appdata.settings[widget.settingKey];

    return ListTile(
      title: Row(
        children: [
          Text(widget.title),
          const SizedBox(width: 4),
          if (widget.help != null)
            Button.icon(
              size: 18,
              icon: const Icon(Icons.help_outline),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) {
                    return ContentDialog(
                      title: "Help".tl,
                      content: Text(
                        widget.help!,
                      ).paddingHorizontal(16).fixWidth(double.infinity),
                      actions: [
                        Button.filled(
                          onPressed: context.pop,
                          child: Text("OK".tl),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
        ],
      ),
      subtitle: Text(widget.optionTranslation[value] ?? "None"),
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
          items: widget.optionTranslation.keys
              .map(
                (key) => PopupMenuItem(
                  value: key,
                  height: App.isMobile ? 46 : 40,
                  child: Text(widget.optionTranslation[key]!),
                ),
              )
              .toList(),
        ).then((value) {
          if (value != null) {
            setState(() {
              if (widget.comicId != null) {
                appdata.settings.setReaderSetting(
                  widget.comicId!,
                  widget.comicSource!,
                  widget.settingKey,
                  value,
                );
              } else if (widget.useDeviceSettings) {
                appdata.settings.setDeviceReaderSetting(
                  widget.settingKey,
                  value,
                );
              } else {
                appdata.settings[widget.settingKey] = value;
              }
            });
            appdata.saveData();
            widget.onChanged?.call();
          }
        });
      },
    );
  }
}

class _EndSelectorSelectSetting extends StatefulWidget {
  const _EndSelectorSelectSetting({
    required this.title,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<_EndSelectorSelectSetting> createState() =>
      _EndSelectorSelectSettingState();
}

class _EndSelectorSelectSettingState extends State<_EndSelectorSelectSetting> {
  @override
  Widget build(BuildContext context) {
    var options = widget.optionTranslation;
    var value = widget.comicId != null
        ? appdata.settings.getReaderSetting(
            widget.comicId!,
            widget.comicSource!,
            widget.settingKey,
          )
        : widget.useDeviceSettings
        ? appdata.settings.getDeviceReaderSetting(widget.settingKey)
        : appdata.settings[widget.settingKey];
    return ListTile(
      title: Row(
        children: [
          Text(widget.title),
          const SizedBox(width: 4),
          if (widget.help != null)
            Button.icon(
              size: 18,
              icon: const Icon(Icons.help_outline),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) {
                    return ContentDialog(
                      title: "Help".tl,
                      content: Text(
                        widget.help!,
                      ).paddingHorizontal(16).fixWidth(double.infinity),
                      actions: [
                        Button.filled(
                          onPressed: context.pop,
                          child: Text("OK".tl),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
        ],
      ),
      trailing: Select(
        current: options[value],
        values: options.values.toList(),
        minWidth: 64,
        onTap: (index) {
          setState(() {
            var value = options.keys.elementAt(index);
            if (widget.comicId != null) {
              appdata.settings.setReaderSetting(
                widget.comicId!,
                widget.comicSource!,
                widget.settingKey,
                value,
              );
            } else if (widget.useDeviceSettings) {
              appdata.settings.setDeviceReaderSetting(widget.settingKey, value);
            } else {
              appdata.settings[widget.settingKey] = value;
            }
          });
          appdata.saveData();
          widget.onChanged?.call();
        },
      ),
    );
  }
}

class _SliderSetting extends StatefulWidget {
  const _SliderSetting({
    required this.title,
    required this.settingsIndex,
    required this.interval,
    required this.min,
    required this.max,
    this.onChanged,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final String title;

  final String settingsIndex;

  final double interval;

  final double min;

  final double max;

  final VoidCallback? onChanged;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<_SliderSetting> createState() => _SliderSettingState();
}

class _SliderSettingState extends State<_SliderSetting> {
  @override
  Widget build(BuildContext context) {
    var value =
        (widget.comicId != null
                ? appdata.settings.getReaderSetting(
                    widget.comicId!,
                    widget.comicSource!,
                    widget.settingsIndex,
                  )
                : widget.useDeviceSettings
                ? appdata.settings.getDeviceReaderSetting(widget.settingsIndex)
                : appdata.settings[widget.settingsIndex])
            .toDouble();
    // Decimal places needed to show the current step without float noise,
    // derived from the interval (0.1 -> 1 digit, 0.05 -> 2 digits, 1 -> 0).
    final fractionDigits = widget.interval >= 1
        ? 0
        : widget.interval.toString().split('.').last.length;
    return ListTile(
      title: Text(widget.title, softWrap: true, maxLines: 2),
      trailing: Text(
        value.toInt() == value
            ? value.toInt().toString()
            : value.toStringAsFixed(fractionDigits),
        style: ts.s12,
      ),
      subtitle: Slider(
        value: value,
        onChanged: (value) {
          if (value.toInt() == value) {
            setState(() {
              if (widget.comicId != null) {
                appdata.settings.setReaderSetting(
                  widget.comicId!,
                  widget.comicSource!,
                  widget.settingsIndex,
                  value.toInt(),
                );
              } else if (widget.useDeviceSettings) {
                appdata.settings.setDeviceReaderSetting(
                  widget.settingsIndex,
                  value.toInt(),
                );
              } else {
                appdata.settings[widget.settingsIndex] = value.toInt();
              }
              appdata.saveData();
            });
          } else {
            // Slider emits values with floating-point accumulation error
            // (e.g. 5.699999999999). Snap to the nearest interval step so the
            // stored and displayed value stays clean.
            final steps = ((value - widget.min) / widget.interval).round();
            value = double.parse(
              (widget.min + steps * widget.interval).toStringAsFixed(4),
            );
            setState(() {
              if (widget.comicId != null) {
                appdata.settings.setReaderSetting(
                  widget.comicId!,
                  widget.comicSource!,
                  widget.settingsIndex,
                  value,
                );
              } else if (widget.useDeviceSettings) {
                appdata.settings.setDeviceReaderSetting(
                  widget.settingsIndex,
                  value,
                );
              } else {
                appdata.settings[widget.settingsIndex] = value;
              }
              appdata.saveData();
            });
          }
          widget.onChanged?.call();
        },
        divisions: ((widget.max - widget.min) / widget.interval).toInt(),
        min: widget.min,
        max: widget.max,
      ),
    );
  }
}

class _PopupWindowSetting extends StatelessWidget {
  const _PopupWindowSetting({required this.title, required this.builder});

  final Widget Function() builder;

  final String title;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      trailing: const Icon(Icons.arrow_right),
      onTap: () {
        showPopUpWidget(App.rootContext, builder());
      },
    );
  }
}

class _MultiPagesFilter extends StatefulWidget {
  const _MultiPagesFilter({
    required this.title,
    required this.settingsIndex,
    required this.pages,
  });

  final String title;

  final String settingsIndex;

  // key - name
  final Map<String, String> pages;

  @override
  State<_MultiPagesFilter> createState() => _MultiPagesFilterState();
}

class _MultiPagesFilterState extends State<_MultiPagesFilter> {
  late List<String> keys;

  @override
  void initState() {
    keys = List.from(appdata.settings[widget.settingsIndex]);
    keys.remove("");
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    Future.microtask(() {
      updateSetting();
    });
  }

  var reorderWidgetKey = UniqueKey();
  var scrollController = ScrollController();
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    var tiles = keys.map((e) => buildItem(e)).toList();

    var view = ReorderableBuilder<String>(
      key: reorderWidgetKey,
      scrollController: scrollController,
      longPressDelay: App.isDesktop
          ? const Duration(milliseconds: 100)
          : const Duration(milliseconds: 500),
      dragChildBoxDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 5,
            offset: Offset(0, 2),
            spreadRadius: 2,
          ),
        ],
      ),
      onReorder: (reorderFunc) {
        setState(() {
          keys = List.from(reorderFunc(keys));
        });
      },
      children: tiles,
      builder: (children) {
        return GridView(
          key: _key,
          controller: scrollController,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 1,
            mainAxisExtent: 48,
          ),
          children: children,
        );
      },
    );

    return PopUpWidgetScaffold(
      title: widget.title,
      tailing: [
        if (keys.length < widget.pages.length)
          TextButton.icon(
            label: Text("Add".tl),
            icon: const Icon(Icons.add),
            onPressed: showAddDialog,
          ),
      ],
      body: view,
    );
  }

  Widget buildItem(String key) {
    Widget removeButton = Padding(
      padding: const EdgeInsets.only(right: 8),
      child: IconButton(
        onPressed: () {
          setState(() {
            keys.remove(key);
          });
        },
        icon: const Icon(Icons.delete_outline),
      ),
    );

    return ListTile(
      title: Text(widget.pages[key] ?? "(Invalid) $key"),
      key: Key(key),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [removeButton, const Icon(Icons.drag_handle)],
      ),
    );
  }

  void showAddDialog() {
    var canAdd = <String, String>{};
    widget.pages.forEach((key, value) {
      if (!keys.contains(key)) {
        canAdd[key] = value;
      }
    });
    var selected = <String>[];
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Add".tl,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: canAdd.entries
                    .map(
                      (e) => CheckboxListTile(
                        value: selected.contains(e.key),
                        title: Text(e.value),
                        key: Key(e.key),
                        onChanged: (value) {
                          setState(() {
                            if (value!) {
                              selected.add(e.key);
                            } else {
                              selected.remove(e.key);
                            }
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
              actions: [
                if (selected.length < canAdd.length)
                  TextButton(
                    child: Text("Select All".tl),
                    onPressed: () {
                      setState(() {
                        selected = canAdd.keys.toList();
                      });
                    },
                  )
                else
                  TextButton(
                    child: Text("Deselect All".tl),
                    onPressed: () {
                      setState(() {
                        selected.clear();
                      });
                    },
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: selected.isNotEmpty
                      ? () {
                          this.setState(() {
                            keys.addAll(selected);
                          });
                          Navigator.pop(context);
                        }
                      : null,
                  child: Text("Add".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void updateSetting() {
    appdata.settings[widget.settingsIndex] = keys;
    appdata.saveData();
  }
}

class _CallbackSetting extends StatelessWidget {
  const _CallbackSetting({
    required this.title,
    required this.callback,
    required this.actionTitle,
    this.subtitle,
  });

  final String title;

  final String? subtitle;

  final VoidCallback callback;

  final String actionTitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Button.normal(
        onPressed: callback,
        child: Text(actionTitle),
      ).fixHeight(28),
      onTap: callback,
    );
  }
}

class _SettingPartTitle extends StatelessWidget {
  const _SettingPartTitle({required this.title, required this.icon});

  final String title;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        padding: const EdgeInsets.only(left: 16, top: 16, bottom: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: context.colorScheme.onSurface.withValues(alpha: 0.1),
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 24),
            const SizedBox(width: 8),
            Text(title, style: ts.s18),
          ],
        ),
      ),
    );
  }
}
