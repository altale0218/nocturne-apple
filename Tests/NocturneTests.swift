import AVFoundation
import AudioToolbox
import CoreVideo
import CryptoKit
import ImageIO
import Network
import Photos
import Security
import UIKit
import XCTest
@testable import Nocturne

final class NocturneTests: XCTestCase {

    func testAlbumReconnectOnlyRetriesTransportBeforePeerAuthentication() {
        XCTAssertTrue(AppleSyncTransport.retryableConnectionLoss(AppleSyncTransport.Failure.closed))
        XCTAssertTrue(AppleSyncTransport.retryableConnectionLoss(AppleSyncTransport.Failure.timeout))
        XCTAssertTrue(AppleSyncTransport.retryableConnectionLoss(NWError.posix(.ECONNREFUSED)))
        XCTAssertTrue(AppleSyncTransport.retryableConnectionLoss(NWError.posix(.EHOSTUNREACH)))
        XCTAssertFalse(AppleSyncTransport.retryableConnectionLoss(AppleSyncTransport.Failure.authentication))
        XCTAssertFalse(AppleSyncTransport.retryableConnectionLoss(AppleSyncTransport.Failure.certificate))
        XCTAssertFalse(AppleSyncTransport.retryableConnectionLoss(AppleSyncTransport.Failure.rejected("consent173")))
        XCTAssertFalse(AppleSyncTransport.retryableConnectionLoss(NWError.tls(errSSLUnknownRootCert)))
        XCTAssertFalse(AppleSyncTransport.retryableConnectionLoss(CancellationError()))
    }

    func testAlbumTransferMetricsKeepValidatedSizesAndClearStaleRate() throws {
        let live = try XCTUnwrap(AppleAlbumTransferMetrics(done: 2_000, total: 8_000, rate: 1_000, inventory: 100_000))
        XCTAssertEqual(live.fraction, 0.25)
        XCTAssertEqual(live.inventory, 100_000)
        XCTAssertEqual(live.bytesPerSecond, 1_000)
        XCTAssertEqual(live.secondsRemaining, 6)

        let verifying = try XCTUnwrap(AppleAlbumTransferMetrics(done: 8_000, total: 8_000, rate: 1_000, inventory: 7_999))
        XCTAssertEqual(verifying.fraction, 1)
        XCTAssertNil(verifying.inventory)
        XCTAssertNil(verifying.bytesPerSecond)
        XCTAssertNil(verifying.secondsRemaining)

        let waiting = try XCTUnwrap(AppleAlbumTransferMetrics(done: 0, total: 8_000, rate: .infinity, inventory: nil))
        XCTAssertNil(waiting.secondsRemaining)
        XCTAssertNil(AppleAlbumTransferMetrics(done: 8_001, total: 8_000, rate: 1, inventory: nil))
        XCTAssertNil(AppleAlbumTransferMetrics(done: 0, total: 0, rate: 0, inventory: nil))
    }

