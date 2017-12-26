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
    var videoEncodingIsFinished = false
    var previousFrameTime = kCMTimeZero
    var previousActualFrameTime = CFAbsoluteTimeGetCurrent()

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
            DispatchQueue.global(priority:DispatchQueue.GlobalQueuePriority.default).async(execute: {
                guard (self.asset.statusOfValue(forKey: "tracks", error:nil) == .loaded) else { return }
                guard let assetReader = self.assetReader else { return }
                
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
                        readerVideoTrackOutput = output;
                    }
                }
                
                while (assetReader.status == .reading) {
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
            })
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
    
    func readNextVideoFrame(from videoTrackOutput:AVAssetReaderOutput) {
        guard let assetReader = self.assetReader else { return }
        
        if ((assetReader.status == .reading) && !videoEncodingIsFinished) {
            if let sampleBuffer = videoTrackOutput.copyNextSampleBuffer() {
                if (playAtActualSpeed) {
                    // Do this outside of the video processing queue to not slow that down while waiting
                    
                    // Sample time eg. first frame is 0,30 second frame is 1,30
                    let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
                    // This produces the rolling frame rate
                    let differenceFromLastFrame = CMTimeSubtract(currentSampleTime, previousFrameTime)
                    
                    // Frame duration in seconds, shorten it ever so slightly to speed up playback
                    let frameTimeDifference = CMTimeGetSeconds(differenceFromLastFrame) - 0.0022
                    // Actual time passed since last frame displayed
                    let actualTimeDifference = CFAbsoluteTimeGetCurrent() - previousActualFrameTime
                    
                    // If the frame duration is longer than the duration we are actually display them at
                    // Slow the duration we are actually displaying them at
                    if (frameTimeDifference > actualTimeDifference) {
                        usleep(UInt32(round(1000000.0 * (frameTimeDifference - actualTimeDifference))))
                    }
                    
                    //actualTimeDifference = CFAbsoluteTimeGetCurrent() - previousActualFrameTime
                    //print("frameTime: \(String(format: "%.6f", frameTimeDifference)) actualTime: \(String(format: "%.6f", actualTimeDifference))")
                    
                    previousFrameTime = currentSampleTime
                    previousActualFrameTime = CFAbsoluteTimeGetCurrent()
                }

                sharedImageProcessingContext.runOperationSynchronously{
                    self.process(movieFrame:sampleBuffer)
                    CMSampleBufferInvalidate(sampleBuffer)
                }
            } else {
                if (!loop) {
                    videoEncodingIsFinished = true
                    if (videoEncodingIsFinished) {
                        self.endProcessing()
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
}
