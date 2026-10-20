"""Stand-ins for mangosd's SOAP port and Discord (API + the authorize page a player would click)."""
import json, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USERS = {"first": {"id": "123456789012345678", "username": "thrall", "global_name": "Thrall Warchief"},
         "second": {"id": "223456789012345678", "username": "jaina", "global_name": "Jaina Proudmoore"}}
STATE = {"who": "first", "log": []}

class Soap(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        cmd = body.split("<command>")[1].split("</command>")[0] if "<command>" in body else ""
        STATE["log"].append("soap " + cmd)
        reply = "Server uptime: 1 minute\nPlayers online: 0" if cmd.startswith("server info") else "ok"
        out = f"<SOAP-ENV:Envelope><SOAP-ENV:Body><ns1:executeCommandResponse><result>{reply}&#xD;\n</result></ns1:executeCommandResponse></SOAP-ENV:Body></SOAP-ENV:Envelope>".encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)

class Discord(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj=None, headers=()):
        data = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        if u.path == "/oauth2/authorize":
            # The player approves (with prompt=consent they pick the other account).
            STATE["log"].append(f"authorize prompt={q.get('prompt')}")
            if q.get("prompt") == "consent":
                STATE["who"] = "second"
            to = q["redirect_uri"] + "?" + urllib.parse.urlencode({"code": "OK-" + STATE["who"], "state": q["state"]})
            return self._send(302, None, [("Location", to)])
        if u.path == "/api/v10/users/@me":
            who = self.headers.get("Authorization", "").split("-")[-1]
            return self._send(200, USERS.get(who, USERS["first"]))
        if "/members/" in u.path:
            return self._send(200, {"roles": ["222222222222222222"]})
        self._send(404, {})
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.path == "/api/v10/oauth2/token":
            who = "second" if "OK-second" in body else "first"
            STATE["log"].append("token " + who)
            return self._send(200, {"access_token": "AT-" + who, "token_type": "Bearer"})
        self._send(404, {})
    def do_PUT(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        STATE["log"].append("put " + self.path)
        self._send(201 if "/roles/" not in self.path else 204)

def start():
    for port, h in ((17878, Soap), (18099, Discord)):
        s = ThreadingHTTPServer(("127.0.0.1", port), h)
        threading.Thread(target=s.serve_forever, daemon=True).start()
