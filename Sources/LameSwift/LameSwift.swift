//
//  Lame.swift
//  RCTP
//
//  Created by 韦烽传 on 2021/3/4.
//

import Foundation
import AudioToolbox
import Lame
import Print

/**
 Lame MP3 转码
 */
open class LameSwift {
    
    /**
     转码
     `ExtAudioFile`方式读取
     
     - parameter    pcmPath:                PCM文件路径
     - parameter    mp3Path:                MP3文件路径
     - parameter    clientDescription:      转换音频参数（采样位数必须`16位`）
     - parameter    ratio:                  压缩比
     - parameter    quality:                算法质量 0～9  0:最好但速度慢；9:最差但速度快
     - parameter    isInterleaved:          双通道是否交错
     - parameter    progress:               进度
     - parameter    complete:               成功或失败
     */
    public static func converter(_ pcmPath: String, mp3Path: String, clientDescription: AudioStreamBasicDescription? = nil, ratio: Float = 8, quality: Int32 = 0, isInterleaved: Bool = true, progress: @escaping (Float)->Void, complete: @escaping (Bool)->Void) {
        
        let queue = DispatchQueue(label: "\(Date().timeIntervalSince1970).converter.\(Self.self).serial")
        
        queue.async {
            
            /// 地址
            guard let url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, pcmPath as CFString, .cfurlposixPathStyle, false) else { complete(false); Print.error("CFURLCreateWithFileSystemPath Error"); return }
            
            /// 状态
            var status: OSStatus = noErr
            
            /// 获取文件句柄
            var file: ExtAudioFileRef?
            status = ExtAudioFileOpenURL(url, &file)
            guard status == noErr else { complete(false); Print.error("ExtAudioFileOpenURL \(status)"); return }
            
            /// 获取文件音频流参数
            var description = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.stride(ofValue: description))
            status = ExtAudioFileGetProperty(file!, kExtAudioFileProperty_FileDataFormat, &size, &description)
            guard status == noErr else { complete(false); Print.error("ExtAudioFileGetProperty kExtAudioFileProperty_FileDataFormat \(status)"); return }
            
            /// 获取文件音频流帧数
            var numbersFrames: Int64 = 0
            var numbersFramesSize = UInt32(MemoryLayout.stride(ofValue: numbersFrames))
            status = ExtAudioFileGetProperty(file!, kExtAudioFileProperty_FileLengthFrames, &numbersFramesSize, &numbersFrames)
            guard status == noErr else { complete(false); Print.error("ExtAudioFileGetProperty kExtAudioFileProperty_FileLengthFrames \(status)"); return }
            
