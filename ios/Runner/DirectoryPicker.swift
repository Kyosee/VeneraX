import UIKit
import Flutter

class DirectoryPicker: NSObject, UIDocumentPickerDelegate {
    private var result: FlutterResult?

    // 初始化选择目录方法
    func selectDirectory(
        result: @escaping FlutterResult,
        presenter: UIViewController?
    ) {
        self.result = result

        // 配置 UIDocumentPicker 为目录选择模式
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false

        if let presenter {
            presenter.present(documentPicker, animated: true, completion: nil)
        } else {
            result(nil)
            self.result = nil
        }
    }

    // 处理选择完成后的结果
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // 获取选中的路径
        if let url = urls.first {
            result?(url.path)
        } else {
            result?(nil)
        }
    }

    // 处理取消选择情况
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        result?(nil)
    }
}
