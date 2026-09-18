import XCTest
@testable import GlassMark

@MainActor
final class GeminiCredentialStoreTests: XCTestCase {
    func testMissingKeyState() {
        let store = GeminiCredentialStore(
            secretStore: InMemorySecretStore(),
            environment: [:],
            generator: FakeGeminiGenerator()
        )
        XCTAssertEqual(store.state, .missing)
        XCTAssertFalse(store.isConfigured)
        XCTAssertNil(store.currentKey())
    }

    func testSaveAndRemoveRoundTrip() {
        let store = GeminiCredentialStore(
            secretStore: InMemorySecretStore(),
            environment: [:],
            generator: FakeGeminiGenerator()
        )
        store.save(key: "  my-key  ")
        XCTAssertEqual(store.state, .available(.keychain))
        XCTAssertEqual(store.currentKey(), "my-key")
        XCTAssertNil(store.lastErrorMessage)

        store.remove()
        XCTAssertEqual(store.state, .missing)
        XCTAssertNil(store.currentKey())
    }

    func testEmptySaveIsRejected() {
        let store = GeminiCredentialStore(
            secretStore: InMemorySecretStore(),
            environment: [:],
            generator: FakeGeminiGenerator()
        )
        store.save(key: "   ")
        XCTAssertEqual(store.state, .missing)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    func testDeniedReadsDoNotFallBackToEnvironment() {
        let secrets = InMemorySecretStore()
        secrets.failReadsWith = .accessDenied
        let store = GeminiCredentialStore(
            secretStore: secrets,
            environment: ["GEMINI_API_KEY": "env-key"],
            generator: FakeGeminiGenerator()
        )
        XCTAssertEqual(store.state, .denied)
        XCTAssertNil(store.currentKey())
    }

    #if DEBUG
    func testDevelopmentEnvironmentOverrideOnlyInDebug() {
        let store = GeminiCredentialStore(
            secretStore: InMemorySecretStore(),
            environment: ["GEMINI_API_KEY": "env-key"],
            generator: FakeGeminiGenerator()
        )
        XCTAssertEqual(store.state, .available(.developmentEnvironment))
        XCTAssertTrue(store.isDevelopmentOverride)
        XCTAssertEqual(store.currentKey(), "env-key")
    }
    #endif

    func testKeychainErrorSurfacesFailedState() {
        let secrets = InMemorySecretStore()
        secrets.failReadsWith = .unexpected(-9999)
        let store = GeminiCredentialStore(
            secretStore: secrets,
            environment: [:],
            generator: FakeGeminiGenerator()
        )
        guard case .failed = store.state else {
            return XCTFail("expected failed state, got \(store.state)")
        }
    }

    func testTestConnectionUsesSyntheticContent() async {
        let secrets = InMemorySecretStore()
        try? secrets.setSecret("k", account: GeminiCredentialStore.account)
        let generator = FakeGeminiGenerator()
        generator.enqueue(events: [.started(id: "x"), .completed(usage: nil)])

        let store = GeminiCredentialStore(
            secretStore: secrets,
            environment: [:],
            generator: generator
        )
        let result = await store.testConnection(model: "gemini-3.5-flash-lite")

        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
        let input = try? XCTUnwrap(generator.receivedInputs.first)
        XCTAssertEqual(input?.selection, "connection test")
        XCTAssertEqual(input?.model, "gemini-3.5-flash-lite")
    }

    func testTestConnectionWithoutKeyFails() async {
        let store = GeminiCredentialStore(
            secretStore: InMemorySecretStore(),
            environment: [:],
            generator: FakeGeminiGenerator()
        )
        let result = await store.testConnection(model: "m")
        guard case .failure(let error) = result else {
            return XCTFail("expected failure, got \(result)")
        }
        XCTAssertEqual(error, .authentication)
    }
}
