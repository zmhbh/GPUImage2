import AVFoundation

extension String: Error {}

public protocol AudioEncodingTarget {
    func activateAudioTrack()
    func processAudioBuffer(_ sampleBuffer:CMSampleBuffer, shouldInvalidateSampleWhenDone:Bool)
}

public class MovieOutput: ImageConsumer, AudioEncodingTarget {
    public let sources = SourceContainer()
    public let maximumInputs:UInt = 1
    
    let assetWriter:AVAssetWriter
    let assetWriterVideoInput:AVAssetWriterInput
    var assetWriterAudioInput:AVAssetWriterInput?
    
    let assetWriterPixelBufferInput:AVAssetWriterInputPixelBufferAdaptor
    let size:Size
    let colorSwizzlingShader:ShaderProgram
    private var isRecording = false
    private var isFinishing = false
    private var finishRecordingCompletionCallback:(() -> Void)? = nil
    var videoEncodingIsFinished = false
    var audioEncodingIsFinished = false
    private var startTime:CMTime?
    private var firstFrameTime: CMTime?
    private var previousFrameTime: CMTime?
    private var previousAudioTime: CMTime?
    var encodingLiveVideo:Bool {
        didSet {
            assetWriterVideoInput.expectsMediaDataInRealTime = encodingLiveVideo
            assetWriterAudioInput?.expectsMediaDataInRealTime = encodingLiveVideo
        }
    }
    var pixelBuffer:CVPixelBuffer? = nil
    var renderFramebuffer:Framebuffer!
    
    var audioSettings:[String:Any]? = nil
    
    let movieProcessingContext:OpenGLContext
    
    public init(URL:Foundation.URL, size:Size, fileType:String = AVFileTypeQuickTimeMovie, liveVideo:Bool = false, videoSettings:[String:Any]? = nil, audioSettings:[String:Any]? = nil) throws {
        imageProcessingShareGroup = sharedImageProcessingContext.context.sharegroup
        // Since we cannot access self before calling super, initialize here and not above
        let movieProcessingContext = OpenGLContext()
        
        if movieProcessingContext.supportsTextureCaches() {
            self.colorSwizzlingShader = movieProcessingContext.passthroughShader
        } else {
            self.colorSwizzlingShader = crashOnShaderCompileFailure("MovieOutput"){try movieProcessingContext.programForVertexShader(defaultVertexShaderForInputs(1), fragmentShader:ColorSwizzlingFragmentShader)}
        }
        
        self.size = size
        
        assetWriter = try AVAssetWriter(url:URL, fileType:fileType)
        // Set this to make sure that a functional movie is produced, even if the recording is cut off mid-stream. Only the last 1/4 second should be lost in that case.
        assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(0.25, 1000)
        
        var localSettings:[String:Any]
        if let videoSettings = videoSettings {
            localSettings = videoSettings
        } else {
            localSettings = [String:Any]()
        }
        
        localSettings[AVVideoWidthKey] = localSettings[AVVideoWidthKey] ?? size.width
        localSettings[AVVideoHeightKey] = localSettings[AVVideoHeightKey] ?? size.height
        localSettings[AVVideoCodecKey] =  localSettings[AVVideoCodecKey] ?? AVVideoCodecH264
        
        assetWriterVideoInput = AVAssetWriterInput(mediaType:AVMediaTypeVideo, outputSettings:localSettings)
        assetWriterVideoInput.expectsMediaDataInRealTime = liveVideo
        encodingLiveVideo = liveVideo
        
        // You need to use BGRA for the video in order to get realtime encoding. I use a color-swizzling shader to line up glReadPixels' normal RGBA output with the movie input's BGRA.
        let sourcePixelBufferAttributesDictionary:[String:Any] = [kCVPixelBufferPixelFormatTypeKey as String:Int32(kCVPixelFormatType_32BGRA),
                                                                        kCVPixelBufferWidthKey as String:self.size.width,
                                                                        kCVPixelBufferHeightKey as String:self.size.height]
        
        assetWriterPixelBufferInput = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:assetWriterVideoInput, sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary)
        assetWriter.add(assetWriterVideoInput)
        
        self.audioSettings = audioSettings
        
