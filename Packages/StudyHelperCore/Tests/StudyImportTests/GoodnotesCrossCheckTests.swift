import Foundation
import StudyCore
import StudyImport
import TestFixtures
import Testing

@Suite("Goodnotes: Abgleich mit dem reduzierten PDF")
struct GoodnotesCrossCheckTests {
    @Test("Genau die fünf absichtlichen Erkennungsfehler werden als abweichend markiert")
    func flagsExactlyTheOCRErrors() throws {
        let editable = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        let reduced = try GoodnotesTestSupport.load(.fotosyntheseReduced)
        #expect(reduced.truth.ocrErrors.count == 5)
        let expectedMismatches = Set(reduced.truth.ocrErrors.map(\.inkWordID))

        var mismatched = Set<String>()
        var confirmed = Set<String>()
        var untouched = Set<String>()
        for pageIndex in 0..<3 {
            let perfect = GoodnotesTestSupport.perfectPage(truth: editable.truth, pageNumber: pageIndex + 1)
            let checked = ReducedPDFComparator.crossCheck(lines: perfect.lines, against: reduced.document.pages[pageIndex])
            #expect(checked.count == perfect.lines.count)
            for (original, line) in zip(perfect.lines, checked) {
                #expect(line.id == original.id && line.text == original.text && line.rect == original.rect)
                var lineHasMismatch = false
                for (index, word) in line.words.enumerated() {
                    let id = try #require(perfect.itemIDs[WordReference(lineID: line.id, wordIndex: index)])
                    #expect(word.text == original.words[index].text && word.rect == original.words[index].rect)
                    if word.reviewReasons.contains(.mismatchWithReducedPDF) {
                        mismatched.insert(id)
                        lineHasMismatch = true
                        #expect(word.status == .uncertain)
                        #expect(!word.reviewReasons.contains(.confirmedByReducedPDF))
                    } else if word.reviewReasons.contains(.confirmedByReducedPDF) {
                        confirmed.insert(id)
                        #expect(word.status == .confident)
                    } else {
                        untouched.insert(id)
                    }
                }
                if lineHasMismatch {
                    #expect(line.status == .uncertain)
                    #expect(line.reviewReasons.contains(.mismatchWithReducedPDF))
                    #expect(line.needsReview)
                } else {
                    #expect(line.status == .confident)
                    #expect(!line.reviewReasons.contains(.mismatchWithReducedPDF))
                }
            }
        }
        #expect(mismatched == expectedMismatches, "abweichend: \(mismatched.sorted())")
        let allWords = Set(editable.truth.items(ofKind: .inkWord).map(\.id))
        #expect(untouched.isEmpty, "ohne Gegenstück: \(untouched.sorted())")
        #expect(confirmed == allWords.subtracting(expectedMismatches))
    }

    @Test("Ohne Gegenstück bleibt ein Wort unverändert, Nutzerkorrektur behält den Zeilenstatus")
    func noCounterpartAndUserCorrection() throws {
        let reduced = try GoodnotesTestSupport.load(.fotosyntheseReduced)
        let page = reduced.document.pages[0]
        let far = NormalizedRect(x: 0.9, y: 0.97, width: 0.05, height: 0.02)
        let lonely = RecognizedWord(text: "Einzelgänger", rect: far)
        let line = RecognizedLine(text: "Einzelgänger", rect: far, words: [lonely])
        let result = ReducedPDFComparator.crossCheck(lines: [line], against: page)
        #expect(result == [line])

        // A deliberately wrong word where the text layer says "Fotosynthese".
        let heading = try #require(page.textLayer.first { $0.text == "Fotosynthese" })
        let wrong = RecognizedWord(text: "Fotosynthese", rect: heading.rect)
        let misread = RecognizedWord(text: "Fotosynthere", rect: heading.rect)
        let normal = RecognizedLine(text: "x", rect: heading.rect, words: [misread])
        var corrected = normal
        corrected.isUserCorrected = true
        let checked = ReducedPDFComparator.crossCheck(lines: [normal, corrected], against: page)
        #expect(checked[0].status == .uncertain)
        #expect(checked[0].words[0].status == .uncertain)
        #expect(checked[1].status == .confident)
        #expect(!checked[1].needsReview)
        #expect(checked[1].words[0].reviewReasons.contains(.mismatchWithReducedPDF))

        let fine = RecognizedLine(text: "Fotosynthese", rect: heading.rect, words: [wrong])
        let confirmed = ReducedPDFComparator.crossCheck(lines: [fine], against: page)[0]
        #expect(confirmed.status == .confident)
        #expect(confirmed.words[0].reviewReasons == [.confirmedByReducedPDF])
    }

    @Test("Groß-/Kleinschreibung und Satzzeichen zählen nicht als Abweichung")
    func caseAndPunctuationAreIgnored() throws {
        let reduced = try GoodnotesTestSupport.load(.fotosyntheseReduced)
        let page = reduced.document.pages[0]
        let ort = try #require(page.textLayer.first { $0.text == "Ort:" })
        let word = RecognizedWord(text: "ORT", rect: ort.rect)
        let line = RecognizedLine(text: "ORT", rect: ort.rect, words: [word])
        let checked = ReducedPDFComparator.crossCheck(lines: [line], against: page)[0]
        #expect(checked.words[0].reviewReasons == [.confirmedByReducedPDF])
    }

    @Test("Ein leeres Textlayer lässt alles unverändert")
    func emptyTextLayer() throws {
        let editable = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        let perfect = GoodnotesTestSupport.perfectPage(truth: editable.truth, pageNumber: 1)
        let result = ReducedPDFComparator.crossCheck(lines: perfect.lines, against: editable.document.pages[0])
        #expect(result == perfect.lines)
    }
}
