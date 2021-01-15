struct Command {
  static let BrewInstalled = ["list", "--formula"]
  static let BrewAvailable = ["search", "--formula"]
  static let BrewInfo = ["info", "--json"]
  static let BrewInstall = ["install"]
}
