import { pdfService } from '@kit.PDFKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MethodCall, MethodCallHandler, MethodResult } from '@ohos/flutter_ohos';

export class PdfService implements MethodCallHandler {
  private documents = new Map<number, pdfService.PdfDocument>();
  private rendering = new Set<number>();
  private closing = new Set<number>();
  private nextId = 1;
  private disposed = false;

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.handle(call, result).catch((error: BusinessError) => {
      result.error('PDF_ERROR', error.message, null);
    });
  }

  private async handle(call: MethodCall, result: MethodResult): Promise<void> {
    if (this.disposed) throw new Error('PDF services have been disposed.');
    if (call.method === 'open') {
      if (!canIUse('SystemCapability.OfficeService.PDFService.Core')) {
        result.error('PDF_UNAVAILABLE',
          'Official PDF Kit is unavailable on this device. The x86 emulator is unsupported; use an ARM emulator or a real device.', null);
        return;
      }
      const path = call.argument('path') as string;
      let document: pdfService.PdfDocument;
      try {
        document = new pdfService.PdfDocument();
      } catch (_) {
        result.error('PDF_UNAVAILABLE', 'The official PDF Kit module is unavailable on this device.', null);
        return;
      }
      try {
        const status = document.loadDocument(path);
        if (status !== pdfService.ParseResult.PARSE_SUCCESS) {
          throw new Error(`PDF parse failed (${status}).`);
        }
        const pages = document.getPageCount();
        if (pages < 1) throw new Error('PDF has no pages.');
        const id = this.nextId++;
        this.documents.set(id, document);
        result.success(new Map<string, number>([['id', id], ['pages', pages]]));
      } catch (error) {
        document.releaseDocument();
        throw new Error((error as BusinessError).message);
      }
      return;
    }
    const id = call.argument('id') as number;
    const document = this.documents.get(id);
    if (document === undefined || this.closing.has(id)) throw new Error('PDF document is closed.');
    if (call.method === 'close') {
      this.closeDocument(id, document);
      result.success(null);
    } else if (call.method === 'render') {
      if (this.rendering.has(id)) throw new Error('PDF rendering is already in progress.');
      const index = call.argument('index') as number;
      if (!Number.isInteger(index) || index < 0 || index >= document.getPageCount()) {
        throw new Error('Invalid PDF page index.');
      }
      this.rendering.add(id);
      let bytes: ArrayBuffer;
      try {
        const page = document.getPage(index);
        try {
          const pageWidth = page.getWidth();
          const pageHeight = page.getHeight();
          if (!Number.isFinite(pageWidth) || !Number.isFinite(pageHeight) || pageWidth <= 0 || pageHeight <= 0) {
            throw new Error('Invalid PDF page size.');
          }
          const scale = Math.min(2, 2400 / Math.max(pageWidth, pageHeight));
          const width = Math.max(1, Math.round(pageWidth * scale));
          const height = Math.max(1, Math.round(pageHeight * scale));
          const matrix = new pdfService.PdfMatrix();
          matrix.x = 0;
          matrix.y = 0;
          matrix.width = width;
          matrix.height = height;
          matrix.rotate = 0;
          const pixels = page.getAreaPixelMap(matrix, width, height, false, true);
          try {
            const packer = image.createImagePacker();
            try {
              bytes = await packer.packToData(pixels, { format: 'image/png', quality: 100 });
            } finally {
              await packer.release();
            }
          } finally {
            await pixels.release();
          }
        } finally {
          page.release();
        }
      } finally {
        this.rendering.delete(id);
        if (this.closing.has(id)) this.closeDocument(id, document);
      }
      if (this.disposed) throw new Error('PDF services have been disposed.');
      result.success(new Uint8Array(bytes));
    } else {
      result.notImplemented();
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.documents.forEach((document: pdfService.PdfDocument, id: number) => {
      try {
        this.closeDocument(id, document);
      } catch (_) {
        console.warn('Venera: releasing a PDF document failed.');
      }
    });
  }

  private closeDocument(id: number, document: pdfService.PdfDocument): void {
    if (this.rendering.has(id)) {
      // Keep the document alive until the active page and image cleanup finish.
      this.closing.add(id);
      return;
    }
    this.closing.delete(id);
    this.documents.delete(id);
    document.releaseDocument();
  }
}
