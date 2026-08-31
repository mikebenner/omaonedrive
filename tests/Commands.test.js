const assert = require("node:assert")
const test = require("node:test")
const fs = require("node:fs")
const path = require("node:path")

const Commands = require("../Commands.js")
const Model = require("../Model.js")

const root = path.join(__dirname, "..")

const PLAIN = {
  service: "onedrive.service",
  instance: "",
  confdir: "/home/u/.config/onedrive",
  description: "OneDrive Client for Linux"
}
const DRAGONES = {
  service: "onedrive@dragones.service",
  instance: "dragones",
  confdir: "/home/u/.config/onedrive/accounts/dragones",
  description: "OneDrive sync (dragones account)"
}

test("resume units are collision-free and keep the legacy name for the plain service", () => {
  assert.equal(Commands.resumeUnit(""), "omaonedrive-resume")
  assert.equal(Commands.resumeUnit("dragones"), "omaonedrive-resume@dragones")
  assert.equal(Commands.resumeUnit("personal"), "omaonedrive-resume@personal")
  // Distinct instances can never collide on one unit name.
  const units = ["", "dragones", "personal", "tandera"].map(Commands.resumeUnit)
  assert.equal(new Set(units).size, units.length)
})

test("control vectors name the account's own service", () => {
  assert.deepEqual(
    Commands.control("stop", "onedrive@dragones.service"),
    ["systemctl", "--user", "stop", "onedrive@dragones.service"])
  assert.deepEqual(
    Commands.control("start", "onedrive.service"),
    ["systemctl", "--user", "start", "onedrive.service"])
})

test("interactive flows carry the account's own confdir", () => {
  assert.deepEqual(Commands.login(DRAGONES.confdir),
    ["omarchy-launch-terminal", "onedrive", "--confdir", DRAGONES.confdir])
  assert.deepEqual(Commands.login(DRAGONES.confdir, "reauth"),
    ["omarchy-launch-terminal", "onedrive", "--confdir", DRAGONES.confdir, "--reauth"])
  assert.deepEqual(Commands.login(DRAGONES.confdir, "resync"),
    ["omarchy-launch-terminal", "onedrive", "--confdir", DRAGONES.confdir, "--sync", "--resync"])
})

test("an unspecified confdir is omitted from the interactive flows too", () => {
  // Reachable before discovery supplies an identity: the seeded fallback
  // descriptor has no confdir. "--confdir ''" is not the same as no --confdir --
  // the client would reject it -- and the old code ran a plain `onedrive` here.
  assert.deepEqual(Commands.login(""), ["omarchy-launch-terminal", "onedrive"])
  assert.deepEqual(Commands.login("", "reauth"),
    ["omarchy-launch-terminal", "onedrive", "--reauth"])
  assert.deepEqual(Commands.login("", "resync"),
    ["omarchy-launch-terminal", "onedrive", "--sync", "--resync"])
  assert.deepEqual(Commands.login(null), ["omarchy-launch-terminal", "onedrive"])
  // No builder may ever emit an empty argument.
  for (const vector of [Commands.login(""), Commands.login("", "reauth"),
                        Commands.status("/p/h.py", {}, 20)]) {
    for (const argument of vector) assert.notEqual(argument, "", vector.join(" "))
  }
})

test("the plain account sends exactly today's command", () => {
  // Before discovery supplies an identity, and for the plain service afterwards,
  // the helper's own defaults ARE the single-account behaviour. Sending the
  // default service or an empty confdir explicitly would be noise at best and,
  // for an empty confdir, rejected by the helper's absolute-path rule.
  assert.deepEqual(
    Commands.status("/p/h.py", { service: "onedrive.service", instance: "", confdir: "" }, 20),
    ["python3", "/p/h.py", "--limit", "20"])
  assert.deepEqual(
    Commands.status("/p/h.py", {}, 20),
    ["python3", "/p/h.py", "--limit", "20"])
  // ...but a discovered plain account still passes its real confdir.
  assert.deepEqual(
    Commands.status("/p/h.py", PLAIN, 20),
    ["python3", "/p/h.py", "--confdir", PLAIN.confdir, "--limit", "20"])
})

test("the status command is account-complete", () => {
  const command = Commands.status("/p/onedrive-status.py", DRAGONES, 20)
  assert.deepEqual(command, [
    "python3", "/p/onedrive-status.py",
    "--service", "onedrive@dragones.service",
    "--confdir", DRAGONES.confdir,
    "--resume-unit", "omaonedrive-resume@dragones",
    "--limit", "20"
  ])
  // The three identity flags must agree with each other on every invocation.
  assert.equal(command[command.indexOf("--service") + 1], DRAGONES.service)
  assert.equal(command[command.indexOf("--confdir") + 1], DRAGONES.confdir)
  assert.equal(command[command.indexOf("--resume-unit") + 1],
    Commands.resumeUnit(DRAGONES.instance))
})

