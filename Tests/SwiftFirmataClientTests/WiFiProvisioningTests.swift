import Testing
import Foundation
import CryptoKit
@testable import SwiftFirmataClient

/// Exercises the encrypted Wi-Fi provisioning client flow by playing the *device*
/// side with CryptoKit: the test decrypts what the client seals (proving the
/// handshake, framing, HKDF + AES-GCM are correct) and replies with status.
/// (The CryptoKit↔mbedTLS interop is verified separately on real hardware.)
@Suite("WiFiProvisioning")
struct WiFiProvisioningTests {

    private func enc(_ b: [UInt8]) -> [UInt8] {
        var o = [UInt8](); for x in b { o.append(x & 0x7F); o.append((x >> 7) & 0x01) }; return o
    }
    private func dec(_ b: [UInt8]) -> [UInt8] {
        var o = [UInt8](); var i = 0
        while i + 1 < b.count { o.append((b[i] & 0x7F) | ((b[i + 1] & 0x01) << 7)); i += 2 }; return o
    }
    /// Poll the mock's sent frames for one addressed to WIFI_CONFIG with subcommand `sub`.
    private func waitSent(_ t: MockTransport, sub: UInt8) async -> [UInt8]? {
        for _ in 0..<300 {
            if let f = t.sentBytes.first(where: {
                $0.count >= 4 && $0[0] == 0xF0 && $0[1] == WiFiCfg.command && $0[2] == sub
            }) { return f }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func provisionRoundTripDecryptsAndReturnsStatus() async throws {
        let t = MockTransport()
        let client = FirmataClient(transport: t)
        await client.connect(); await Task.yield()

        let devPriv = Curve25519.KeyAgreement.PrivateKey()   // the test plays "device"
        let provTask = Task { try await client.provisionWiFi(ssid: "Doraks", password: "karo37220") }

        // 1) client → WC_BEGIN ; device → WC_KEY(devicePub)
        let begin = await waitSent(t, sub: WiFiCfg.begin)
        #expect(begin == [0xF0, WiFiCfg.command, WiFiCfg.begin, 0xF7])
        t.inject([0xF0, WiFiCfg.command, WiFiCfg.key]
                 + enc([UInt8](devPriv.publicKey.rawRepresentation)) + [0xF7])

        // 2) client → WC_SET(clientPub‖nonce‖ct‖tag) ; device decrypts it
        guard let setf = await waitSent(t, sub: WiFiCfg.set) else { Issue.record("no SET frame"); return }
        let payload = dec(Array(setf[3..<(setf.count - 1)]))
        #expect(payload.count >= 32 + 12 + 16)
        let clientPub = Array(payload[0..<32])
        let nonce     = Array(payload[32..<44])
        let ctTag     = Array(payload[44...])
        let ct        = Array(ctTag[0..<(ctTag.count - 16)])
        let tag       = Array(ctTag[(ctTag.count - 16)...])

        let shared = try devPriv.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(clientPub)))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                    salt: Data(WiFiCfg.hkdfSalt.utf8), sharedInfo: Data(), outputByteCount: 32)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(nonce)),
                                        ciphertext: Data(ct), tag: Data(tag))
        let pt = [UInt8](try AES.GCM.open(box, using: key))

        // plaintext = <ssidLen> ssid <passLen> pass
        let sl = Int(pt[0]); let ssid = String(decoding: pt[1..<1+sl], as: UTF8.self)
        let pl = Int(pt[1+sl]); let pass = String(decoding: pt[(2+sl)..<(2+sl+pl)], as: UTF8.self)
        #expect(ssid == "Doraks")
        #expect(pass == "karo37220")

        // 3) device → WC_STATUS(connected, ip)
        let ip = "192.168.1.50"
        t.inject([0xF0, WiFiCfg.command, WiFiCfg.status, 1, UInt8(ip.utf8.count)]
                 + enc([UInt8](ip.utf8)) + [0xF7])

        let status = try await provTask.value
        #expect(status.connected == true)
        #expect(status.ip == ip)
    }

    @Test func rejectedCredentialsThrow() async throws {
        let t = MockTransport()
        let client = FirmataClient(transport: t)
        await client.connect(); await Task.yield()

        let devPriv = Curve25519.KeyAgreement.PrivateKey()
        let provTask = Task { try await client.provisionWiFi(ssid: "x", password: "y") }
        _ = await waitSent(t, sub: WiFiCfg.begin)
        t.inject([0xF0, WiFiCfg.command, WiFiCfg.key]
                 + enc([UInt8](devPriv.publicKey.rawRepresentation)) + [0xF7])
        _ = await waitSent(t, sub: WiFiCfg.set)
        t.inject([0xF0, WiFiCfg.command, WiFiCfg.status, 2, 0, 0xF7])   // code 2 = rejected

        do { _ = try await provTask.value; Issue.record("expected a throw") }
        catch FirmataError.wifiCredentialsRejected { /* expected */ }
        catch { Issue.record("wrong error: \(error)") }
    }
}
