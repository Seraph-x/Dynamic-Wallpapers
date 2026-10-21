import SwiftUI

struct HelpCommand: Commands {
    @ObservedObject var model: AppModel
    let product: ProductBundleMetadata

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(model.localizer("帮助文档")) {
                AppHelp.open(localizer: model.localizer, product: product)
            }
        }
    }
}