    func testXiaomiArchivePreservesAllBytesAndRejectsTampering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SecureStorage(root: directory)
        try storage.unlock()
        let lease = try storage.resourceLease193(), archive = XiaomiOriginalArchive(storage: storage, lease: lease)
        let original = Data((0..<2_097_187).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 6)) })
        let raw = directory.appendingPathComponent("dynamic.jpg")
        try original.write(to: raw, options: [.atomic, .completeFileProtection])
        let descriptor = PhotoSyncLibrary.Resource(role: 1, filename: "dynamic.jpg", uti: "public.jpeg",
            bytes: Int64(original.count), sha256: AppleSyncTransport.hex(Data(SHA256.hash(data: original))))
        try archive.preserve(raw, resource: descriptor)
        try archive.verify(descriptor)
        let restored = directory.appendingPathComponent("checked.raw")
        try Data().write(to: restored)
        let io = try FileHandle(forWritingTo: restored)
        try archive.extract(descriptor, to: io)
        try io.close()
        XCTAssertEqual(try Data(contentsOf: restored), original)

        let sealed = directory.appendingPathComponent("AlbumOriginals").appendingPathComponent(descriptor.sha256 + ".nca")
        var corrupt = try Data(contentsOf: sealed)
        corrupt[1_048_620] ^= 1
        try corrupt.write(to: sealed, options: [.atomic, .completeFileProtection])
        XCTAssertThrowsError(try archive.verify(descriptor))
        XCTAssertEqual(try Data(contentsOf: raw), original)
    }

    func testXiaomiClipRemuxUsesOriginalCompressedFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoOnly = directory.appendingPathComponent("frames.mp4")
        try await localMotionFixture(videoOnly)
        let video = directory.appendingPathComponent("fixture.mp4")
        try await addSyntheticAudio(to: videoOnly, output: video)
        let clip = try Data(contentsOf: video)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64), format: format).jpegData(withCompressionQuality: 0.95) { frame in
            UIColor.systemBlue.setFill(); frame.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            UIColor.systemYellow.setFill(); frame.fill(CGRect(x: 8, y: 10, width: 42, height: 22))
        }
        let original = cover + clip
        let file = directory.appendingPathComponent("MVIMG_fixture.jpg")
        try original.write(to: file, options: .completeFileProtection)
        let part = PhotoSyncLibrary.Resource(role: 1, filename: "MVIMG_fixture.jpg", uti: "public.jpeg",
            bytes: Int64(original.count), sha256: AppleSyncTransport.hex(Data(SHA256.hash(data: original))))
        let motion = MobileAlbumManifest.EmbeddedMotion(offset: Int64(cover.count), length: Int64(clip.count), presentationUs: 400_000)
        let metadata = PhotoSyncLibrary.Location(latitude: 32.057832123, longitude: 118.789102345, altitude: 29.123)
        let manifest = try MobileAlbumManifest(id: String(repeating: "8", count: 32), layout: .motion,
            captureMillis: 1_718_890_123_456, location: metadata, favorite: true, resources: [part], embeddedMotion: motion)
        let converted = try await XiaomiLivePhoto.make(manifest, from: file, in: directory)
        XCTAssertTrue(converted.item.live)
        XCTAssertEqual(converted.item.resources.map(\.role), [1, 9])
        XCTAssertEqual(converted.item.location, metadata)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let before = try await localSampleHashes(video, mediaType: .video)
        let after = try await localSampleHashes(converted.files[1], mediaType: .video)
        XCTAssertGreaterThan(before.count, 1)
        XCTAssertEqual(after, before)
        let audioBefore = try await localSampleHashes(video, mediaType: .audio)
        let audioAfter = try await localSampleHashes(converted.files[1], mediaType: .audio)
        XCTAssertGreaterThan(audioBefore.count, 1)
        XCTAssertEqual(audioAfter, audioBefore)
        let movieAsset = AVURLAsset(url: converted.files[1])
        let movieMetadata = try await movieAsset.load(.metadata)
        let marked = movieMetadata.first { $0.identifier?.rawValue == "mdta/com.apple.quicktime.content.identifier" }
        let movieID = try await marked?.load(.stringValue)
        XCTAssertNotNil(movieID)
        let visibleCover = try XCTUnwrap(CGImageSourceCreateWithURL(converted.files[0] as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(visibleCover, 0, nil) as? [String: Any])
        let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
        XCTAssertEqual(maker?["17"] as? String, movieID, "The still image and movie require the same Live Photo content identifier")
        let markerTrack = try await movieAsset.loadTracks(withMediaType: .metadata)
        XCTAssertEqual(markerTrack.count, 1)
        let scanner = try AVAssetReader(asset: movieAsset)
        let timing = AVAssetReaderTrackOutput(track: try XCTUnwrap(markerTrack.first), outputSettings: nil)
        scanner.add(timing)
        let records = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: timing)
        XCTAssertTrue(scanner.startReading())
        let marker = try XCTUnwrap(records.nextTimedMetadataGroup())
        XCTAssertEqual(marker.timeRange.start.seconds, 0.4, accuracy: 0.005)
        XCTAssertTrue(marker.items.contains { $0.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" })
        let native = XCTestExpectation(description: "PhotoKit reads the converted files as a full Live Photo")
        native.assertForOverFulfill = false
        let request = PHLivePhoto.request(withResourceFileURLs: converted.files, placeholderImage: nil,
                                          targetSize: CGSize(width: 128, height: 128), contentMode: .aspectFit) { pair, info in
            guard info[PHLivePhotoInfoIsDegradedKey] as? Bool != true else { return }
            XCTAssertNotNil(pair, "PhotoKit rejected the Live Photo pair: \(info[PHLivePhotoInfoErrorKey] ?? "unknown")")
            native.fulfill()
        }
        await fulfillment(of: [native], timeout: 20)
        PHLivePhoto.cancelRequest(withRequestID: request)
    }

    func testMotionPhotoMarkerUsesTheVisibleTrackTimeline() throws {
        let track = CMTimeRange(start: CMTime(seconds: 0.25, preferredTimescale: 1_000_000),
                                duration: CMTime(seconds: 2, preferredTimescale: 1_000_000))
        let step = CMTime(value: 1, timescale: 24)
        let middle = try XiaomiLivePhoto.stillMarkerRange(in: track, minimumFrame: step, presentationUs: -1)
        XCTAssertEqual(middle.start.seconds, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(middle.duration.seconds, 1.0 / 24.0, accuracy: 0.000_001)
        let explicit = try XiaomiLivePhoto.stillMarkerRange(in: track, minimumFrame: step, presentationUs: 418_240)
        XCTAssertEqual(explicit.start.seconds, 0.418_240, accuracy: 0.000_001)
        let early = try XiaomiLivePhoto.stillMarkerRange(in: track, minimumFrame: step, presentationUs: 0)
        XCTAssertEqual(early.start.seconds, 0.25, accuracy: 0.000_001)
        let late = try XiaomiLivePhoto.stillMarkerRange(in: track, minimumFrame: step, presentationUs: 3_000_000)
        XCTAssertEqual(late.end.seconds, 2.25, accuracy: 0.000_001)
        XCTAssertThrowsError(try XiaomiLivePhoto.stillMarkerRange(in: .invalid, minimumFrame: step, presentationUs: -1))
    }

    private func localMotionFixture(_ destination: URL) async throws {
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64]
        let track = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let options: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                       kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track, sourcePixelBufferAttributes: options)
        writer.add(track)
        guard writer.startWriting() else { throw writer.error ?? MediaError193.unavailable }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw MediaError193.unavailable }
        for frame in 0..<30 {
            while !track.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? MediaError193.verification }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess, let buffer = pixel
                  else { throw MediaError193.unavailable }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(50 + frame * 3), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
                  else { throw writer.error ?? MediaError193.verification }
        }
        track.markAsFinished()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in writer.finishWriting { done.resume() } }
        guard writer.status == .completed else { throw writer.error ?? MediaError193.verification }
    }

    private func addSyntheticAudio(to video: URL, output: URL) async throws {
        let toneURL = output.deletingLastPathComponent().appendingPathComponent("tone.m4a")
        let frameCount: AVAudioFrameCount = 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = samples.floatChannelData?[0] else { throw MediaError193.unavailable }
        samples.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            channel[index] = Float(sin(2 * Double.pi * 440 * Double(index) / 44_100) * 0.18)
        }
        do {
            let writer = try AVAudioFile(forWriting: toneURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: samples)
        }
        let composition = AVMutableComposition()
        for (url, type) in [(video, AVMediaType.video), (toneURL, .audio)] {
            let source = AVURLAsset(url: url)
            let tracks = try await source.loadTracks(withMediaType: type)
            let track = try XCTUnwrap(tracks.first)
            let timeRange = try await track.load(.timeRange)
            let destination = try XCTUnwrap(composition.addMutableTrack(withMediaType: type,
                                                                        preferredTrackID: kCMPersistentTrackID_Invalid))
            try destination.insertTimeRange(timeRange, of: track, at: .zero)
        }
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { done.resume() }
        }
        guard exporter.status == .completed else { throw exporter.error ?? MediaError193.verification }
    }

    private func localSampleHashes(_ url: URL, mediaType: AVMediaType) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: mediaType).first else { throw MediaError193.verification }
        let scanner = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        scanner.add(output)
        guard scanner.startReading() else { throw scanner.error ?? MediaError193.unavailable }
        var hashes: [String] = []
        while let sample = output.copyNextSampleBuffer() {
            // AVFoundation may return an empty edit marker when a new MOV track starts.
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let buffer = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(buffer) > 0 else {
                XCTFail("A nonempty sample has no compressed data in \(url.pathExtension)")
                throw MediaError193.verification
            }
            var data = Data(count: CMBlockBufferGetDataLength(buffer))
            let size = data.count
            let code = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: size, destination: bytes.baseAddress!)
            }
            guard code == noErr else { throw MediaError193.verification }
            hashes.append(AppleSyncTransport.hex(Data(SHA256.hash(data: data))))
        }
        return hashes
    }

    func testAppleAlbumFrameAgreesWithAndroidWireVector() throws {
        let shared = Data((0..<48).map { UInt8($0) })
        let salt = Data((48..<96).map { UInt8($0) })
        let context = Data((96..<128).map { UInt8($0) })
        let cipher = try AppleSyncTransport.Cipher(shared: shared, salt: salt, context: context)
        let data = Data("Nocturne Android iOS sync vector".utf8)
        let expected = "04000000000000000000000020339c71017fe561feae22612d533b250085d93f075108c1632b4f585217c4da86b5ce8d01c2f9611726c0030ac62e6b0d"
        XCTAssertEqual(AppleSyncTransport.hex(try cipher.seal(data, kind: 4, sequence: 0)), expected)
        let server = "0400000000000000000000002018906eb9527b67a275917b16f1372a6ee422d1de8f592a99988d5ff532896ac5d81e7fae382f96b3bbddaf9080404acb"
        let bytes = Data(stride(from: 0, to: server.count, by: 2).map { offset in
            let start = server.index(server.startIndex, offsetBy: offset)
            return UInt8(server[start..<server.index(start, offsetBy: 2)], radix: 16)!
        })
        let header = Data(bytes.prefix(13)), body = Data(bytes.dropFirst(13))
        XCTAssertEqual(try cipher.open(body, header: header, sequence: 0), data)
        XCTAssertThrowsError(try cipher.open(body, header: header, sequence: 1))
        var corrupted = body
        corrupted[0] ^= 0x01
        XCTAssertThrowsError(try cipher.open(corrupted, header: header, sequence: 0))
    }

    func testPhotoSyncUsesAllOriginalPartsAndValidCoordinates() throws {
        let still = PhotoSyncLibrary.Resource(role: 1, filename: "IMG_1.HEIC", uti: "public.heic", bytes: 4096, sha256: String(repeating: "a", count: 64))
        let movie = PhotoSyncLibrary.Resource(role: 9, filename: "IMG_1.MOV", uti: "com.apple.quicktime-movie", bytes: 11000, sha256: String(repeating: "b", count: 64))
        let location = PhotoSyncLibrary.Location(latitude: 32.057832123, longitude: 118.789102345, altitude: 29.123)
        let original = PhotoSyncLibrary.Item(kind: 1, live: true, creation: Date(timeIntervalSince1970: 1730000000.125), location: location, favorite: true, resources: [still, movie])
        try original.validate()
        let reordered = PhotoSyncLibrary.Item(kind: 1, live: true, creation: original.creation, location: location, favorite: true, resources: [movie, still])
        XCTAssertEqual(original.byteIdentity, reordered.byteIdentity)
        let alternateMovie = PhotoSyncLibrary.Resource(role: movie.role, filename: movie.filename, uti: movie.uti, bytes: movie.bytes, sha256: String(repeating: "c", count: 64))
        let alternate = PhotoSyncLibrary.Item(kind: 1, live: true, creation: original.creation, location: location, favorite: true, resources: [still, alternateMovie])
        XCTAssertNotEqual(original.byteIdentity, alternate.byteIdentity)
        let missing = PhotoSyncLibrary.Item(kind: 1, live: true, creation: original.creation, location: location, favorite: true, resources: [still])
        XCTAssertThrowsError(try missing.validate())
        let bad = PhotoSyncLibrary.Location(latitude: .nan, longitude: 0, altitude: nil)
        XCTAssertThrowsError(try bad.validated())
        let recovered = try JSONDecoder().decode(PhotoSyncLibrary.Item.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(recovered.location, location)
        XCTAssertEqual(recovered.creation, original.creation)
        XCTAssertEqual(recovered.byteIdentity, original.byteIdentity)
    }

    func testExactAlbumIndexKeepsDistinctLocationAndDatePlacement() throws {
        let part = PhotoSyncLibrary.Resource(role: 1, filename: "content.jpg", uti: "public.jpeg",
            bytes: 512, sha256: String(repeating: "b", count: 64))
        let first = try MobileAlbumManifest(id: String(repeating: "1", count: 32), layout: .image,
            captureMillis: 1_731_000_000_000, location: nil, favorite: false, resources: [part])
        let second = try MobileAlbumManifest(id: String(repeating: "2", count: 32), layout: .image,
            captureMillis: 1_732_000_000_000, location: .init(latitude: 31.123456789, longitude: 121.123456789, altitude: nil),
            favorite: true, resources: [part])
        XCTAssertEqual(first.key, second.key)
        var index = MobileAlbumManifest.ExactIndex()
        index.add(first, localID: "A", metadata: "original")
        index.add(second, localID: "B", metadata: "edited")
        XCTAssertEqual(index.match(first, metadata: "original"), "A")
        XCTAssertEqual(index.match(second, metadata: "edited"), "B")
        XCTAssertNil(index.match(second, metadata: "third"))
        XCTAssertTrue(index.containsOriginal(second))
    }

    func testAlbumCandidateBucketsMatchOnlyEligiblePlacementAndNeverProveOriginals() throws {
        let t: Int64 = 1_704_067_199_327
        let creation = Date(timeIntervalSince1970: Double(t) / 1000)
        XCTAssertEqual(try MobileAlbumManifest.captureMilliseconds(creation), t)
        XCTAssertNil(try MobileAlbumManifest.captureMilliseconds(nil))
        let resource = PhotoSyncLibrary.Resource(role: 1, filename: "IMG.HEIC", uti: "public.heic",
                                                 bytes: 3_000_000, sha256: String(repeating: "a", count: 64))
        let different = PhotoSyncLibrary.Resource(role: 1, filename: "IMG.HEIC", uti: "public.heic",
                                                  bytes: resource.bytes, sha256: String(repeating: "b", count: 64))
        let id = String(repeating: "1", count: 32)
        let original = try MobileAlbumManifest(id: id, layout: .image, captureMillis: t,
                                              location: nil, favorite: false, resources: [resource])
        let lookalike = try MobileAlbumManifest(id: id, layout: .image, captureMillis: t,
                                               location: nil, favorite: false, resources: [different])
        let alteredDate = try MobileAlbumManifest(id: id, layout: .image, captureMillis: t + 1,
                                                  location: nil, favorite: false, resources: [resource])
        XCTAssertEqual(original.placementBucket, lookalike.placementBucket)
        XCTAssertNotEqual(original.placementBucket, alteredDate.placementBucket)
        XCTAssertEqual(original.key, alteredDate.key)
        XCTAssertNotEqual(original.key, lookalike.key)
        var index = MobileAlbumManifest.ExactIndex()
        index.add(original, localID: "actual-original", metadata: "same-place")
        XCTAssertNil(index.match(lookalike, metadata: "same-place"))
    }

    func testAlbumReceiptWindowBoundsOutstandingFilesAndHandlesLargeOriginals() {
        var window = MobileAlbumTransfer.PageWindow()
        for index in 1...32 {
            XCTAssertEqual(window.checkpoint(32_768, next: 32_768), index == 32)
        }
        XCTAssertTrue(window.checkpoint(10 * 1024 * 1024, next: 60 * 1024 * 1024))
        XCTAssertTrue(window.checkpoint(80 * 1024 * 1024, next: 32_768))
        XCTAssertFalse(window.checkpoint(32_768, next: 0))
    }

    func testValidatesAndroidKeystoreDelegationAndRejectsPinChanges() throws {
        // Public certificates generated for this test only. The RSA root matches Android Keystore's non-CA identity.
        let root = try certificateFixture("MIIDzzCCAjegAwIBAgIDAWqTMA0GCSqGSIb3DQEBCwUAMCAxHjAcBgNVBAMMFU5vY3R1cm5lIExBTiBTeW5jIDE3MzAeFw0yMDAxMDEwMDAwMDBaFw00NTAxMDEwMDAwMDBaMCAxHjAcBgNVBAMMFU5vY3R1cm5lIExBTiBTeW5jIDE3MzCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAJmTp9nnOLuDMqEYzRYkBjjIYjKhFYE4iwJkQ8Xo2o5RqAByOgUVYemlC5mxS0hfEVMAl6oO3PVxGOFyd16VmStr1b/SZzrrobHRCLyV5mgCwUuwt8l6DougJv+VQAmTkzWwtAnvd+SzmmUoH6kziXpn5uk1Ofj9O98gn/2afE3fATRlW3Gr/kDLSxUT9PuMZe2oo8O0vtomlKZeCc4f1Jiz34wxK0XiPYJ5FnkidlsPlunMzzZAdhTX0oK1M47j/t4cD7d1IR5vL2VRVcxfpC35OrnH2sowjGjHdv/HAJQGkIa1H36XgMLoDt6YJdf2h9rqsF10Bai26cSqESvO5Kpv/G8A3VSXweYKSt6Qyj41G7keqi2v9EhMIdKQZY8QBaUuRLtIHng41650eX2sQvCeBsuk8JhYZqRAndAxW2a2KpKE61L0N/B6OxyirbSDGdBdDM4LZEp7Pfw/zKhRZozABPokgXHA3dP8k7KAs6liWunJYTmC5ArGnzoymmLJcQIDAQABoxIwEDAOBgNVHQ8BAf8EBAMCBaAwDQYJKoZIhvcNAQELBQADggGBAIgVdaEuY9Gx5s7kboG5dppjewEuWtNcTK7+PPd2hAqf71QIvsrCUYTYJlvhyqTO87J9LK3QH4yBXOz4Tu+ihxqu39z6dk38gco3LCSMqS1bYdvwHYz5z+7Zd59r8ks6BXebjh8wyoQ425Zfj39DjOwQT6sfFfvlOpA8KXqAcWnGxH0JjSA8Z7EBJTNNbirHCpYk1v51pAGPM3b52Koictl1qI5oEfhVV5kCJIWsD5qK6TYYpMgELHlisiKT+YJ0vcb03Kij8/z6H7hN4dVX4xTFsYAfAJE1NZCbaTUAEdNLS211Be8cbWz4c3YYVsTm12njONo4Woa/cazy2HXfyqZnuN/VwuW8w+cr75kI5+1eZYkYcx4rzrywBIwxUF6X8XC/r6YQc6T/ENr1LHsfxqFWOtzivxJZUkaTLrFC4Kp2QdlQV8WxaGtrsF1qOuqOF05rbRlRkZH96FXH4JwcIEPXgVBCW1GMQt+WiVMNIPdyqjxwCWLhI++efaJnWy51LQ==")
        let leaf = try certificateFixture("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")
        let expired = try certificateFixture("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")
        let rootPin = AppleSyncTransport.hex(Data(SHA256.hash(data: SecCertificateCopyData(root) as Data)))
        XCTAssertEqual(AppleSyncTransport.verifiedPeerPin([leaf, root], expected: rootPin), rootPin)
        XCTAssertEqual(AppleSyncTransport.verifiedPeerPin([leaf], expected: rootPin), rootPin)
        XCTAssertNil(AppleSyncTransport.verifiedPeerPin([leaf, leaf], expected: rootPin))
        XCTAssertNil(AppleSyncTransport.verifiedPeerPin([leaf, root], expected: String(repeating: "a", count: 64)))
        XCTAssertNil(AppleSyncTransport.verifiedPeerPin([expired, root], expected: rootPin))
        XCTAssertNil(AppleSyncTransport.verifiedPeerPin([leaf, root, root], expected: rootPin))
    }

    private func certificateFixture(_ base64: String) throws -> SecCertificate {
        let bytes = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, bytes as CFData))
    }


    func testCaptureDateKeepsOriginalInstantAcrossTimeZonesAndRejectsTransferTime() throws {
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let source = try XCTUnwrap(clock.date(from: "2020-01-01T00:29:59.327+05:45"))
        let utc = try XCTUnwrap(clock.date(from: "2019-12-31T18:44:59.327Z"))
        XCTAssertTrue(PhotoSyncLibrary.sameDate(source, utc))
        XCTAssertFalse(PhotoSyncLibrary.sameDate(Date(), source))
        XCTAssertFalse(PhotoSyncLibrary.sameDate(Date(), nil))
        XCTAssertFalse(PhotoSyncLibrary.sameDate(source, utc.addingTimeInterval(0.001)))
        XCTAssertTrue(PhotoSyncLibrary.sameDate(nil, nil))
        let historical = Date(timeIntervalSince1970: -6_422_400.019)
        let part = PhotoSyncLibrary.Resource(role: 1, filename: "photo.jpg", uti: "public.jpeg",
            bytes: 1024, sha256: String(repeating: "a", count: 64))
        for original in [source, historical] {
            let item = PhotoSyncLibrary.Item(kind: 1, live: false, creation: original, location: nil,
                                             favorite: false, resources: [part])
            let manifest = try MobileAlbumManifest(id: String(repeating: "9", count: 32), item: item)
            let decoded = try JSONDecoder().decode(MobileAlbumManifest.self, from: JSONEncoder().encode(manifest))
            XCTAssertTrue(PhotoSyncLibrary.sameDate(try decoded.nativeItem().creation, original))
        }
    }

    @MainActor
    func testSystemPhotosNativeImportAlbumReuseAndMembershipRemoval() async throws {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
            let end = ProcessInfo.processInfo.systemUptime + 6
            while PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined,
                  ProcessInfo.processInfo.systemUptime < end {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard PhotoSyncLibrary.allowsReadWrite(authorization) else {
            throw XCTSkip("Simulator Photos status \(authorization.rawValue), host \(Bundle.main.bundleIdentifier ?? "unknown")")
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let storage = try SecureStorage(root: workspace)
        try storage.unlock()
        let lease = try storage.resourceLease193(), store = PhotoSyncLibrary(storage: storage)
        let prefix = "Nocturne QA \(UUID().uuidString.prefix(9))"
        let first = try await store.createAlbum(prefix + " A", lease: lease)
        let second = try await store.createAlbum(prefix + " B", lease: lease)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 44, height: 36)).jpegData(withCompressionQuality: 1) { frame in
            UIColor.red.setFill(); frame.fill(CGRect(x: 0, y: 0, width: 44, height: 36))
            UIColor.blue.setFill(); frame.fill(CGRect(x: 2, y: 4, width: 18, height: 26))
        }
        let original = workspace.appendingPathComponent("fixture.jpg")
        try image.write(to: original, options: .completeFileProtection)
        let fingerprint = AppleSyncTransport.hex(Data(SHA256.hash(data: image)))
        let resource = PhotoSyncLibrary.Resource(role: PHAssetResourceType.photo.rawValue, filename: "fixture.jpg",
            uti: "public.jpeg", bytes: Int64(image.count), sha256: fingerprint)
        let place = PhotoSyncLibrary.Location(latitude: 32.061520139, longitude: 118.782871281, altitude: 34.812)
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = try XCTUnwrap(clock.date(from: "2020-01-01T00:29:59.327+05:45"))
        let asset = PhotoSyncLibrary.Item(kind: PHAssetMediaType.image.rawValue, live: false, creation: date,
                                         location: place, favorite: true, resources: [resource])
        let peer = String(repeating: "d", count: 32), remote = String(repeating: "e", count: 32)
        let id = try await store.receive(asset, files: [original], protectedDirectory: workspace,
            albumID: first.identifier, peer: peer, remoteID: remote, lease: lease)
        try await store.verifyCreated(id, against: asset, lease: lease)
        let same = try await store.receive(asset, files: [], protectedDirectory: workspace,
            albumID: second.identifier, peer: peer, remoteID: remote, lease: lease)
        XCTAssertEqual(same, id)
        XCTAssertEqual(try store.albumContents(first.identifier, lease: lease).visible.map(\.localIdentifier), [id])
        let member = try XCTUnwrap(store.albumContents(second.identifier, lease: lease).visible.first)
        XCTAssertEqual(member.localIdentifier, id)
        XCTAssertTrue(PhotoSyncLibrary.sameDate(member.creationDate, date))
        XCTAssertFalse(PhotoSyncLibrary.sameDate(member.creationDate, Date()))
        let undated = PhotoSyncLibrary.Item(kind: PHAssetMediaType.image.rawValue, live: false, creation: nil,
                                           location: place, favorite: false, resources: [resource])
        do {
            _ = try await store.receive(undated, files: [original], protectedDirectory: workspace,
                albumID: first.identifier, peer: peer, remoteID: String(repeating: "2", count: 32), lease: lease)
            XCTFail("Unverified time must never create a photo carrying the time of transfer")
        } catch MediaError193.unavailable {}
        XCTAssertEqual(try store.albumContents(first.identifier, lease: lease).visible.map(\.localIdentifier), [id])
        try await store.removeAlbumMembership([member], albumID: second.identifier, lease: lease)
        XCTAssertTrue(try store.albumContents(second.identifier, lease: lease).visible.isEmpty)
        XCTAssertEqual(try store.albumContents(first.identifier, lease: lease).visible.map(\.localIdentifier), [id])
        XCTAssertFalse(try storage.hasConfirmedAlbumDeletion(id, lease: lease))
        let persisted = try store.receipt(peer: peer, remoteID: remote, lease: lease)
        XCTAssertEqual(persisted?.item.resources[0].sha256, fingerprint)
        XCTAssertEqual(persisted?.item.location, place)
        XCTAssertEqual(try Data(contentsOf: original), image)
    }

    func testConfirmedLocalAlbumDeletionLedgerSurvivesUnlock() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let storage = try SecureStorage(root: workspace)
        try storage.unlock()
        let old = try storage.resourceLease193()
        XCTAssertFalse(try storage.hasConfirmedAlbumDeletion("sample-A", lease: old))
        try storage.markConfirmedAlbumDeletions(["sample-A", "sample-B"], lease: old)
        storage.lock()
        XCTAssertThrowsError(try storage.markConfirmedAlbumDeletions(["sample-C"], lease: old))
        try storage.unlock()
        let current = try storage.resourceLease193()
        XCTAssertTrue(try storage.hasConfirmedAlbumDeletion("sample-A", lease: current))
        XCTAssertTrue(try storage.hasConfirmedAlbumDeletion("sample-B", lease: current))
        XCTAssertFalse(try storage.hasConfirmedAlbumDeletion("sample-C", lease: current))
    }


    func testAlbumSimilarityKeepsFiveThousandExactAndApproximateEntriesSeparate() throws {
        typealias Entry = PhotoAlbumDuplicates.Entry
        typealias Hash = PhotoAlbumDuplicates.Fingerprint
        func mix(_ n: UInt64) -> UInt64 {
            var n = n &+ 0x9e3779b97f4a7c15
            n = (n ^ (n >> 30)) &* 0xbf58476d1ce4e5b9
            n = (n ^ (n >> 27)) &* 0x94d049bb133111eb
            return n ^ (n >> 31)
        }
        let sample = Hash(tone: 0x35aa873c00f119dc, edge: 0xd0124431002040ac, average: 128)
        var entries: [Entry] = []
        for index in 0..<5_000 {
            let content = index % 4_550
            let hash: Hash
            switch content {
            case 4_548:
                hash = sample
            case 4_549:
                hash = Hash(tone: sample.tone ^ 4, edge: sample.edge ^ 8, average: 130)
            default:
                hash = Hash(tone: mix(UInt64(content)), edge: mix(UInt64(content + 9000)), average: 125)
            }
            entries.append(Entry(index: index, raw: "raw-\(content)", footprint: hash, video: false, aspect: 1.5, duration: 0))
        }
        let groups = try PhotoAlbumDuplicates.groups(entries, unavailable: 0)
        let exact = groups.groups.filter(\.exact)
        XCTAssertEqual(exact.count, 450)
        XCTAssertTrue(exact.allSatisfy { $0.members.count == 2 })
        XCTAssertTrue(groups.groups.contains { !$0.exact && $0.members == [4_548, 4_549] })
        XCTAssertFalse(exact.contains { $0.members.contains(4_548) || $0.members.contains(4_549) })
    }

    func testExactCopiesShareOneThumbnailScanWhileUnknownOriginalsRemainIndependent() {
        let batches = PhotoAlbumDuplicates.visualWorkItems(["a", nil, "b", "a", nil, "b", "a"])
        XCTAssertEqual(batches, [[0, 3, 6], [1], [2, 5], [4]])
    }

    func testAlbumSyncAcceptsOnlyPrivateNumericIPv4() {
        for address in ["10.30.20.2", "192.168.31.22", "172.16.20.4", "172.31.252.3"] {
            XCTAssertTrue(AppleSyncTransport.localIPv4(address))
        }
        for address in ["172.32.20.4", "8.8.8.8", "127.0.0.1", "192.168.031.9", "192.168.1.0", "192.168.1.255", "localhost", "10.0.0.1:48773", "[::1]", "192.168.1.5 " ] {
            XCTAssertFalse(AppleSyncTransport.localIPv4(address))
        }
    }

    func testAuthenticationPrecedesDecryptionAndRejectsEveryTamperedRegion() throws {
        let key = try AuthenticatedCipher.random(64), content = Data("private thumbnail fixture".utf8)
        let first = try AuthenticatedCipher.seal(content, key: key), second = try AuthenticatedCipher.seal(content, key: key)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try AuthenticatedCipher.open(first, key: key), content)
        for offset in [0, 4, 19, 20, first.count - 33, first.count - 1] {
            var altered = first; altered[offset] ^= 0x01
            XCTAssertThrowsError(try AuthenticatedCipher.open(altered, key: key))
        }
        XCTAssertThrowsError(try AuthenticatedCipher.open(first, key: AuthenticatedCipher.random(64)))
        XCTAssertThrowsError(try AuthenticatedCipher.open(Data(first.dropLast()), key: key))
    }
    func testPrivateSwitchKeepsMediaRecordsAndCiphertextKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SecureStorage(root: root); try storage.unlock()
        storage.update { state in state.records["fixture"] = MediaRecord(favorite: true, star: true, folder: "private", views: 3, lastViewed: nil, mark: 2.4) }
        let cache = try storage.thumbnailURL(for: "fixture", pixels: 480)
        try storage.write(Data([1, 2, 3, 4]), to: cache); try storage.save()
        let cacheBytes = try Data(contentsOf: cache)
        try storage.enablePrivate(password: "Unit-test-password-2026!"); try storage.save(); storage.lock()
        XCTAssertThrowsError(try storage.unlock(password: "wrong password"))
        try storage.unlock(password: "Unit-test-password-2026!")
        XCTAssertEqual(storage.state.records["fixture"]?.views, 3)
        XCTAssertEqual(try storage.read(cache), Data([1, 2, 3, 4]))
        XCTAssertEqual(try Data(contentsOf: cache), cacheBytes)
        let header = storage.root.appendingPathComponent("mode.json")
        let previousHeader = try Data(contentsOf: header)
        XCTAssertThrowsError(try storage.changePrivatePassword(current: "wrong password", replacement: "New-password-204!"))
        XCTAssertEqual(try Data(contentsOf: header), previousHeader)
        try storage.changePrivatePassword(current: "Unit-test-password-2026!", replacement: "New-password-204!")
        storage.lock()
        XCTAssertThrowsError(try storage.unlock(password: "Unit-test-password-2026!"))
        try storage.unlock(password: "New-password-204!")
        XCTAssertEqual(try storage.read(cache), Data([1, 2, 3, 4]))
        XCTAssertEqual(try Data(contentsOf: cache), cacheBytes)
        try storage.enableOrdinary(password: "New-password-204!"); try storage.save(); storage.lock(); try storage.unlock()
        XCTAssertEqual(storage.state.records["fixture"]?.mark, 2.4)
    }
    func testViewsAreHourlyAndOneBookmarkTogglesOffAnywhere() {
        var record = MediaRecord(); let now = Date(timeIntervalSince1970: 1_000_000)
        record.viewed(at: now); record.viewed(at: now.addingTimeInterval(3599)); XCTAssertEqual(record.views, 1)
        record.viewed(at: now.addingTimeInterval(3600)); XCTAssertEqual(record.views, 2)
        record.toggleMark(2.4); record.toggleMark(3.3); XCTAssertNil(record.mark)
        record.toggleMark(2.4); record.toggleMark(4.0); XCTAssertNil(record.mark)
    }
    func testSessionPauseAndExitPreserveOnlyActiveTime() {
        let clock = SessionClock(), now = Date(timeIntervalSince1970: 1_000_000)
        clock.start(sequence: 1, now: now); clock.pause(now: now.addingTimeInterval(10)); clock.resume(now: now.addingTimeInterval(100))
        let session = clock.finish(now: now.addingTimeInterval(105))
        XCTAssertEqual(session?.activeSeconds, 15); XCTAssertEqual(session?.ended, now.addingTimeInterval(105)); XCTAssertNil(clock.current)
    }
    func testRetirementDoesNotTouchUnknownFilesOrMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SecureStorage(root: root); try storage.unlock()
        let cache = try storage.thumbnailURL(for: "old", pixels: 480), original = root.appendingPathComponent("untouched-original.bin")
        try storage.write(Data([5, 6]), to: cache); try Data([8, 9]).write(to: original)
        storage.update { state in state.cacheVersions = ["1.0", "1.1", "1.1.2", Release.version]; state.cacheGenerations[cache.lastPathComponent] = "1.0" }
        try storage.save(); storage.lock(); try storage.unlock()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path)); XCTAssertEqual(try Data(contentsOf: original), Data([8, 9])); XCTAssertEqual(storage.state.cacheVersions.count, 3)
    }
    func testPresetColumnsAndOrphanRows() {
        let phone = GalleryRules122.gallerySizes.map { GalleryRules122.columns(width: 336, preset: $0) }
        XCTAssertEqual(phone, [6, 5, 4, 3, 2, 1])
        XCTAssertGreaterThan(GalleryRules122.columns(width: 780, preset: 1), phone[3])
        XCTAssertEqual(GalleryRules122.columns(width: 780, preset: 3), 1)
        XCTAssertEqual(GalleryRules122.rowCount(remaining: 3, columns: 2), 3)
        XCTAssertEqual(GalleryRules122.rowCount(remaining: 5, columns: 4), 3)
    }
    func testRankingUsesFavoritesOnlyAndPersistsDragOrder() throws {
        var a = MediaRecord(); a.favorite = true; a.favoriteRank122 = 1
        var b = MediaRecord(); b.favorite = true; b.favoriteRank122 = 0
        let records = ["a": a, "b": b, "not-favorite": MediaRecord()]
        XCTAssertEqual(GalleryRules122.ranking(["a", "not-favorite", "b"], records: records), ["b", "a"])
        XCTAssertEqual(GalleryRules122.move(["a", "b", "c"], from: 0, to: 2), ["b", "c", "a"])
        XCTAssertEqual(try JSONDecoder().decode(MediaRecord.self, from: JSONEncoder().encode(a)).favoriteRank122, 1)
    }
    func testLastFrameQuantizationAndSubframeAccumulation() {
        XCTAssertEqual(GalleryRules122.quantize(10, duration: 10, fps: 30), 299.0 / 30, accuracy: 0.00001)
        XCTAssertEqual(GalleryRules122.quantize(0.020, duration: 10, fps: 60), 1.0 / 60, accuracy: 0.00001)
        XCTAssertEqual(GalleryRules122.quantize(.nan, duration: 10, fps: 60), 0)
        XCTAssertEqual(GalleryRules122.quantize(-5, duration: 10, fps: 60), 0)
        var raw = 0.0
        for _ in 0..<8 { raw += 0.25 / (60 * 2) }
        XCTAssertEqual(GalleryRules122.quantize(raw, duration: 10, fps: 60), 1.0 / 60, accuracy: 0.00001)
    }
    func testExistingEncryptedMetadataDecodesWithNewOptionalFields() throws {
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryState())) as! [String: Any]
        var settings = old["settings"] as! [String: Any]
        for key in ["gallerySize122", "openAtMarker122", "markerLead122", "markerPreview122", "markerWindow122", "finePixels122", "holdSpeed122", "showDate122", "viewerBackgroundAll122"] { settings.removeValue(forKey: key) }
        old["settings"] = settings; old.removeValue(forKey: "cacheOwners123")
        let loaded = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(loaded.settings.sizePreset, 1); XCTAssertEqual(loaded.settings.markerLead, 3); XCTAssertEqual(loaded.settings.finePixels, 2)
    }

}