            /// 设置客户端音频流参数（输出数据参数）
            var client = clientDescription
            if client != nil {
                status = ExtAudioFileSetProperty(file!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.stride(ofValue: client)), &client)
                guard status == noErr else { complete(false); Print.error("ExtAudioFileSetProperty kExtAudioFileProperty_ClientDataFormat \(status)"); return }
                /// 转码率后的帧数
                numbersFrames = Int64(Float64(numbersFrames)/description.mSampleRate*client!.mSampleRate)
                description = client!
            }
            else if description.mBitsPerChannel != 16 {
                /// 采样位数必须`16位`
                var pcm = AudioStreamBasicDescription.init()
                /// 类型
                pcm.mFormatID = kAudioFormatLinearPCM
                /// flags
                pcm.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                /// 采样率
                pcm.mSampleRate = description.mSampleRate
                /// 采样位数
                pcm.mBitsPerChannel = 16
                /// 声道
                pcm.mChannelsPerFrame = description.mChannelsPerFrame
                /// 每个包的帧数
                pcm.mFramesPerPacket = description.mFramesPerPacket
                /// 每个帧的字节数
                pcm.mBytesPerFrame = description.mBitsPerChannel / 8 * description.mChannelsPerFrame
                /// 每个包的字节数
                pcm.mBytesPerPacket = description.mBytesPerFrame * description.mFramesPerPacket
                status = ExtAudioFileSetProperty(file!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.stride(ofValue: pcm)), &pcm)
                guard status == noErr else { complete(false); Print.error("ExtAudioFileSetProperty kExtAudioFileProperty_ClientDataFormat \(status)"); return }
                /// 转码率后的帧数
                numbersFrames = Int64(Float64(numbersFrames)/description.mSampleRate*pcm.mSampleRate)
                description = pcm
            }
            
            /// 转码器
            let lame = lame_init()
            
            /// 采样率
            lame_set_in_samplerate(lame, Int32(description.mSampleRate))
            /// 通道数（声道）
            lame_set_num_channels(lame, Int32(description.mChannelsPerFrame))
            /// 算法质量
            lame_set_quality(lame, quality)
            /// 压缩率
            lame_set_compression_ratio(lame, ratio)
            /// 初始化参数
            lame_init_params(lame)
            
            /// 删除旧的MP3文件
            do {
                try FileManager.default.removeItem(atPath: mp3Path)
            } catch  {
                
            }
            
            /// MP3文件
            let mp3File: UnsafeMutablePointer<FILE> = fopen(mp3Path, "wb")
            let mp3Size: Int32 = 1024 * 8
            let mp3buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(mp3Size))
            var number: Int32 = 0
            
            var inNumberFrames = mp3Size
            
            if !isInterleaved && description.mChannelsPerFrame == 2 {
                
                /// 非交错周期帧数 （目前没获取到）
                inNumberFrames = mp3Size
            }
            
            /// 缓冲
            var bufferList = AudioBufferList()
            bufferList.mNumberBuffers = 1
            bufferList.mBuffers.mNumberChannels = description.mChannelsPerFrame
            bufferList.mBuffers.mDataByteSize = UInt32(inNumberFrames) * description.mBytesPerFrame
            bufferList.mBuffers.mData = calloc(Int(inNumberFrames), Int(description.mBytesPerFrame))
            
            /// 关闭
            func closeFile() {
                
                /// 关闭编码
                lame_close(lame)
                /// 释放内存
                free(bufferList.mBuffers.mData!)
                /// 释放内存
                mp3buffer.deallocate()
                /// 关闭文件
                ExtAudioFileDispose(file!)
                /// 关闭文件
                fclose(mp3File)
            }
            
            /// 编码帧数
            var encodeNumberFrames: UInt32 = 0
            
            /// 帧数
            var ioNumberFrames: UInt32 = bufferList.mBuffers.mDataByteSize/description.mBytesPerFrame
            
            repeat {
                
                progress(Float(encodeNumberFrames)/Float(numbersFrames))
                
                /// 读取数据
                status = ExtAudioFileRead(file!, &ioNumberFrames, &bufferList)
                guard status == noErr else { Print.error("ExtAudioFileRead \(status)"); closeFile(); complete(false); return }
                
                /// 转换读取数据
                guard let pcmBuffer = bufferList.mBuffers.mData?.bindMemory(to: Int16.self, capacity: Int(bufferList.mBuffers.mDataByteSize)/MemoryLayout.stride(ofValue: Int16())) else { Print.error("mBuffers.mData to UnsafeMutablePointer<Int16> Error"); closeFile(); complete(false); return }
                
                if ioNumberFrames == 0 {
                    
                    /// 编码结束填充
                    number = lame_encode_flush(lame, mp3buffer, mp3Size)
                    
                    /// 时长不正确 需加这个
                    lame_mp3_tags_fid(lame, mp3File)
                }
                else {
                    
                    if description.mChannelsPerFrame == 2 {
                        
                        if isInterleaved {
                            
                            /// 双声道交错编码
                            number = lame_encode_buffer_interleaved(lame, pcmBuffer, Int32(ioNumberFrames), mp3buffer, mp3Size)
                        }
                        else {
                            
                            /// 左通道
                            let l = UnsafeMutablePointer<Int16>.allocate(capacity: Int(ioNumberFrames))
                            l.initialize(from: pcmBuffer, count: Int(ioNumberFrames))
                            
                            /// 右通道
                            var buffer = pcmBuffer
                            buffer += UnsafeMutablePointer<Int16>.Stride(ioNumberFrames)
                            let r = UnsafeMutablePointer<Int16>.allocate(capacity: Int(ioNumberFrames))
                            r.initialize(from: buffer, count: Int(ioNumberFrames))
                            
                            /// 左右声道编码
                            number = lame_encode_buffer(lame, l, r, Int32(ioNumberFrames), mp3buffer, mp3Size)
                            
                            l.deallocate()
                            r.deallocate()
                        }
                    }
                    else {
                        
                        /// 单声道编码
                        number = lame_encode_buffer(lame, pcmBuffer, pcmBuffer, Int32(ioNumberFrames), mp3buffer, mp3Size)
                    }
                    
                    if number < 0 {
                        
                        Print.error("lame_encode_buffer error write: \(number)")
                        closeFile()
                        complete(false)
                        return
                    }
                }
                
                fwrite(mp3buffer, 1, Int(number), mp3File)
                
                encodeNumberFrames += ioNumberFrames
                
            } while ioNumberFrames != 0
            
            closeFile()
            
            complete(true)
        }
    }
    
    /**
     转码
     `C`语言读取文件，需设置音频参数
     
     - parameter    samplerate:     采样率
     - parameter    channels:       通道数
     - parameter    ratio:          压缩比
     - parameter    quality:        算法质量 0～9  0:最好但速度慢；9:最差但速度快
     - parameter    pcmPath:        CAF(PCM)路径
     - parameter    mp3Path:        MP3路径
     - parameter    progress:       进度
     - parameter    complete:       转码完成
     */
    public static func converter(_ samplerate: Int32 = 44100, channels: Int32 = 2, quality: Int32 = 0, ratio: Float = 8, pcmPath: String, mp3Path: String, progress: @escaping (Float)->Void, complete: @escaping ()->Void) {
        
        let queue = DispatchQueue(label: "\(Date().timeIntervalSince1970).converter.\(Self.self).serial")
        
        queue.async {

            /// 删除旧的MP3文件
            do {
                try FileManager.default.removeItem(atPath: mp3Path)
            } catch  {
                
            }
            /// 转码器
            let lame = lame_init()
            
            /// PCM 采样率
            lame_set_in_samplerate(lame, samplerate)
            /// 算法质量 0:最好，速度最慢;  9:最差，速度最快
            lame_set_quality(lame, quality)
            /// 通道数（声道）
            lame_set_num_channels(lame, channels)
            /// 压缩率
            lame_set_compression_ratio(lame, ratio)
            /// 启用设置参数
            lame_init_params(lame)
            
            /// PCM文件
            let pcmFile: UnsafeMutablePointer<FILE> = fopen(pcmPath, "rb")
            fseek(pcmFile, 0 , SEEK_END)
            /// 文件长度
            let fileSize = ftell(pcmFile)
            /// 头文件.
            let fileHeader = 4 * 1024
            fseek(pcmFile, fileHeader, SEEK_SET)
            /// PCM大小
            let pcmSize = 1024 * 8
            /// PCM缓冲
            let pcmbuffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(pcmSize * 2))
            
            /// MP3文件
            let mp3File: UnsafeMutablePointer<FILE> = fopen(mp3Path, "wb")
            /// MP3大小
            let mp3Size: Int32 = 1024 * 8
            /// MP3缓冲
            let mp3buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(mp3Size))
            
            /// 写入数量
            var write: Int32 = 0
            /// 读取数量
            var read = 0
            
            repeat {
                
                progress(Float(ftell(pcmFile)) / Float(fileSize))
                
                let size = MemoryLayout<Int16>.size * 2
                read = fread(pcmbuffer, size, pcmSize, pcmFile)
                
                if read == 0 {
                    
                    write = lame_encode_flush(lame, mp3buffer, mp3Size)
                    /// 时长不正确 需加这个
                    lame_mp3_tags_fid(lame, mp3File)
                    
                }
                else {
                    
                    if channels == 2 {
                        
                        write = lame_encode_buffer_interleaved(lame, pcmbuffer, Int32(read), mp3buffer, mp3Size)
                    }
                    else {
                        
                        write = lame_encode_buffer(lame, pcmbuffer, pcmbuffer, Int32(read), mp3buffer, mp3Size)
                    }
                }
                
                fwrite(mp3buffer, Int(write), 1, mp3File)

            } while read != 0
                        
            /// 关闭清除
            lame_close(lame)
            fclose(mp3File)
            fclose(pcmFile)
            pcmbuffer.deallocate()
            mp3buffer.deallocate()
            
            complete()
        }
    }
    
    /// 队列
    public let queue: DispatchQueue
    /// 编码器
    public let lame = lame_init()
    /// 采样率
    public let sampleRate: Int32
    /// 采样位数
    public let bitsPer: Int32
    /// 通道数
    public let numberChannels: Int32
    /// 压缩比
    public let ratio: Float
    /// 算法质量 0～9  0:最好但速度慢；9:最差但速度快
    public let quality: Int32
    /// 双通道是否交错
    public let isInterleaved: Bool
    /// MP3文件路径
    public let path: String
    /// MP3文件
    public let file: UnsafeMutablePointer<FILE>
    /// MP3缓冲大小
    public let size: Int32 = 1024 * 8
    /// MP3缓冲
    public let buffer: UnsafeMutablePointer<UInt8>
    /// 每次编码数据大小
    public let encodeSize: Int
    /// PCM数据
    open var bytes: [UInt8] = []
    /// 编码数据回调
    open var callback: ((Data)->Void)?
    
    /**
     初始化
     
     - parameter    samplerate:         采样率
     - parameter    bitsPer:            采样位数（仅支持16位PCM）
     - parameter    channels:           通道数
     - parameter    ratio:              压缩比
     - parameter    quality:            算法质量 0～9  0:最好但速度慢；9:最差但速度快
     - parameter    isDualInterleaved:  双通道是否交错
     - parameter    path:               MP3路径
     */
    public init(_ sampleRate: Int32 = 44100, bitsPer: Int32 = 16, channels: Int32 = 2, ratio: Float = 8, quality: Int32 = 0, isDualInterleaved: Bool = true, path: String) {
        
        queue = DispatchQueue(label: "\(Date().timeIntervalSince1970).\(Self.self).serial")
        numberChannels = channels
        self.sampleRate = sampleRate
        self.bitsPer = bitsPer
        self.ratio = ratio
        self.quality = quality
        
        /// 采样率
        lame_set_in_samplerate(lame, sampleRate)
        /// 通道数（声道）
        lame_set_num_channels(lame, channels)
        /// 算法质量
        lame_set_quality(lame, quality)
        /// 压缩率
        lame_set_compression_ratio(lame, ratio)
        /// 初始化参数
        lame_init_params(lame)
        
        isInterleaved = isDualInterleaved
        
        self.path = path
        
        /// 删除旧的MP3文件
        if FileManager.default.fileExists(atPath: path) {
            
            do {
                
                try FileManager.default.removeItem(atPath: path)
                
            } catch  {
                
            }
        }
        
        /// MP3文件
        file = fopen(path, "wb")
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(size))
        encodeSize = Int(size*channels*bitsPer/8)
    }
    
    /**
     添加数据
     */
    open func addData(_ bytes: [UInt8]) {
        
        queue.async {
            
            self.bytes += bytes
            
             var start = 0
             var end = self.encodeSize
             
             while self.bytes.count >= end {
                
                 self.encode([UInt8](self.bytes[start..<end]))
                 
                 start = end
                 end += self.encodeSize
             }
             
             if start == 0 {
                 
             }
             else if start == self.bytes.count {
                 
                 self.bytes = []
             }
             else {
                 
                 self.bytes = [UInt8](self.bytes[start..<self.bytes.count])
             }
        }
    }
    
    /**
     编码
     */
    func encode(_ data: [UInt8]) {
        
        var ioData = data
        
        ioData.withUnsafeMutableBytes { (body: UnsafeMutableRawBufferPointer) -> Void in
            
            let bind = body.bindMemory(to: Int16.self)
            if let bytes = bind.baseAddress {
                
                var number: Int32 = 0
                
                if numberChannels == 2 {
                    
                    let ioNumberFrames = data.count/Int(numberChannels)/Int(bitsPer/8)
                    
                    if isInterleaved {
                        
                        /// 双声道交错编码
                        number = lame_encode_buffer_interleaved(lame, bytes, Int32(ioNumberFrames), buffer, size)
                    }
                    else {
                        
                        /// 左通道
                        let l = UnsafeMutablePointer<Int16>.allocate(capacity: Int(ioNumberFrames))
                        l.initialize(from: bytes, count: Int(ioNumberFrames))
                        
                        /// 右通道
                        var bufferR = bytes
                        bufferR += UnsafeMutablePointer<Int16>.Stride(ioNumberFrames)
                        let r = UnsafeMutablePointer<Int16>.allocate(capacity: Int(ioNumberFrames))
                        r.initialize(from: bufferR, count: Int(ioNumberFrames))
                        
                        /// 左右声道编码
                        number = lame_encode_buffer(lame, l, r, Int32(ioNumberFrames), buffer, size)
                        
                        l.deallocate()
                        r.deallocate()
                    }
                }
                else {
                    
                    /// 单声道编码
                    number = lame_encode_buffer(lame, bytes, bytes, Int32(data.count/Int(bitsPer/8)), buffer, size)
                }
                
                if number >= 0 {
                    
                    fwrite(buffer, Int(number), 1, file)
                    callback?(Data(bytes: buffer, count: Int(number)))
                }
                else {
                    
                    Print.error("lame_encode_buffer error number: \(number)")
                }
            }
        }
    }
    
    /**
     停止
     */
    open func stop() {
        
        queue.async {
            
            self.encode(self.bytes)
            
            /// 编码结束填充
            let number = lame_encode_flush(self.lame, self.buffer, self.size)
            
            /// 时长不正确 需加这个
            lame_mp3_tags_fid(self.lame, self.file)
            
            if number >= 0 {
                
                fwrite(self.buffer, Int(number), 1, self.file)
            }
            else {
                
                Print.error("lame_encode_flush error number: \(number)")
            }
            
            /// 关闭
            lame_close(self.lame)
            fclose(self.file)
            self.buffer.deallocate()
        }
    }
}
