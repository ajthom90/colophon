import Testing
@testable import ABSKit

@Suite struct ServerVersionTests {
    @Test func parsesAndCompares() {
        #expect(ServerVersion("2.26.0")! < ServerVersion("2.35.1")!)
        #expect(ServerVersion("2.35.1")! < ServerVersion("3.0.0")!)
        #expect(!(ServerVersion("2.26.0")! < ServerVersion("2.26.0")!))
        #expect(ServerVersion("2.9.0")! < ServerVersion("2.26.0")!)   // numeric, not lexicographic
        #expect(ServerVersion("v2.26.0") == nil)
        #expect(ServerVersion("2.26") == nil)
        #expect(ServerVersion("") == nil)
    }

    @Test func gateConstant() {
        #expect(ABSKit.minimumServerVersion == ServerVersion("2.26.0")!)
    }

    @Test func errorsAreHumanReadable() {
        #expect(ABSError.serverTooOld(found: "2.20.0").errorDescription?.contains("2.26.0") == true)
        #expect(ABSError.http(status: 401).errorDescription?.contains("401") == true)
        #expect(ABSError.notAuthenticated.errorDescription?.isEmpty == false)
        #expect(ABSError.reauthRequired.errorDescription?.isEmpty == false)
        #expect(ABSError.invalidResponse.errorDescription?.isEmpty == false)
        #expect(TokenStoreError.keychainFailure(-25300).errorDescription?.contains("-25300") == true)
    }

    @Test func toleratesPreReleaseAndBuildSuffixes() {
        #expect(ServerVersion("2.36.0-beta.1") == ServerVersion("2.36.0"))
        #expect(ServerVersion("2.36.0+build5") == ServerVersion("2.36.0"))
        #expect(ServerVersion("2.36.0-beta")! > ServerVersion("2.26.0")!)
        #expect(ServerVersion("2.36-beta") == nil)
    }
}
