#!/usr/bin/env python3
"""Palette-quantize a PNG to 256 colors using only the Python stdlib +
system ImageIO (via ctypes). Preserves per-pixel alpha via a tRNS chunk."""
import sys, os, zlib, struct, ctypes, ctypes.util
from ctypes import c_void_p, c_size_t, c_uint32, c_int, byref

cf=ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
cg=ctypes.CDLL(ctypes.util.find_library("CoreGraphics"))
io=ctypes.CDLL(ctypes.util.find_library("ImageIO"))
cf.CFStringCreateWithCString.restype=c_void_p; cf.CFStringCreateWithCString.argtypes=[c_void_p,ctypes.c_char_p,c_uint32]
cf.CFURLCreateWithFileSystemPath.restype=c_void_p; cf.CFURLCreateWithFileSystemPath.argtypes=[c_void_p,c_void_p,c_int,c_int]
cf.CFDictionaryCreateMutable.restype=c_void_p; cf.CFDictionaryCreateMutable.argtypes=[c_void_p,c_int,c_void_p,c_void_p]
cf.CFDictionarySetValue.argtypes=[c_void_p,c_void_p,c_void_p]
cf.CFNumberCreate.restype=c_void_p; cf.CFNumberCreate.argtypes=[c_void_p,c_int,c_void_p]
io.CGImageSourceCreateWithURL.restype=c_void_p; io.CGImageSourceCreateWithURL.argtypes=[c_void_p,c_void_p]
io.CGImageSourceCreateThumbnailAtIndex.restype=c_void_p; io.CGImageSourceCreateThumbnailAtIndex.argtypes=[c_void_p,c_size_t,c_void_p]
cg.CGImageGetWidth.restype=c_size_t; cg.CGImageGetWidth.argtypes=[c_void_p]
cg.CGImageGetHeight.restype=c_size_t; cg.CGImageGetHeight.argtypes=[c_void_p]
cg.CGColorSpaceCreateDeviceRGB.restype=c_void_p
cg.CGBitmapContextCreate.restype=c_void_p
cg.CGBitmapContextCreate.argtypes=[c_void_p,c_size_t,c_size_t,c_size_t,c_size_t,c_void_p,c_uint32]
class CGRect(ctypes.Structure): _fields_=[("x",ctypes.c_double),("y",ctypes.c_double),("w",ctypes.c_double),("h",ctypes.c_double)]
cg.CGContextDrawImage.argtypes=[c_void_p,CGRect,c_void_p]
def S(s): return cf.CFStringCreateWithCString(None,s.encode(),0x08000100)
def URL(p): return cf.CFURLCreateWithFileSystemPath(None,S(p),0,False)

def decode(path, maxpx):
    src=io.CGImageSourceCreateWithURL(URL(path),None)
    if not src: return None
    o=cf.CFDictionaryCreateMutable(None,0,c_void_p.in_dll(cf,"kCFTypeDictionaryKeyCallBacks"),c_void_p.in_dll(cf,"kCFTypeDictionaryValueCallBacks"))
    cf.CFDictionarySetValue(o,S("kCGImageSourceCreateThumbnailFromImageAlways"),c_void_p.in_dll(cf,"kCFBooleanTrue"))
    cf.CFDictionarySetValue(o,S("kCGImageSourceThumbnailMaxPixelSize"),cf.CFNumberCreate(None,9,byref(ctypes.c_int(maxpx))))
    img=io.CGImageSourceCreateThumbnailAtIndex(src,0,o)
    if not img: return None
    w,h=cg.CGImageGetWidth(img),cg.CGImageGetHeight(img)
    buf=(ctypes.c_ubyte*(w*h*4))()
    ctx=cg.CGBitmapContextCreate(buf,w,h,8,w*4,cg.CGColorSpaceCreateDeviceRGB(),1|(4<<12))
    if not ctx: return None
    cg.CGContextDrawImage(ctx,CGRect(0,0,w,h),img)
    # kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big gives RGBA
    # directly, so no byte reordering is needed.
    return w,h,bytes(buf)

def quantize(px, ncolors=256):
    """Median cut over unique RGBA tuples."""
    boxes=[list(px)]
    while len(boxes)<ncolors:
        # pick box with largest spread
        best=-1; bi=-1; bc=0
        for i,b in enumerate(boxes):
            if len(b)<2: continue
            for c in range(4):
                vals=[p[c] for p in b]; spread=max(vals)-min(vals)
                if spread>best: best=spread; bi=i; bc=c
        if bi<0: break
        b=boxes.pop(bi); b.sort(key=lambda p:p[bc]); m=len(b)//2
        boxes.append(b[:m]); boxes.append(b[m:])
    pal=[]
    for b in boxes:
        n=len(b)
        pal.append(tuple(sum(p[c] for p in b)//n for c in range(4)))
    return pal

def main():
    src,dst,maxpx=sys.argv[1],sys.argv[2],int(sys.argv[3])
    r=decode(src,maxpx)
    if not r: sys.exit(1)
    w,h,data=r
    # unique colors
    uniq={}
    for i in range(0,len(data),4):
        t=data[i:i+4]
        uniq[t]=uniq.get(t,0)+1
    if len(uniq)<=256:
        pal=[tuple(k) for k in uniq]
    else:
        # Median cut over every distinct color is the slowest part on photos and
        # gains nothing: a capped sample of the most frequent colors yields a
        # visually identical palette in a fraction of the time.
        keys=sorted(uniq, key=uniq.get, reverse=True)[:20000]
        pal=quantize([tuple(k) for k in keys],256)
    # Map each pixel to the nearest palette entry. A 4-bit-per-channel cache
    # key collapses ~16M possible colors to 65k buckets, which turns the
    # per-pixel nearest search into a dictionary hit for almost every pixel.
    pal_t=[tuple(p) for p in pal]
    cache={}
    def nearest(t):
        best=0; bd=1<<30
        for i,p in enumerate(pal_t):
            dr=p[0]-t[0]; dg=p[1]-t[1]; db=p[2]-t[2]; da=p[3]-t[3]
            d=dr*dr+dg*dg+db*db+da*da*3
            if d<bd: bd=d; best=i
        return best
    rows=[]
    for y in range(h):
        base=y*w*4
        row=bytearray(w+1)          # leading filter byte stays 0
        for x in range(w):
            o=base+x*4
            # Quantize the cache key to 5 bits per channel. Visually
            # indistinguishable after palette mapping, but it bounds the cache
            # so photographic images stop missing on every pixel.
            k=((data[o]>>3)<<15)|((data[o+1]>>3)<<10)|((data[o+2]>>3)<<5)|(data[o+3]>>3)
            i=cache.get(k)
            if i is None:
                i=nearest((data[o],data[o+1],data[o+2],data[o+3])); cache[k]=i
            row[x+1]=i
        rows.append(bytes(row))
    raw=b"".join(rows)
    def chunk(tag,payload):
        c=struct.pack(">I",len(payload))+tag+payload
        return c+struct.pack(">I",zlib.crc32(tag+payload)&0xffffffff)
    out=b"\x89PNG\r\n\x1a\n"
    out+=chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,3,0,0,0))
    out+=chunk(b"PLTE",b"".join(bytes(p[:3]) for p in pal))
    if any(p[3]<255 for p in pal):
        out+=chunk(b"tRNS",bytes(p[3] for p in pal))
    out+=chunk(b"IDAT",zlib.compress(raw,9))
    out+=chunk(b"IEND",b"")
    open(dst,"wb").write(out)

main()
