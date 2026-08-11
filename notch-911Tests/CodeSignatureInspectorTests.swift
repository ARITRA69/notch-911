import Testing
@testable import notch_911

@Suite("Code signature diagnostics")
struct CodeSignatureInspectorTests {
    @Test("Recognizes the persistent local authority")
    func stableAuthority() {
        let status = CodeSignatureInspector.parse("""
        Identifier=com.aritra360.notch-911
        Authority=notch-911 Local Development
        TeamIdentifier=not set
        """)

        #expect(status.kind == .stable)
        #expect(status.authority == "notch-911 Local Development")
    }

    @Test("Distinguishes ad-hoc and unavailable signatures")
    func unstableSignatures() {
        #expect(CodeSignatureInspector.parse("Signature=adhoc").kind == .adHoc)
        #expect(CodeSignatureInspector.parse("Identifier=com.example.app").kind == .unavailable)
    }
}
