import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Creates a Photos-compatible presentation. The original Android container is archived independently before creation.
enum XiaomiLivePhoto {
    struct Converted {
        let item: PhotoSyncLibrary.Item
        let files: [URL]
    }

    static func make(_ manifest: MobileAlbumManifest, from original: URL, in directory: URL) async throws -> Converted {
        guard manifest.layout == .motion, let motion = manifest.embeddedMotion,
              let source = manifest.resources.first else { throw MediaError193.malformed }
        try motion.validate(containerBytes: source.bytes)
        let id = UUID().uuidString
        let name = (source.filename as NSString).deletingPathExtension
        let extracted = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        let mov = directory.appendingPathComponent(UUID().uuidString + ".mov")
        try extract(original, to: extracted, motion: motion)
        defer { try? FileManager.default.removeItem(at: extracted) }
        async let stillImage = still(original, in: directory, pairingID: id)
        try await remux(extracted, to: mov, pairingID: id, presentationUs: motion.presentationUs)
        let image = try await stillImage
        try Task.checkCancellation()
        async let photoResource = describe(image.url, role: PHAssetResourceType.photo.rawValue,
                                           filename: String(name.prefix(1000)) + "." + image.url.pathExtension, uti: image.uti)
        async let videoResource = describe(mov, role: PHAssetResourceType.pairedVideo.rawValue,
                                           filename: String(name.prefix(1000)) + ".MOV", uti: UTType.quickTimeMovie.identifier)
        let (photo, movie) = try await (photoResource, videoResource)
        let item = PhotoSyncLibrary.Item(kind: PHAssetMediaType.image.rawValue, live: true,
                                       creation: manifest.captureMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                                       location: manifest.location, favorite: manifest.favorite, resources: [photo, movie])
        try item.validate()
        return Converted(item: item, files: [image.url, mov])
    }

    private static func extract(_ original: URL, to target: URL, motion: MobileAlbumManifest.EmbeddedMotion) throws {
        guard FileManager.default.createFile(atPath: target.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.complete])
              else { throw MediaError193.unavailable }
        let inFile = try FileHandle(forReadingFrom: original)
        defer { try? inFile.close() }
        let outFile = try FileHandle(forWritingTo: target)
        defer { try? outFile.close() }
        try inFile.seek(toOffset: UInt64(motion.offset))
        var remaining = motion.length
        while remaining > 0 {
            try Task.checkCancellation()
            guard let data = try inFile.read(upToCount: Int(min(remaining, 1_048_576))), !data.isEmpty
                  else { throw MediaError193.changed }
            try outFile.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
        try outFile.synchronize()
    }

