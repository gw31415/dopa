public protocol Power: AnyObject {
  func readDisabled() throws -> Bool
  func setDisabled(_ disabled: Bool) throws
}

public protocol DisplayControls: AnyObject {
  func keepDisplayOn() throws
  func releaseDisplay() throws
}

public enum Session {
  public static func recover(power: any Power, state: State) throws {
    if try state.pending() {
      try power.setDisabled(false)
      guard try !power.readDisabled() else { throw DopaError("restoration was not confirmed") }
      try state.clear()
      log("original sleep setting restored")
    }
  }
  public static func start(power: any Power, state: State) throws {
    try recover(power: power, state: state)
    guard try !power.readDisabled() else {
      throw DopaError("sleep is already disabled by another tool or manual setting")
    }
    try state.save()
    try power.setDisabled(true)
    guard try power.readDisabled() else { throw DopaError("sleep inhibition was not confirmed") }
  }
}
