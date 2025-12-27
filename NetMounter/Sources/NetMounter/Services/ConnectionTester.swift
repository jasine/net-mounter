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
        
        var hasCompleted = false
        
        let timeoutWork = DispatchWorkItem {
            if !hasCompleted {
                hasCompleted = true
                connection.cancel()
                completion(.failure(ConnectionError.timeout))
            }
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        
        connection.stateUpdateHandler = { state in
            if hasCompleted { return }
            
            switch state {
            case .ready:
                hasCompleted = true
                timeoutWork.cancel()
                connection.cancel()
                completion(.success(true))
            case .failed(let error):
                hasCompleted = true
                timeoutWork.cancel()
                connection.cancel()
                completion(.failure(error))
            case .cancelled:
                // Do nothing if cancelled manually
                break
            default:
                break
            }
        }
        
        connection.start(queue: .global())
    }
}
