/*
 * SwiftFirmataClient — a concurrency-safe Firmata 2.x client.
 *
 * FirmataClient (actor) speaks the protocol over any FirmataTransport; four
 * transports ship with the package (Bonjour, TCP, BLE, USB serial). Live calls
 * drive the board directly; FirmataTaskRecorder records tasks the board runs
 * on its own, including the on-device extension (registers, branches, HTTP +
 * JSON/string inspection, nested tasks). See README + COOKBOOK for usage.
 */

public enum FirmataError: Error, Sendable {
    case transportClosed
    case invalidData
    case noResponse
    /// Wi-Fi provisioning: the device rejected the credentials (the encrypted
    /// handshake failed to authenticate — wrong key / tampered / corrupted frame).
    case wifiCredentialsRejected
}
