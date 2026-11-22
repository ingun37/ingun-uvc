import AppKit
import SwiftUI

enum ColorTheme {
    static let backgroundColor = Color(.sRGB, red: 67.0 / 255.0, green: 66.0 / 255.0,
                                       blue: 59.0 / 255.0, opacity: 1)
    static let fontColor1 = Color(.sRGB, red: 247.0 / 255.0, green: 239.0 / 255.0,
                                  blue: 190.0 / 255.0, opacity: 1)
    static let fontColor2 = Color(.sRGB, red: 1, green: 229.0 / 255.0,
                                  blue: 28.0 / 255.0, opacity: 1)
    static let haloPurpleLight = Color(.sRGB, red: 202.0 / 255.0, green: 157.0 / 255.0,
                                       blue: 232.0 / 255.0, opacity: 1)
    static let haloPurpleDark = Color(.sRGB, red: 165.0 / 255.0, green: 59.0 / 255.0,
                                      blue: 227.0 / 255.0, opacity: 1)

    static let fontColor1NS = NSColor(fontColor1)
    static let fontColor2NS = NSColor(fontColor2)
}
