
import common from '@ohos.app.ability.common';
import { FlutterPage } from '@ohos/flutter_ohos'
import { LauncherIconService } from '../bridge/LauncherIconService';

let storage = LocalStorage.getShared()
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'

@Component
struct StartupSplash {
  @State private icon: Resource | undefined = undefined;
  private visible = false;

  aboutToAppear(): void {
    this.visible = true;
    LauncherIconService.getStartupIcon().then((icon: Resource | undefined): void => {
      if (this.visible) this.icon = icon;
    });
  }

  aboutToDisappear(): void {
    this.visible = false;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.icon !== undefined) {
        Image(this.icon)
          .width(96)
          .height(96)
          .objectFit(ImageFit.Contain)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.start_window_background'))
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
      FlutterPage({ viewId: this.viewId, splashScreenView: startupSplash })
    }
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}
