import AVFoundation

extension String: Error {}

public protocol AudioEncodingTarget {
    var shouldInvalidateAudioSampleWhenDone: Bool { get set }
    
    func activateAudioTrack()
    func processAudioBuffer(_ sampleBuffer:CMSampleBuffer)
}

public class MovieOutput: ImageConsumer, AudioEncodingTarget {
    public let sources = SourceContainer()
    public let maximumInputs:UInt = 1
    
    public var shouldInvalidateAudioSampleWhenDone: Bool = false
    
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
    
    let movieProcessingContext:OpenGLContext
    
    public init(URL:Foundation.URL, size:Size, fileType:String = AVFileTypeQuickTimeMovie, liveVideo:Bool = false, settings:[String:AnyObject]? = nil) throws {
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
        // Set this to make sure that a functional movie is produced, even if the recording is cut off mid-stream. Only the last second should be lost in that case.
        assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(1.0, 1000)
        
        var localSettings:[String:AnyObject]
        if let settings = settings {
            localSettings = settings
        } else {
            localSettings = [String:AnyObject]()
        }
        
        localSettings[AVVideoWidthKey] = localSettings[AVVideoWidthKey] ?? NSNumber(value:size.width)
        localSettings[AVVideoHeightKey] = localSettings[AVVideoHeightKey] ?? NSNumber(value:size.height)
        localSettings[AVVideoCodecKey] =  localSettings[AVVideoCodecKey] ?? AVVideoCodecH264 as NSString
        
        assetWriterVideoInput = AVAssetWriterInput(mediaType:AVMediaTypeVideo, outputSettings:localSettings)
        assetWriterVideoInput.expectsMediaDataInRealTime = liveVideo
        encodingLiveVideo = liveVideo
        
        // You need to use BGRA for the video in order to get realtime encoding. I use a color-swizzling shader to line up glReadPixels' normal RGBA output with the movie input's BGRA.
        let sourcePixelBufferAttributesDictionary:[String:AnyObject] = [kCVPixelBufferPixelFormatTypeKey as         String:NSNumber(value:Int32(kCVPixelFormatType_32BGRA)),
                                                                        kCVPixelBufferWidthKey as String:NSNumber(value:self.size.width),
                                                                        kCVPixelBufferHeightKey as String:NSNumber(value:self.size.height)]
        
        assetWriterPixelBufferInput = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:assetWriterVideoInput, sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary)
        assetWriter.add(assetWriterVideoInput)
        
