import Foundation
import Network

enum ConnectionError: Error {
    case connectionFailed
    case timeout
    case cancelled
}

class ConnectionTester {
    static let shared = ConnectionTester()

    func checkReachability(host: String, port: UInt16 = 445, timeout: TimeInterval = 2.0, completion: @escaping (Result<Bool, Error>) -> Void) {
        let hostEndpoint = NWEndpoint.Host(host)
        let portEndpoint = NWEndpoint.Port(integerLiteral: port)

        let connection = NWConnection(host: hostEndpoint, port: portEndpoint, using: .tcp)

        // Use a serial queue to protect shared completion state
        let guardQueue = DispatchQueue(label: "ConnectionTester.guard")
        var hasCompleted = false

        let complete: (Result<Bool, Error>) -> Void = { result in
            guardQueue.async {
                guard !hasCompleted else { return }
                hasCompleted = true
                connection.cancel()
                completion(result)
            }
        }

        let timeoutWork = DispatchWorkItem {
            complete(.failure(ConnectionError.timeout))
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                timeoutWork.cancel()
                complete(.success(true))
            case .failed(let error):
                timeoutWork.cancel()
                complete(.failure(error))
            case .cancelled:
                break
            default:
                break
            }
        }

        connection.start(queue: .global())
    }
}
