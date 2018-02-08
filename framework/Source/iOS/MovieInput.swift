import AVFoundation

public class MovieInput: ImageSource {
    public let targets = TargetContainer()
    public var runBenchmark = false
    
    let yuvConversionShader:ShaderProgram
    let asset:AVAsset
    let videoComposition:AVVideoComposition?
    let playAtActualSpeed:Bool
    public var loop:Bool
    public var startFrameTime:CMTime?
    public var currentFrameTime:CMTime? {
        get {
            return self.lastFrameTime
        }
    }
    var currentThread:Thread?
    var lastFrameTime:CMTime?

    var numberOfFramesCaptured = 0
    var totalFrameTimeDuringCapture:Double = 0.0
    
    var movieFramebuffer:Framebuffer?
    
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
        self.movieFramebuffer?.unlock()
        self.cancel()
    }

    // MARK: -
    // MARK: Playback control
    // Only call these methods from the main thread

    @objc public func start() {
        if let currentThread = self.currentThread,
            currentThread.isExecuting,
            !currentThread.isCancelled {
            // If the current thread is running and has not been cancelled, bail.
            return
        }
        // Just to be safe.
        self.currentThread?.cancel()
        
        self.currentThread = Thread(target: self, selector: #selector(beginReading), object: nil)
        self.currentThread?.start()
    }
    
    public func cancel() {
        self.currentThread?.cancel()
        self.currentThread = nil
    }
    
    public func pause() {
        self.cancel()
        self.startFrameTime = self.lastFrameTime
    }
    
    // MARK: -
    // MARK: Internal processing functions
    
    func createReader() -> AVAssetReader?
    {
        do {
            let outputSettings:[String:AnyObject] =
                [(kCVPixelBufferPixelFormatTypeKey as String):NSNumber(value:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))]
            
            let assetReader = try AVAssetReader.init(asset: self.asset)
            
            if(self.videoComposition == nil) {
                let readerVideoTrackOutput = AVAssetReaderTrackOutput(track:self.asset.tracks(withMediaType: AVMediaTypeVideo)[0], outputSettings:outputSettings)
                readerVideoTrackOutput.alwaysCopiesSampleData = false
                assetReader.add(readerVideoTrackOutput)
            }
            else {
                let readerVideoTrackOutput = AVAssetReaderVideoCompositionOutput(videoTracks: self.asset.tracks(withMediaType: AVMediaTypeVideo), videoSettings: outputSettings)
                readerVideoTrackOutput.videoComposition = self.videoComposition
                readerVideoTrackOutput.alwaysCopiesSampleData = false
                assetReader.add(readerVideoTrackOutput)
            }
            
            if let startFrameTime = self.startFrameTime {
                assetReader.timeRange = CMTimeRange(start: startFrameTime, duration: kCMTimePositiveInfinity)
            }
            self.startFrameTime = nil
            self.lastFrameTime = nil
            
            return assetReader
        } catch {
            print("Could not create asset reader: \(error)")
        }
        return nil
    }
    
    @objc func beginReading() {
        let thread = Thread.current
        
        self.configureThread()
        
        guard let assetReader = self.createReader() else {
            return // A return statement will end thread execution
        }
        
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
        
        var readerVideoTrackOutput:AVAssetReaderOutput? = nil;
        
        for output in assetReader.outputs {
            if(output.mediaType == AVMediaTypeVideo) {
                readerVideoTrackOutput = output
            }
        }
        
        while(assetReader.status == .reading) {
            if(thread.isCancelled) { break }
            self.readNextVideoFrame(with: assetReader, from: readerVideoTrackOutput!)
        }
        
        assetReader.cancelReading()
        
        // Since only the main thread will cancel threads
        // jump onto the main thead to prevent the current thread from being cancelled
        // in between the below if statement check and creating the new thread
        DispatchQueue.main.async {
            // Start the video over so long as it wasn't cancelled
            if (self.loop && !thread.isCancelled) {
                self.currentThread = Thread(target: self, selector: #selector(self.beginReading), object: nil)
                self.currentThread?.start()
            }
        }
    }
    
    func readNextVideoFrame(with assetReader: AVAssetReader, from videoTrackOutput:AVAssetReaderOutput) {
        if let sampleBuffer = videoTrackOutput.copyNextSampleBuffer() {
            
            let renderStart = DispatchTime.now()
            var frameDurationNanos: Float64 = 0
            
            if (self.playAtActualSpeed) {
                // Sample time eg. first frame is 0,30 second frame is 1,30
                let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
                
                // Retrieve the rolling frame rate (duration between each frame)
                let frameDuration = CMTimeSubtract(currentSampleTime, self.lastFrameTime ?? CMTimeAdd(currentSampleTime, CMTime(value: 1, timescale: 30)))
                frameDurationNanos = CMTimeGetSeconds(frameDuration) * 1_000_000_000
                
                self.lastFrameTime = currentSampleTime
            }
            
            sharedImageProcessingContext.runOperationSynchronously{
                self.process(movieFrame:sampleBuffer)
                CMSampleBufferInvalidate(sampleBuffer)
            }
            
            if(self.playAtActualSpeed) {
                let renderEnd = DispatchTime.now()
                
                // Find the amount of time it took to display the last frame
                let renderDurationNanos = Double(renderEnd.uptimeNanoseconds - renderStart.uptimeNanoseconds)
                
                // Find how much time we should wait to display the next frame. So it would be the frame duration minus the
                // amount of time we already spent rendering the current frame.
                let waitDurationNanos = Int(frameDurationNanos - renderDurationNanos)
                
                // When the wait duration begins returning negative values consistently
                // It means the OS is unable to provide enough processing time for the above work
                // and that you need to adjust the real time thread policy below
                //print("Render duration: \(String(format: "%.4f",renderDurationNanos / 1_000_000)) ms Wait duration: \(String(format: "%.4f",Double(waitDurationNanos) / 1_000_000)) ms")
                
                if(waitDurationNanos > 0) {
                    mach_wait_until(mach_absolute_time()+self.nanosToAbs(UInt64(waitDurationNanos)))
                }
            }
        }
    }
    
    func process(movieFrame frame:CMSampleBuffer) {
        let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(frame)
        let movieFrame = CMSampleBufferGetImageBuffer(frame)!
        
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
        
        chrominanceFramebuffer.lock()
        
        self.movieFramebuffer?.unlock()
        let movieFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:false)
        movieFramebuffer.lock()
        movieFramebuffer.sampleTime = withSampleTime
        
        convertYUVToRGB(shader:self.yuvConversionShader, luminanceFramebuffer:luminanceFramebuffer, chrominanceFramebuffer:chrominanceFramebuffer, resultFramebuffer:movieFramebuffer, colorConversionMatrix:conversionMatrix)
        CVPixelBufferUnlockBaseAddress(movieFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        
        movieFramebuffer.timingStyle = .videoFrame(timestamp:Timestamp(withSampleTime))
        self.movieFramebuffer = movieFramebuffer
        
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
    
    public func reprocessLastFrame() {
        sharedImageProcessingContext.runOperationAsynchronously {
            if let movieFramebuffer = self.movieFramebuffer {
                self.updateTargetsWithFramebuffer(movieFramebuffer)
            }
        }
    }
    
    // MARK: -
    // MARK: Thread configuration
    
    var timebaseInfo = mach_timebase_info_data_t()
    
    func configureThread() {
        mach_timebase_info(&timebaseInfo)
        let clock2abs = Double(timebaseInfo.denom) / Double(timebaseInfo.numer) * Double(NSEC_PER_MSEC)
        
        // http://docs.huihoo.com/darwin/kernel-programming-guide/scheduler/chapter_8_section_4.html
        //
        // To see the impact of adjusting these values, uncomment the print statement above mach_wait_until() in self.readNextVideoFrame()
        //
        // Setup for 5 ms of work.
        // The anticpated frame render duration is in the 1-3 ms range on an iPhone 6 for 1080p without filters and 1-7 ms range with filters
        // If the render duration is allowed to exceed 16ms (the duration of a frame in 60fps video)
        // the 60fps video will no longer be playing in real time.
        let computation = UInt32(5 * clock2abs)
        // Tell the scheduler the next 20 ms of work needs to be done as soon as possible.
        let period      = UInt32(0 * clock2abs)
        // According to the above scheduling chapter this constraint only appears relevant
        // if preemtible is set to true and the period is not 0. If this is wrong, please let me know.
        let constraint  = UInt32(5 * clock2abs)
        
        //print("period: \(period) computation: \(computation) constraint: \(constraint)")
        
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
