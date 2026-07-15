import Darwin

// Cumulative interface byte counters via getifaddrs. Stateless — the caller
// keeps the previous reading plus a timestamp and turns the difference into a
// per-second rate. The counters are the 32-bit `if_data` fields, so a delta
// that goes negative (counter wrap or interface reset) is clamped to zero by
// the caller rather than reported as a spike.
//
// Adapted from Stats (MIT) — `Modules/Net/readers.swift`
// `UsageReader.readInterfaceBandwidth()`.
enum NetworkSampler {
    /// Summed received/transmitted bytes across all up, non-loopback link
    /// interfaces, plus the name of the busiest one for display.
    static func counters() -> (rx: UInt64, tx: UInt64, name: String?)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return nil }
        defer { freeifaddrs(head) }

        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0
        var bestName: String?
        var bestRx: UInt64 = 0

        var cursor = head
        while let cur = cursor {
            defer { cursor = cur.pointee.ifa_next }

            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK)
            else { continue }

            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("lo") || name.hasPrefix("gif") || name.hasPrefix("stf") {
                continue
            }
            guard (cur.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  let raw = cur.pointee.ifa_data
            else { continue }

            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            let rx = UInt64(data.ifi_ibytes)
            let tx = UInt64(data.ifi_obytes)
            totalRx += rx
            totalTx += tx
            if rx > bestRx {
                bestRx = rx
                bestName = name
            }
        }

        return (totalRx, totalTx, bestName)
    }
}