final class Port193Tests: XCTestCase {
    func testChineseOnlyAndNewDefaults() throws {
        for code in ["en", "ja", "zh-Hant"] { Strings.language = code; XCTAssertEqual(Strings.language, "zh-Hans"); XCTAssertEqual(Strings.all, "全部影像") }
        let state = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(LibraryState()))
        XCTAssertTrue(state.settings.squareTiles); XCTAssertTrue(state.settings.roundedSquare)
    }
    func testSessionRequiresManualStart() {
        let clock = SessionClock(); clock.tick(); XCTAssertNil(clock.current); XCTAssertFalse(clock.running)
        clock.start(sequence: 1); XCTAssertTrue(clock.running); XCTAssertNotNil(clock.finish()); XCTAssertNil(clock.current)
    }
    func testCompatibleCacheSurvivesVersionChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SecureStorage(root: root); try store.unlock()
        let file = try store.thumbnailURL(for: "fixture193", pixels: 480); try store.write(Data([1, 2, 3]), to: file)
        store.update { $0.cacheGenerations[file.lastPathComponent] = "0.1.0"; $0.cacheVersions = ["0.1.0", "0.2.0", "0.3.0"] }
        try store.save(); let before = try Data(contentsOf: file); store.lock(); try store.unlock()
        XCTAssertEqual(try Data(contentsOf: file), before); XCTAssertEqual(try store.read(file), Data([1, 2, 3]))
    }
}

