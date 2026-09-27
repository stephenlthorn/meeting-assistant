import Accelerate
import AVFoundation

/// Level and channel helpers for Float32 PCM buffers.
enum AudioMath {
    /// Root-mean-square amplitude across every channel: 0 for silence, 1 for full scale.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved {
            return meanSquare(channels[0], count: Int(buffer.frameLength) * channelCount).squareRoot()
        }
        let total = (0..<channelCount).reduce(Float(0)) { sum, channel in
            sum + meanSquare(channels[channel], count: Int(buffer.frameLength))
        }
        return (total / Float(channelCount)).squareRoot()
    }

    /// Averages the channels into one. Returns `buffer` itself when it is
    /// already mono, and nil for interleaved or non-float formats.
    static func monoMix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let channels = buffer.floatChannelData, !buffer.format.isInterleaved else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 1 else { return buffer }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let output = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = buffer.frameLength
        let count = vDSP_Length(buffer.frameLength)
        output.update(from: channels[0], count: Int(buffer.frameLength))
        for channel in 1..<channelCount {
            vDSP_vadd(output, 1, channels[channel], 1, output, 1, count)
        }
        var scale = 1 / Float(channelCount)
        vDSP_vsmul(output, 1, &scale, output, 1, count)
        return mono
    }

    private static func meanSquare(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        var result: Float = 0
        vDSP_measqv(samples, 1, &result, vDSP_Length(count))
        return result
    }
}
