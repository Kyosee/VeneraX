# 漫画翻译模型与许可

下表中的模型权重均在安装 VeneraX 后按需下载。在「设置 → AI 翻译 → 翻译模型」中选择文件，应用会从对应的发布源或所选镜像下载，在设备上运行。默认消字直接处理像素，无需额外下载修复模型。「仅对白」可以使用内置规则，也可以下载 RT-DETR 增强对白识别。翻译用的第三方服务由用户另行配置，其服务条款、费用及对所提交文字的处理规则由服务提供方说明。[使用指南](guide.zh.md) · [English](model-notices.en.md)

## 下载文件和来源

| 用途 | 文件与发布者 |
| --- | --- |
| 默认文字检测 | PaddleOCR 的 PP-OCRv4 移动检测器，由 SWHL/RapidOCR 提供 ONNX 文件 `ch_PP-OCRv4_det_infer.onnx`。[发布文件](https://huggingface.co/SWHL/RapidOCR/tree/main/PP-OCRv4) |
| 简体中文与拉丁字母、英语、韩语识别 | SWHL/RapidOCR 分别提供 `ch_PP-OCRv4_rec_infer.onnx`、`en_PP-OCRv3_rec_infer.onnx`、`korean_mobile_v2.0_rec_infer.onnx`。韩语 v2.0 文件位于发布库的 `PP-OCRv1` 目录。三份字典取自 PaddleOCR v2.7.0，应用按文件配置从 jsDelivr 或 GitHub 获取。[ONNX 文件](https://huggingface.co/SWHL/RapidOCR/tree/main) · [中文字典](https://github.com/PaddlePaddle/PaddleOCR/blob/v2.7.0/ppocr/utils/ppocr_keys_v1.txt) · [英文](https://github.com/PaddlePaddle/PaddleOCR/blob/v2.7.0/ppocr/utils/en_dict.txt) · [韩文](https://github.com/PaddlePaddle/PaddleOCR/blob/v2.7.0/ppocr/utils/dict/korean_dict.txt) |
| 简繁中文识别 | PP-OCRv5 移动识别器及配套字典优先来自 ModelScope 的 RapidAI/RapidOCR。备用来源 webnn/PP-OCRv5-ONNX 发布 `ch_PP-OCRv5_rec.onnx` 和 `ch_PP-OCRv5_dict.txt`。两个发布库均标示 Apache-2.0。[RapidAI 文件目录](https://modelscope.cn/models/RapidAI/RapidOCR/files) · [webnn 模型卡及文件](https://huggingface.co/webnn/PP-OCRv5-ONNX/tree/main) |
| 日语漫画识别 | mayocream 提供 `encoder_model.onnx`、`decoder_model.onnx` 和词表 `vocab.txt`。原模型为 kha-white/manga-ocr-base。原权重和 ONNX 导出库的模型卡均标示 Apache-2.0。[原模型](https://huggingface.co/kha-white/manga-ocr-base) · [ONNX 与词表](https://huggingface.co/mayocream/manga-ocr-onnx/tree/main) |
| 可选识别语言与检测预设 | RapidAI/RapidOCR 在 ModelScope 提供三个 PP-OCRv5 移动识别预设，分别为拉丁字母（`latin`）、西里尔字母（`cyrillic`）和泰文（`th`）。每项配套同名 `ppocrv5_<代号>_dict.txt`。两个检测预设为 `ch_PP-OCRv5_det_mobile.onnx` 和 `PP-OCRv6_det_small.onnx`。[RapidAI 文件目录](https://modelscope.cn/models/RapidAI/RapidOCR/files) · [应用预设配置](https://github.com/Kyosee/VeneraX/blob/master/lib/pages/settings/translation_languages_settings.dart) |
| 可选对白识别 | ogkalu（Comic Translate 作者）的 `detector-v4-s_int8.onnx`，固定修订 `16e8a622f91fabc6b5b65c96d32d1183f8843546`。该修订的模型卡标示 Apache-2.0，文件列表列出了这个 INT8 导出。关闭增强会保留文件。「全部文字」跳过该模型。[固定模型卡](https://huggingface.co/ogkalu/comic-text-and-bubble-detector/blob/16e8a622f91fabc6b5b65c96d32d1183f8843546/README.md) · [固定权重](https://huggingface.co/ogkalu/comic-text-and-bubble-detector/blob/16e8a622f91fabc6b5b65c96d32d1183f8843546/detector-v4-s_int8.onnx) |

Hugging Face 默认使用其官方站点。选择 `hf-mirror.com` 会切换使用该下载端点的请求。ModelScope、字典 CDN 等地址仍按文件配置执行。自行填写检测模型 URL，或识别模型和字典 URL 时，应查看各文件发布者提供的许可。大部分 OCR 权重和词表跟随发布库的 `main` 或 `master`，重新下载时可能取得更新版本。[应用下载配置](https://github.com/Kyosee/VeneraX/blob/master/lib/foundation/image_translation/translation_models.dart)

## 许可、训练数据与再分发

- **模型与字典。** RapidOCR 的「Models」声明将原始 PaddleOCR 权重的版权归于百度及相应 PaddleOCR 权利人，说明其发布的相关 ONNX 转换沿用 Apache-2.0。PaddleOCR v2.7.0 仓库附 Apache-2.0。其他导出文件的许可依据见上表各发布者的模型卡。下载某个模型并不会取得其训练图像、漫画、字体或语料的版权。[RapidOCR 模型声明](https://github.com/RapidAI/RapidOCR#models) · [PaddleOCR v2.7.0 许可](https://github.com/PaddlePaddle/PaddleOCR/blob/v2.7.0/LICENSE)
- **日语模型的训练数据致谢。** Manga OCR 作者列出 Manga109-s 和 CC-100。Manga109-s 的使用条款允许商业使用实验结果，要求发表基于该数据集的研究结果（包括预训练模型）时注明使用了 Manga109-s，并禁止再分发数据集本身。CC-100 的发布方说明语料来自 Common Crawl，请使用者引用页面列出的研究论文。VeneraX 下载的是识别模型与词表。[作者致谢](https://github.com/kha-white/manga-ocr#acknowledgments) · [Manga109-s 使用条款](https://huggingface.co/datasets/hal-utokyo/Manga109-s) · [CC-100 发布说明](https://data.statmt.org/cc-100/)
- **复制或重新发布。** VeneraX 应用代码使用 GNU GPLv3。将 Apache-2.0 覆盖的文件打包、镜像或随修改版分发时，应依第 4 节向接收方提供完整许可证副本，给改动过的文件加上明显的修改声明，在分发的衍生作品源码中保留适用的版权、专利、商标及署名声明，并传递上游 `NOTICE` 中适用的署名（如有）。下载来源链接方便核对，实际分发应携带相应材料。[VeneraX 许可](https://github.com/Kyosee/VeneraX/blob/master/LICENSE) · [Apache-2.0 全文及第 4 节](https://www.apache.org/licenses/LICENSE-2.0)
