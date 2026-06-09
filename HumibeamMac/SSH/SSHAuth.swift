import Foundation
import NIOCore
import NIOSSH
import Crypto

/// Offers the configured authentication method to the server.
final class UserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let method: SSHAuthMethod
    private var offered = false

    init(username: String, method: SSHAuthMethod) {
        self.username = username
        self.method = method
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true

        let offer: NIOSSHUserAuthenticationOffer.Offer
        switch method {
        case .password(let pw):
            guard availableMethods.contains(.password) else { nextChallengePromise.succeed(nil); return }
            offer = .password(.init(password: pw))
        case .ed25519Raw(let raw):
            guard availableMethods.contains(.publicKey),
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
                nextChallengePromise.succeed(nil); return
            }
            offer = .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))
        case .privateKey(let pk):
            guard availableMethods.contains(.publicKey) else { nextChallengePromise.succeed(nil); return }
            offer = .privateKey(.init(privateKey: pk))
        }

        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer)
        )
    }
}

/// Bridges NIOSSH host-key validation to the app's verifier (known_hosts / TOFU).
final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: Int
    private weak var verifier: SSHHostKeyVerifier?

    init(host: String, port: Int, verifier: SSHHostKeyVerifier?) {
        self.host = host
        self.port = port
        self.verifier = verifier
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if let verifier {
            verifier.verify(host: host, port: port, hostKey: hostKey, promise: validationCompletePromise)
        } else {
            // No verifier configured: accept (TOFU handled at a higher layer).
            validationCompletePromise.succeed(())
        }
    }
}
