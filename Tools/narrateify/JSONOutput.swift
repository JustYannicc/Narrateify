import Foundation

enum JSONOutput {
    static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: shortestNumbers(value), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// JSONSerialization writes 1.872 back as 1.8720000000000001; Swift's own
    /// description is the shortest round-trip form.
    private static func shortestNumbers(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues(shortestNumbers)
        case let array as [Any]: return array.map(shortestNumbers)
        case let number as NSNumber where CFNumberIsFloatType(number) && !(value is Bool):
            return NSDecimalNumber(string: String(number.doubleValue))
        default: return value
        }
    }

}
