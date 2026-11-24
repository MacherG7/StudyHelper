import Foundation
import Testing

@testable import StudyCore

private func usd(_ estimate: CostEstimate) -> Double { estimate.usd ?? -1 }

@Suite("Preise")
struct PricingTests {
    @Test("Claude: Cache-Tokens stehen neben den Input-Tokens")
    func claudeCache() {
        // sonnet 5.5: 2 / 10, cache read 0.10, cache write 2.5
        let cost = CostEstimate.compute(
            model: "claude-sonnet-5-5", usdToEurRate: 0.5, input: 1_000_000, output: 100_000,
            cacheRead: 2_000_000, cacheWrite: 1_000_000, cacheIncludedInInput: false)
        #expect(abs(usd(cost) - (2 + 1 + 0.2 + 2.5)) < 1e-9)
        #expect(abs((cost.eur ?? 0) - usd(cost) * 0.5) < 1e-9)
    }

    @Test("OpenAI: Cache-Tokens sind Teil des Inputs, Reasoning steckt im Output")
    func openAICached() {
        // gpt-5.5: 5 / 0.50 / 30; input 1M of which 400k cached
        let cost = CostEstimate.compute(
            model: "gpt-5.5", usdToEurRate: 1, input: 1_000_000, output: 100_000, cacheRead: 400_000,
            reasoning: 60_000, cacheIncludedInInput: true)
        #expect(abs(usd(cost) - (0.6 * 5 + 0.4 * 0.5 + 0.1 * 30)) < 1e-9)
    }

    @Test("Reasoning wird nur addiert, wenn es nicht im Output steckt")
    func reasoningSeparate() {
        let included = CostEstimate.compute(
            model: "gpt-5", usdToEurRate: 1, input: 0, output: 1_000_000, reasoning: 500_000, cacheIncludedInInput: true)
        let separate = CostEstimate.compute(
            model: "gpt-5", usdToEurRate: 1, input: 0, output: 1_000_000, reasoning: 500_000,
            reasoningIncludedInOutput: false, cacheIncludedInInput: true)
        #expect(abs(usd(included) - 10) < 1e-9)
        #expect(abs(usd(separate) - 15) < 1e-9)
    }

    @Test("Haiku 5.5: langer Prompt über 100K nutzt den höheren Preis")
    func haikuLong() {
        let short = CostEstimate.compute(
            model: "claude-haiku-5-5", usdToEurRate: 1, input: 100_000, output: 10_000, cacheIncludedInInput: false)
        let long = CostEstimate.compute(
            model: "claude-haiku-5-5", usdToEurRate: 1, input: 100_001, output: 10_000, cacheIncludedInInput: false)
        #expect(abs(usd(short) - (0.01 + 0.005)) < 1e-9)
        #expect(abs(usd(long) - (100_001 * 0.5 / 1e6 + 10_000 * 2.5 / 1e6)) < 1e-9)
    }

    @Test("Langer Prompt zählt Cache-Tokens mit")
    func haikuLongWithCache() {
        let cost = CostEstimate.compute(
            model: "claude-haiku-5-5", usdToEurRate: 1, input: 10, output: 0, cacheRead: 150_000, cacheIncludedInInput: false)
        #expect(abs(usd(cost) - (10 * 0.5 / 1e6 + 150_000 * 0.01 / 1e6)) < 1e-9)
    }

    @Test("Unbekanntes Modell ergibt unbekannt, kostenloser Anbieter 0")
    func unknownAndFree() {
        #expect(CostEstimate.compute(model: "llama3", usdToEurRate: 1, input: 1, output: 1, cacheIncludedInInput: true) == .unknown)
        let free = CostEstimate.compute(
            model: "llama3", isFree: true, usdToEurRate: 1, input: 1, output: 1, cacheIncludedInInput: true)
        #expect(free == .free)
        #expect(free.usd == 0 && free.eur == 0)
        #expect(CostEstimate.unknown.usd == nil)
    }

    @Test("Ohne Usage-Angaben ist der Preis unbekannt")
    func noUsage() {
        #expect(CostEstimate.compute(model: "gpt-5", usdToEurRate: 1, input: nil, output: nil, cacheIncludedInInput: true) == .unknown)
    }

    @Test("Datierte Varianten finden den längsten passenden Präfix")
    func prefixMatch() {
        let table = PriceTable()
        #expect(table.price(for: "claude-sonnet-5-5-20261001")?.input == 2)
        #expect(table.price(for: "gpt-5.4-mini-2026-03-01")?.input == 0.75)
        #expect(table.price(for: "gpt-5.4-2026-03-01")?.input == 2.5)
        #expect(table.price(for: "gpt-5.4")?.output == 15)
        #expect(table.price(for: "gpt-50") == nil)
        #expect(table.price(for: "claude-opus-5-5")?.input == 4)
        #expect(table.price(for: "claude-opus-5-20261001")?.input == 5)
    }

    @Test("Standardregeln für Cache: Lesen 10 %, Schreiben 125 % des Inputs")
    func cacheDefaults() throws {
        let price = try #require(PriceTable().price(for: "claude-opus-5"))
        #expect(abs(price.cacheRead - 0.5) < 1e-9)
        #expect(abs(price.cacheWrite - 6.25) < 1e-9)
    }

    @Test("Eigene Preise gewinnen")
    func overrideWins() {
        let table = PriceTable(overrides: ["gpt-5": ModelPrice(input: 100, output: 200)])
        #expect(table.price(for: "gpt-5")?.input == 100)
        #expect(table.price(for: "gpt-5-2026-01-01")?.input == 100)
        #expect(table.price(for: "gpt-5-mini")?.input == 0.25)
        let cost = CostEstimate.compute(
            model: "gpt-5", table: table, usdToEurRate: 1, input: 1_000_000, output: 0, cacheIncludedInInput: true)
        #expect(abs(usd(cost) - 100) < 1e-9)
    }
}
