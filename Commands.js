// Command vectors for one OneDrive account.
//
// Every function returns an argv array. Nothing here is ever passed through a
// shell, and no value is interpolated into a string that becomes a command --
// that is the invariant `docs/ARCHITECTURE.md` states and that
// `tests/Commands.test.js` pins with exact-array assertions.
//
// Each account is identified by its systemd service, its config directory, and
// the instance parsed out of the service name. Nothing is derived from a naming
// convention: the confdir comes from the helper's discovery, which reads it out
// of each unit's own ExecStart.

var DEFAULT_SERVICE = "onedrive.service"
var DEFAULT_RESUME_UNIT = "omaonedrive-resume"

// The plain service deliberately keeps the legacy unit name, so a timer that is
// already in flight survives an upgrade and stays visible and cancellable.
function resumeUnit(instance) {
  var value = String(instance || "")
  return value === "" ? DEFAULT_RESUME_UNIT : DEFAULT_RESUME_UNIT + "@" + value
}

// The status call is account-complete: every invocation names the service, the
// config directory and the resume unit, so no part of the answer can be about a
// different account. `mode` is "" for the routine local poll, or "quota" /
// "sync-status" for an explicit cloud check.
function status(helperPath, account, recentFileLimit, mode) {
  var command = ["python3", String(helperPath)]
  // An empty value means "unspecified", not "empty string": the helper's own
  // defaults are the single-account behaviour, so before discovery has supplied
  // an identity this produces exactly the command the widget sends today.
  var service = String(account.service || "")
  var confdir = String(account.confdir || "")
  var instance = String(account.instance || "")
  if (service !== "" && service !== DEFAULT_SERVICE) {
    command.push("--service", service)
  }
  if (confdir !== "") command.push("--confdir", confdir)
  if (instance !== "") command.push("--resume-unit", resumeUnit(instance))
  command.push("--limit", String(recentFileLimit))
  if (mode === "quota") command.push("--quota")
  else if (mode === "sync-status") command.push("--sync-status")
  return command
}

function listAccounts(helperPath) {
  return ["python3", String(helperPath), "--list-accounts"]
}

function control(action, service) {
  return ["systemctl", "--user", String(action), String(service)]
}

// The interactive CLI flows are the only place --resync may appear, and only
// through omarchy-launch-terminal, where the client prompts for confirmation.
function login(confdir, mode) {
  var command = ["omarchy-launch-terminal", "onedrive"]
  // Same rule as status(): an unspecified confdir means the client's own
  // default, not an empty string. Passing "--confdir ''" would hand the CLI a
  // value it must reject, and this path is reachable before discovery has
  // supplied an identity.
  if (String(confdir || "") !== "") command.push("--confdir", String(confdir))
  if (mode === "reauth") command.push("--reauth")
  else if (mode === "resync") {
    command.push("--sync")
    command.push("--resync")
  }
  return command
}

// Cancel only this account's timer and service; another account's pause is
// untouched.
function cancelResume(unit) {
  return ["systemctl", "--user", "stop", unit + ".timer", unit + ".service"]
}

// On expiry the timer starts the SAME service the pause stopped.
function scheduleResume(unit, service, minutes) {
  return [
    "systemd-run", "--user",
    "--unit=" + unit,
    "--description=Resume OneDrive after timed pause",
    "--on-active=" + String(minutes) + "m",
    "--timer-property=AccuracySec=1s",
    "--collect",
    "/usr/bin/systemctl", "--user", "start", String(service)
  ]
}

function notify(urgency, summary, body, action) {
  var command = ["notify-send", "--app-name=OmaOneDrive", "--urgency=" + String(urgency)]
  if (action) {
    command.push("--action=" + String(action.id) + "=" + String(action.label))
  }
  command.push(String(summary))
  command.push(String(body))
  return command
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_SERVICE: DEFAULT_SERVICE,
    DEFAULT_RESUME_UNIT: DEFAULT_RESUME_UNIT,
    resumeUnit: resumeUnit,
    status: status,
    listAccounts: listAccounts,
    control: control,
    login: login,
    cancelResume: cancelResume,
    scheduleResume: scheduleResume,
    notify: notify
  }
}
