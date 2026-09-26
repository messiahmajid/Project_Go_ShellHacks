import AppKit
import ApplicationServices
import Testing
@testable import Go

@MainActor
struct RadioSelectionTests {
    private func node(_ title: String = "Landscape", selected: Bool?, role: String = kAXRadioButtonRole,
                      children: [AccessibilityElementNode] = []) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: nil, title: title, value: nil,
                                 frameInAppKitCoordinates: CGRect(x: 10, y: 10, width: 100, height: 30),
                                 depth: 0, children: children, publishedActionNames: [kAXPressAction],
                                 radioSelection: selected)
    }
    private let intent = ElementActionIntent(role: kAXRadioButtonRole, title: "Landscape", action: .press)

    @Test func numericValuesAreSeparateFromLabels() {
        #expect(AccessibilityTreeWalker.decodeRadioSelection(NSNumber(value: 0)) == false)
        #expect(AccessibilityTreeWalker.decodeRadioSelection(NSNumber(value: 1)) == true)
        #expect(AccessibilityTreeWalker.decodeRadioSelection(NSNumber(value: 2)) == nil)
        #expect(AccessibilityTreeWalker.decodeRadioSelection(NSNumber(value: 0.5)) == nil)
        #expect(AccessibilityTreeWalker.decodeRadioSelection("1" as NSString) == nil)
        #expect(AccessibilityTreeWalker.decodeRadioSelection(nil) == nil)
        let radio = node(selected: true)
        #expect(radio.displayName?.raw == "Landscape")
        #expect(HarnessServer.summarise(radio)["radioSelection"] as? Bool == true)
        #expect(HarnessServer.summarise(node(selected: nil))["radioSelection"] is NSNull)
        let field = node(selected: true, role: kAXTextFieldRole)
        #expect(field.radioSelection == nil)
        #expect(HarnessServer.summarise(field)["radioSelection"] == nil)
    }

    @Test func onlyTheRequestedSelectionChangeConfirms() {
        let before = node(selected: false)
        #expect(ActionVerifier.radioPressConfirmed(intent: intent, previous: before, laterRoot: node(selected: true)))
        #expect(!ActionVerifier.radioPressConfirmed(intent: intent, previous: before, laterRoot: node(selected: false)))
        #expect(!ActionVerifier.radioPressConfirmed(intent: intent, previous: before, laterRoot: node(selected: nil)))
        #expect(!ActionVerifier.radioPressConfirmed(intent: intent, previous: node(selected: nil), laterRoot: node(selected: true)))
        #expect(!ActionVerifier.radioPressConfirmed(intent: intent, previous: node(selected: true), laterRoot: node(selected: true)))
        #expect(!ActionVerifier.radioPressConfirmed(intent: intent, previous: before, laterRoot: node("Portrait", selected: true)))
        let ambiguous = node("Window", selected: nil, role: kAXWindowRole,
                             children: [node(selected: true), node(selected: true)])
        #expect(!ActionVerifier.radioPressConfirmed(intent: intent, previous: before, laterRoot: ambiguous))
        let unrelated = node("New window title", selected: nil, role: kAXWindowRole,
                             children: [node(selected: false), node("Portrait", selected: true)])
        #expect(!ActionVerifier.radioPressConfirmed(intent: intent, previous: before, laterRoot: unrelated))
    }
}