    private static func still(_ url: URL, in directory: URL, pairingID: String) throws -> (url: URL, uti: String) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let type = CGImageSourceGetType(source) else { throw MediaError193.unavailable }
        let uti = type as String
        let outputType = [UTType.heic.identifier, UTType.heif.identifier].contains(uti) ? UTType.heic : UTType.jpeg
        let result = directory.appendingPathComponent(UUID().uuidString + "." + (outputType.preferredFilenameExtension ?? "jpg"))
        guard let output = CGImageDestinationCreateWithURL(result as CFURL, outputType.identifier as CFString, 1, nil)
              else { throw MediaError193.unavailable }
        var metadata = imageProperties
        var maker = metadata[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
        maker["17"] = pairingID
        metadata[kCGImagePropertyMakerAppleDictionary as String] = maker
        metadata[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        CGImageDestinationAddImageFromSource(output, source, 0, metadata as CFDictionary)
        // Retain a gain map exactly when ImageIO exposes the original as an auxiliary image.
        if let gain = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) {
            CGImageDestinationAddAuxiliaryDataInfo(output, kCGImageAuxiliaryDataTypeHDRGainMap, gain)
        }
        guard CGImageDestinationFinalize(output) else { throw MediaError193.verification }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: result.path)
        return (result, outputType.identifier)
    }

    private static func remux(_ input: URL, to output: URL, pairingID: String, presentationUs: Int64) async throws {
        let asset = AVURLAsset(url: input)
        async let videoTracks = asset.loadTracks(withMediaType: .video)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        let (video, audio) = try await (videoTracks, audioTracks)
        // Android Motion Photo orders the main video before its optional high-resolution still-frame track.
        guard (1...2).contains(video.count), let primary = video.first, audio.count <= 8
              else { throw MediaError193.unavailable }
        async let sourceRange = primary.load(.timeRange)
        async let minimumFrame = primary.load(.minFrameDuration)
        let markRange = try await stillMarkerRange(in: sourceRange, minimumFrame: minimumFrame,
                                                   presentationUs: presentationUs)
        let reader = try AVAssetReader(asset: asset), writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let id = AVMutableMetadataItem()
        id.keySpace = .quickTimeMetadata
        id.key = "com.apple.quicktime.content.identifier" as NSString
        id.value = pairingID as NSString
        id.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [id]

        var tracks: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for track in [primary] + audio {
            guard let format = try await track.load(.formatDescriptions).first else { throw MediaError193.unavailable }
            let sink = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            sink.expectsMediaDataInRealTime = false
            if track.mediaType == .video { sink.transform = try await track.load(.preferredTransform) }
            let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            samples.alwaysCopiesSampleData = false
            guard writer.canAdd(sink), reader.canAdd(samples) else { throw MediaError193.unavailable }
            writer.add(sink); reader.add(samples)
            tracks.append((samples, sink))
        }
        let marker = try metadataTrack()
        guard writer.canAdd(marker.assetWriterInput) else { throw MediaError193.unavailable }
        writer.add(marker.assetWriterInput)
        guard writer.startWriting(), reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? writer.error ?? MediaError193.unavailable
        }
        writer.startSession(atSourceTime: .zero)
        var completed = Set<Int>()
        var markerWritten = false
        do {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "com.apple.quicktime.still-image-time" as NSString
            item.value = NSNumber(value: Int8(-1))
            item.dataType = kCMMetadataBaseDataType_SInt8 as String
            let mark = AVTimedMetadataGroup(items: [item], timeRange: markRange)
            var lastProgress = ProcessInfo.processInfo.systemUptime
            while completed.count < tracks.count || !markerWritten {
                try Task.checkCancellation()
                if reader.status == .failed || writer.status == .failed {
                    throw reader.error ?? writer.error ?? MediaError193.verification
                }
                var advanced = false
                if !markerWritten, marker.assetWriterInput.isReadyForMoreMediaData {
                    guard marker.append(mark) else { throw writer.error ?? MediaError193.verification }
                    marker.assetWriterInput.markAsFinished()
                    advanced = true; markerWritten = true
                }
                for (index, track) in tracks.enumerated() where !completed.contains(index) && track.input.isReadyForMoreMediaData {
                    if let sample = track.output.copyNextSampleBuffer() {
                        guard track.input.append(sample) else { throw writer.error ?? MediaError193.verification }
                    } else {
                        if reader.status == .failed { throw reader.error ?? MediaError193.verification }
                        track.input.markAsFinished()
                        completed.insert(index)
                    }
                    advanced = true
                }
                if advanced { lastProgress = ProcessInfo.processInfo.systemUptime }
                else {
                    guard ProcessInfo.processInfo.systemUptime - lastProgress < 30 else { throw MediaError193.unavailable }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            guard writer.status == .completed else { throw writer.error ?? MediaError193.verification }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: output.path)
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    static func stillMarkerRange(in timeline: CMTimeRange, minimumFrame: CMTime,
                                 presentationUs: Int64) throws -> CMTimeRange {
        guard timeline.start.isNumeric, timeline.duration.isNumeric, timeline.end.isNumeric,
              timeline.duration.seconds > 0, timeline.duration.seconds <= 600 else { throw MediaError193.malformed }
        let first = max(0, timeline.start.seconds)
        let end = timeline.end.seconds
        guard end > first else { throw MediaError193.malformed }
        let sample = minimumFrame.isNumeric && minimumFrame.seconds > 0 ? minimumFrame.seconds : 1.0 / 30.0
        let length = min(sample, end - first)
        let requested = presentationUs >= 0 ? Double(presentationUs) / 1_000_000 : first + (end - first) * 0.5
        let start = max(first, min(requested, end - length))
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1_000_000),
                           duration: CMTime(seconds: length, preferredTimescale: 1_000_000))
    }

    private static func metadataTrack() throws -> AVAssetWriterInputMetadataAdaptor {
        let fields: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String
        ]
        var format: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [fields] as CFArray, formatDescriptionOut: &format)
        guard status == noErr, let format = format else { throw MediaError193.unavailable }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    private static func describe(_ url: URL, role: Int, filename: String, uti: String) throws -> PhotoSyncLibrary.Resource {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256(), size: Int64 = 0
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            size += Int64(data.count)
            guard size <= PhotoSyncLibrary.maximumAssetBytes else { throw MediaError193.tooLarge }
            hash.update(data: data)
        }
        return PhotoSyncLibrary.Resource(role: role, filename: filename, uti: uti, bytes: size,
                                         sha256: AppleSyncTransport.hex(Data(hash.finalize())))
    }
}
