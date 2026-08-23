import Foundation

struct ManualRetryPolicy: Sendable {
    func shouldRetry(
        error: Error?,
        response: HTTPURLResponse?,
        attempt: Int
    ) -> Bool {
        guard attempt < 3 else { return false }
        if let statusCode = response?.statusCode {
            return [408, 425, 429].contains(statusCode) || (500...599).contains(statusCode)
        }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
            .secureConnectionFailed,
            .cannotLoadFromNetwork
        ].contains(urlError.code)
    }

    func delaySeconds(attempt: Int) -> UInt64 {
        [1, 3, 9][min(max(attempt, 0), 2)]
    }
}
