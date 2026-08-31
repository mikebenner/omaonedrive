const assert = require("node:assert")
const test = require("node:test")

const Model = require("../Model.js")

// These exist because a reviewer pointed out that deleting the ramp or bypassing
// the cloud semaphore passed the entire suite: the logic lived in QML, which has
// no harness here. Pulling the DECISIONS out makes them assertable.

function acct(overrides) {
  return Object.assign({ routinePolling: false, initialized: true }, overrides || {})
}

test("an account already polling is never handed another slot", () => {
  const accounts = [acct({ routinePolling: true }), acct()]
  assert.equal(Model.nextPollIndex(accounts, 0), 1)
  // ...and if every account is busy, nobody is picked.
  assert.equal(Model.nextPollIndex([acct({ routinePolling: true })], 0), -1)
})

test("accounts that have not reported take priority over ones that have", () => {
  const accounts = [acct(), acct({ initialized: false }), acct()]
  assert.equal(Model.nextPollIndex(accounts, 0), 1)
})

test("several unreported accounts interleave instead of one taking every slot", () => {
  // This is the defect this function was extracted to prevent: the old code
  // returned the FIRST unreported account every slot, so with three of them the
  // second and third were never polled until the first exhausted a 15-slot
  // counter -- 150 seconds at default settings, with no badge on the bar.
  const accounts = [acct({ initialized: false }), acct({ initialized: false }), acct({ initialized: false })]
  const picked = []
  let cursor = 0
  for (let slot = 0; slot < 6; slot++) {
    const index = Model.nextPollIndex(accounts, cursor)
    picked.push(index)
    cursor = (index + 1) % accounts.length
  }
  assert.deepEqual(picked, [0, 1, 2, 0, 1, 2])
  // Every account is reached within one round, not after the first gives up.
  assert.equal(new Set(picked.slice(0, 3)).size, 3)
})

test("a paused account does not consume startup priority", () => {
  // Priority is "has not reported", not "not running". A deliberately paused
  // account is a known state; treating it as ramping made it monopolise slots
  // every time the user paused it.
  const accounts = [acct({ initialized: true }), acct({ initialized: false })]
  assert.equal(Model.nextPollIndex(accounts, 0), 1)
})

test("the round-robin advances and wraps", () => {
  const accounts = [acct(), acct(), acct()]
  assert.equal(Model.nextPollIndex(accounts, 0), 0)
  assert.equal(Model.nextPollIndex(accounts, 1), 1)
  assert.equal(Model.nextPollIndex(accounts, 2), 2)
  assert.equal(Model.nextPollIndex(accounts, 3), 0)
  // A cursor left over from a longer list cannot index out of range.
  assert.equal(Model.nextPollIndex(accounts, 99), 0)
  assert.equal(Model.nextPollIndex([], 0), -1)
})

test("a busy slot queues a cloud check rather than starting a second one", () => {
  // Two concurrent 30-second cloud checks is the invariant this protects.
  assert.equal(Model.cloudDecision(false, [], "a.service", "quota"), "start")
  assert.equal(Model.cloudDecision(true, [], "a.service", "quota"), "queue")
})

test("a repeated request is dropped, not queued twice", () => {
  const queue = [{ service: "a.service", mode: "quota" }]
  assert.equal(Model.cloudDecision(true, queue, "a.service", "quota"), "drop")
  // A different mode for the same account is a different request.
  assert.equal(Model.cloudDecision(true, queue, "a.service", "sync-status"), "queue")
  // ...as is the same mode for a different account.
  assert.equal(Model.cloudDecision(true, queue, "b.service", "quota"), "queue")
})

test("a malformed cloud request is dropped", () => {
  assert.equal(Model.cloudDecision(false, [], "", "quota"), "drop")
  assert.equal(Model.cloudDecision(false, [], "a.service", ""), "drop")
})

test("the queue cannot grow past one entry per account per mode", () => {
  // Bounded by construction: 2 modes x N accounts. A user leaning on the refresh
  // key cannot build a backlog.
  const queue = []
  for (const service of ["a", "b", "c"]) {
    for (const mode of ["quota", "sync-status"]) {
      for (let repeat = 0; repeat < 5; repeat++) {
        if (Model.cloudDecision(true, queue, service, mode) === "queue") {
          queue.push({ service: service, mode: mode })
        }
      }
    }
  }
  assert.equal(queue.length, 6)
})
