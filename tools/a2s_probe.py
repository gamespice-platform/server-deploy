#!/usr/bin/env python3
"""Asks a running server the one question every browser and listing asks: A2S_INFO over UDP. Exit 0 and print the
server's name when it answers, 1 when it does not. The boot smoke uses it as "a client can connect and query".
  a2s_probe.py PORT [HOST] [TIMEOUT_SECONDS]
"""
import socket, struct, sys

port = int(sys.argv[1]); host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
wait = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
req = b"\xff\xff\xff\xffTSource Engine Query\x00"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(wait)
try:
    s.sendto(req, (host, port)); data, _ = s.recvfrom(4096)
    if data[4:5] == b"A":                       # a challenge: answer it
        s.sendto(req + data[5:9], (host, port)); data, _ = s.recvfrom(4096)
    if data[:4] != b"\xff\xff\xff\xff" or data[4:5] != b"I":
        print("a2s_probe: not an A2S_INFO answer: %r" % data[:16]); sys.exit(1)
    name = data[6:].split(b"\x00", 1)[0].decode("utf-8", "replace")
    print("a2s_probe: answered, server name %r" % name)
except OSError as e:
    print("a2s_probe: no answer from %s:%d (%s)" % (host, port, e)); sys.exit(1)