// Apple SDK XCTest source: execute in Xcode; Windows syntax checking is not a test execution.
final class PrivateResource193Tests: XCTestCase {
    private func fixture(_ bytes: Data) -> EncryptedMedia193 {
        let hash = SHA193(); hash.append(bytes)
        let part = EncryptedPart193(id: UUID().uuidString.lowercased(), role: 1, filename: "fixture.jpg", uti: "public.jpeg", bytes: Int64(bytes.count), sha256: hash.finish(), chunks: 1)
        return EncryptedMedia193(id: UUID().uuidString.lowercased(), sourceIDs: ["generated-fixture"], kind: 1, width: 16, height: 16, duration: 0, creation: nil, modification: nil, latitude: nil, longitude: nil, altitude: nil, live: false, parts: [part], imported: Date())
    }
    func testMalformedManifestCannotReachRegistrationOrAllocation() throws {
        let valid = fixture(Data([1, 2, 3])); try valid.validate193()
        var bad = valid; bad.parts.append(valid.parts[0]); XCTAssertThrowsError(try bad.validate193())
        bad = valid; bad.parts[0].chunks = Int.max; XCTAssertThrowsError(try bad.validate193())
        bad = valid; bad.parts[0].bytes = Int64.max; XCTAssertThrowsError(try bad.validate193())
        bad = valid; bad.parts[0].filename = "../original.jpg"; XCTAssertThrowsError(try bad.validate193())
        bad = valid; bad.parts[0].sha256 = String(repeating: "g", count: 64); XCTAssertThrowsError(try bad.validate193())
        bad = valid; bad.duration = .nan; XCTAssertThrowsError(try bad.validate193())
        bad = valid; bad.live = true; XCTAssertThrowsError(try bad.validate193())
        bad = valid; bad.latitude = 91; bad.longitude = 0; XCTAssertThrowsError(try bad.validate193())
    }
    func testResourceCiphertextCannotBeReboundOrReordered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SecureStorage(root: root); try store.unlock()
        let content = Data([10, 20, 30]), media = fixture(content), part = media.parts[0]
        let lease = try store.resourceLease193(), reader = try PrivateReader193(storage: store, media: media)
        let file = try reader.partURL(part, index: 0)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        try store.writeResourceChunk193(content, to: file, media: media.id, part: part.id, index: 0, lease: lease)
        XCTAssertNotEqual(try Data(contentsOf: file), content)
        XCTAssertEqual(try reader.read(part, index: 0), content); try reader.verify(part)
        XCTAssertThrowsError(try store.readResourceChunk193(file, media: UUID().uuidString, part: part.id, index: 0, lease: lease))
        XCTAssertThrowsError(try store.readResourceChunk193(file, media: media.id, part: UUID().uuidString, index: 0, lease: lease))
        XCTAssertThrowsError(try store.readResourceChunk193(file, media: media.id, part: part.id, index: 1, lease: lease))
        var altered = try Data(contentsOf: file); altered[altered.count - 1] ^= 1; try altered.write(to: file)
        XCTAssertThrowsError(try store.readResourceChunk193(file, media: media.id, part: part.id, index: 0, lease: lease))
        store.lock(); try store.unlock()
        // A cached plaintext chunk must not bypass a revoked session lease.
        XCTAssertThrowsError(try reader.read(part, index: 0))
    }
    func testResourcePathRejectsExternalWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SecureStorage(root: root); try store.unlock(); let lease = try store.resourceLease193()
        let outside = root.appendingPathComponent("do-not-create.bin")
        XCTAssertThrowsError(try store.writeResourceChunk193(Data([1]), to: outside, media: UUID().uuidString, part: UUID().uuidString, index: 0, lease: lease))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }
    func testRawIdentityIncludesEveryOriginalComponent() {
        let first = fixture(Data([1, 2, 3])); var renamed = first
        renamed.id = UUID().uuidString; renamed.parts[0].id = UUID().uuidString; renamed.parts[0].filename = "renamed.jpg"
        XCTAssertEqual(first.rawIdentity193, renamed.rawIdentity193)
        renamed.parts[0].sha256 = String(repeating: "0", count: 64)
        XCTAssertNotEqual(first.rawIdentity193, renamed.rawIdentity193)
        renamed = first; var motion = first.parts[0]; motion.id = UUID().uuidString; motion.role = 9; renamed.parts.append(motion)
        XCTAssertNotEqual(first.rawIdentity193, renamed.rawIdentity193)
    }
    func testCommittedResourcesSurviveAbandonedImportCleanupAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SecureStorage(root: root); try store.unlock(); try store.enablePrivate(password: "Resource-fixture-193!")
        let content = Data([7, 8, 9]), media = fixture(content), part = media.parts[0], lease = try store.resourceLease193()
        let reader = try PrivateReader193(storage: store, media: media), file = try reader.partURL(part, index: 0)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        try store.writeResourceChunk193(content, to: file, media: media.id, part: part.id, index: 0, lease: lease)
        try store.registerMedia193(media, sourceRecord: MediaRecord(favorite: true, views: 4), lease: lease)
        let ciphertext = try Data(contentsOf: file)
        try store.discardUncommitted193(media.id, lease: lease); XCTAssertEqual(try Data(contentsOf: file), ciphertext)
        store.lock(); try store.unlock(password: "Resource-fixture-193!")
        XCTAssertEqual(store.state.records[media.localIdentifier]?.views, 4)
        let reopened = try PrivateReader193(storage: store, media: store.state.internalMedia193![media.id]!)
        try reopened.verify(part); XCTAssertEqual(try Data(contentsOf: file), ciphertext)
    }
}

