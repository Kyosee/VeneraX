import { ReadingWidgetItem } from '../ReadingWidgetData';

const storage = new LocalStorage();

@Entry(storage)
@Component
struct ReadingCard {
  @LocalStorageProp('kind') private kind: string = 'history';
  @LocalStorageProp('uri') private uri: string = 'venerax://reading-widget/history';
  @LocalStorageProp('title') private title: string = '';
  @LocalStorageProp('subtitle') private subtitle: string = '';
  @LocalStorageProp('emptyText') private emptyText: string = '';
  @LocalStorageProp('items') private items: ReadingWidgetItem[] = [];
  @LocalStorageProp('dimension') private dimension: number = 2;

  private open(uri: string): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: { 'venera.readingWidget.uri': uri }
    });
  }

  private titleResource(): Resource {
    switch (this.kind) {
      case 'following': return $r('app.string.reading_widget_following');
      case 'updates': return $r('app.string.reading_widget_updates');
      case 'local': return $r('app.string.reading_widget_local');
      default: return $r('app.string.reading_widget_title');
    }
  }

  @Builder
  private cover(item: ReadingWidgetItem, width: number, height: number) {
    Image(item.image.length > 0 ? item.image : $r('app.media.reading_widget_placeholder'))
      .width(width).height(height).objectFit(ImageFit.Cover).borderRadius(8)
      .backgroundColor($r('app.color.reading_widget_placeholder'))
      .accessibilityText(item.title)
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.title.length > 0 ? this.title : this.titleResource())
          .fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.reading_widget_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Text('›').fontSize(20).fontColor($r('app.color.reading_widget_secondary'))
      }.height(24).width('100%').onClick(() => this.open(this.uri))
      if (this.subtitle.length > 0) {
        Text(this.subtitle).fontSize(10).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.reading_widget_secondary')).width('100%')
      }
      if (this.items.length === 0) {
        Text(this.emptyText.length > 0 ? this.emptyText : $r('app.string.reading_widget_open'))
          .fontSize(13).fontColor($r('app.color.reading_widget_secondary'))
          .textAlign(TextAlign.Center).width('100%').layoutWeight(1)
          .onClick(() => this.open(this.uri))
      } else if (this.dimension === 2) {
        Row({ space: 8 }) {
          ForEach(this.items.slice(0, 2), (item: ReadingWidgetItem) => {
            Column({ space: 4 }) {
              Image(item.image.length > 0 ? item.image : $r('app.media.reading_widget_placeholder'))
                .width('100%').layoutWeight(1).objectFit(ImageFit.Cover).borderRadius(8)
                .backgroundColor($r('app.color.reading_widget_placeholder'))
              Text(item.title).fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor($r('app.color.reading_widget_text')).width('100%')
              Text(item.progress).fontSize(10).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor($r('app.color.reading_widget_secondary')).width('100%')
            }.layoutWeight(1).height('100%').onClick(() => this.open(item.uri))
            .accessibilityText(`${item.title}, ${item.progress}`)
          }, (item: ReadingWidgetItem) => item.uri)
        }.width('100%').layoutWeight(1)
      } else {
        Column({ space: 6 }) {
          ForEach(this.items.slice(0, this.dimension === 4 ? 4 : 2), (item: ReadingWidgetItem) => {
            Row({ space: 10 }) {
              this.cover(item, 34, 46)
              Column({ space: 4 }) {
                Text(item.title).fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor($r('app.color.reading_widget_text')).width('100%')
                Text(item.progress).fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor($r('app.color.reading_widget_secondary')).width('100%')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').layoutWeight(1).onClick(() => this.open(item.uri))
            .accessibilityText(`${item.title}, ${item.progress}`)
          }, (item: ReadingWidgetItem) => item.uri)
        }.width('100%').layoutWeight(1)
      }
    }.padding(12).width('100%').height('100%')
    .backgroundColor($r('app.color.reading_widget_background')).borderRadius(16)
  }
}
