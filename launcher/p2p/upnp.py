"""Port mapping on the host's router: UPnP-IGD first, then NAT-PMP. Only with the host's consent.

    m = PortMapper(consent=True)
    method, external_ip = m.map([3724, 8085])     # ("upnp"|"natpmp"|None, "203.0.113.5"|None)
    m.renew()                                     # every 30 minutes (leases are an hour)
    m.unmap()                                     # Stop hosting

Never maps anything but the ports it is given (the host passes 3724 and 8085, never 3306/7878).
"""
import ipaddress
import re
import socket
import struct
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET

from . import http

SSDP_ADDR = ("239.255.255.250", 1900)
SERVICES = ("urn:schemas-upnp-org:service:WANIPConnection:2", "urn:schemas-upnp-org:service:WANIPConnection:1",
            "urn:schemas-upnp-org:service:WANPPPConnection:1")
LEASE = 3600
DESCRIPTION = "Open Vanilla host"


def local_ip_for(target="10.255.255.255"):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((target, 1))   # no packet is sent
        return s.getsockname()[0]


def default_gateway(run=subprocess.run):
    """The IPv4 default gateway, or None."""
    if sys.platform.startswith("linux"):
        try:
            with open("/proc/net/route") as f:
                for line in f.read().splitlines()[1:]:
                    p = line.split()
                    if len(p) > 2 and p[1] == "00000000" and int(p[3], 16) & 2:
                        return socket.inet_ntoa(struct.pack("<I", int(p[2], 16)))
        except (OSError, ValueError):
            return None
    try:
        if sys.platform == "win32":
            r = run(["route", "print", "-4", "0.0.0.0"], capture_output=True, text=True, timeout=5,
                    creationflags=0x08000000)
            m = re.search(r"^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)", r.stdout, re.M)
        else:
            r = run(["route", "-n", "get", "default"], capture_output=True, text=True, timeout=5)
            m = re.search(r"gateway:\s*(\d+\.\d+\.\d+\.\d+)", r.stdout)
        return m.group(1) if m else None
    except (OSError, subprocess.SubprocessError):
        return None


def is_public(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return a.is_global and not (a in ipaddress.ip_network("100.64.0.0/10"))


# ---------------------------------------------------------------- UPnP IGD

def ssdp_discover(timeout=2.0, addr=SSDP_ADDR):
    """LOCATION URLs of Internet gateway devices that answered."""
    msg = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n"
           "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n").encode()
    found = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP) as s:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        s.settimeout(timeout)
        try:
            s.sendto(msg, addr)
            while True:
                data, _ = s.recvfrom(4096)
                m = re.search(rb"(?im)^location:\s*(\S+)", data)
                if m and m.group(1).decode() not in found:
                    found.append(m.group(1).decode("latin-1"))
        except OSError:
            pass
    return found


def find_service(location, fetch=None):
    """(control URL, service type) of the WAN connection service in an IGD description."""
    status, body, _ = (fetch or (lambda u: http(u, timeout=4)))(location)
    if status != 200:
        return None
    root = ET.fromstring(body)
    ns = {"d": "urn:schemas-upnp-org:device-1-0"}
    base = root.findtext("d:URLBase", default="", namespaces=ns) or location
    for svc in root.iter("{urn:schemas-upnp-org:device-1-0}service"):
        st = svc.findtext("d:serviceType", default="", namespaces=ns)
        if st in SERVICES:
            ctl = svc.findtext("d:controlURL", default="", namespaces=ns)
            return urllib.parse.urljoin(base, ctl), st
    return None


def soap_call(control, service, action, args, post=None):
    inner = "".join(f"<{k}>{v}</{k}>" for k, v in args)
    body = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            f'<u:{action} xmlns:u="{service}">{inner}</u:{action}></s:Body></s:Envelope>').encode()
    headers = {"Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": f'"{service}#{action}"'}
    status, data, _ = (post or (lambda u, d, h: http(u, "POST", headers=h, data=d, timeout=5)))(control, body, headers)
    return status, data


