"""Local SOCKS5 CONNECT endpoints with a required macOS IPv4 interface."""

import argparse
import http.client
import ipaddress
import json
import os
import re
import select
import socket
import socketserver
import ssl
import struct
import threading
import time
from urllib.parse import urlencode


IP_BOUND_IF = 25  # Darwin <netinet/in.h>; socket has no fallback to the default route.
RESOLVER_IP = "1.1.1.1"
RESOLVER_NAME = "cloudflare-dns.com"
CONNECT_TIMEOUT = 6
TLS_CONTEXT = ssl.create_default_context()
HOSTNAME = re.compile(r"[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.?", re.ASCII)


def connect_ipv4(interface, address, port):
    index = socket.if_nametoindex(interface)
    stream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        stream.settimeout(CONNECT_TIMEOUT)
        stream.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, index)
        stream.connect((str(address), port))
        return stream
    except BaseException:
        stream.close()
        raise


class BoundHTTPS(http.client.HTTPSConnection):
    def __init__(self, interface):
        super().__init__(RESOLVER_NAME, timeout=CONNECT_TIMEOUT, context=TLS_CONTEXT)
        self.interface = interface

    def connect(self):
        with connect_ipv4(self.interface, RESOLVER_IP, 443) as stream:
            self.sock = TLS_CONTEXT.wrap_socket(stream, server_hostname=RESOLVER_NAME)


class Resolver:
    def __init__(self, interface):
        self.interface = interface
        self.cache = {}
        self.lock = threading.Lock()

    def lookup(self, host):
        host = host.lower()
        if len(host) > 254 or not HOSTNAME.fullmatch(host):
            raise OSError("Invalid DNS name")
        with self.lock:
            current = self.cache.get(host)
            if current and current[0] > time.monotonic():
                return current[1]

        connection = BoundHTTPS(self.interface)
        try:
            query = urlencode({"name": host, "type": "A"})
            connection.request("GET", "/dns-query?" + query, headers={"Accept": "application/dns-json"})
            with connection.getresponse() as response:
                if response.status != 200:
                    raise OSError("DNS resolver returned an error")
                body = json.loads(response.read(65_536))
        finally:
            connection.close()
        if body.get("Status") != 0:
            raise OSError("DNS name could not be resolved")

        records = [record for record in body.get("Answer", []) if record["type"] == 1]
        if not records:
            raise OSError("DNS name has no IPv4 address")
        addresses = [ipaddress.IPv4Address(record["data"]) for record in records]
        ttl = max(0, min(300, *(int(record["TTL"]) for record in body["Answer"])))
        with self.lock:
            if len(self.cache) >= 512:
                self.cache.pop(next(iter(self.cache)))
            self.cache[host] = (time.monotonic() + ttl, addresses)
        return addresses


def read_exact(stream, count):
    data = bytearray()
    while len(data) < count:
        chunk = stream.recv(count - len(data))
        if not chunk:
            raise EOFError
        data.extend(chunk)
    return bytes(data)


def destination(stream, resolver):
    version, command, reserved, address_type = read_exact(stream, 4)
    if (version, command, reserved) != (5, 1, 0):
        raise OSError("Only SOCKS5 CONNECT is supported")
    if address_type == 1:
        addresses = [ipaddress.IPv4Address(read_exact(stream, 4))]
    elif address_type == 3:
        length = read_exact(stream, 1)[0]
        host = read_exact(stream, length).decode("ascii")
        try:
            addresses = [ipaddress.IPv4Address(host)]
        except ipaddress.AddressValueError:
            addresses = resolver.lookup(host)
    else:
        raise OSError("Only IPv4 destinations are supported")
    port = struct.unpack("!H", read_exact(stream, 2))[0]
    if not port:
        raise OSError("Invalid destination port")
    for address in addresses:
        # In particular, never relay requests to the proxy itself or another local listener.
        if address.is_loopback or address.is_unspecified or address.is_multicast:
            continue
        try:
            return connect_ipv4(resolver.interface, address, port)
        except OSError:
            continue
    raise OSError("Destination unreachable on the selected interface")


def relay(client, target):
    peers = {client: target, target: client}
    while peers:
        readable, _, _ = select.select(list(peers), [], [], 600)
        if not readable:
            return
        for source in readable:
            sink = peers[source]
            chunk = source.recv(65_536)
            if chunk:
                sink.sendall(chunk)
            else:
                del peers[source]
                sink.shutdown(socket.SHUT_WR)


class SocksHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(10)
        try:
            version, count = read_exact(client, 2)
            methods = read_exact(client, count)
            if version != 5 or 0 not in methods:
                client.sendall(b"\x05\xff")
                return
            client.sendall(b"\x05\x00")
            try:
                target = destination(client, self.server.resolver)
            except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException):
                client.sendall(b"\x05\x04\x00\x01" + bytes(6))
                return
            with target:
                address, port = target.getsockname()
                client.sendall(b"\x05\x00\x00\x01" + socket.inet_aton(address) + struct.pack("!H", port))
                client.settimeout(30)
                target.settimeout(30)
                relay(client, target)
        except (OSError, EOFError):
            pass


class SocksServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, interface, port):
        self.resolver = Resolver(interface)
        self.slots = threading.BoundedSemaphore(96)
        super().__init__(("127.0.0.1", port), SocksHandler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wifi_interface")
    parser.add_argument("wifi_port", type=int)
    parser.add_argument("usb_interface")
    parser.add_argument("usb_port", type=int)
    parser.add_argument("--parent", type=int)
    args = parser.parse_args()
    with SocksServer(args.wifi_interface, args.wifi_port) as wifi:
        with SocksServer(args.usb_interface, args.usb_port) as usb:
            if args.parent is not None:
                def watch_parent():
                    while os.getppid() == args.parent:
                        time.sleep(1)
                    os._exit(0)

                threading.Thread(target=watch_parent, daemon=True).start()
            print("ready", flush=True)
            threading.Thread(target=wifi.serve_forever, daemon=True).start()
            usb.serve_forever()


if __name__ == "__main__":
    main()
