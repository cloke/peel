//
//  WANAddressResolver.swift
//  Peel
//
//  Discovers the device's public (WAN) IP address for peer-to-peer
//  connections across networks. Uses lightweight HTTP services that
//  return the caller's public IP.
//

import Foundation
import os.log

/// Resolves the public WAN IP address for this device
public enum WANAddressResolver {
  private static let logger = Logger(subsystem: "com.peel.distributed", category: "WANAddress")

  /// Well-known services that return our public IP as plain text
  private static let ipServices = [
    "https://api.ipify.org",
    "https://ifconfig.me/ip",
    "https://icanhazip.com",
    "https://checkip.amazonaws.com"
  ]

  /// Resolve the public IP with a timeout. Tries multiple services for resilience.
  public static func resolve(timeout: TimeInterval = 5) async -> String? {
    for service in ipServices {
      guard let url = URL(string: service) else { continue }

      var request = URLRequest(url: url)
      request.timeoutInterval = timeout
      request.cachePolicy = .reloadIgnoringLocalCacheData

      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let ip = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              isValidIPv4(ip) else {
          continue
        }
        logger.info("Resolved WAN address: \(ip) (via \(service))")
        return ip
      } catch {
        logger.debug("WAN resolve failed via \(service): \(error.localizedDescription)")
        continue
      }
    }

    logger.warning("Could not resolve WAN address from any service")
    return nil
  }

  /// Basic IPv4 validation
  private static func isValidIPv4(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".")
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
      guard let n = Int(part) else { return false }
      return (0...255).contains(n)
    }
  }
}
