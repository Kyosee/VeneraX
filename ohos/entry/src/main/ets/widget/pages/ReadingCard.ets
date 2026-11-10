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

  private iconResource(): Resource {
    switch (this.kind) {
      case 'following': return $r('app.media.reading_widget_following');
      case 'updates': return $r('app.media.reading_widget_updates');
      case 'local': return $r('app.media.reading_widget_local');
      default: return $r('app.media.reading_widget_history');
    }
  }

  @Builder
  private progress(item: ReadingWidgetItem) {
    Text(item.progress).fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      .fontColor($r('app.color.reading_widget_secondary')).width('100%')
    if (item.pageProgress >= 0 && this.dimension !== 3) {
      Progress({ value: item.pageProgress, total: 100, type: ProgressType.Linear })
        .color($r('app.color.reading_widget_accent'))
        .backgroundColor($r('app.color.reading_widget_placeholder'))
        .style({ strokeWidth: 3 }).width('100%').height(3)
    }
  }

  @Builder
  private bookTitle(item: ReadingWidgetItem, compact: boolean) {
    Column({ space: 4 }) {
      Text(item.title).fontSize(compact ? 13 : 14).fontWeight(FontWeight.Medium)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor($r('app.color.reading_widget_text')).width('100%')
      if (item.badge.length > 0) {
        Text(item.badge).fontSize(10).fontWeight(FontWeight.Medium).maxLines(1)
          .fontColor($r('app.color.reading_widget_badge'))
      } else if (item.sourceName.length > 0) {
        Text(item.sourceName).fontSize(10).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.reading_widget_secondary')).width('100%')
      }
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
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
      Row({ space: 6 }) {
        Image(this.iconResource()).width(16).height(16)
          .fillColor($r('app.color.reading_widget_accent')).accessibilityLevel('no')
        Text(this.title.length > 0 ? this.title : this.titleResource())
          .fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.reading_widget_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Text('›').fontSize(20).fontColor($r('app.color.reading_widget_secondary'))
      }.height(24).width('100%').onClick(() => this.open(this.uri))
      if (this.items.length === 0) {
        Column({ space: 10 }) {
          Image(this.iconResource()).width(32).height(32)
            .fillColor($r('app.color.reading_widget_accent')).accessibilityLevel('no')
          Text(this.emptyText.length > 0 ? this.emptyText : $r('app.string.reading_widget_open'))
            .fontSize(12).fontColor($r('app.color.reading_widget_secondary'))
            .textAlign(TextAlign.Center).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.justifyContent(FlexAlign.Center).width('100%').layoutWeight(1)
        .onClick(() => this.open(this.uri))
      } else if (this.dimension === 2) {
        Column({ space: 6 }) {
          Row({ space: 10 }) {
            this.cover(this.items[0], 52, 76)
            this.bookTitle(this.items[0], true)
          }.width('100%').layoutWeight(1)
          this.progress(this.items[0])
        }.width('100%').layoutWeight(1).onClick(() => this.open(this.items[0].uri))
        .accessibilityText(`${this.items[0].title}, ${this.items[0].progress}, ${this.items[0].sourceName}`)
      } else {
        Column({ space: 6 }) {
          ForEach(this.items.slice(0, this.dimension === 4 ? 4 : 2), (item: ReadingWidgetItem) => {
            Row({ space: 10 }) {
              this.cover(item, this.dimension === 3 ? 28 : 40, this.dimension === 3 ? 40 : 58)
              Column({ space: 4 }) {
                Text(item.title).fontSize(13).fontWeight(FontWeight.Medium).maxLines(this.dimension === 3 ? 1 : 2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor($r('app.color.reading_widget_text')).width('100%')
                this.progress(item)
                if (item.badge.length > 0 && this.dimension !== 3) {
                  Text(item.badge).fontSize(10).fontColor($r('app.color.reading_widget_badge')).maxLines(1)
                }
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').layoutWeight(1).onClick(() => this.open(item.uri))
            .accessibilityText(`${item.title}, ${item.progress}, ${item.sourceName}`)
          }, (item: ReadingWidgetItem) => item.uri)
        }.width('100%').layoutWeight(1)
      }
      if (this.subtitle.length > 0 && this.dimension === 4) {
        Text(this.subtitle).fontSize(10).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.reading_widget_secondary')).width('100%')
      }
    }.padding(12).width('100%').height('100%')
    .backgroundColor($r('app.color.reading_widget_background')).borderRadius(16)
  }
}
