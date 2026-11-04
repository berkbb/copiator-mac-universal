// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// İlerleme penceresi hızlı işlemlerde göz kırpar gibi açılıp kapanmaz: en az gösterim süresini doldurur.
@MainActor @Suite struct OverlayTimingTests {
    let start = ContinuousClock.now

    @Test func quickOperationLingersForTheRestOfTheMinimum() {
        let remaining = OverlayTiming.remaining(shownAt: start, now: start + .milliseconds(100), outcome: .succeeded, isDeterminate: false)
        #expect(remaining == OverlayTiming.minimumDuration - .milliseconds(100))
    }

    @Test func slowIndeterminateOperationClosesImmediately() {
        #expect(OverlayTiming.remaining(shownAt: start, now: start + OverlayTiming.minimumDuration, outcome: .succeeded, isDeterminate: false) == nil)
        #expect(OverlayTiming.remaining(shownAt: start, now: start + .seconds(3), outcome: .succeeded, isDeterminate: false) == nil)
    }

    /// Uzun kopyalamada çubuk %98'deyken pencere aniden kaybolmaz: %100 kısa bir an görünür.
    @Test func slowDeterminateSuccessShowsCompletionBeat() {
        #expect(OverlayTiming.remaining(shownAt: start, now: start + .seconds(12), outcome: .succeeded, isDeterminate: true) == OverlayTiming.completionBeat)
    }

    @Test func quickDeterminateSuccessUsesTheLongerOfMinimumAndBeat() {
        let remaining = OverlayTiming.remaining(shownAt: start, now: start + .milliseconds(100), outcome: .succeeded, isDeterminate: true)
        #expect(remaining == OverlayTiming.minimumDuration - .milliseconds(100))
        let late = OverlayTiming.remaining(shownAt: start, now: start + .milliseconds(600), outcome: .succeeded, isDeterminate: true)
        #expect(late == OverlayTiming.completionBeat)
    }

    /// İptal ve hata: pencere hemen kapanır; iptal edilen işlem "tamamlandı" (%100) görünmez.
    @Test(arguments: [OperationOutcome.cancelled, .failed])
    func cancelAndFailureCloseImmediately(outcome: OperationOutcome) {
        #expect(OverlayTiming.remaining(shownAt: start, now: start + .milliseconds(50), outcome: outcome, isDeterminate: true) == nil)
        #expect(OverlayTiming.remaining(shownAt: start, now: start + .milliseconds(50), outcome: outcome, isDeterminate: false) == nil)
    }

    /// Hazırlık adımı (sonuç yok): ardından gerçek işlem başlar, en az süre kuralı aynen uygulanır.
    @Test func preparationStepKeepsMinimumRule() {
        #expect(OverlayTiming.remaining(shownAt: start, now: start + .milliseconds(200), outcome: nil, isDeterminate: false) == .milliseconds(500))
        #expect(OverlayTiming.remaining(shownAt: start, now: start + .seconds(1), outcome: nil, isDeterminate: false) == nil)
    }

    @Test func customMinimumIsRespected() {
        #expect(OverlayTiming.remaining(shownAt: start, now: start + .milliseconds(50), outcome: .succeeded, isDeterminate: false, minimum: .milliseconds(200)) == .milliseconds(150))
    }

    @Test func finishedStateCompletesDeterminateProgressOnly() {
        let determinate = OperationState(titleKey: .progressVerifying, progress: 0.4)
        let finished = OverlayTiming.finished(determinate)
        #expect(finished.progress == 1)
        #expect(finished.id == determinate.id)
        #expect(finished.titleKey == .progressVerifying)

        let indeterminate = OperationState(titleKey: .progressUpdatingEngine, progress: nil)
        #expect(OverlayTiming.finished(indeterminate).progress == nil)
    }
}