test("cloud modes add exactly one flag and never both", () => {
  const quota = Commands.status("/p/h.py", PLAIN, 5, "quota")
  const sync = Commands.status("/p/h.py", PLAIN, 5, "sync-status")
  assert.ok(quota.includes("--quota") && !quota.includes("--sync-status"))
  assert.ok(sync.includes("--sync-status") && !sync.includes("--quota"))
  const local = Commands.status("/p/h.py", PLAIN, 5)
  assert.ok(!local.includes("--quota") && !local.includes("--sync-status"))
})

test("a timed pause cancels and schedules only its own account", () => {
  const unit = Commands.resumeUnit(DRAGONES.instance)
  assert.deepEqual(Commands.cancelResume(unit),
    ["systemctl", "--user", "stop",
      "omaonedrive-resume@dragones.timer", "omaonedrive-resume@dragones.service"])

  const schedule = Commands.scheduleResume(unit, DRAGONES.service, 15)
  assert.deepEqual(schedule, [
    "systemd-run", "--user",
    "--unit=omaonedrive-resume@dragones",
    "--description=Resume OneDrive after timed pause",
    "--on-active=15m",
    "--timer-property=AccuracySec=1s",
    "--collect",
    "/usr/bin/systemctl", "--user", "start", "onedrive@dragones.service"
  ])
  // The timer must start the same service the pause stopped.
  assert.equal(schedule[schedule.length - 1], DRAGONES.service)
  // ...and must not mention any other account.
  assert.ok(!schedule.join(" ").includes("personal"))
})

test("the plain service keeps today's exact vectors", () => {
  const unit = Commands.resumeUnit(PLAIN.instance)
  assert.deepEqual(Commands.cancelResume(unit),
    ["systemctl", "--user", "stop", "omaonedrive-resume.timer", "omaonedrive-resume.service"])
  assert.deepEqual(Commands.scheduleResume(unit, PLAIN.service, 60), [
    "systemd-run", "--user",
    "--unit=omaonedrive-resume",
    "--description=Resume OneDrive after timed pause",
    "--on-active=60m",
    "--timer-property=AccuracySec=1s",
    "--collect",
    "/usr/bin/systemctl", "--user", "start", "onedrive.service"
  ])
})

test("--resync appears only in the interactive terminal vector", () => {
  // Every non-interactive builder, exercised, must be free of the mutating flags.
  const vectors = [
    Commands.status("/p/h.py", DRAGONES, 20),
    Commands.status("/p/h.py", DRAGONES, 20, "quota"),
    Commands.status("/p/h.py", DRAGONES, 20, "sync-status"),
    Commands.listAccounts("/p/h.py"),
    Commands.control("start", DRAGONES.service),
    Commands.control("stop", DRAGONES.service),
    Commands.cancelResume(Commands.resumeUnit(DRAGONES.instance)),
    Commands.scheduleResume(Commands.resumeUnit(DRAGONES.instance), DRAGONES.service, 15),
    Commands.notify("normal", "s", "b")
  ]
  for (const vector of vectors) {
    const joined = vector.join(" ")
    assert.ok(!joined.includes("--resync"), joined)
    assert.ok(!joined.includes("--logout"), joined)
  }
  assert.ok(Commands.login(DRAGONES.confdir, "resync")[0] === "omarchy-launch-terminal")
})

test("no builder ever produces a shell invocation", () => {
  const vectors = [
    Commands.status("/p/h.py", DRAGONES, 20),
    Commands.listAccounts("/p/h.py"),
    Commands.control("start", DRAGONES.service),
    Commands.login(DRAGONES.confdir, "reauth"),
    Commands.cancelResume("omaonedrive-resume"),
    Commands.scheduleResume("omaonedrive-resume", PLAIN.service, 5),
    Commands.notify("critical", "s", "b", { id: "resync", label: "Run resync repair" })
  ]
  for (const vector of vectors) {
    assert.ok(Array.isArray(vector))
    for (const argument of vector) assert.equal(typeof argument, "string")
    assert.ok(!["sh", "bash", "/bin/sh", "/bin/bash", "env"].includes(vector[0]), vector[0])
    assert.ok(!vector.includes("-c"), vector.join(" "))
  }
})

test("the source itself contains no shell construction", () => {
  const source = fs.readFileSync(path.join(root, "Commands.js"), "utf8")
  assert.ok(!/\bbash\b|\bsh -c\b|execDetached\(\s*"/.test(source))
})

test("account names are labels, not systemd sentences", () => {
  assert.equal(Model.accountName("dragones"), "Dragones")
  assert.equal(Model.accountName("personal"), "Personal")
  assert.equal(Model.accountName("work-mail"), "Work Mail")
  assert.equal(Model.accountName("work_mail"), "Work Mail")
  // The plain service has no instance and keeps today's identity.
  assert.equal(Model.accountName("", "OneDrive Client for Linux"), "OneDrive")
  assert.equal(Model.accountName(null), "OneDrive")
})
