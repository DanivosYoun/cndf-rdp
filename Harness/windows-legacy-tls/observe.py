"""Print RDP TCP attempts, selected security and TLS ServerHello metadata."""
import argparse
import socket
from datetime import datetime, timedelta, timezone

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("interface")
parser.add_argument("server", type=socket.inet_aton)
args = parser.parse_args()
kst = timezone(timedelta(hours=9), "KST")
streams = {}
seen = set()


def log(port, event):
    stamp = datetime.now(kst).isoformat(timespec="milliseconds")
    print(f"{stamp} KST client_port={port} {event}", flush=True)


with socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, socket.htons(3)) as capture:
    capture.bind((args.interface, 3))
    print("READY", flush=True)
    while True:
        ip = capture.recv(65535)
        if len(ip) < 40 or ip[0] >> 4 != 4 or ip[9] != 6:
            continue
        tcp = ip[(ip[0] & 15) * 4:]
        src = int.from_bytes(tcp[:2], "big")
        dst = int.from_bytes(tcp[2:4], "big")
        seq = int.from_bytes(tcp[4:8], "big")
        if ip[16:20] == args.server and dst == 3389 and tcp[13] & 0x12 == 0x02:
            if (src, seq) not in seen:
                seen.add((src, seq))
                streams[src] = b""
                log(src, "TCP SYN")
            continue
        if ip[12:16] != args.server or src != 3389 or dst not in streams:
            continue
        data = tcp[(tcp[12] >> 4) * 4:]
        if not data or (dst, seq) in seen:
            continue
        seen.add((dst, seq))
        data = streams[dst] + data
        if data[:2] == b"\x03\x00" and len(data) >= 4:
            length = int.from_bytes(data[2:4], "big")
            if len(data) >= length:
                response = data[11:length]
                if len(response) >= 8 and response[0] == 2:
                    log(dst, "RDP selectedProtocol=" + str(int.from_bytes(response[4:8], "little")))
                data = data[length:]
        if data[:1] == b"\x16" and len(data) >= 11 and data[5] == 2:
            log(dst, "TLS ServerHello version=0x" + data[9:11].hex())
            del streams[dst]
        elif data[:1] == b"\x15" and len(data) >= 7:
            log(dst, "TLS alert description=" + str(data[6]))
            del streams[dst]
        elif len(data) > 4096:
            del streams[dst]
        else:
            streams[dst] = data
