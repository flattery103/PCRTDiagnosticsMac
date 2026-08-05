import Foundation

public enum LineDelimitedJSON {
    public static func encode(_ message: IPCMessage, using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    public static func decodeMessages(buffer: inout Data, using decoder: JSONDecoder = JSONDecoder()) throws -> [IPCMessage] {
        var output: [IPCMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            output.append(try decoder.decode(IPCMessage.self, from: Data(line)))
        }
        return output
    }
}
