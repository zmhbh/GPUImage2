#if canImport(OpenGL)
import OpenGL.GL3
#endif

#if canImport(OpenGLES)
import OpenGLES
#endif

#if canImport(COpenGLES)
import COpenGLES.gles2
#endif

#if canImport(COpenGL)
import COpenGL
#endif

import AVFoundation

public class FlutterTextureOutput: ImageConsumer {
    public var dataAvailableCallback:(() -> ())?
    
    public let sources = SourceContainer()
    public let maximumInputs:UInt = 1
    
    public var pixelBuffer:CVPixelBuffer? = nil
    let resolution: CGSize
    
    public init(resolution: CGSize) {
        self.resolution = resolution
    }
    
    // TODO: Replace with texture caches
    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        //Int(framebuffer.size.width)
        if pixelBuffer == nil {
            CVPixelBufferCreate(kCFAllocatorDefault, Int(resolution.width), Int(resolution.height), kCVPixelFormatType_32BGRA, nil, &(self.pixelBuffer))
        }
        
        renderIntoPixelBuffer(pixelBuffer!, framebuffer: framebuffer)
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        dataAvailableCallback?()
    }
    
    
    func renderIntoPixelBuffer(_ pixelBuffer:CVPixelBuffer, framebuffer:Framebuffer) {
        let renderFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:framebuffer.orientation, size:framebuffer.size)
        renderFramebuffer.lock()
        
        renderFramebuffer.activateFramebufferForRendering()
        clearFramebufferWithColor(Color.black)
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
             renderQuadWithShader(sharedImageProcessingContext.passthroughShader, uniformSettings:ShaderUniformSettings(), vertexBufferObject:sharedImageProcessingContext.standardImageVBO, inputTextures:[framebuffer.texturePropertiesForOutputRotation(.noRotation)])
        
        glReadPixels(0, 0, renderFramebuffer.size.width, renderFramebuffer.size.height, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddress(pixelBuffer))
         renderFramebuffer.unlock()
    }
}
