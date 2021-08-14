import Foundation
import Combine
import Network

enum ServerError: Error {
    case noOpenControllerPorts
}

public class Server: ObservableObject {
    private let netService: NWListener
    
    @Published var name: String? = nil
    @Published var controllers: [Int: ControllerConnection?] = [:]
    var controllerCount = 4
    
    var nextControllerIndex: Int? {
        for i in 0...controllerCount {
            if controllers[i] == nil {
                return i
            }
        }
        return nil
    }
    
    init() {
        self.netService = try! NWListener(using: .custom())
        netService.service = NWListener.Service(
            name: nil,
            type: "_\(serviceType)._tcp.",
            domain: nil,
            txtRecord: nil
        )
        netService.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self.broadcasting = true
                default:
                    self.broadcasting = false
                }
            }
        }
        netService.newConnectionHandler = { connection in
            guard let index = self.nextControllerIndex else {
                connection.cancel()
                return
            }
            
            let controllerConnection = try! ControllerConnection(
                index: index,
                connection: connection
            ) { error in
                DispatchQueue.main.async {
                    self.controllers[index] = nil
                }
            }
            
            DispatchQueue.main.async {
                self.controllers[index] = controllerConnection
            }
        }
    }
    
    func start() throws {
        netService.start(queue: .global(qos: .userInitiated))
    }
    
    func stop() throws {
        netService.cancel()
        print("Server closed")
    }
}

enum PipeError: Error {
    case openFailed
}

func createPipe(index: Int) throws -> OutputStream {
    let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    
    let pipesFolder = applicationSupport
        .appendingPathComponent("Dolphin")
        .appendingPathComponent("Pipes")
    if !FileManager.default.fileExists(atPath: pipesFolder.path) {
        try FileManager.default.createDirectory(
            at: pipesFolder,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
    let pipeUrl = pipesFolder.appendingPathComponent("ctrl\(index+1)")
    mkfifo(pipeUrl.path, 0o644)
    guard let outputStream = OutputStream(url: pipeUrl, append: true) else {
        throw PipeError.openFailed
    }
    
    return outputStream
}
