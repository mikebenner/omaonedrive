import QtQuick
import Quickshell

// A Process that never actually launches. `running` latches on assignment and
// only clears when the harness calls finish(), which is exactly the lifecycle
// the widget depends on -- and exactly what a command that cannot launch
// silently breaks.
QtObject {
  id: proc
  property var command: []
  property bool running: false
  property var stdout: null
  property var stderr: null
  signal exited(int exitCode, int exitStatus)

  onRunningChanged: {
    if (running) {
      Quickshell.spawnCount += 1
      lastCommand = (command || []).slice()
    }
  }
  property var lastCommand: []

  Component.onCompleted: Quickshell.register(proc)

  // Harness: complete this process with the given exit code and stdout.
  function finish(exitCode, out) {
    if (!running) return false
    if (stdout && out !== undefined) stdout.feed(out)
    if (stderr) stderr.feed("")
    running = false
    exited(exitCode === undefined ? 0 : exitCode, 0)
    return true
  }
}
