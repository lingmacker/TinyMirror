#!/usr/bin/env python3
"""Check the built C bridge's actual /info advertisement; no iPhone required."""
import ctypes as c
import os
import plistlib
import re
import socket
import subprocess

core = c.CDLL(os.path.abspath("native/build/libMirrorCore.dylib"))
Video = c.CFUNCTYPE(None, c.c_void_p, c.c_void_p, c.c_int, c.c_uint64, c.c_uint64, c.c_int)
Audio = c.CFUNCTYPE(None, c.c_void_p, c.c_void_p, c.c_int, c.c_ubyte, c.c_uint64)
Event = c.CFUNCTYPE(None, c.c_void_p, c.c_int, c.c_int, c.c_char_p)
Log = c.CFUNCTYPE(None, c.c_void_p, c.c_int, c.c_char_p)


class Callbacks(c.Structure):
    _fields_ = [("ctx", c.c_void_p), ("video", Video), ("audio", Audio), ("event", Event), ("log", Log)]


callbacks = Callbacks(None, Video(lambda *args: None), Audio(lambda *args: None),
                      Event(lambda *args: None), Log(lambda *args: None))
core.mb_start_video.argtypes = [c.c_char_p, c.POINTER(Callbacks), c.c_int, c.c_int, c.c_int, c.c_int]
core.mb_start_video.restype = c.c_int
core.mb_start.argtypes = [c.c_char_p, c.POINTER(Callbacks), c.c_int]
core.mb_start.restype = c.c_int
core.mb_stop.argtypes = []

for width, height, hevc in [(0, 1080, 0), (1920, -1, 0), (10000, 1080, 0), (1920, 1080, 2)]:
    assert core.mb_start_video(b"MirrorDeck Configuration Check", c.byref(callbacks), 0, width, height, hevc) == -2

for height in [720, 1080, 1440, 2160, None]:
    width = (height or 1080) * 16 // 9
    hevc = int(height is not None and height > 1080)
    try:
        if height is None:
            result = core.mb_start(b"MirrorDeck Legacy API Check", c.byref(callbacks), 0)
        else:
            result = core.mb_start_video(b"MirrorDeck Resolution Check", c.byref(callbacks), 0, width, height, hevc)
        assert result == 0, f"Receiver failed to start: {result}"
        listeners = subprocess.check_output(
            ["lsof", "-a", "-p", str(os.getpid()), "-iTCP", "-sTCP:LISTEN", "-Fn"], text=True)
        ports = set(re.findall(r"^n.*:(\d+)$", listeners, re.M))
        assert len(ports) == 1, f"Unexpected test process listeners: {ports}"
        with socket.create_connection(("127.0.0.1", int(ports.pop())), timeout=3) as connection:
            # Match AirPlay's header spelling; this core treats CSeq case-sensitively.
            connection.sendall(b"GET /info RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n")
            packet = b""
            while b"\r\n\r\n" not in packet:
                chunk = connection.recv(4096)
                assert chunk and len(packet) < 65536
                packet += chunk
            header, body = packet.split(b"\r\n\r\n", 1)
            assert header.startswith(b"RTSP/1.0 200")
            length = int(re.search(rb"Content-Length: (\d+)", header).group(1))
            assert 0 < length < 1000000
            while len(body) < length:
                chunk = connection.recv(4096)
                assert chunk
                body += chunk
            info = plistlib.loads(body[:length])
        display = info["displays"][0]
        assert (display["widthPixels"], display["heightPixels"]) == (width, height or 1080)
        assert bool(info["features"] & (1 << 42)) == bool(hevc)
        assert display["maxFPS"] == 30
        print(f"Receiver advertisement passed: {width}×{height or 1080}, HEVC={bool(hevc)}")
    finally:
        core.mb_stop()
