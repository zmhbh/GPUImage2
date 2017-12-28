import AVFoundation

public class MovieInput: ImageSource {
    public let targets = TargetContainer()
    public var runBenchmark = false
    
    let yuvConversionShader:ShaderProgram
    let asset:AVAsset
    let videoComposition: AVVideoComposition?
    var assetReader:AVAssetReader?
    var started = false
    let playAtActualSpeed:Bool
    public var loop:Bool
    var previousFrameTime = kCMTimeZero

    var numberOfFramesCaptured = 0
    var totalFrameTimeDuringCapture:Double = 0.0

    // TODO: Add movie reader synchronization
    // TODO: Someone will have to add back in the AVPlayerItem logic, because I don't know how that works
    public init(asset:AVAsset, videoComposition: AVVideoComposition?, playAtActualSpeed:Bool = false, loop:Bool = false) throws {
        self.asset = asset
        self.videoComposition = videoComposition
        self.playAtActualSpeed = playAtActualSpeed
        self.loop = loop
        self.yuvConversionShader = crashOnShaderCompileFailure("MovieInput"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader:YUVConversionFullRangeFragmentShader)}
        
        // TODO: Audio here
    }

    public convenience init(url:URL, playAtActualSpeed:Bool = false, loop:Bool = false) throws {
        let inputOptions = [AVURLAssetPreferPreciseDurationAndTimingKey:NSNumber(value:true)]
        let inputAsset = AVURLAsset(url:url, options:inputOptions)
        try self.init(asset:inputAsset, videoComposition: nil, playAtActualSpeed:playAtActualSpeed, loop:loop)
    }
    
    deinit {
        self.cancel()
    }

    // MARK: -
    // MARK: Playback control
    
    public func createReader() -> AVAssetReader?
    {
        var assetReader: AVAssetReader?
        do {
            let outputSettings:[String:AnyObject] =
                [(kCVPixelBufferPixelFormatTypeKey as String):NSNumber(value:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))]
            
            assetReader = try AVAssetReader.init(asset: self.asset)
            
            if(self.videoComposition == nil) {
                let readerVideoTrackOutput = AVAssetReaderTrackOutput(track:self.asset.tracks(withMediaType: AVMediaTypeVideo)[0], outputSettings:outputSettings)
                readerVideoTrackOutput.alwaysCopiesSampleData = false
                assetReader!.add(readerVideoTrackOutput)
            }
            else {
                let readerVideoTrackOutput = AVAssetReaderVideoCompositionOutput(videoTracks: self.asset.tracks(withMediaType: AVMediaTypeVideo), videoSettings: outputSettings)
                readerVideoTrackOutput.videoComposition = self.videoComposition
                assetReader!.add(readerVideoTrackOutput)
            }

        } catch {
            print("Could not create asset reader: \(error)")
        }
        
        return assetReader
    }


    public func start() {
        if(self.started) { return }
        
        if(assetReader == nil) { assetReader = createReader() }
        if(assetReader == nil) { return }
        
        self.started = true
        
        asset.loadValuesAsynchronously(forKeys:["tracks"], completionHandler:{
            DispatchQueue.global().async(qos: .background) {
                guard (self.asset.statusOfValue(forKey: "tracks", error:nil) == .loaded) else { return }
                guard let assetReader = self.assetReader else { return }
                guard self.started else { return }
                
                do {
                    try ObjC.catchException {
                        guard assetReader.startReading() else {
                            print("Couldn't start reading: \(assetReader.error)")
                            return
                        }
                    }
                }
                catch {
                    print("Couldn't start reading: \(error)")
                    return
                }
                
                Thread.detachNewThreadSelector(#selector(self.beginReading), toTarget: self, with: nil)
            }
        })
    }
    
    public func cancel() {
        if let assetReader = self.assetReader {
            assetReader.cancelReading()
            self.endProcessing()
        }
    }
    
    func endProcessing() {
        self.assetReader = nil
        self.started = false
    }
    
    // MARK: -
    // MARK: Internal processing functions
    
    @objc func beginReading() {
        guard let assetReader = self.assetReader else { return }
        
        var readerVideoTrackOutput:AVAssetReaderOutput? = nil;
        
        for output in assetReader.outputs {
            if(output.mediaType == AVMediaTypeVideo) {
                readerVideoTrackOutput = output;
            }
        }
        
        self.configureThread()
        
        while(assetReader.status == .reading) {
            self.readNextVideoFrame(from:readerVideoTrackOutput!)
        }
        
        if (assetReader.status == .completed) {
            assetReader.cancelReading()
            
            if (self.loop) {
                self.endProcessing()
                self.start()
            } else {
                self.endProcessing()
            }
        }
    }
    
    func readNextVideoFrame(from videoTrackOutput:AVAssetReaderOutput) {
        guard let assetReader = self.assetReader else { return }
        
        let renderStart = DispatchTime.now()
        var frameDurationNanos: Float64 = 0
        
        if (assetReader.status == .reading) {
            if let sampleBuffer = videoTrackOutput.copyNextSampleBuffer() {
                if (playAtActualSpeed) {
                    // Do this outside of the video processing queue to not slow that down while waiting
                    
                    // Sample time eg. first frame is 0,30 second frame is 1,30
                    let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
                    
                    // Retrieve the rolling frame rate (duration between each frame)
                    let frameDuration = CMTimeSubtract(currentSampleTime, previousFrameTime)
                    frameDurationNanos = CMTimeGetSeconds(frameDuration) * 1_000_000_000
                    
                    self.previousFrameTime = currentSampleTime
                }
                
                sharedImageProcessingContext.runOperationSynchronously{
                    self.process(movieFrame:sampleBuffer)
                    CMSampleBufferInvalidate(sampleBuffer)
                }
                
                if(playAtActualSpeed) {
                    let renderEnd = DispatchTime.now()
                    
                    // Find the amount of time it took to display the last frame in microseconds
                    let renderDurationNanos = Double(renderEnd.uptimeNanoseconds - renderStart.uptimeNanoseconds)
                    
                    // Find how much time we should wait to display the next frame. So it would be the frame duration minus the
                    // amount of time we already spent rendering the current frame.
                    let waitDurationNanos = Int(frameDurationNanos - renderDurationNanos)
                    
                    if(waitDurationNanos > 0) {
                        mach_wait_until(mach_absolute_time()+self.nanosToAbs(UInt64(waitDurationNanos)))
                    }
                }
            }
        }
//        else if (synchronizedMovieWriter != nil) {
//            if (assetReader.status == .Completed) {
//                self.endProcessing()
//            }
//        }
        
    }
    
    func process(movieFrame frame:CMSampleBuffer) {
        let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(frame)
        let movieFrame = CMSampleBufferGetImageBuffer(frame)!
    
//        processingFrameTime = currentSampleTime
        self.process(movieFrame:movieFrame, withSampleTime:currentSampleTime)
    }
    
    //Code from pull request https://github.com/BradLarson/GPUImage2/pull/183
    func process(movieFrame:CVPixelBuffer, withSampleTime:CMTime) {
        let bufferHeight = CVPixelBufferGetHeight(movieFrame)
        let bufferWidth = CVPixelBufferGetWidth(movieFrame)
        CVPixelBufferLockBaseAddress(movieFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        
        let conversionMatrix = colorConversionMatrix601FullRangeDefault
        // TODO: Get this color query working
        //        if let colorAttachments = CVBufferGetAttachment(movieFrame, kCVImageBufferYCbCrMatrixKey, nil) {
        //            if(CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == .EqualTo) {
        //                _preferredConversion = kColorConversion601FullRange
        //            } else {
        //                _preferredConversion = kColorConversion709
        //            }
        //        } else {
        //            _preferredConversion = kColorConversion601FullRange
        //        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        var luminanceGLTexture: CVOpenGLESTexture?
        
        glActiveTexture(GLenum(GL_TEXTURE0))
        
        let luminanceGLTextureResult = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, movieFrame, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), 0, &luminanceGLTexture)
        
        if(luminanceGLTextureResult != kCVReturnSuccess || luminanceGLTexture == nil) {
            print("Could not create LuminanceGLTexture")
            return
        }
        
        let luminanceTexture = CVOpenGLESTextureGetName(luminanceGLTexture!)
        
        glBindTexture(GLenum(GL_TEXTURE_2D), luminanceTexture)
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE));
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE));
        
        let luminanceFramebuffer: Framebuffer
        do {
            luminanceFramebuffer = try Framebuffer(context: sharedImageProcessingContext, orientation: .portrait, size: GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly: true, overriddenTexture: luminanceTexture)
        } catch {
            print("Could not create a framebuffer of the size (\(bufferWidth), \(bufferHeight)), error: \(error)")
            return
        }
        
        luminanceFramebuffer.cache = sharedImageProcessingContext.framebufferCache
        luminanceFramebuffer.lock()
        
        var chrominanceGLTexture: CVOpenGLESTexture?
        
        glActiveTexture(GLenum(GL_TEXTURE1))
        
        let chrominanceGLTextureResult = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, movieFrame, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), 1, &chrominanceGLTexture)
        
        if(chrominanceGLTextureResult != kCVReturnSuccess || chrominanceGLTexture == nil) {
            print("Could not create ChrominanceGLTexture")
            return
        }
        
        let chrominanceTexture = CVOpenGLESTextureGetName(chrominanceGLTexture!)
        
        glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceTexture)
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE));
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE));
        
        let chrominanceFramebuffer: Framebuffer
        do {
            chrominanceFramebuffer = try Framebuffer(context: sharedImageProcessingContext, orientation: .portrait, size: GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly: true, overriddenTexture: chrominanceTexture)
        } catch {
            print("Could not create a framebuffer of the size (\(bufferWidth), \(bufferHeight)), error: \(error)")
            return
        }
        
        chrominanceFramebuffer.cache = sharedImageProcessingContext.framebufferCache
        chrominanceFramebuffer.lock()
        
        let movieFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:false)
        
        convertYUVToRGB(shader:self.yuvConversionShader, luminanceFramebuffer:luminanceFramebuffer, chrominanceFramebuffer:chrominanceFramebuffer, resultFramebuffer:movieFramebuffer, colorConversionMatrix:conversionMatrix)
        CVPixelBufferUnlockBaseAddress(movieFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        
        movieFramebuffer.timingStyle = .videoFrame(timestamp:Timestamp(withSampleTime))
        self.updateTargetsWithFramebuffer(movieFramebuffer)
        
        if self.runBenchmark {
            let currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime)
            self.numberOfFramesCaptured += 1
            self.totalFrameTimeDuringCapture += currentFrameTime
            print("Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.numberOfFramesCaptured)) ms")
            print("Current frame time : \(1000.0 * currentFrameTime) ms")
        }
    }

    public func transmitPreviousImage(to target:ImageConsumer, atIndex:UInt) {
        // Not needed for movie inputs
    }
    
    // MARK: -
    // MARK: Thread configuration
    
    var timebaseInfo = mach_timebase_info_data_t()
    
    func configureThread() {
        mach_timebase_info(&timebaseInfo)
        let clock2abs = Double(timebaseInfo.denom) / Double(timebaseInfo.numer) * Double(NSEC_PER_MSEC)
        
        let period      = UInt32(0.00 * clock2abs)
        // Setup for 30 milliseconds of work
        // The anticpated render duration is in the 10-30 ms range on an iPhone 6 for 1080p video with no filters
        // If the computation value is set too high, setting the thread policy will fail
        let computation = UInt32(30 * clock2abs)
        // With filters the upper bound is unlimited but with a lot of approximation it falls in the 20-100 ms range with 1080p video
        // If we surpass our constraint the computation is scheduled for a later point
        // You can test this by setting a low constraint and then applying a filter
        let constraint  = UInt32(100 * clock2abs)
        
        let THREAD_TIME_CONSTRAINT_POLICY_COUNT = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        
        var policy = thread_time_constraint_policy()
        var ret: Int32
        let thread: thread_port_t = pthread_mach_thread_np(pthread_self())
        
        policy.period = period
        policy.computation = computation
        policy.constraint = constraint
        policy.preemptible = 0
        
        ret = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(THREAD_TIME_CONSTRAINT_POLICY_COUNT)) {
                thread_policy_set(thread, UInt32(THREAD_TIME_CONSTRAINT_POLICY), $0, THREAD_TIME_CONSTRAINT_POLICY_COUNT)
            }
        }
        
        if ret != KERN_SUCCESS {
            mach_error("thread_policy_set:", ret)
            fatalError("Unable to configure thread")
        }
    }
    
    func nanosToAbs(_ nanos: UInt64) -> UInt64 {
        return nanos * UInt64(timebaseInfo.denom) / UInt64(timebaseInfo.numer)
    }
}
