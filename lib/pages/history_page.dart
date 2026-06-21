import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/history_tasks.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/translations.dart';

const _historyReadFilterList = ['All', 'UnCompleted', 'Completed'];

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    HistoryManager().addListener(onUpdate);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onUpdate);
    searchTextController.dispose();
    super.dispose();
  }

  void onUpdate() {
    setState(() {
      comics = HistoryManager().getAll();
      if (multiSelectMode) {
        selectedComics.removeWhere((comic, _) => !comics.contains(comic));
        if (selectedComics.isEmpty) {
          multiSelectMode = false;
        }
      }
    });
  }

  var comics = HistoryManager().getAll();
  var controller = FlyoutController();
  var searchTextController = TextEditingController();
  var keyword = "";
  var readFilterSelect = "All";
  var sourceFilterSelect = <String>{};

  bool multiSelectMode = false;
  Map<History, bool> selectedComics = {};

  List<History> get filteredComics {
    return comics.where((comic) {
      if (sourceFilterSelect.isNotEmpty &&
          !sourceFilterSelect.contains(comic.sourceKey)) {
        return false;
      }
      var readCompleted = comic.maxPage != null && comic.page == comic.maxPage;
      if (readFilterSelect == "UnCompleted" && readCompleted) {
        return false;
      }
      if (readFilterSelect == "Completed" && !readCompleted) {
        return false;
      }
      var kw = keyword.trim().toLowerCase();
      if (kw.isEmpty) {
        return true;
      }
      return comic.title.toLowerCase().contains(kw) ||
          comic.subtitle.toLowerCase().contains(kw) ||
          sourceLabel(comic.sourceKey).toLowerCase().contains(kw);
    }).toList();
  }

  List<String> get sourceFilterValues {
    var values = {
      ...comics.map((comic) => comic.sourceKey),
      ...sourceFilterSelect,
    }.toList();
    values.sort((a, b) => sourceLabel(a).compareTo(sourceLabel(b)));
    return values;
  }

  Map<String, List<History>> get groupedFilteredComics {
    var result = <String, List<History>>{};
    for (var comic in filteredComics) {
      result.putIfAbsent(_dateGroupTitle(comic.time), () => []).add(comic);
    }
    return result;
  }

  String _dateGroupTitle(DateTime time) {
    var now = DateTime.now();
    var today = DateUtils.dateOnly(now);
    var day = DateUtils.dateOnly(time);
    if (day == today) {
      return "Today";
    }
    if (day == today.subtract(const Duration(days: 1))) {
      return "Yesterday";
    }
    var startOfWeek = today.subtract(Duration(days: today.weekday - 1));
    if (!day.isBefore(startOfWeek)) {
      return "This Week";
    }
    return "Earlier";
  }

  String sourceLabel(String sourceKey) {
    if (sourceKey == 'local') {
      return 'Local'.tl;
    }
    if (sourceKey.startsWith('Unknown:')) {
      return sourceKey;
    }
    return ComicSource.find(sourceKey)?.name ?? sourceKey;
  }

  void selectAll() {
    setState(() {
      selectedComics = filteredComics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      filteredComics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  void showFilterDialog() {
    var readFilter = readFilterSelect;
    var sourceFilter = {...sourceFilterSelect};
    final sourceValues = sourceFilterValues;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return ContentDialog(
              title: "Filter".tl,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text("Filter reading status".tl),
                    trailing: Select(
                      current: readFilter.tl,
                      values: _historyReadFilterList.map((e) => e.tl).toList(),
                      minWidth: 96,
                      onTap: (index) {
                        setDialogState(() {
                          readFilter = _historyReadFilterList[index];
                        });
                      },
                    ),
                  ),
                  ListTile(title: Text("Filter comic source".tl)),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: sourceValues.map((sourceKey) {
                      return CheckboxListTile(
                        title: Text(sourceLabel(sourceKey)),
                        value: sourceFilter.contains(sourceKey),
                        onChanged: (checked) {
                          setDialogState(() {
                            if (checked ?? false) {
                              sourceFilter.add(sourceKey);
                            } else {
                              sourceFilter.remove(sourceKey);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      readFilter = "All";
                      sourceFilter.clear();
                    });
                  },
                  child: Text("Reset".tl),
                ),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      readFilterSelect = readFilter;
                      sourceFilterSelect = sourceFilter;
                      selectedComics.removeWhere(
                        (comic, _) => !filteredComics.contains(comic),
                      );
                    });
                    context.pop();
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _removeHistory(History comic) {
    if (comic.sourceKey.startsWith("Unknown")) {
      HistoryManager().remove(
        comic.id,
        ComicType(int.parse(comic.sourceKey.split(':')[1])),
      );
    } else if (comic.sourceKey == 'local') {
      HistoryManager().remove(comic.id, ComicType.local);
    } else {
      HistoryManager().remove(comic.id, ComicType.fromKey(comic.sourceKey));
    }
  }

  void _removeHistoriesWithConfirm(List<History> histories) {
    if (histories.isEmpty) {
      return;
    }
    showConfirmDialog(
      context: context,
      title: "Delete".tl,
      content: "Delete @c histories?".tlParams({"c": histories.length}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        var removedHistories = List<History>.from(histories);
        setState(() {
          multiSelectMode = false;
          selectedComics.clear();
        });
        for (final comic in removedHistories) {
          _removeHistory(comic);
        }
        if (mounted) {
          showToast(
            context: context,
            message: "Deleted @c histories".tlParams({
              "c": removedHistories.length,
            }),
            trailing: TextButton(
              onPressed: () {
                for (final comic in removedHistories) {
                  HistoryManager().addHistory(comic);
                }
              },
              child: Text("Undo".tl),
            ),
          );
        }
      },
    );
  }

  void _removeHistorySwipe(History comic) {
    var removed = comic;
    _removeHistory(removed);
    if (mounted) {
      showToast(
        context: context,
        message: "Deleted @c histories".tlParams({"c": 1}),
        trailing: TextButton(
          onPressed: () {
            HistoryManager().addHistory(removed);
          },
          child: Text("Undo".tl),
        ),
      );
    }
  }

  void _refreshHistory(History comic) async {
    var result = await HistoryManager().refreshHistoryInfo(comic);
    if (result) {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Success".tl);
      }
    } else {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Failed".tl);
      }
    }
  }

  void _refreshAllHistories() async {
    HistoryRefreshTaskManager.instance.startRefreshAll();
    App.rootContext.showMessage(message: "Task started".tl);
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      IconButton(
        icon: const Icon(Icons.delete),
        tooltip: "Delete".tl,
        onPressed: selectedComics.isEmpty
            ? null
            : () => _removeHistoriesWithConfirm(
                List<History>.from(selectedComics.keys),
              ),
      ),
      MenuButton(
        entries: [
          MenuEntry(
            icon: Icons.favorite_border,
            text: "Add to favorites".tl,
            onClick: () {
              if (selectedComics.isEmpty) return;
              addFavorite(List<History>.from(selectedComics.keys));
            },
          ),
          MenuEntry(
            icon: Icons.watch_later_outlined,
            text: "Read later".tl,
            onClick: () async {
              if (selectedComics.isEmpty) return;
              final picked = List<History>.from(selectedComics.keys);
              await ReadLaterManager().addComics(picked);
              setState(() {
                multiSelectMode = false;
                selectedComics.clear();
              });
              if (mounted) {
                App.rootContext.showMessage(
                  message: "Added to read later".tl,
                );
              }
            },
          ),
        ],
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.filter_alt_outlined),
        tooltip: "Filter".tl,
        color: readFilterSelect != "All" || sourceFilterSelect.isNotEmpty
            ? context.colorScheme.primaryContainer
            : null,
        onPressed: showFilterDialog,
      ),
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh All Histories'.tl,
        onPressed: _refreshAllHistories,
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: multiSelectMode ? "Exit Multi-Select".tl : "Multi-Select".tl,
        onPressed: () {
          setState(() {
            multiSelectMode = !multiSelectMode;
          });
        },
      ),
      Tooltip(
        message: 'Clear History'.tl,
        child: Flyout(
          controller: controller,
          flyoutBuilder: (context) {
            return FlyoutContent(
              title: 'Clear History'.tl,
              content: Text('Are you sure you want to clear your history?'.tl),
              actions: [
                Button.outlined(
                  onPressed: () {
                    HistoryManager().clearUnfavoritedHistory();
                    context.pop();
                  },
                  child: Text('Clear Unfavorited'.tl),
                ),
                const SizedBox(width: 4),
                Button.filled(
                  color: context.colorScheme.error,
                  onPressed: () {
                    HistoryManager().clearHistory();
                    context.pop();
                  },
                  child: Text('Clear'.tl),
                ),
              ],
            );
          },
          child: IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () {
              controller.show();
            },
          ),
        ),
      ),
    ];

    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        }
      },
      child: Scaffold(
        body: SmoothCustomScrollView(
          slivers: [
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text('History'.tl),
              actions: multiSelectMode ? selectActions : normalActions,
            ),
            if (!multiSelectMode)
              SliverToBoxAdapter(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: TextField(
                    decoration: InputDecoration(
                      icon: const Icon(Icons.search),
                      hintText: "Search".tl,
                      border: InputBorder.none,
                      suffixIcon: keyword.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                setState(() {
                                  keyword = "";
                                  searchTextController.clear();
                                });
                              },
                            ),
                    ),
                    controller: searchTextController,
                    onChanged: (value) {
                      setState(() {
                        keyword = value;
                        selectedComics.removeWhere(
                          (comic, _) => !filteredComics.contains(comic),
                        );
                      });
                    },
                  ),
                ),
              ),
            if (filteredComics.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    comics.isEmpty ? "No history".tl : "No matching history".tl,
                    style: ts.s16,
                  ),
                ),
              )
            else
              for (var entry in groupedFilteredComics.entries) ...[
                SliverToBoxAdapter(
                  child: Text(
                    entry.key.tl,
                    style: ts.s16,
                  ).paddingHorizontal(16).paddingTop(12).paddingBottom(4),
                ),
                SliverGridComics(
                  comics: entry.value,
                  selections: selectedComics,
                  onLongPressed: null,
                  swipeActionBuilder: multiSelectMode
                      ? null
                      : (c) => (
                            start: null,
                            end: SwipePane(
                              dismissOnFullSwipe: true,
                              onFullSwipe: () =>
                                  _removeHistorySwipe(c as History),
                              actions: [
                                SwipeAction(
                                  icon: Icons.delete_outline,
                                  label: 'Delete'.tl,
                                  onPressed: () =>
                                      _removeHistorySwipe(c as History),
                                ),
                              ],
                            ),
                          ),
                  onTap: multiSelectMode
                      ? (c, heroID) {
                          setState(() {
                            if (selectedComics.containsKey(c as History)) {
                              selectedComics.remove(c);
                            } else {
                              selectedComics[c] = true;
                            }
                            if (selectedComics.isEmpty) {
                              multiSelectMode = false;
                            }
                          });
                        }
                      : null,
                  badgeBuilder: (c) {
                    return ComicSource.find(c.sourceKey)?.name;
                  },
                  menuBuilder: (c) {
                    return [
                      MenuEntry(
                        icon: Icons.refresh,
                        text: 'Refresh Info'.tl,
                        onClick: () {
                          _refreshHistory(c as History);
                        },
                      ),
                      MenuEntry(
                        icon: Icons.delete_outline,
                        text: 'Remove'.tl,
                        color: context.colorScheme.error,
                        onClick: () {
                          _removeHistoriesWithConfirm([c as History]);
                        },
                      ),
                    ];
                  },
                ),
              ],
          ],
        ),
      ),
    );
  }

  String getDescription(History h) {
    var res = "";
    if (h.ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": h.ep});
    }
    if (h.page >= 1) {
      if (h.ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": h.page});
    }
    return res;
  }
}
