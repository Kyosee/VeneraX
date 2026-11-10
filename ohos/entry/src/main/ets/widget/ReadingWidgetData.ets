export class ReadingWidgetItem {
  id: string = '';
  type: number = 0;
  title: string = '';
  progress: string = '';
  sourceName: string = '';
  badge: string = '';
  pageProgress: number = -1;
  coverPath: string = '';
  uri: string = '';
  image: string = '';
}

export class ReadingWidgetData {
  kind: string = 'history';
  locked: boolean = false;
  title: string = '';
  subtitle: string = '';
  emptyText: string = '';
  uri: string = 'venerax://reading-widget/history';
  items: ReadingWidgetItem[] = [];
  dimension: number = 2;
  formImages: Record<string, number> = {};
}

export function isReadingWidgetKind(kind: string): boolean {
  return ['history', 'following', 'updates', 'local'].includes(kind);
}

export function parseReadingWidgetData(json: string): ReadingWidgetData {
  const parsed = JSON.parse(json) as ReadingWidgetData;
  if (parsed === null || typeof parsed !== 'object' || !Array.isArray(parsed.items)) {
    throw new Error('Invalid reading widget snapshot');
  }
  const result = new ReadingWidgetData();
  if (typeof parsed.kind !== 'string' || !isReadingWidgetKind(parsed.kind)) {
    throw new Error('Unknown reading widget kind');
  }
  result.kind = parsed.kind;
  result.locked = parsed.locked === true;
  result.uri = `venerax://reading-widget/${result.kind}`;
  result.title = typeof parsed.title === 'string' ? parsed.title : '';
  result.subtitle = typeof parsed.subtitle === 'string' ? parsed.subtitle : '';
  result.emptyText = typeof parsed.emptyText === 'string' ? parsed.emptyText : '';
  if (result.locked) return result;
  // API 17 supports at most five transferred images. Four rows fit a 4x4 card.
  parsed.items.slice(0, 4).forEach((item: ReadingWidgetItem) => {
    if (item === null || typeof item !== 'object' || typeof item.id !== 'string' ||
      item.id.length === 0 || typeof item.type !== 'number' || !Number.isSafeInteger(item.type) ||
      typeof item.title !== 'string') return;
    const entry = new ReadingWidgetItem();
    entry.id = item.id;
    entry.type = item.type;
    entry.title = item.title;
    entry.progress = typeof item.progress === 'string' ? item.progress : '';
    entry.sourceName = typeof item.sourceName === 'string' ? item.sourceName : '';
    entry.badge = typeof item.badge === 'string' ? item.badge : '';
    entry.pageProgress = typeof item.pageProgress === 'number' && Number.isFinite(item.pageProgress) && item.pageProgress >= 0
      ? Math.min(100, Math.round(item.pageProgress)) : -1;
    entry.coverPath = typeof item.coverPath === 'string' ? item.coverPath : '';
    const path = result.kind === 'history' ? 'read' : `${result.kind}/read`;
    entry.uri = `venerax://reading-widget/${path}?id=${encodeURIComponent(item.id)}&type=${item.type}`;
    result.items.push(entry);
  });
  return result;
}
