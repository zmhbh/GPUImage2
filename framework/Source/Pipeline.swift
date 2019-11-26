// MARK: -
// MARK: Basic types
import Foundation

public protocol ImageSource {
    var targets:TargetContainer { get }
    func transmitPreviousImage(to target:ImageConsumer, atIndex:UInt)
}

public protocol ImageConsumer:AnyObject {
    var maximumInputs:UInt { get }
    var sources:SourceContainer { get }
    
    func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt)
}

public protocol ImageProcessingOperation: ImageConsumer, ImageSource {
}

infix operator --> : AdditionPrecedence
//precedencegroup ProcessingOperationPrecedence {
//    associativity: left
////    higherThan: Multiplicative
//}
@discardableResult public func --><T:ImageConsumer>(source:ImageSource, destination:T) -> T {
    source.addTarget(destination)
    return destination
}

// MARK: -
// MARK: Extensions and supporting types

public extension ImageSource {
    func addTarget(_ target:ImageConsumer, atTargetIndex:UInt? = nil) {
        sharedImageProcessingContext.runOperationAsynchronously {
            if let targetIndex = atTargetIndex {
                target.setSource(self, atIndex:targetIndex)
                self.targets.append(target, indexAtTarget:targetIndex)
                self.transmitPreviousImage(to:target, atIndex:targetIndex)
            } else if let indexAtTarget = target.addSource(self) {
                self.targets.append(target, indexAtTarget:indexAtTarget)
                self.transmitPreviousImage(to:target, atIndex:indexAtTarget)
            } else {
                debugPrint("Warning: tried to add target beyond target's input capacity")
            }
        }
    }

    func removeAllTargets() {
        sharedImageProcessingContext.runOperationAsynchronously {
            for (target, index) in self.targets {
                target.removeSourceAtIndex(index)
            }
            self.targets.removeAll()
        }
    }
    
    func remove(_ target:ImageConsumer) {
        sharedImageProcessingContext.runOperationAsynchronously {
            for (testTarget, index) in self.targets {
                if(target === testTarget) {
                    target.removeSourceAtIndex(index)
                    self.targets.remove(target)
                }
            }
        }
    }
    
    func updateTargetsWithFramebuffer(_ framebuffer:Framebuffer) {
        if (DispatchQueue.getSpecific(key:sharedImageProcessingContext.dispatchQueueKey) != sharedImageProcessingContext.dispatchQueueKeyValue) {
            print("WARNING: updateTargetsWithFramebuffer() must be called from the sharedImageProcessingContext")
        }
        
        var foundTargets = [(ImageConsumer, UInt)]()
        for target in targets {
            foundTargets.append(target)
        }
        
        if foundTargets.count == 0 { // Deal with the case where no targets are attached by immediately returning framebuffer to cache
            framebuffer.lock()
            framebuffer.unlock()
        } else {
            // Lock first for each output, to guarantee proper ordering on multi-output operations
            for _ in foundTargets {
                framebuffer.lock()
            }
        }
        for (target, index) in foundTargets {
            target.newFramebufferAvailable(framebuffer, fromSourceIndex:index)
        }
    }
}

public extension ImageConsumer {
    fileprivate func addSource(_ source:ImageSource) -> UInt? {
        return sources.append(source, maximumInputs:maximumInputs)
    }
    
    fileprivate func setSource(_ source:ImageSource, atIndex:UInt) {
        _ = sources.insert(source, atIndex:atIndex, maximumInputs:maximumInputs)
    }

    fileprivate func removeSourceAtIndex(_ index:UInt) {
        sources.removeAtIndex(index)
    }
    
    func removeAllSources() {
        sharedImageProcessingContext.runOperationAsynchronously {
            for (index, source) in self.sources.sources {
                self.removeSourceAtIndex(index)
                source.targets.remove(self)
            }
        }
    }
}

class WeakImageConsumer {
    weak var value:ImageConsumer?
    let indexAtTarget:UInt
    init (value:ImageConsumer, indexAtTarget:UInt) {
        self.indexAtTarget = indexAtTarget
        self.value = value
    }
}

public class TargetContainer:Sequence {
    private var targets = [WeakImageConsumer]()

    public init() {
    }
    
    internal func append(_ target:ImageConsumer, indexAtTarget:UInt) {
        // TODO: Don't allow the addition of a target more than once
        self.targets.append(WeakImageConsumer(value:target, indexAtTarget:indexAtTarget))
    }
    
    public func makeIterator() -> AnyIterator<(ImageConsumer, UInt)> {
        // Get the list of values that have not deallocated
        let targets: [(ImageConsumer, UInt)] = self.targets.compactMap { weakImageConsumer in
            if let imageConsumer = weakImageConsumer.value {
                return (imageConsumer, weakImageConsumer.indexAtTarget)
            }
            else {
                return nil
            }
        }
        
        // Remove the deallocated values
        self.targets = self.targets.filter { $0.value != nil }
        
        var index = 0
        
        return AnyIterator { () -> (ImageConsumer, UInt)? in
            if (index >= targets.count) {
                return nil
            }
            
            index += 1
            return targets[index - 1]
        }
    }
    
    fileprivate func removeAll() {
        self.targets.removeAll()
    }
    
    fileprivate func remove(_ target:ImageConsumer) {
        self.targets = self.targets.filter { $0.value !== target }
    }
}

public class SourceContainer {
    fileprivate var sources:[UInt:ImageSource] = [:]
    
    public init() {
    }
    
    fileprivate func append(_ source:ImageSource, maximumInputs:UInt) -> UInt? {
        var currentIndex:UInt = 0
        while currentIndex < maximumInputs {
            if (sources[currentIndex] == nil) {
                sources[currentIndex] = source
                return currentIndex
            }
            currentIndex += 1
        }
        
        return nil
    }
    
    fileprivate func insert(_ source:ImageSource, atIndex:UInt, maximumInputs:UInt) -> UInt {
        guard (atIndex < maximumInputs) else { fatalError("ERROR: Attempted to set a source beyond the maximum number of inputs on this operation") }
        sources[atIndex] = source
        return atIndex
    }
    
    fileprivate func removeAtIndex(_ index:UInt) {
        sources[index] = nil
    }
}

public class ImageRelay: ImageProcessingOperation {
    public var newImageCallback:((Framebuffer) -> ())?
    
    public let sources = SourceContainer()
    public let targets = TargetContainer()
    public let maximumInputs:UInt = 1
    public var preventRelay:Bool = false
    
    public init() {
    }
    
    public func transmitPreviousImage(to target:ImageConsumer, atIndex:UInt) {
        if let source = self.sources.sources[0] {
            source.transmitPreviousImage(to:self, atIndex:0)
        }
    }

    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        if let newImageCallback = newImageCallback {
            newImageCallback(framebuffer)
        }
        if (!preventRelay) {
            relayFramebufferOnward(framebuffer)
        }
    }
    
    public func relayFramebufferOnward(_ framebuffer:Framebuffer) {
        // Need to override to guarantee a removal of the previously applied lock
        for _ in targets {
            framebuffer.lock()
        }
        framebuffer.unlock()
        for (target, index) in targets {
            target.newFramebufferAvailable(framebuffer, fromSourceIndex:index)
        }
    }
}
