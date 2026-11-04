// SPDX-License-Identifier: GPL-3.0-only
@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import CopiatorCore

/// Gerçek bir film dosyası (AVAssetWriter ile H.264, 1280×720, 2 saniye, QuickTime kamera modeli ve oluşturulma tarihi):
/// süre, çözünürlük, çekim tarihi ve kamera modeli dosyadan okunur ve kurallarda kullanılır.
@Test func readsDetailsFromARealMovie() async throws {
    let workspace = try Workspace()
    let movie = workspace.url("Videolar/klip.mov")
    try FileManager.default.createDirectory(at: movie.deletingLastPathComponent(), withIntermediateDirectories: true)
    let taken = Date(timeIntervalSince1970: 1_700_000_000)
    try await writeMovie(movie, width: 1280, height: 720, seconds: 2, model: "TestCam Video 2", creation: taken)
    try workspace.write("Videolar/notlar.txt", "x")

    let info = try #require(await MediaInfo.load(movie, type: .quickTimeMovie))
    #expect(abs((info.duration ?? 0) - 2) < 0.2, "\(info)")
    #expect(info.pixelWidth == 1280 && info.pixelHeight == 720)
    #expect(info.longestSide == 1280)
    #expect(info.cameraModel == "TestCam Video 2")
    #expect(abs((info.captureDate ?? .distantPast).timeIntervalSince(taken)) < 1)

    func scan(_ conditions: [RuleCondition]) async throws -> [String] {
        try await RuleScanner.scan(workspace.url("Videolar"), rules: RuleGroup(conditions: conditions)).paths
    }
    #expect(try await scan([RuleCondition(attribute: .duration, op: .greaterThan, number: 1, unit: .seconds)]) == ["klip.mov"])
    #expect(try await scan([RuleCondition(attribute: .duration, op: .greaterThan, number: 1, unit: .minutes)]).isEmpty)
    #expect(try await scan([RuleCondition(attribute: .resolution, op: .lessThan, number: 1920)]) == ["klip.mov"])
    #expect(try await scan([RuleCondition(attribute: .cameraModel, op: .contains, value: "testcam")]) == ["klip.mov"])
    #expect(try await scan([RuleCondition(attribute: .captureDate, op: .after, date: taken.addingTimeInterval(-3 * 86_400))]) == ["klip.mov"])
}

private func writeMovie(_ url: URL, width: Int, height: Int, seconds: Int, model: String, creation: Date) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    let modelItem = AVMutableMetadataItem()
    modelItem.identifier = .quickTimeMetadataModel
    modelItem.value = model as NSString
    let dateItem = AVMutableMetadataItem()
    dateItem.identifier = .quickTimeMetadataCreationDate
    dateItem.value = ISO8601DateFormatter().string(from: creation) as NSString
    writer.metadata = [modelItem, dateItem]
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let fps: Int32 = 10
    for frame in 0..<(seconds * Int(fps)) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 10 % 255), CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds) * CMTimeValue(fps), timescale: fps))
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
}
