import Foundation
import AVFoundation

// Test/export helper only. No playback, audio device, window or display link.
final class OffscreenMovie {
    private let writer: AVAssetWriter
    private let track: AVAssetWriterInput
    private let adapter: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int
    private(set) var frames = 0
    init(url: URL, width: Int, height: Int) throws {
        self.width=width;self.height=height
        if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}
        writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        track=AVAssetWriterInput(mediaType:.video,outputSettings:[
            AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:8_000_000,AVVideoExpectedSourceFrameRateKey:30]
        ])
        track.expectsMediaDataInRealTime=false
        adapter=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:track,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height
        ])
        writer.add(track)
        guard writer.startWriting() else {throw writer.error ?? MoltenError.failed("Cannot start offscreen movie.")}
        writer.startSession(atSourceTime:.zero)
    }
    func append(_ image: PixelImage) throws {
        guard image.width==width,image.height==height,let pool=adapter.pixelBufferPool else {throw MoltenError.failed("Movie frame size or pool mismatch.")}
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixelBuffer)==kCVReturnSuccess,let buffer=pixelBuffer else {throw MoltenError.failed("Movie frame allocation failed.")}
        CVPixelBufferLockBaseAddress(buffer,[])
        let row=CVPixelBufferGetBytesPerRow(buffer),base=CVPixelBufferGetBaseAddress(buffer)!
        image.bytes.withUnsafeBytes { bytes in
            for y in 0..<height {base.advanced(by:y*row).copyMemory(from:bytes.baseAddress!.advanced(by:y*width*4),byteCount:width*4)}
        }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        let deadline=Date().addingTimeInterval(10)
        while !track.isReadyForMoreMediaData && writer.status == .writing && Date()<deadline {Thread.sleep(forTimeInterval:0.003)}
        guard track.isReadyForMoreMediaData,adapter.append(buffer,withPresentationTime:CMTime(value:Int64(frames),timescale:30)) else {
            throw writer.error ?? MoltenError.failed("Movie encoder did not accept a frame.")
        }
        frames+=1
    }
    func finish() throws {
        track.markAsFinished();let done=DispatchSemaphore(value:0)
        writer.finishWriting {done.signal()}
        guard done.wait(timeout:.now()+30) == .success,writer.status == .completed else {throw writer.error ?? MoltenError.failed("Offscreen movie did not finish.")}
    }
}
