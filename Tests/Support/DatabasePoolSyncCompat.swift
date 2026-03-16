import Foundation
import GRDB

private final class AsyncOperationBox<T>: @unchecked Sendable {
    let operation: () async throws -> T

    init(operation: @escaping () async throws -> T) {
        self.operation = operation
    }
}

private final class AsyncResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

extension DatabasePool {
    func read<T>(_ value: @escaping (Database) throws -> T) throws -> T {
        let operation = AsyncOperationBox(operation: { try await self.read(value) })
        return try syncAwait(operation)
    }

    func write<T>(_ updates: @escaping (Database) throws -> T) throws -> T {
        let operation = AsyncOperationBox(operation: { try await self.write(updates) })
        return try syncAwait(operation)
    }

    private func syncAwait<T>(_ operation: AsyncOperationBox<T>) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = AsyncResultBox<T>()

        Task {
            do {
                resultBox.result = .success(try await operation.operation())
            } catch {
                resultBox.result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try resultBox.result!.get()
    }
}