        self.movieProcessingContext = movieProcessingContext
    }
    
    public func startRecording(_ completionCallback:((_ started: Bool) -> Void)? = nil) {
        startTime = nil
        
        // Don't do this work on the movieProcessingContext que so we don't block it.
        // If it does get blocked framebuffers will pile up and after it is no longer blocked/this work has finished
        // we will be able to accept framebuffers but the ones that piled up will come in too quickly resulting in most being dropped
        DispatchQueue.global(qos: .utility).async {
            do {
                var success = false
                try NSObject.catchException {
                    success = self.assetWriter.startWriting()
                }
                
                if(!success) {
                    throw "Could not start asset writer: \(String(describing: self.assetWriter.error))"
                }
                
                guard let pixelBufferPool = self.assetWriterPixelBufferInput.pixelBufferPool else {
                    // When the pixelBufferPool returns nil, check the following:
                    // https://stackoverflow.com/a/20110179/1275014
                    throw "Pixel buffer pool was nil"
                }
                
                CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &self.pixelBuffer)
                
                guard let pixelBuffer = self.pixelBuffer else {
                    throw "Unable to create pixel buffer"
                }
                
                /* AVAssetWriter will use BT.601 conversion matrix for RGB to YCbCr conversion
                 * regardless of the kCVImageBufferYCbCrMatrixKey value.
                 * Tagging the resulting video file as BT.601, is the best option right now.
                 * Creating a proper BT.709 video is not possible at the moment.
                 */
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                
                // This work must be done on the movieProcessingContext since we access openGL
                try self.movieProcessingContext.runOperationSynchronously {
                    let bufferSize = GLSize(self.size)
                    var cachedTextureRef:CVOpenGLESTexture? = nil
                    let _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, self.movieProcessingContext.coreVideoTextureCache, pixelBuffer, nil, GLenum(GL_TEXTURE_2D), GL_RGBA, bufferSize.width, bufferSize.height, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), 0, &cachedTextureRef)
                    let cachedTexture = CVOpenGLESTextureGetName(cachedTextureRef!)
                    
                    self.renderFramebuffer = try Framebuffer(context:self.movieProcessingContext, orientation:.portrait, size:bufferSize, textureOnly:false, overriddenTexture:cachedTexture)
                    
                    self.isRecording = true
                    
                    completionCallback?(true)
                }
            } catch {
                print("Unable to start recording: \(error)")
                
                self.assetWriter.cancelWriting()
                
                completionCallback?(false)
            }
        }
        
    }
    
    public func finishRecording(_ completionCallback:(() -> Void)? = nil) {
        movieProcessingContext.runOperationAsynchronously{
            guard self.isRecording,
                !self.isFinishing,
                self.assetWriter.status == .writing else {
                    completionCallback?()
                    return
            }
            
            self.finishRecordingCompletionCallback = completionCallback
            
            self.audioEncodingIsFinished = true
            
            // Check that there was audio and that this is live video
            if let previousAudioTime = self.previousAudioTime,
                self.encodingLiveVideo {
                
                // Check if the last frame is later than the last recorded audio buffer
                if let previousFrameTime = self.previousFrameTime,
                    CMTimeCompare(previousAudioTime, previousFrameTime) == -1 {
                    // Finish immediately
                    self.finishWriting()
                }
                else {
                    // Video will finish once a there is a frame time that is later than the last recorded audio buffer time
                    self.isFinishing = true
                    
                    // Finish after a delay just incase we don't recieve any additional audio buffers
                    self.movieProcessingContext.serialDispatchQueue.asyncAfter(deadline: .now() + 0.1) {
                        self.finishWriting()
                    }
                }
            }
            else {
                // Finish immediately since there is no audio
                self.finishWriting()
            }
        }
    }
    
    private func finishWriting() {
        guard self.isRecording else { return }
        
        self.isFinishing = false
        self.isRecording = false
        
        self.videoEncodingIsFinished = true
        
        self.assetWriter.finishWriting {
            self.finishRecordingCompletionCallback?()
        }
    }
    
    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        glFinish();
        
        movieProcessingContext.runOperationAsynchronously {
            guard self.isRecording,
                self.assetWriter.status == .writing,
                !self.videoEncodingIsFinished else { return }
            
            // Ignore still images and other non-video updates (do I still need this?)
            guard let frameTime = framebuffer.timingStyle.timestamp?.asCMTime else { return }
            
            // Check if we are finishing and if this frame is later than the last recorded audio buffer
            // Note: isFinishing is only set when there is an audio buffer, otherwise the video is finished immediately
            if self.isFinishing,
                let previousAudioTime = self.previousAudioTime,
                CMTimeCompare(previousAudioTime, frameTime) == -1 {
                self.finishWriting()
                return
            }
            
            // If two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
            guard (frameTime != self.previousFrameTime) else { return }
            
            if (self.startTime == nil) {
                self.assetWriter.startSession(atSourceTime: frameTime)
                self.startTime = frameTime
                self.firstFrameTime = frameTime
            }
            
            self.previousFrameTime = frameTime

            guard (self.assetWriterVideoInput.isReadyForMoreMediaData || !self.encodingLiveVideo) else {
                debugPrint("Had to drop a frame at time \(frameTime)")
                return
            }
            
            while(!self.assetWriterVideoInput.isReadyForMoreMediaData && !self.encodingLiveVideo && !self.videoEncodingIsFinished) {
                if(synchronizedEncodingDebug) { print("Video waiting...") }
                // Better to poll isReadyForMoreMediaData often since when it does become true
                // we don't want to risk letting framebuffers pile up in between poll intervals.
                usleep(100000) // 0.1 seconds
            }
            
            if !self.movieProcessingContext.supportsTextureCaches() {
                let pixelBufferStatus = CVPixelBufferPoolCreatePixelBuffer(nil, self.assetWriterPixelBufferInput.pixelBufferPool!, &self.pixelBuffer)
                guard ((self.pixelBuffer != nil) && (pixelBufferStatus == kCVReturnSuccess)) else { return }
            }
            
            self.renderIntoPixelBuffer(self.pixelBuffer!, framebuffer:framebuffer)
            
            if(synchronizedEncodingDebug && !self.encodingLiveVideo) { print("Process frame output") }
            
            if (!self.assetWriterPixelBufferInput.append(self.pixelBuffer!, withPresentationTime:frameTime)) {
                debugPrint("Problem appending pixel buffer at time: \(frameTime)")
            }
            
            CVPixelBufferUnlockBaseAddress(self.pixelBuffer!, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
            if !self.movieProcessingContext.supportsTextureCaches() {
                self.pixelBuffer = nil
            }

            framebuffer.unlock()
        }
    }
    
    func renderIntoPixelBuffer(_ pixelBuffer:CVPixelBuffer, framebuffer:Framebuffer) {
        if !movieProcessingContext.supportsTextureCaches() {
            renderFramebuffer = movieProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:framebuffer.orientation, size:GLSize(self.size))
            renderFramebuffer.lock()
        }
        
        renderFramebuffer.activateFramebufferForRendering()
        clearFramebufferWithColor(Color.black)
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        renderQuadWithShader(colorSwizzlingShader, uniformSettings:ShaderUniformSettings(), vertexBufferObject:movieProcessingContext.standardImageVBO, inputTextures:[framebuffer.texturePropertiesForOutputRotation(.noRotation)], context: movieProcessingContext)
        
        if movieProcessingContext.supportsTextureCaches() {
            glFinish()
        } else {
            glReadPixels(0, 0, renderFramebuffer.size.width, renderFramebuffer.size.height, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddress(pixelBuffer))
            renderFramebuffer.unlock()
        }
    }
    
    // MARK: -
    // MARK: Audio support
    
    public func activateAudioTrack() {
        assetWriterAudioInput = AVAssetWriterInput(mediaType:AVMediaTypeAudio, outputSettings:self.audioSettings)
        assetWriter.add(assetWriterAudioInput!)
        assetWriterAudioInput?.expectsMediaDataInRealTime = encodingLiveVideo
    }
    
    public func processAudioBuffer(_ sampleBuffer:CMSampleBuffer, shouldInvalidateSampleWhenDone:Bool) {
        let work = {
            defer {
                if(shouldInvalidateSampleWhenDone) {
                    CMSampleBufferInvalidate(sampleBuffer)
                }
            }
            
            guard self.isRecording,
                self.assetWriter.status == .writing,
                !self.audioEncodingIsFinished,
                let assetWriterAudioInput = self.assetWriterAudioInput else { return }
            
            let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            
            if let firstFrameTime = self.firstFrameTime {
                // If the time of this audio sample is before the time of the first frame ignore it
                if (CMTimeCompare(currentSampleTime, firstFrameTime) == -1) {
                    return
                }
            }
            else {
                // We have not recorded any video yet so we do not know if this audio sample
                // falls before or after the time of the first frame which has not yet come in.
                // There may be a better solution for this case
                return
            }
            
            self.previousAudioTime = currentSampleTime
            
            guard (assetWriterAudioInput.isReadyForMoreMediaData || !self.encodingLiveVideo) else {
                debugPrint("Had to drop a audio sample at time \(currentSampleTime)")
                return
            }
            
            while(!assetWriterAudioInput.isReadyForMoreMediaData && !self.encodingLiveVideo && !self.audioEncodingIsFinished) {
                if(synchronizedEncodingDebug) { print("Audio waiting...") }
                usleep(100000)
            }
            
            if(synchronizedEncodingDebug && !self.encodingLiveVideo) { print("Process audio sample output") }
            
            if (!assetWriterAudioInput.append(sampleBuffer)) {
                print("Trouble appending audio sample buffer: \(String(describing: self.assetWriter.error))")
            }
        }
        
        if(self.encodingLiveVideo) {
            movieProcessingContext.runOperationAsynchronously(work)
        }
        else {
            work()
        }
    }
}


public extension Timestamp {
    public init(_ time:CMTime) {
        self.value = time.value
        self.timescale = time.timescale
        self.flags = TimestampFlags(rawValue:time.flags.rawValue)
        self.epoch = time.epoch
    }
    
    public var asCMTime:CMTime {
        get {
            return CMTimeMakeWithEpoch(value, timescale, epoch)
        }
    }
}
