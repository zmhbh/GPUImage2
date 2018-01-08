import UIKit

public protocol RenderViewDelegate: class {
    func didDisplayFramebuffer(renderView: RenderView, framebuffer: Framebuffer)
}

// TODO: Add support for transparency
// TODO: Deal with view resizing
public class RenderView:UIView, ImageConsumer {
    public weak var delegate:RenderViewDelegate?
    
    public var backgroundRenderColor = Color.black
    public var fillMode = FillMode.preserveAspectRatio
    public var orientation:ImageOrientation = .portrait
    public var sizeInPixels:Size { get { return Size(width:Float(frame.size.width * contentScaleFactor), height:Float(frame.size.height * contentScaleFactor))}}
    
    public let sources = SourceContainer()
    public let maximumInputs:UInt = 1
    var displayFramebuffer:GLuint?
    var displayRenderbuffer:GLuint?
    var backingSize = GLSize(width:0, height:0)
    
    private lazy var displayShader:ShaderProgram = {
        return sharedImageProcessingContext.passthroughShader
    }()
    
    private var internalLayer: CAEAGLLayer!
    
    // TODO: Need to set viewport to appropriate size, resize viewport on view reshape
    
    required public init?(coder:NSCoder) {
        super.init(coder:coder)
        self.commonInit()
    }
    
    public override init(frame:CGRect) {
        super.init(frame:frame)
        self.commonInit()
    }
    
    override public class var layerClass:Swift.AnyClass {
        get {
            return CAEAGLLayer.self
        }
    }
    
    override public var bounds: CGRect {
        didSet {
            // Check if the size changed
            if(oldValue.size != self.bounds.size) {
                // Destroy the displayFramebuffer so we render at the correct size
                self.destroyDisplayFramebuffer()
            }
        }
    }
    
    func commonInit() {
        self.contentScaleFactor = UIScreen.main.scale
        
        let eaglLayer = self.layer as! CAEAGLLayer
        eaglLayer.isOpaque = true
        eaglLayer.drawableProperties = [kEAGLDrawablePropertyRetainedBacking: NSNumber(value:false), kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8]
        
        self.internalLayer = eaglLayer
    }
    
    deinit {
        destroyDisplayFramebuffer()
    }
    
    func createDisplayFramebuffer() -> Bool {
        var newDisplayFramebuffer:GLuint = 0
        glGenFramebuffers(1, &newDisplayFramebuffer)
        displayFramebuffer = newDisplayFramebuffer
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), displayFramebuffer!)
        
        var newDisplayRenderbuffer:GLuint = 0
        glGenRenderbuffers(1, &newDisplayRenderbuffer)
        displayRenderbuffer = newDisplayRenderbuffer
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), displayRenderbuffer!)
        
        CATransaction.flush()
        sharedImageProcessingContext.context.renderbufferStorage(Int(GL_RENDERBUFFER), from:self.internalLayer)
        
        var backingWidth:GLint = 0
        var backingHeight:GLint = 0
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &backingWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &backingHeight)
        backingSize = GLSize(width:backingWidth, height:backingHeight)
        
        guard ((backingWidth > 0) && (backingHeight > 0)) else {
            print("Warning: View had a zero size")
            return false
        }
        
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), displayRenderbuffer!)
        
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        if (status != GLenum(GL_FRAMEBUFFER_COMPLETE)) {
            print("Warning: Display framebuffer creation failed with error: \(FramebufferCreationError(errorCode:status))")
            return false
        }
        
        return true
    }
    
    func destroyDisplayFramebuffer() {
        sharedImageProcessingContext.runOperationSynchronously{
            if let displayFramebuffer = self.displayFramebuffer {
                var temporaryFramebuffer = displayFramebuffer
                glDeleteFramebuffers(1, &temporaryFramebuffer)
                self.displayFramebuffer = nil
            }
            
            if let displayRenderbuffer = self.displayRenderbuffer {
                var temporaryRenderbuffer = displayRenderbuffer
                glDeleteRenderbuffers(1, &temporaryRenderbuffer)
                self.displayRenderbuffer = nil
            }
        }
    }
    
    func activateDisplayFramebuffer() {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), displayFramebuffer!)
        glViewport(0, 0, backingSize.width, backingSize.height)
    }
    
    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        if (self.displayFramebuffer == nil && !self.createDisplayFramebuffer()) {
            // Bail if we couldn't successfully create the displayFramebuffer
            return
        }
        self.activateDisplayFramebuffer()
        
        clearFramebufferWithColor(backgroundRenderColor)
        
        let scaledVertices = fillMode.transformVertices(verticallyInvertedImageVertices, fromInputSize:framebuffer.sizeForTargetOrientation(self.orientation), toFitSize:backingSize)
        renderQuadWithShader(self.displayShader, vertices:scaledVertices, inputTextures:[framebuffer.texturePropertiesForTargetOrientation(self.orientation)])
        framebuffer.unlock()
        
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), displayRenderbuffer!)
        sharedImageProcessingContext.presentBufferForDisplay()
        
        self.delegate?.didDisplayFramebuffer(renderView: self, framebuffer: framebuffer)
    }
}

