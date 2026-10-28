part of '../tasks_page.dart';

mixin _PreTranslationTaskCard on _TaskCardCommon {
  PreTranslationTaskManager get preTranslationManager;

  String preTranslateStatusText(PreTranslationTask task) {
    return switch (task.status) {
      PreTranslationTaskStatus.running => "Running".tl,
      PreTranslationTaskStatus.paused => "Paused".tl,
      PreTranslationTaskStatus.completed => "Completed".tl,
      PreTranslationTaskStatus.canceled => "Canceled".tl,
      PreTranslationTaskStatus.failed => "Failed".tl,
    };
  }

  Widget? _buildPreTranslateTrailing(PreTranslationTask task) {
    // Running and paused jobs can both be canceled; use compact icon buttons so
    // pause/resume + cancel fit the ExpansionTile trailing without overflow.
    switch (task.status) {
      case PreTranslationTaskStatus.running:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: "Pause".tl,
              icon: const Icon(Icons.pause),
              onPressed: () => preTranslationManager.pause(task.id),
            ),
            IconButton(
              tooltip: "Cancel".tl,
              icon: const Icon(Icons.close),
              onPressed: () => preTranslationManager.cancel(task.id),
            ),
          ],
        );
      case PreTranslationTaskStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: "Resume".tl,
              icon: const Icon(Icons.play_arrow),
              onPressed: () => preTranslationManager.resume(task.id),
            ),
            IconButton(
              tooltip: "Cancel".tl,
              icon: const Icon(Icons.close),
              onPressed: () => preTranslationManager.cancel(task.id),
            ),
          ],
        );
      default:
        // Finished/canceled/failed jobs live in history. Offer a retry when
        // some pages failed — it re-runs only those, not the whole job.
        if (task.hasFailures) {
          return IconButton(
            tooltip: "Retry failed pages".tl,
            icon: const Icon(Icons.refresh),
            onPressed: () => preTranslationManager.retryFailed(task.id),
          );
        }
        return null;
    }
  }

  /// Label for one live pipeline phase. Shown in place of "Running" because
  /// the committed page count only moves when a whole group lands, so the
  /// phase is the only thing that tells a stalled job from a working one.
  String translationStageText(TranslationStage stage) => switch (stage) {
    TranslationStage.fetching => "Downloading images".tl,
    TranslationStage.loadingModel => "Loading recognition model".tl,
    TranslationStage.recognizing => "Recognizing text".tl,
    TranslationStage.translating => "Translating".tl,
    TranslationStage.rendering => "Rendering pages".tl,
  };

  /// "Recognizing text ×2 · Translating ×1" — one entry per phase that has a
  /// live group, so concurrent groups read as parallel work instead of making
  /// the single phase label flicker between them.
  String translationStageBreakdown(PreTranslationActivity activity) {
    var counts = activity.stageCounts;
    return [
      for (var stage in TranslationStage.values)
        if (counts[stage] != null)
          counts[stage]! > 1
              ? '${translationStageText(stage)} ×${counts[stage]}'
              : translationStageText(stage),
    ].join(' · ');
  }

  Widget buildPreTranslateTaskCard(
    PreTranslationTask task, {
    required bool expanded,
  }) {
    var activity = task.isRunning
        ? preTranslationManager.activityOf(task.id)
        : null;
    var stage = activity?.headStage;
    var progress = activity?.liveProgress(task) ?? task.progress;
    // Committed counters lag by design (they double as the resume cursor), so
    // the card reports the live figures a running job's activity carries.
    var failedPages = activity?.liveFailed(task) ?? task.failed;
    // Pages the job is finished with, matching what the percentage counts. A
    // failed page must still move this number, otherwise the counter sits
    // still while the bar advances and the card reads as stuck.
    var processedPages =
        activity?.liveProcessed(task) ?? (task.done + task.failed);
    var progressText = task.total == 0
        ? "0%"
        : "${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: _TaskExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('pre_translate', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
getTaskTitle('pre_translate', {'title': task.title}),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [
            stage == null
                ? preTranslateStatusText(task)
                : translationStageText(stage),
            "@count chapters".tlParams({'count': task.chapters.length}),
            progressText,
          ],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: _buildPreTranslateTrailing(task),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning && task.total == 0 ? null : progress,
            ),
          ),
          const SizedBox(height: 8),
          buildSourceBox(
            title: "Details".tl,
            titleTrailing: TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => context.to(
                () => ComicPage(
                  id: task.cid,
                  sourceKey: task.sourceKey,
                  title: task.title,
                ),
              ),
              icon: const Icon(Icons.chrome_reader_mode_outlined, size: 16),
              label: Text("View Detail".tl, style: ts.s12),
            ),
            children: [
              if (activity != null && activity.chapterIndex > 0) ...[
                Text(
                  activity.chapterTitle.isEmpty
                      ? "Chapter @index/@total".tlParams({
                          'index': activity.chapterIndex,
                          'total': task.chapters.length,
                        })
                      : "Chapter @index/@total: @title".tlParams({
                          'index': activity.chapterIndex,
                          'total': task.chapters.length,
                          'title': activity.chapterTitle,
                        }),
                  style: ts.s14,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
              ],
              if (activity != null && activity.groups.isNotEmpty) ...[
                Text(
                  "In progress: @detail".tlParams({
                    'detail': translationStageBreakdown(activity),
                  }),
                  style: ts.s14,
                ),
                const SizedBox(height: 2),
              ],
              Text(
                "Pages: @processed/@total".tlParams({
                  'processed': processedPages,
                  'total': task.total,
                }),
                style: ts.s14,
              ),
              if (failedPages > 0) ...[
                const SizedBox(height: 2),
                Text(
                  "Failed: @count".tlParams({'count': failedPages}),
                  style: ts.s14.withColor(context.colorScheme.error),
                ),
              ],
            ],
          ),
        ],
      ),
    );

    return _wrapHistoryCard(card, 'pre_translate', task.id, task.isRunning);
  }
}