final class BrowserPersistence193Tests: XCTestCase {
    func testHistoryAndFavoritesAreEncryptedBoundedAndLeaseBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SecureStorage(root: root); try store.unlock(); let lease = try store.resourceLease193()
        let entry = BrowserEntry193(url: "https://example.com/private-fixture193", title: "Generated private title193", visited: Date())
        try store.saveBrowserEntry193(entry, favorite: false, lease: lease)
        try store.saveBrowserEntry193(entry, favorite: false, lease: lease)
        try store.saveBrowserEntry193(entry, favorite: true, lease: lease)
        XCTAssertEqual(try store.browserEntries193(favorites: false, lease: lease).count, 1)
        let file = try Data(contentsOf: root.appendingPathComponent("library.ncv"))
        XCTAssertNil(file.range(of: Data(entry.url.utf8))); XCTAssertNil(file.range(of: Data(entry.title.utf8)))
        let records = BrowserRecords193(store); store.lock(); try store.unlock()
        XCTAssertTrue(records.entries(favorites: false).isEmpty)
        XCTAssertThrowsError(try store.saveBrowserEntry193(entry, favorite: false, lease: lease))
        let fresh = try store.resourceLease193(); XCTAssertEqual(try store.browserEntries193(favorites: true, lease: fresh).first?.url, entry.url)
        try store.clearBrowserHistory193(lease: fresh)
        XCTAssertTrue(try store.browserEntries193(favorites: false, lease: fresh).isEmpty)
        XCTAssertEqual(try store.browserEntries193(favorites: true, lease: fresh).count, 1)
    }
    func testNativeRecordStoreRejectsLocalAndMalformedURLs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SecureStorage(root: root); try store.unlock(); let lease = try store.resourceLease193()
        for address in ["file:///private/original.jpg", "https://127.0.0.1/library", "javascript:alert(1)", "https://user:secret@example.com/"] {
            XCTAssertThrowsError(try store.saveBrowserEntry193(BrowserEntry193(url: address, title: "fixture", visited: Date()), favorite: false, lease: lease))
        }
        XCTAssertTrue(try store.browserEntries193(favorites: false, lease: lease).isEmpty)
    }
}

final class GalleryDateLayout199Tests: XCTestCase {
    func testDateGroupsStartSeparateRowsAndAlignLeft() {
        for mode in [GalleryMode.tiles, .galaxy] {
            let layout = GalleryLayout()
            let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), collectionViewLayout: layout)
            layout.mode = mode
            layout.square = false
            layout.ratios = [1, 1.5, 0.7]
            layout.dayStarts = [0: "昨天", 2: "今天"]
            collection.layoutIfNeeded()
            layout.prepare()
            let date = IndexPath(item: 2, section: 0)
            let prior = IndexPath(item: 1, section: 0)
            guard let frame = layout.layoutAttributesForItem(at: date)?.frame,
                  let previous = layout.layoutAttributesForItem(at: prior)?.frame,
                  let title = layout.layoutAttributesForSupplementaryView(ofKind: GalleryLayout.dayHeader, at: date)?.frame
            else { return XCTFail("Missing layout geometry") }
            XCTAssertEqual(frame.minX, 12, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(title.minY, previous.maxY)
            XCTAssertGreaterThanOrEqual(frame.minY, title.maxY)
        }
    }
}
