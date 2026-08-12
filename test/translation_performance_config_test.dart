import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';

void main() {
  test('unknown and old settings default to balanced', () {
    expect(
      TranslationPerformanceConfig.fromSetting(null),
      TranslationPerformancePreset.balanced,
    );
    expect(
      TranslationPerformanceConfig.fromSetting('old-value'),
      TranslationPerformancePreset.balanced,
    );
  });

  test('mobile presets stay below desktop concurrency', () {
    var mobile = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.fast,
      isDesktop: false,
    );
    var desktop = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.fast,
      isDesktop: true,
    );
    expect(mobile.ocrWorkers, 2);
    expect(mobile.imageConcurrency, lessThan(desktop.imageConcurrency));
    expect(mobile.llmConcurrency, lessThan(desktop.llmConcurrency));
  });

  test('saver uses one unit of every resource', () {
    var values = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.saver,
      isDesktop: false,
    );
    expect(values.batchPages, 1);
    expect(values.ocrWorkers, 1);
    expect(values.imageConcurrency, 1);
    expect(values.llmConcurrency, 1);
  });

  test('mobile presets stay within mobile-safe ceilings', () {
    for (var preset in [
      TranslationPerformancePreset.saver,
      TranslationPerformancePreset.balanced,
      TranslationPerformancePreset.fast,
    ]) {
      var values = TranslationPerformanceConfig.valuesFor(
        preset,
        isDesktop: false,
      );
      expect(values.batchPages, lessThanOrEqualTo(8));
      expect(values.ocrWorkers, lessThanOrEqualTo(2));
      expect(values.imageConcurrency, lessThanOrEqualTo(3));
      expect(values.llmConcurrency, lessThanOrEqualTo(3));
    }
  });

  test('mobile custom values clamp desktop-sized synced settings', () {
    var oldBatch = appdata.settings['imageTranslationPreBatchPages'];
    var oldOcr = appdata.settings['imageTranslationOcrWorkers'];
    var oldImage = appdata.settings['imageTranslationImageConcurrency'];
    var oldLlm = appdata.settings['imageTranslationLlmConcurrency'];
    addTearDown(() {
      appdata.settings['imageTranslationPreBatchPages'] = oldBatch;
      appdata.settings['imageTranslationOcrWorkers'] = oldOcr;
      appdata.settings['imageTranslationImageConcurrency'] = oldImage;
      appdata.settings['imageTranslationLlmConcurrency'] = oldLlm;
    });
    appdata.settings['imageTranslationPreBatchPages'] = 20;
    appdata.settings['imageTranslationOcrWorkers'] = 6;
    appdata.settings['imageTranslationImageConcurrency'] = 6;
    appdata.settings['imageTranslationLlmConcurrency'] = 4;

    var values = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.custom,
      isDesktop: false,
    );
    expect(values.batchPages, 8);
    expect(values.ocrWorkers, 2);
    expect(values.imageConcurrency, 3);
    expect(values.llmConcurrency, 3);
  });

  test('mobile Japanese pipeline keeps one group in flight', () {
    var performance = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.fast,
      isDesktop: false,
    );
    expect(
      PreTranslationTaskManager.pipelineConcurrencyFor(
        performance,
        isMobile: true,
        sourceLang: 'ja',
        hasJapaneseModel: true,
      ),
      1,
    );
    expect(
      PreTranslationTaskManager.pipelineConcurrencyFor(
        performance,
        isMobile: true,
        sourceLang: 'auto',
        hasJapaneseModel: true,
      ),
      1,
    );
  });

  test('desktop pipeline follows LLM concurrency', () {
    var performance = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.fast,
      isDesktop: true,
    );
    expect(
      PreTranslationTaskManager.pipelineConcurrencyFor(
        performance,
        isMobile: false,
        sourceLang: 'ja',
        hasJapaneseModel: true,
      ),
      performance.llmConcurrency,
    );
  });

  test('performance tuning is excluded from cross-device sync', () {
    var disabled = Appdata.syncDisabledFields(const []);
    expect(disabled, contains(TranslationPerformanceConfig.settingKey));
    expect(disabled, contains('imageTranslationPreBatchPages'));
    expect(disabled, contains('imageTranslationOcrWorkers'));
    expect(disabled, contains('imageTranslationImageConcurrency'));
    expect(disabled, contains('imageTranslationLlmConcurrency'));
  });
}
