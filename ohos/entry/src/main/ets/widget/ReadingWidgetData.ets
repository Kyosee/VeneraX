export class ReadingWidgetItem {
  id: string = '';
  type: number = 0;
  title: string = '';
  progress: string = '';
  coverPath: string = '';
  uri: string = '';
  image: string = '';
}

export class ReadingWidgetData {
  title: string = '';
  emptyText: string = '';
  items: ReadingWidgetItem[] = [];
  dimension: number = 2;
  formImages: Record<string, number> = {};
}

export function parseReadingWidgetData(json: string): ReadingWidgetData {
  const parsed = JSON.parse(json) as ReadingWidgetData;
  if (parsed === null || typeof parsed !== 'object' || !Array.isArray(parsed.items)) {
    throw new Error('Invalid reading widget snapshot');
  }
  const result = new ReadingWidgetData();
  result.title = typeof parsed.title === 'string' ? parsed.title : '';
  result.emptyText = typeof parsed.emptyText === 'string' ? parsed.emptyText : '';
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
    entry.coverPath = typeof item.coverPath === 'string' ? item.coverPath : '';
    entry.uri = `venerax://reading-widget/read?id=${encodeURIComponent(item.id)}&type=${item.type}`;
    result.items.push(entry);
  });
  return result;
}
