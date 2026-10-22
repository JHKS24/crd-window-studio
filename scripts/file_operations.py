"""Recoverable bundle replacement using Foundation, available since macOS 10.8.

No trash executable, Swift compiler, Finder or Automation permission is needed.
"""
import ctypes
import os


# --- Recoverable bundle replacement ---

def trash(path):
    """Move an item to this volume's Trash, or leave it in place and report failure."""
    pointer = ctypes.c_void_p
    foundation = ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
    objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    core = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.objc_getClass.restype = pointer
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = pointer
    core.CFURLCreateFromFileSystemRepresentation.argtypes = [pointer, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool]
    core.CFURLCreateFromFileSystemRepresentation.restype = pointer
    core.CFRelease.argtypes = [pointer]
    core.CFRelease.restype = None

    def send(receiver, selector, result=pointer, types=(), values=()):
        """Invoke an Objective-C selector with explicit argument and result types."""
        call = ctypes.CFUNCTYPE(result, pointer, pointer, *types)(("objc_msgSend", objc))
        return call(receiver, objc.sel_registerName(selector.encode()), *values)

    pool = send(send(objc.objc_getClass(b"NSAutoreleasePool"), "alloc"), "init")
    url = None
    try:
        encoded = os.fsencode(os.path.abspath(path))
        url = core.CFURLCreateFromFileSystemRepresentation(None, encoded, len(encoded), path.is_dir())
        if not url:
            raise OSError(f"Cannot create a file URL for Trash: {path}")
        manager = send(objc.objc_getClass(b"NSFileManager"), "defaultManager")
        error = pointer()
        moved = send(manager, "trashItemAtURL:resultingItemURL:error:", ctypes.c_bool,
                     (pointer, pointer, ctypes.POINTER(pointer)), (url, None, ctypes.byref(error)))
        if not moved:
            detail = send(send(error.value, "localizedDescription"), "UTF8String", ctypes.c_char_p) if error.value else None
            raise OSError(f"Trash failed; item retained at {path}: {detail.decode() if detail else 'no error detail'}")
    finally:
        if url:
            core.CFRelease(url)
        send(pool, "drain", None)


def replace_bundle(staged, destination, previous):
    """Publish an already verified bundle before retiring the previous one.

    `previous` must be a fresh path outside any automatically deleted staging folder.
    A publish failure restores the old destination; a Trash failure retains it at
    `previous` while the new destination stays usable.
    """
    had_previous = destination.exists()
    if had_previous:
        destination.rename(previous)
    try:
        staged.rename(destination)
    except OSError:
        if had_previous:
            previous.rename(destination)
        raise
    if had_previous:
        trash(previous)
