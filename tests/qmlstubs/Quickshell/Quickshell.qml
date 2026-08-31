pragma Singleton
import QtQuick

// Stand-in for the Quickshell singleton, and the harness's bus. Every Process
// the widget creates registers here, so a test can see what was launched and
// decide how it exits -- which is what makes the scheduler, the cloud semaphore
// and the notification broker observable at all.
QtObject {
  property var processes: []
  property var detached: []
  property int spawnCount: 0

  function execDetached(command) {
    detached.push(command)
    detachedChanged()
  }

  function register(process) {
    processes.push(process)
    processesChanged()
  }

  function reset() {
    processes = []
    detached = []
    spawnCount = 0
  }

  // Every Process currently running, in creation order.
  function running() {
    var live = []
    for (var i = 0; i < processes.length; i++) {
      if (processes[i].running) live.push(processes[i])
    }
    return live
  }

  // The running processes whose command contains a given flag or token.
  function runningWith(token) {
    var hits = []
    var live = running()
    for (var i = 0; i < live.length; i++) {
      if ((live[i].command || []).indexOf(token) !== -1) hits.push(live[i])
    }
    return hits
  }
}
