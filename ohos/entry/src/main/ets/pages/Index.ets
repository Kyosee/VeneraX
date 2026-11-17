
import common from '@ohos.app.ability.common';
import { FlutterPage } from '@ohos/flutter_ohos'
import { LauncherIconService } from '../bridge/LauncherIconService';
import { StartupTheme } from '../bridge/StartupTheme';

let storage = LocalStorage.getShared()
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'
// The system start window drew the icon at its own 512 px, whatever the
// screen density; the launcher rounds icon corners by about a fifth.
const STARTUP_ICON_PX = 512
const STARTUP_ICON_CORNER = 0.2

@Component
struct StartupSplash {
  @State private icon: Resource | undefined = undefined;
  @StorageLink('veneraThemeMode') private themeMode: string = 'system';
  private visible = false;

  aboutToAppear(): void {
    StartupTheme.restore(getContext(this) as common.UIAbilityContext);
    this.visible = true;
    LauncherIconService.getStartupIcon().then((icon: Resource | undefined): void => {
      if (this.visible) this.icon = icon;
    });
  }

  aboutToDisappear(): void {
    this.visible = false;
  }

  private iconSize(): number {
    return this.getUIContext().px2vp(STARTUP_ICON_PX);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.icon !== undefined) {
        Image(this.icon)
          .width(this.iconSize())
          .height(this.iconSize())
          .objectFit(ImageFit.Contain)
          .borderRadius(this.iconSize() * STARTUP_ICON_CORNER)
          .clip(true)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(StartupTheme.background(this.themeMode))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

@Builder
function startupSplash() {
  StartupSplash()
}

@Entry(storage)
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext
  @LocalStorageLink('viewId') viewId: string = "";

  build() {
    Column() {
      FlutterPage({
        viewId: this.viewId,
        splashScreenView: startupSplash,
        // Keep the previous surface frame proportional during window resizing.
        xComponentRenderFit: RenderFit.RESIZE_CONTAIN
      })
    }
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}
