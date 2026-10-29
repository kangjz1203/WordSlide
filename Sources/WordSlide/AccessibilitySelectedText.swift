import ApplicationServices
import Foundation

/// Extracts selected text without knowing which accessibility transport supplies it.
/// Web documents can expose opaque text markers instead of the CFRange used by native editors.
/// The caller owns IPC timeouts, process ownership checks, and secure-field filtering.
enum AccessibilitySelectedText {
    static func read(
        attribute: (String) -> CFTypeRef?,
        parameterized: (String, CFTypeRef) -> CFTypeRef?
    ) -> String? {
        if let text = boundedText(attribute(kAXSelectedTextAttribute)) { return text }

        // Text-marker ranges are opaque. Pass them back to their owning element rather
        // than attempting to cast them to AXValue or interpret their private bytes.
        if let markerRange = attribute("AXSelectedTextMarkerRange") {
            if let length = parameterized("AXLengthForTextMarkerRange", markerRange) as? NSNumber,
               length.doubleValue > 128 {
                return " "
            }
            if let text = boundedText(parameterized("AXStringForTextMarkerRange", markerRange)) {
                return text
            }
        }

        guard let rawRange = attribute(kAXSelectedTextRangeAttribute),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
        // CF type identity is checked before this cast. Never cast an arbitrary
        // attribute (including a text marker) to an AXValue.
        let rangeValue = rawRange as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range),
              range.location >= 0, range.length > 0 else { return nil }
        guard range.length <= 128 else { return " " }
        guard range.location <= CFIndex.max - range.length else { return nil }
        return boundedText(parameterized(kAXStringForRangeParameterizedAttribute, rangeValue))
    }

    private static func boundedText(_ value: CFTypeRef?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        // A non-word sentinel preserves the distinction between an unsupported
        // selection and a deliberately rejected long selection in the caller.
        return text.utf8.count <= 256 ? text : " "
    }
}
