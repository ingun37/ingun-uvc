import AVFoundation
import IOKit

struct DetailRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

enum USBDetails {
    /// AVFoundation USB IDs encode location, vendor and product as hexadecimal.
    /// Only display registry metadata when all three identifiers match.
    static func rows(for device: AVCaptureDevice) -> [DetailRow] {
        guard device.uniqueID.hasPrefix("0x"),
              let identifier = UInt64(device.uniqueID.dropFirst(2), radix: 16),
              let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func number(_ key: String) -> UInt64 {
                (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint64Value ?? UInt64.max
            }
            guard number("locationID") == identifier >> 32,
                  number("idVendor") == (identifier >> 16) & 0xffff,
                  number("idProduct") == identifier & 0xffff else { continue }
            var rows = [
                DetailRow(label: "USB vendor ID", value: String(format: "0x%04llX", number("idVendor"))),
                DetailRow(label: "USB product ID", value: String(format: "0x%04llX", number("idProduct"))),
                DetailRow(label: "USB location", value: String(format: "0x%08llX", number("locationID")))
            ]
            var children: io_iterator_t = 0
            if IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS {
                defer { IOObjectRelease(children) }
                var interfaces: Set<String> = []
                while case let child = IOIteratorNext(children), child != 0 {
                    defer { IOObjectRelease(child) }
                    func property(_ key: String) -> NSNumber? {
                        IORegistryEntryCreateCFProperty(child, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
                    }
                    if let cls = property("bInterfaceClass"), let sub = property("bInterfaceSubClass") {
                        let name = cls.intValue == 14 ? (sub.intValue == 1 ? "Video control" : sub.intValue == 2 ? "Video streaming" : "Video") : "USB interface"
                        interfaces.insert(String(format: "%@ — class 0x%02X, subclass 0x%02X", name, cls.intValue, sub.intValue))
                    }
                }
                for (index, value) in interfaces.sorted().enumerated() {
                    rows.append(DetailRow(label: "Interface \(index + 1)", value: value))
                }
            }
            return rows
        }
        return []
    }
}
