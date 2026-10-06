import Testing
@testable import CallWhisperCore

/// Słownictwo dla whispera wyciągane z kontekstu projektu.
struct VocabularyTests {
    let context = """
    ## Kandydat
    Stack: Next.js, React, **Nuxt**, Python/Django, Playwright. Pracuje z Pythonem.
    Testy w Vitest i Playwright, React Native w Acme. Talent Huby w Brazylii.
    Ściąga: `defineModel`, `useFetch`. Projekt m.in. example.com, wymóg DPP, CV i UI.
    """

    @Test func wyciagaNazwyTechnologii() {
        let terms = Vocabulary.terms(from: context)
        for expected in ["Next.js", "Nuxt", "Playwright", "Vitest", "React Native", "example.com", "DPP"] {
            #expect(terms.contains(expected), "brak \(expected) w \(terms)")
        }
    }

    @Test func pomijaKodSkrotyIPoczatekZdania() {
        let terms = Vocabulary.terms(from: context)
        for unwanted in ["defineModel", "useFetch", "m.in", "CV", "UI", "Stack", "Testy", "Ściąga", "Projekt"] {
            #expect(!terms.contains(unwanted), "\(unwanted) nie powinno trafić do \(terms)")
        }
    }

    @Test func odmianyZostajaRaz() {
        let terms = Vocabulary.terms(from: "Używam Figma. Projekty w Figmie i z Figmy, znowu w Figmie.")
        #expect(terms.filter { $0.lowercased().hasPrefix("figm") }.count == 1)
    }

    @Test func polskieOdmianyNaKoncu() {
        let terms = Vocabulary.terms(from: context)
        let brazil = terms.firstIndex(of: "Brazylii")!
        #expect(terms.firstIndex(of: "Next.js")! < brazil)
        #expect(terms.firstIndex(of: "Playwright")! < brazil)
    }

    @Test func scalanieNieDublujeIPilnujeLimitu() {
        let merged = Vocabulary.merge("React, Next.js, Python.", context: context, maxChars: 80)
        #expect(merged.hasPrefix("React, Next.js, Python, "))
        #expect(merged.count <= 80)
        #expect(!merged.contains("Pythonem"))
        #expect(merged.components(separatedBy: "Next.js").count == 2)
        #expect(Vocabulary.merge("", context: "") == "")
    }
}