        self.movieProcessingContext = movieProcessingContext
    }
    
    public func startRecording(_ completionCallback:((_ started: Bool) -> Void)? = nil) {
        startTime = nil
        
        movieProcessingContext.runOperationAsynchronously {
            do {
                try NSObject.catchException {
                    self.isRecording = self.assetWriter.startWriting()
                }
                
                if(!self.isRecording) {
                    throw "Could not start asset writer: \(String(describing: self.assetWriter.error))"
                }
                
                guard let pixelBufferPool = self.assetWriterPixelBufferInput.pixelBufferPool else {
                    //When the pixelBufferPool returns nil, check the following:
                    //https://stackoverflow.com/a/20110179/1275014
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
                
                let bufferSize = GLSize(self.size)
                var cachedTextureRef:CVOpenGLESTexture? = nil
                let _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, self.movieProcessingContext.coreVideoTextureCache, pixelBuffer, nil, GLenum(GL_TEXTURE_2D), GL_RGBA, bufferSize.width, bufferSize.height, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), 0, &cachedTextureRef)
                let cachedTexture = CVOpenGLESTextureGetName(cachedTextureRef!)
                
                self.renderFramebuffer = try Framebuffer(context:self.movieProcessingContext, orientation:.portrait, size:bufferSize, textureOnly:false, overriddenTexture:cachedTexture)
                
                completionCallback?(true)
            } catch {
                print("Unable to start recording: \(error)")
                
                self.assetWriter.cancelWriting()
                self.isRecording = false
                
                completionCallback?(false)
            }
        }
        
    }
    
    public func finishRecording(_ completionCallback:(() -> Void)? = nil) {
        movieProcessingContext.runOperationAsynchronously{
            guard self.isRecording else { return }
            guard !self.isFinishing else { return }
            
            self.finishRecordingCompletionCallback = completionCallback
            
            if (self.assetWriter.status != .writing) {
                completionCallback?()
                return
            }

            self.finishAudioWriting()
            
            // Check if there was audio
            if(self.previousAudioTime != nil) {
                // Video will finish once a there is a frame time that is later than the last recorded audio buffer time
                self.isFinishing = true
                
                // Call finishVideoWriting again just incase we don't recieve any additional buffers
                self.movieProcessingContext.serialDispatchQueue.asyncAfter(deadline: .now() + 0.1) {
                    self.finishVideoWriting()
                }
            }
            else {
                // We can finish immediately since there is no audio
                self.finishVideoWriting()
            }
        }
    }
    
    private func finishVideoWriting() {
        guard self.isRecording else { return }
        
        self.isFinishing = false
        self.isRecording = false
        
        if ((self.assetWriter.status == .writing) && (!self.videoEncodingIsFinished)) {
            self.videoEncodingIsFinished = true
            self.assetWriterVideoInput.markAsFinished()
        }
        
        self.assetWriter.finishWriting{
            self.finishRecordingCompletionCallback?()
        }
    }
    
    private func finishAudioWriting() {
        if ((self.assetWriter.status == .writing) && (!self.audioEncodingIsFinished)) {
            self.audioEncodingIsFinished = true
            self.assetWriterAudioInput?.markAsFinished()
        }
    }
    
    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        glFinish();
        
        movieProcessingContext.runOperationAsynchronously {
            guard self.renderFramebuffer != nil,
                self.isRecording,
                self.assetWriter.status == .writing,
                !self.videoEncodingIsFinished else { return }
            
            // Ignore still images and other non-video updates (do I still need this?)
            guard let frameTime = framebuffer.timingStyle.timestamp?.asCMTime else {
                return
                
            }
            
            // Check if we are finishing and if this frame is later than the last recorded audio buffer
            // Note: isFinishing is only set when there is an audio buffer, otherwise the video is finished immediately
            if self.isFinishing,
                let previousAudioTime = self.previousAudioTime,
                CMTimeCompare(previousAudioTime, frameTime) == -1 {
                // Finish recording
                self.finishVideoWriting()
                return
            }
            
            // If two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
            guard (frameTime != self.previousFrameTime) else {
                return
            }
            
            if (self.startTime == nil) {
                self.assetWriter.startSession(atSourceTime: frameTime)
                self.startTime = frameTime
                self.firstFrameTime = frameTime
            }
            
            self.previousFrameTime = frameTime

            guard (self.assetWriterVideoInput.isReadyForMoreMediaData || (!self.encodingLiveVideo)) else {
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
            
            if(synchronizedEncodingDebug) { print("Process frame output") }
            
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
        // TODO: Add ability to set custom output settings
        assetWriterAudioInput = AVAssetWriterInput(mediaType:AVMediaTypeAudio, outputSettings:nil)
        assetWriter.add(assetWriterAudioInput!)
        assetWriterAudioInput?.expectsMediaDataInRealTime = encodingLiveVideo
    }
    
    public func processAudioBuffer(_ sampleBuffer:CMSampleBuffer) {
        guard let assetWriterAudioInput = assetWriterAudioInput else { return }
        
        let work = {
            defer {
                if(self.shouldInvalidateAudioSampleWhenDone) {
                    CMSampleBufferInvalidate(sampleBuffer)
                }
            }
            
            guard self.isRecording,
                self.assetWriter.status == .writing,
                !self.audioEncodingIsFinished else { return }
            
            let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            
            if let firstFrameTime = self.firstFrameTime {
                // Check if the time of this audio sample is before the time of the first frame
                // If so then ignore it
                if (CMTimeCompare(currentSampleTime, firstFrameTime) == -1) {
                    return
                }
            }
            else {
                // We have not recorded any video yet, so we do not know if this audio sample
                // falls before or after the time of the first frame which has not yet come in.
                // There may be a better solution for this case
                return
            }
            
            self.previousAudioTime = currentSampleTime
            
            guard (assetWriterAudioInput.isReadyForMoreMediaData || (!self.encodingLiveVideo)) else {
                return
            }
            
            while(!assetWriterAudioInput.isReadyForMoreMediaData && !self.encodingLiveVideo && !self.audioEncodingIsFinished) {
                if(synchronizedEncodingDebug) { print("Audio waiting...") }
                usleep(100000)
            }
            
            if(synchronizedEncodingDebug) { print("Process audio sample output") }
            
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
