import SwiftUI

extension KeptIcon {
    // The packaged app puts resources in Contents/Resources. SwiftPM also supports loose binaries.
    private static let resources = Bundle.main.url(forResource: "Kept_Kept", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? .module

    private static let templates: [Self: NSImage] = {
        Dictionary(uniqueKeysWithValues: allCases.compactMap { icon in
            guard let url = resources.url(forResource: icon.rawValue, withExtension: "svg", subdirectory: "Icons"),
                  let image = NSImage(contentsOf: url) else {
                assertionFailure("Missing Phosphor icon \(icon.rawValue)")
                return nil
            }
            image.isTemplate = true
            return (icon, image)
        })
    }()

    func image(size: CGFloat = 16) -> Image {
        guard let image = Self.templates[self]?.copy() as? NSImage else {
            return Image(nsImage: NSImage(size: NSSize(width: size, height: size)))
        }
        image.size = NSSize(width: size, height: size)
        return Image(nsImage: image).renderingMode(.template)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, icon: KeptIcon, size: CGFloat = 16) {
        self.init { Text(title) } icon: { icon.image(size: size) }
    }
}
