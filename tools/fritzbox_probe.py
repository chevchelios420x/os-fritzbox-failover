#!/usr/bin/env python3
"""
Read-only probe of FRITZ!Box WAN status interfaces (UPnP IGD and TR-064).

Lists the WAN related services a FRITZ!Box offers and calls every
argument-less "Get..." action of those services. Nothing is changed on the
box. IPv4/IPv6 and MAC addresses in the output are masked, so the output can
be shared.

usage:
    python3 fritzbox_probe.py 192.168.0.1 [192.168.1.1 ...]
    python3 fritzbox_probe.py --user opnsense 192.168.0.1   (asks for password,
                                                             adds TR-064 calls)

Without --user only the UPnP IGD interface (no login) is queried, plus the
TR-064 service list. With --user the authenticated TR-064 actions are queried
as well (digest authentication, password is asked interactively).
"""

import argparse
import getpass
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

TIMEOUT = 6
PORT = 49000
WAN_PATTERN = re.compile(r"WAN|Mobile|DSL|Cable|Docsis", re.IGNORECASE)


def mask(text):
    """hide addresses so the output can be shared"""
    text = re.sub(r"\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b", "<mac>", text)
    text = re.sub(r"\b(\d{1,3})\.\d{1,3}\.\d{1,3}\.(\d{1,3})\b", r"\1.x.x.\2", text)
    text = re.sub(r"\b[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){3,7}\b", "<ipv6>", text)
    return text


def strip_ns(tag):
    return tag.split("}", 1)[-1]


def fetch(url, opener):
    with opener.open(url, timeout=TIMEOUT) as resp:
        return resp.read()


def parse_services(xml_bytes):
    """returns list of (serviceType, controlURL, SCPDURL)"""
    services = []
    root = ET.fromstring(xml_bytes)
    for el in root.iter():
        if strip_ns(el.tag) == "service":
            info = {strip_ns(c.tag): (c.text or "").strip() for c in el}
            services.append((info.get("serviceType", ""), info.get("controlURL", ""), info.get("SCPDURL", "")))
    return services


def getter_actions(scpd_bytes):
    """argument-less actions (only output arguments) starting with Get"""
    actions = []
    root = ET.fromstring(scpd_bytes)
    for action in root.iter():
        if strip_ns(action.tag) != "action":
            continue
        name = ""
        has_in = False
        for child in action:
            if strip_ns(child.tag) == "name":
                name = (child.text or "").strip()
            elif strip_ns(child.tag) == "argumentList":
                for arg in child.iter():
                    if strip_ns(arg.tag) == "direction" and (arg.text or "").strip() == "in":
                        has_in = True
        if name.startswith("Get") and not has_in:
            actions.append(name)
    return sorted(set(actions))


def soap(base, control, service, action, opener):
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:%s xmlns:u="%s"></u:%s></s:Body></s:Envelope>' % (action, service, action)
    ).encode()
    req = urllib.request.Request(base + control, data=body, headers={
        "Content-Type": 'text/xml; charset="utf-8"',
        "SoapAction": "%s#%s" % (service, action),
    })
    try:
        raw = fetch(req, opener)
    except urllib.error.HTTPError as err:
        return "HTTP %s" % err.code
    except Exception as err:  # noqa: BLE001 - report any error, keep going
        return "error: %s" % err
    values = []
    try:
        root = ET.fromstring(raw)
        for el in root.iter():
            tag = strip_ns(el.tag)
            if tag.startswith("New"):
                values.append("%s=%s" % (tag, (el.text or "").strip()))
    except ET.ParseError:
        return "unparsable answer"
    return ", ".join(values) if values else "(no values)"


def probe_interface(base, desc, label, opener, call_actions):
    print("\n--- %s (%s) ---" % (label, desc))
    try:
        services = parse_services(fetch(base + "/" + desc, opener))
    except Exception as err:  # noqa: BLE001
        print("  not available: %s" % err)
        return
    for stype, control, scpd in services:
        # match only the service name, not the namespace (urn:dslforum-org:...)
        if not WAN_PATTERN.search(stype.split(":service:")[-1]):
            continue
        print("\n  service %s" % stype)
        print("    control %s" % control)
        if not call_actions:
            continue
        try:
            actions = getter_actions(fetch(base + scpd, opener))
        except Exception as err:  # noqa: BLE001
            print("    actions: not readable (%s)" % err)
            continue
        for action in actions:
            print("    %-32s %s" % (action, mask(soap(base, control, stype, action, opener))))


def main():
    parser = argparse.ArgumentParser(description="Read-only FRITZ!Box WAN status probe")
    parser.add_argument("hosts", nargs="+", help="FRITZ!Box IP address(es)")
    parser.add_argument("--user", help="FRITZ!Box user for TR-064 (password is asked)")
    args = parser.parse_args()

    password = getpass.getpass("FRITZ!Box password for %s: " % args.user) if args.user else None

    for host in args.hosts:
        base = "http://%s:%d" % (host, PORT)
        print("=" * 70)
        print("FRITZ!Box %s" % mask(host))
        plain = urllib.request.build_opener()
        try:
            root = ET.fromstring(fetch(base + "/tr64desc.xml", plain))
            for el in root.iter():
                if strip_ns(el.tag) in ("modelName", "Display") and el.text:
                    print("  %s: %s" % (strip_ns(el.tag), el.text.strip()))
        except Exception as err:  # noqa: BLE001
            print("  tr64desc.xml not available: %s" % err)

        # UPnP IGD: no login needed
        probe_interface(base, "igddesc.xml", "UPnP IGD, no login", plain, True)

        # TR-064: service list always, actions only with login
        if password is not None:
            mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
            mgr.add_password(None, base, args.user, password)
            auth = urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(mgr))
            probe_interface(base, "tr64desc.xml", "TR-064, with login", auth, True)
        else:
            probe_interface(base, "tr64desc.xml", "TR-064, service list only (use --user for values)", plain, False)
    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())
