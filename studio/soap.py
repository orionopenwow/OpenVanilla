"""mangosd's SOAP console: run one GM command and get its text reply.

CMaNGOS checks the HTTP Basic credentials against the account table and needs GM level 3, so
Studio sends the signed-in admin's own credentials (held in server memory for the session only).
"""
import base64
import re
import xml.sax.saxutils

import aiohttp

_ENT = {"&#xD;": "", "&#xA;": "\n", "&#13;": "", "&#10;": "\n", "&quot;": '"', "&apos;": "'"}


class SoapError(RuntimeError):
    pass


class SoapUnavailable(SoapError):
    """mangosd is not listening for SOAP (stopped, or SOAP.Enabled = 0)."""


async def run(url, user, password, command, timeout=10):
    body = ('<?xml version="1.0" encoding="utf-8"?>'
            '<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" '
            'xmlns:ns1="urn:MaNGOS"><SOAP-ENV:Body><ns1:executeCommand><command>'
            + xml.sax.saxutils.escape(command) +
            '</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>').encode("utf-8")
    auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
    headers = {"Content-Type": "text/xml; charset=utf-8", "Authorization": f"Basic {auth}"}
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout)) as s:
            async with s.post(url, data=body, headers=headers) as r:
                text = await r.text(errors="replace")
                status = r.status
    except (aiohttp.ClientConnectionError, TimeoutError) as e:
        raise SoapUnavailable(f"the world server's SOAP console is not answering ({e.__class__.__name__})") from e
    if status == 401:
        raise SoapError("the world server refused the admin credentials")
    m = re.search(r"<result>(.*?)</result>", text, re.S)
    if m:
        return xml.sax.saxutils.unescape(m.group(1), _ENT).strip()
    fault = re.search(r"<faultstring>(.*?)</faultstring>", text, re.S)
    if fault:
        raise SoapError(xml.sax.saxutils.unescape(fault.group(1), _ENT).strip())
    raise SoapError(f"unexpected SOAP reply (HTTP {status})")
