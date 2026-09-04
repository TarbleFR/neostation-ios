import ExtensionFoundation

@available(iOS 26.0, *)
extension AppExtensionPoint {
    @Definition
    static var neoStationDolphinJITHelper: AppExtensionPoint {
        Name("DolphinJITHelper")
    }
}
