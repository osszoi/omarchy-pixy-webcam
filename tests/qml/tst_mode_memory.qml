// Remembered Standard/Tracking: what modeSync does with each state read.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest
import "../../Model.js" as Model

TestCase {
  name: "ModeMemory"

  function live(props) {
    var s = { present: true, privacy: false, streaming: true, selfStreaming: false, mode: "standard" }
    for (var k in props) s[k] = props[k]
    return s
  }

  // feeds reads through modeSync the way the panel does, returning every step
  function run(reads, remembered, memory) {
    var steps = []
    for (var i = 0; i < reads.length; i++) {
      var step = Model.modeSync(memory || null, live(reads[i].state), remembered, reads[i].at)
      memory = step.memory
      steps.push(step)
    }
    return steps
  }

  function writes(steps) {
    return steps.map(function(s) { return s.write })
  }

  function test_nothing_happens_while_the_mode_cannot_be_read() {
    compare(Model.modeSync(null, live({ streaming: false, mode: null }), "tracking", 0).write, "")
    compare(Model.modeSync(null, live({ privacy: true, mode: "privacy" }), "tracking", 0).write, "")
    compare(Model.modeSync(null, live({ privacy: null }), "tracking", 0).write, "")
    compare(Model.modeSync(null, live({ present: false }), "tracking", 0).write, "")
    compare(Model.modeSync(null, null, "tracking", 0).write, "")
  }

  function test_nothing_happens_before_anything_was_picked() {
    compare(Model.modeSync(null, live({ mode: "tracking" }), "", 0).write, "")
    compare(Model.modeSync(null, live({ mode: "tracking" }), null, 0).write, "")
    compare(Model.modeSync(null, live({ mode: "tracking" }), "privacy", 0).write, "")
  }

  function test_a_call_starting_in_the_wrong_mode_gets_the_remembered_one() {
    // what the live test showed: the camera reopens its own lens into Tracking
    compare(Model.modeSync(null, live({ mode: "tracking" }), "standard", 0).write, "standard")
  }

  function test_a_call_already_in_the_remembered_mode_is_left_alone() {
    compare(Model.modeSync(null, live({ mode: "standard" }), "standard", 0).write, "")
  }

  function test_our_own_preview_counts_as_in_use() {
    var step = Model.modeSync(null, live({ streaming: false, selfStreaming: true, mode: "tracking" }),
                              "standard", 0)
    compare(step.write, "standard")
  }

  function test_a_dropped_write_is_retried_but_not_on_every_read() {
    var steps = run([
      { state: { mode: "tracking" }, at: 0 },
      { state: { mode: "tracking" }, at: 400 },
      { state: { mode: "tracking" }, at: 1500 },
      { state: { mode: "tracking" }, at: 2100 }
    ], "standard")
    compare(writes(steps), ["standard", "", "", "standard"])
  }

  function test_retries_stop_eventually() {
    var reads = []
    for (var i = 0; i < 10; i++) reads.push({ state: { mode: "tracking" }, at: i * 5000 })
    var steps = run(reads, "standard")
    compare(writes(steps).filter(function(w) { return w !== "" }).length, Model.MODE_SYNC_ATTEMPTS)
    verify(!Model.modeSyncPending(steps[steps.length - 1].memory),
           "or the fast poll would keep running for the rest of the call")
  }

  function test_a_landed_write_clears_the_pending_state() {
    var steps = run([
      { state: { mode: "tracking" }, at: 0 },
      { state: { mode: "standard" }, at: 2500 }
    ], "standard")
    verify(Model.modeSyncPending(steps[0].memory))
    verify(!Model.modeSyncPending(steps[1].memory))
  }

  function test_a_change_mid_call_is_undone_not_adopted() {
    var steps = run([
      { state: { mode: "standard" }, at: 0 },
      { state: { mode: "standard" }, at: 6000 },
      { state: { mode: "tracking" }, at: 12000 },
      { state: { mode: "standard" }, at: 14500 }
    ], "standard")
    compare(writes(steps), ["", "", "standard", ""])
  }

  function test_a_mid_call_change_gets_fresh_retries() {
    // the attempt budget is per disagreement, not per call
    var reads = []
    for (var i = 0; i < 6; i++) reads.push({ state: { mode: "tracking" }, at: i * 5000 })
    reads.push({ state: { mode: "standard" }, at: 40000 })
    reads.push({ state: { mode: "tracking" }, at: 50000 })
    var steps = run(reads, "standard")
    compare(steps[steps.length - 1].write, "standard")
  }

  function test_the_lens_reopening_mid_call_gets_the_pick() {
    var memory = run([{ state: { mode: "tracking" }, at: 0 }], "tracking")[0].memory
    var shut = Model.modeSync(memory, live({ privacy: true, mode: "privacy" }), "tracking", 6000)
    var open = Model.modeSync(shut.memory, live({ mode: "standard" }), "tracking", 12000)
    compare(open.write, "tracking")
  }

  function test_a_pick_by_hand_is_not_resent_by_the_settle_read() {
    var memory = Model.modeMemoryAfterPick("tracking", 1000)
    var early = Model.modeSync(memory, live({ mode: "standard" }), "tracking", 1400)
    compare(early.write, "")
    var later = Model.modeSync(early.memory, live({ mode: "standard" }), "tracking", 3100)
    compare(later.write, "tracking")
  }

  function test_chips_work_idle_only_with_the_lens_open() {
    var idleOpen = { present: true, privacy: false, streaming: false, selfStreaming: false }
    var idleShut = { present: true, privacy: true, streaming: false, selfStreaming: false }
    var idleUnknown = { present: true, privacy: null, streaming: false, selfStreaming: false }
    verify(Model.modeChoosable(idleOpen, true))
    verify(!Model.modeChoosable(idleOpen, false))
    verify(!Model.modeChoosable(idleShut, true))
    verify(!Model.modeChoosable(idleUnknown, true))
    verify(!Model.modeChoosable({ present: false }, true))
    verify(Model.modeChoosable({ present: true, privacy: true, streaming: true }, false))
  }

  function test_the_note_says_a_pick_made_while_idle_is_kept() {
    var idle = Model.parseState(JSON.stringify({
      ok: true, present: true, streaming: false, privacy: false,
      mode: null, modeUnknown: "needs-stream", modeRaw: 3
    }))
    var note = Model.modeNote(idle, "tracking")
    verify(note.indexOf("Tracking is saved") === 0, note)
    verify(Model.modeNote(idle, "").indexOf("Turn the preview on") >= 0)
  }

  function test_the_remembered_mode_is_parsed_from_state() {
    function parsed(value) {
      return Model.parseState(JSON.stringify({ ok: true, present: true, remembered: value })).remembered
    }
    compare(parsed("standard"), "standard")
    compare(parsed("tracking"), "tracking")
    compare(parsed("privacy"), null)
    compare(parsed(null), null)
    compare(parsed(undefined), null)
    compare(Model.parseState("").remembered, null)
  }

  function test_the_remember_command_is_one_argv() {
    compare(Model.rememberArgs("/x/pixy", "tracking"), ["/x/pixy", "remember", "tracking"])
  }
}
