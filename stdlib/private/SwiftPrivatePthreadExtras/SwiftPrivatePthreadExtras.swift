//===--- SwiftPrivatePthreadExtras.swift ----------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// This file contains wrappers for pthread APIs that are less painful to use
// than the C APIs.
//
//===----------------------------------------------------------------------===//

#if os(OSX) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#elseif os(Linux) || os(FreeBSD) || os(PS4) || os(Android)
import Glibc
#endif

/// An abstract base class to encapsulate the context necessary to invoke
/// a block from pthread_create.
internal class PthreadBlockContext {
  /// Execute the block, and return an `UnsafeMutablePointer` to memory
  /// allocated with `UnsafeMutablePointer.alloc` containing the result of the
  /// block.
  func run() -> UnsafeMutablePointer<Void> { fatalError("abstract") }
}

internal class PthreadBlockContextImpl<Argument, Result>: PthreadBlockContext {
  let block: (Argument) -> Result
  let arg: Argument

  init(block: (Argument) -> Result, arg: Argument) {
    self.block = block
    self.arg = arg
    super.init()
  }

  override func run() -> UnsafeMutablePointer<Void> {
    let result = UnsafeMutablePointer<Result>(allocatingCapacity: 1)
    result.initialize(with: block(arg))
    return UnsafeMutablePointer(result)
  }
}

/// Entry point for `pthread_create` that invokes a block context.
internal func invokeBlockContext(
  _ contextAsVoidPointer: UnsafeMutablePointer<Void>?
) -> UnsafeMutablePointer<Void>! {
  // The context is passed in +1; we're responsible for releasing it.
  let context = Unmanaged<PthreadBlockContext>
    .fromOpaque(contextAsVoidPointer!)
    .takeRetainedValue()

  return context.run()
}

/// Block-based wrapper for `pthread_create`.
public func _stdlib_pthread_create_block<Argument, Result>(
  _ attr: UnsafePointer<pthread_attr_t>?,
  _ start_routine: (Argument) -> Result,
  _ arg: Argument
) -> (CInt, pthread_t?) {
  let context = PthreadBlockContextImpl(block: start_routine, arg: arg)
  // We hand ownership off to `invokeBlockContext` through its void context
  // argument.
  let contextAsVoidPointer = Unmanaged.passRetained(context).toOpaque()

  var threadID = _make_pthread_t()
  let result = pthread_create(&threadID, attr,
    { invokeBlockContext($0) }, contextAsVoidPointer)
  if result == 0 {
    return (result, threadID)
  } else {
    return (result, nil)
  }
}

#if os(Linux) || os(Android)
internal func _make_pthread_t() -> pthread_t {
  return pthread_t()
}
#else
internal func _make_pthread_t() -> pthread_t? {
  return nil
}
#endif

/// Block-based wrapper for `pthread_join`.
public func _stdlib_pthread_join<Result>(
  _ thread: pthread_t,
  _ resultType: Result.Type
) -> (CInt, Result?) {
  var threadResultPtr: UnsafeMutablePointer<Void>? = nil
  let result = pthread_join(thread, &threadResultPtr)
  if result == 0 {
    let threadResult = UnsafeMutablePointer<Result>(threadResultPtr!).pointee
    threadResultPtr!.deinitialize()
    threadResultPtr!.deallocateCapacity(1)
    return (result, threadResult)
  } else {
    return (result, nil)
  }
}

public class _stdlib_Barrier {
  var _pthreadBarrier: _stdlib_pthread_barrier_t

  var _pthreadBarrierPtr: UnsafeMutablePointer<_stdlib_pthread_barrier_t> {
    return UnsafeMutablePointer(_getUnsafePointerToStoredProperties(self))
  }

  public init(threadCount: Int) {
    self._pthreadBarrier = _stdlib_pthread_barrier_t()
    let ret = _stdlib_pthread_barrier_init(
      _pthreadBarrierPtr, nil, CUnsignedInt(threadCount))
    if ret != 0 {
      fatalError("_stdlib_pthread_barrier_init() failed")
    }
  }

  deinit {
    let ret = _stdlib_pthread_barrier_destroy(_pthreadBarrierPtr)
    if ret != 0 {
      fatalError("_stdlib_pthread_barrier_destroy() failed")
    }
  }

  public func wait() {
    let ret = _stdlib_pthread_barrier_wait(_pthreadBarrierPtr)
    if !(ret == 0 || ret == _stdlib_PTHREAD_BARRIER_SERIAL_THREAD) {
      fatalError("_stdlib_pthread_barrier_wait() failed")
    }
  }
}
