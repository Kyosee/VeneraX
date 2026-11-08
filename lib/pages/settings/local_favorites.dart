part of 'settings_page.dart';

class LocalFavoritesSettings extends StatefulWidget {
  const LocalFavoritesSettings({super.key, this.section});

  final String? section;

  @override
  State<LocalFavoritesSettings> createState() => _LocalFavoritesSettingsState();
}

class _LocalFavoritesSettingsState extends State<LocalFavoritesSettings> {
  Future<void> _openSection(String section) async {
    await context.to(() => LocalFavoritesSettings(section: section));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsPageView(
      title: 'Library & favorites',
      description:
          'Choose how favorites open and how your library is organized',
      section:
          widget.section ??
          _settingsSectionForTitle(2, _SettingsJumpScope.targetOf(context)),
      onOpenSection: _openSection,
      sections: [
        _SettingsSection(
          title: 'Favorite actions',
          common: true,
          children: [
            SelectSetting(
              title: "Click favorite".tl,
              settingKey: "onClickFavorite",
              optionTranslation: {
                "viewDetail": "View Detail".tl,
                "read": "Read".tl,
              },
            ),
            SelectSetting(
              title: "Quick Favorite".tl,
              settingKey: "quickFavorite",
              help:
                  "Long press on the favorite button to quickly add to this folder"
                      .tl,
              optionTranslation: {
                for (var e in LocalFavoritesManager().folderNames)
                  e: LocalFavoritesManager().folderTree.pathLabel(e),
              },
            ),
            _SwitchSetting(
              title: "Auto close favorite panel after operation".tl,
              settingKey: "autoCloseFavoritePanel",
            ),
            _SettingsLink(
              title: 'Follow Updates Settings',
              icon: Icons.update,
              onTap: () => FollowUpdatesPage.openSettings(context),
            ),
          ],
        ),
        _SettingsSection(
          title: 'Sorting and placement',
          subtitle: 'Favorite order and placement',
          icon: Icons.sort,
          children: [
            _SwitchSetting(
              title: "Show local favorites before network favorites".tl,
              settingKey: "localFavoritesFirst",
            ),
            SelectSetting(
              title: "Add new favorite to".tl,
              settingKey: "newFavoriteAddTo",
              optionTranslation: {"start": "Start".tl, "end": "End".tl},
            ),
            SelectSetting(
              title: "Move favorite after reading".tl,
              settingKey: "moveFavoriteAfterRead",
              optionTranslation: {
                "none": "None".tl,
                "end": "End".tl,
                "start": "Start".tl,
              },
            ),
          ],
        ),
        _SettingsSection(
          title: 'Library maintenance',
          subtitle: 'Clean up unavailable favorites',
          icon: Icons.cleaning_services_outlined,
          children: [
            _CallbackSetting(
              title: "Delete all unavailable local favorite items".tl,
              callback: () async {
                var controller = showLoadingDialog(context);
                var count = await LocalFavoritesManager().removeInvalid();
                controller.close();
                context.showMessage(
                  message: "Deleted @a favorite items".tlParams({'a': count}),
                );
              },
              actionTitle: 'Delete'.tl,
            ),
          ],
        ),
      ],
    );
  }
}