class UPnP:
    def __init__(self, control, service, local_ip, post=None):
        self.control, self.service, self.local_ip, self.post = control, service, local_ip, post

    def add(self, port, lease=LEASE):
        status, _ = soap_call(self.control, self.service, "AddPortMapping", [
            ("NewRemoteHost", ""), ("NewExternalPort", port), ("NewProtocol", "TCP"), ("NewInternalPort", port),
            ("NewInternalClient", self.local_ip), ("NewEnabled", 1), ("NewPortMappingDescription", DESCRIPTION),
            ("NewLeaseDuration", lease)], self.post)
        if status != 200 and lease:
            # Some IGDs only take permanent leases (error 725); fall back, unmap() cleans up.
            status, _ = soap_call(self.control, self.service, "AddPortMapping", [
                ("NewRemoteHost", ""), ("NewExternalPort", port), ("NewProtocol", "TCP"), ("NewInternalPort", port),
                ("NewInternalClient", self.local_ip), ("NewEnabled", 1), ("NewPortMappingDescription", DESCRIPTION),
                ("NewLeaseDuration", 0)], self.post)
        return status == 200

    def delete(self, port):
        status, _ = soap_call(self.control, self.service, "DeletePortMapping", [
            ("NewRemoteHost", ""), ("NewExternalPort", port), ("NewProtocol", "TCP")], self.post)
        return status == 200

    def external_ip(self):
        status, data = soap_call(self.control, self.service, "GetExternalIPAddress", [], self.post)
        if status != 200:
            return None
        m = re.search(rb"<NewExternalIPAddress>([^<]*)</NewExternalIPAddress>", data)
        return m.group(1).decode() if m and m.group(1) else None


# ---------------------------------------------------------------- NAT-PMP (RFC 6886)

class NatPMP:
    def __init__(self, gateway, port=5351, timeout=0.5, tries=4):
        self.gateway, self.port, self.timeout, self.tries = gateway, port, timeout, tries

    def _req(self, data, size):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            t = self.timeout
            for _ in range(self.tries):
                s.settimeout(t)
                try:
                    s.sendto(data, (self.gateway, self.port))
                    reply, src = s.recvfrom(64)
                    if src[0] == self.gateway and len(reply) >= size:
                        return reply
                except OSError:
                    pass
                t *= 2
        return None

    def external_ip(self):
        r = self._req(b"\x00\x00", 12)
        if not r or r[1] != 128 or struct.unpack(">H", r[2:4])[0] != 0:
            return None
        return socket.inet_ntoa(r[8:12])

    def add(self, port, lease=LEASE):
        r = self._req(struct.pack(">BBHHHI", 0, 2, 0, port, port, lease), 16)
        return bool(r) and r[1] == 130 and struct.unpack(">H", r[2:4])[0] == 0

    def delete(self, port):
        return self.add_lifetime_zero(port)

    def add_lifetime_zero(self, port):
        r = self._req(struct.pack(">BBHHHI", 0, 2, 0, port, 0, 0), 16)
        return bool(r) and struct.unpack(">H", r[2:4])[0] == 0


# ---------------------------------------------------------------- the host's mapper

class PortMapper:
    def __init__(self, consent=False, discover=ssdp_discover, gateway=default_gateway, local_ip=local_ip_for,
                 fetch=None, post=None, natpmp_port=5351):
        self.consent = consent
        self._discover, self._gateway, self._local_ip = discover, gateway, local_ip
        self.fetch, self.post, self.natpmp_port = fetch, post, natpmp_port
        self.method, self.client, self.ports, self.external = None, None, [], None

    def map(self, ports):
        """Map TCP ports (same number outside and in). -> (method or None, external ip or None)."""
        if not self.consent:
            return None, None
        ports = [int(p) for p in ports]
        for loc in self._discover():
            try:
                svc = find_service(loc, self.fetch)
                if not svc:
                    continue
                gw_host = urllib.parse.urlsplit(loc).hostname
                client = UPnP(svc[0], svc[1], self._local_ip(gw_host), self.post)
                if all(client.add(p) for p in ports):
                    self.method, self.client, self.ports = "upnp", client, ports
                    self.external = client.external_ip()
                    return self.method, self.external
                for p in ports:
                    client.delete(p)
            except (OSError, ET.ParseError, ValueError):
                continue
        gw = self._gateway()
        if gw:
            client = NatPMP(gw, self.natpmp_port)
            if all(client.add(p) for p in ports):
                self.method, self.client, self.ports = "natpmp", client, ports
                self.external = client.external_ip()
                return self.method, self.external
        return None, None

    def renew(self):
        if self.client:
            for p in self.ports:
                self.client.add(p)

    def unmap(self):
        if self.client:
            for p in self.ports:
                try:
                    self.client.delete(p)
                except OSError:
                    pass
        self.method, self.client, self.ports = None, None, []
