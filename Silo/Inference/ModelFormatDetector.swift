import Foundation

enum ModelFormat {
    case gguf
    case unknown
}

class ModelFormatDetector {
    static func detectFormat(url: URL) -> ModelFormat {
        let pathExtension = url.pathExtension.lowercased()

        if pathExtension == "gguf" {
            return .gguf
        }

        return .unknown
    }

    static func detectFormat(path: String) -> ModelFormat {
        let url = URL(fileURLWithPath: path)
        return detectFormat(url: url)
    }
}
