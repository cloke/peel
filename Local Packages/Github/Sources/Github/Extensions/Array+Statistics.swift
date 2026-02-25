extension Array where Element == Double {
  func median() -> Double {
    let sorted = self.sorted()
    guard !sorted.isEmpty else { return 0 }
    if sorted.count % 2 == 1 {
      return sorted[sorted.count / 2]
    }
    let upper = sorted.count / 2
    return (sorted[upper - 1] + sorted[upper]) / 2
  }
}
