// Remembered framing: what framingSync does with each state read.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest
import "../../Model.js" as Model

TestCase {
  name: "FramingSync"

  function cam(props) {
    var s = { present: true, privacy: false, streaming: true, selfStreaming: false,
              mode: "standard", ptzKnown: true, pan: 0, tilt: -5 }
    for (var k in props) s[k] = props[k]
    return s
  }

  // feeds reads through framingSync the way the panel does, returning every write
  function run(reads, enabled) {
    var live = false
    var writes = []
    for (var i = 0; i < reads.length; i++) {
      var step = Model.framingSync(live, cam(reads[i]), enabled === undefined ? true : enabled,
                                   !!reads[i].moving)
      live = step.live
      writes.push(step.write)
    }
    return writes
  }

  function test_a_call_starting_writes_the_shown_angles_back() {
    // the lens opens at stream start and the motors go to 0,0 while the readback stays -5
    compare(run([{ streaming: false, mode: null }, {}]), [null, { pan: 0, tilt: -5 }])
  }

  function test_once_per_edge_not_on_every_read() {
    compare(run([{}, {}, {}]), [{ pan: 0, tilt: -5 }, null, null])
  }

  function test_the_lens_reopening_mid_call_writes_again() {
    var writes = run([{}, { privacy: true, mode: "privacy" }, {}])
    compare(writes, [{ pan: 0, tilt: -5 }, null, { pan: 0, tilt: -5 }])
  }

  function test_tracking_handing_over_to_standard_writes_again() {
    // tracking moves the motors without touching the readback, and Standard leaves them there
    var writes = run([{}, { mode: "tracking" }, { mode: "tracking" }, {}])
    compare(writes, [{ pan: 0, tilt: -5 }, null, null, { pan: 0, tilt: -5 }])
  }

  function test_nothing_while_tracking_owns_the_motors() {
    compare(run([{ mode: "tracking" }]), [null])
  }

  function test_a_mode_not_read_yet_waits_for_it() {
    // the first read of a call can come back before the mode does
    compare(run([{ mode: null }, {}]), [null, { pan: 0, tilt: -5 }])
  }

  function test_our_own_preview_counts_as_in_use() {
    compare(run([{ streaming: false, selfStreaming: true }]), [{ pan: 0, tilt: -5 }])
  }

  function test_nothing_while_idle_or_closed_or_unplugged() {
    compare(run([{ streaming: false }]), [null])
    compare(run([{ privacy: true, mode: "privacy" }]), [null])
    compare(run([{ privacy: null }]), [null])
    compare(run([{ present: false }]), [null])
    verify(!Model.framingSync(false, null, true, false).live)
  }

  function test_angles_that_were_not_read_are_never_written() {
    // pan/tilt fall back to 0 on a failed read, writing that would recenter the camera
    compare(run([{ ptzKnown: false, pan: 0, tilt: 0 }]), [null])
  }

  function test_switched_off_writes_nothing_but_still_follows_the_edge() {
    compare(run([{}, {}], false), [null, null])
    verify(Model.framingSync(false, cam({}), false, false).live,
           "or turning it on mid-call would fire on the next read")
  }

  function test_a_move_in_flight_wins() {
    // the readback can predate the user's own pan/tilt, and the edge is spent either way
    compare(run([{ moving: true }, {}]), [null, null])
  }

  function test_parse_state_says_whether_the_angles_were_read() {
    verify(Model.parseState(JSON.stringify({ present: true, pan: 0, tilt: -5 })).ptzKnown)
    verify(!Model.parseState(JSON.stringify({ present: true, videoError: "busy" })).ptzKnown)
    verify(!Model.parseState("").ptzKnown)
  }

  function test_on_unless_turned_off() {
    verify(Model.callSettingDefault("rememberFraming"))
  }
}
