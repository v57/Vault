import Foundation
import Testing

@testable import VaultKit

struct ItemFieldsTests {
  let mac = "mac"
  let phone = "phone"

  func clock(_ millis: Int64, _ device: String, counter: Int = 0) -> HybridClock {
    HybridClock(millis: millis, counter: counter, device: device)
  }

  @Test func clockTextSortsLikeTheClock() {
    let clocks = [clock(5, "b"), clock(5, "a", counter: 2), clock(1_700_000_000_000, "a"), clock(5, "a")]
    #expect(clocks.sorted().map(\.description) == clocks.map(\.description).sorted())
    for value in clocks { #expect(HybridClock(value.description) == value) }
  }

  @Test func clockNeverRunsBackwards() {
    let later = clock(10_000, mac)
    let next = later.next(now: Date(timeIntervalSince1970: 1), device: mac)
    #expect(next > later)
    #expect(next.millis == later.millis)
    #expect(next.counter == 1)
  }

  @Test func editsToDifferentFieldsBothSurvive() {
    var base = ItemFields()
    base.apply(["name": "prod", "port": 22], clock: clock(1, mac))
    var onMac = base
    onMac.apply(["port": 2222], clock: clock(5, mac))
    var onPhone = base
    onPhone.apply(["name": "Production"], clock: clock(3, phone))

    let merged = onMac.merged(with: onPhone)
    #expect(merged.values == ["name": "Production", "port": 2222])
    #expect(merged == onPhone.merged(with: onMac))
  }

  @Test func theLaterWriteOfOneFieldWinsEverywhere() {
    var onMac = ItemFields()
    onMac.apply(["name": "mac"], clock: clock(7, mac))
    var onPhone = ItemFields()
    onPhone.apply(["name": "phone"], clock: clock(9, phone))
    #expect(onMac.merged(with: onPhone).values["name"] == "phone")
    #expect(onPhone.merged(with: onMac).values["name"] == "phone")
  }

  @Test func equalClocksPickTheSameValueOnEveryDevice() {
    var a = ItemFields()
    a.apply(["name": "a"], clock: clock(7, mac))
    var b = ItemFields()
    b.apply(["name": "b"], clock: clock(7, mac))
    #expect(a.merged(with: b) == b.merged(with: a))
  }

  @Test func aDeleteLosesToALaterEdit() {
    var base = ItemFields()
    base.apply(["name": "db"], clock: clock(1, mac))
    var deleted = base
    deleted.stamped[ItemFields.deletedKey] = StampedValue(true, clock: clock(5, mac))
    #expect(deleted.isDeleted)

    var editedLater = base
    editedLater.apply(["name": "db2"], clock: clock(8, phone))
    #expect(!deleted.merged(with: editedLater).isDeleted)

    var editedEarlier = base
    editedEarlier.apply(["name": "db2"], clock: clock(3, phone))
    #expect(deleted.merged(with: editedEarlier).isDeleted)
  }

  @Test func unchangedValuesKeepTheirClock() {
    var fields = ItemFields()
    fields.apply(["name": "x", "port": 1], clock: clock(1, mac))
    let changed = fields.apply(["name": "x", "port": 2], clock: clock(2, mac))
    #expect(changed)
    #expect(fields.stamped["name"]?.clock == clock(1, mac))
    #expect(fields.stamped["port"]?.clock == clock(2, mac))
    let again = fields.apply(["name": "x"], clock: clock(3, mac))
    #expect(!again)
  }

  @Test func jsonValuesRoundTrip() throws {
    let value: JSONValue = .object([
      "a": 1, "b": .double(1.5), "c": "text", "d": true, "e": nil, "f": .array([1, "x"]),
    ])
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
  }
}
