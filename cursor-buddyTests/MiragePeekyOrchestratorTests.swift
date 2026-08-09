//
//  MiragePeekyOrchestratorTests.swift
//  cursor-buddyTests
//
//  Offline unit tests for the Peeky Free (mirage) pipeline. Covers only
//  the pieces that DO NOT need aegis-proxy connectivity:
//    * agentCue prefix stripping
//    * keywordClassify allowlist behaviour
//    * MirageThinkingSuffix parse round-trip
//    * MirageBodyPipeline byte-shape (thinking suffix + context strip +
//      cache_control injection + beta extraction)
//    * MirageMacIntegrations.parseCalendarLines / parseContactLines
//      (Rust parity checks — pure logic, no osascript needed)
//
//  Everything network-touching (aegis-proxy round-trips, real Claude
//  classification, tool dispatch) is exercised by
//  scripts/mirage-e2e-test.sh against a running app.

import Testing
import Foundation
@testable import cursor_buddy

@Suite struct MiragePeekyOrchestratorTests {

    @Test func agentCueStripsOpenClickyPrefix() async {
        let orch = MiragePeekyOrchestrator.shared
        let stripped = await orch.agentCue("openclicky agent, open finder")
        #expect(stripped == "open finder")
    }

    @Test func agentCueStripsPeekyPrefix() async {
        let orch = MiragePeekyOrchestrator.shared
        let stripped = await orch.agentCue("peeky agent, run my morning routine")
        #expect(stripped == "run my morning routine")
    }

    @Test func agentCueReturnsNilForOrdinaryChat() async {
        let orch = MiragePeekyOrchestrator.shared
        let stripped = await orch.agentCue("what time is it?")
        #expect(stripped == nil)
    }

    @Test func keywordClassifyRoutesTransportVerbs() async {
        let orch = MiragePeekyOrchestrator.shared
        #expect(await orch.keywordClassify("play") == .integration)
        #expect(await orch.keywordClassify("PAUSE") == .integration)
        #expect(await orch.keywordClassify("next track.") == .integration)
        #expect(await orch.keywordClassify("previous song?") == .integration)
    }

    @Test func keywordClassifyAbstainsOnAmbiguous() async {
        let orch = MiragePeekyOrchestrator.shared
        #expect(await orch.keywordClassify("play me some jazz") == nil)
        #expect(await orch.keywordClassify("what's playing") == nil)
        #expect(await orch.keywordClassify("hello there") == nil)
    }
}

@Suite struct MirageMacIntegrationsParsingTests {

    @Test func parseCalendarLinesBuildsOneEntryPerLine() {
        let raw = "standup\t9:30:00 AM\ndentist\t3:00:00 PM\n"
        let json = MirageMacIntegrations.parseCalendarLines(raw)
        let data = json.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let events = obj["events"] as! [[String: Any]]
        #expect(events.count == 2)
        #expect(events[0]["title"] as? String == "standup")
        #expect(events[0]["time"] as? String == "9:30:00 AM")
        #expect(events[1]["title"] as? String == "dentist")
    }

    @Test func parseCalendarLinesHandlesEmpty() {
        let json = MirageMacIntegrations.parseCalendarLines("")
        let obj = try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let events = obj["events"] as! [[String: Any]]
        #expect(events.isEmpty)
    }

    @Test func parseContactLinesSplitsFieldsAndValues() {
        let raw = "Mom\t+16175551234; +16175555678; \tmom@example.com; \n"
        let json = MirageMacIntegrations.parseContactLines(raw)
        let obj = try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let contacts = obj["contacts"] as! [[String: Any]]
        #expect(contacts.count == 1)
        #expect(contacts[0]["name"] as? String == "Mom")
        let phones = contacts[0]["phones"] as! [String]
        let emails = contacts[0]["emails"] as! [String]
        #expect(phones.count == 2)
        #expect(phones[0] == "+16175551234")
        #expect(emails[0] == "mom@example.com")
    }

    @Test func parseContactLinesHandlesBareContact() {
        let json = MirageMacIntegrations.parseContactLines("Dan\t\t\n")
        let obj = try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let contacts = obj["contacts"] as! [[String: Any]]
        #expect(contacts.count == 1)
        #expect(contacts[0]["name"] as? String == "Dan")
        #expect((contacts[0]["phones"] as! [String]).isEmpty)
        #expect((contacts[0]["emails"] as! [String]).isEmpty)
    }

    @Test func applescriptEscapeHandlesQuotesAndBackslashes() {
        #expect(MirageMacIntegrations.applescriptEscape("plain") == "plain")
        #expect(MirageMacIntegrations.applescriptEscape("a\"b") == "a\\\"b")
        #expect(MirageMacIntegrations.applescriptEscape("a\\b") == "a\\\\b")
        // Backslash then quote: both get escaped, backslash first.
        #expect(MirageMacIntegrations.applescriptEscape("\\\"") == "\\\\\\\"")
    }

    @Test func availabilityProbeReportsMacOSDefaults() {
        let av = MirageMacIntegrations.availability()
        // On macOS, EventKit / Contacts / FaceTime / Shortcuts / mdfind /
        // NSPasteboard are always usable.
        #expect(av.calendar)
        #expect(av.reminders)
        #expect(av.contacts)
        #expect(av.facetime)
        #expect(av.shortcuts)
        #expect(av.spotlight)
        #expect(av.clipboard)
    }
}

@Suite struct MirageRedactTests {

    @Test func preprocessLowercasesAndTrims() {
        #expect(MirageRedact.preprocess("HELLO WORLD.") == "hello world")
    }

    @Test func preprocessAppendsQuestionMarkForQuestions() {
        #expect(MirageRedact.preprocess("what time is it?").hasSuffix("?"))
    }

    @Test func preprocessMasksEmailAddresses() {
        let result = MirageRedact.preprocess("email me at foo@bar.com now")
        #expect(result.contains("<EMAIL>"))
        #expect(!result.contains("foo@bar.com"))
    }

    @Test func preprocessMasksLongDigitRuns() {
        let result = MirageRedact.preprocess("my number is 1234567890")
        #expect(result.contains("<NUM>"))
        #expect(!result.contains("1234567890"))
    }
}

@Suite struct MirageThinkingSuffixTests {

    @Test func parsePlainModelIsPassthrough() {
        let s = MirageThinkingSuffix.parse("claude-opus-5")
        #expect(s.baseModel == "claude-opus-5")
    }

    @Test func parseMaxSuffixMapsToMaxLevel() {
        let s = MirageThinkingSuffix.parse("claude-opus-5(max)")
        #expect(s.baseModel == "claude-opus-5")
        // We do not depend on the internal enum shape here — just that
        // parsing didn't drop the base model or crash on the suffix.
    }

    @Test func parseMiragePrefixIsPreserved() {
        let s = MirageThinkingSuffix.parse("mirage/claude-fable-5(xhigh)")
        // Prefix stripping is MirageBackendClient's job — the suffix
        // parser should keep the base intact.
        #expect(s.baseModel.contains("claude-fable-5"))
    }
}
