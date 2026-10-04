#!/usr/bin/env python3
"""Print or apply the scores-only WAF guard. No credentials needed for --plan."""
import argparse
import json
import os
import urllib.error
import urllib.request

REF = "allday_scores_request_guard"
PHASE = "http_request_firewall_custom"
HOSTS = ("scores.alldayidreamaboutsports.com", "scores-staging.alldayidreamaboutsports.com")
# These request headers participate in Cloudflare's default cache key.
# Native score clients require none of them (including cross-origin requests).
FRAGMENT_HEADERS = ("origin", "x-http-method-override", "x-http-method", "x-method-override",
                    "x-forwarded-host", "x-host", "x-forwarded-scheme", "x-original-url",
                    "x-rewrite-url", "forwarded")


def rule():
    hosts = " ".join(json.dumps(host) for host in HOSTS)
    path = "http.request.uri.path"
    allowed = (f'({path} eq "/catalog.json" or '
               f'(starts_with({path}, "/fixtures-") and ends_with({path}, ".json") and len({path}) eq 25) or '
               f'(starts_with({path}, "/matches/") and ends_with({path}, ".json") and len({path}) le 40))')
    bad_headers = " or ".join(f'len(http.request.headers["{h}"]) gt 0' for h in FRAGMENT_HEADERS)
    return {
        "ref": REF, "description": "Block noncanonical scores requests before R2",
        "action": "block", "enabled": True,
        "expression": (f'(http.host in {{{hosts}}} and '
                       f'(not http.request.method in {{"GET" "HEAD"}} or '
                       f'http.request.uri.query ne "" or not {allowed} or {bad_headers}))'),
    }


def apply(api, zone):
    """Change only our rule; keep unrelated access controls and emergency blocks."""
    base = f"/zones/{zone}/rulesets"
    try:
        entry = api("GET", f"{base}/phases/{PHASE}/entrypoint")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        api("POST", base, {"name": "Scores request protection", "kind": "zone",
                           "phase": PHASE, "rules": [rule()]})
        return
    existing = next((r for r in entry.get("rules", []) if r.get("ref") == REF), None)
    payload = {**rule(), "position": {"before": ""}}
    if existing:
        api("PATCH", f'{base}/{entry["id"]}/rules/{existing["id"]}', payload)
    else:
        api("POST", f'{base}/{entry["id"]}/rules', payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true")
    mode.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.plan:
        print(json.dumps(rule(), indent=2))
        return
    token = os.environ["CLOUDFLARE_API_TOKEN"]  # Zone WAF Edit on this zone only
    zone = os.environ["CLOUDFLARE_ZONE_ID"]
    if len(zone) != 32 or any(c not in "0123456789abcdef" for c in zone):
        parser.error("CLOUDFLARE_ZONE_ID must be a 32-character hexadecimal zone ID")

    def api(method, path, payload=None):
        request = urllib.request.Request(
            "https://api.cloudflare.com/client/v4" + path, method=method,
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
            data=None if payload is None else json.dumps(payload).encode(),
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        if not result.get("success"):
            raise RuntimeError("Cloudflare rejected the rule: " + json.dumps(result.get("errors")))
        return result["result"]

    apply(api, zone)
    entry = api("GET", f"/zones/{zone}/rulesets/phases/{PHASE}/entrypoint")
    stored = next(r for r in entry["rules"] if r.get("ref") == REF)
    if any(stored.get(k) != v for k, v in rule().items()):
        raise RuntimeError("Cloudflare read-back does not match the requested rule")
    print("Scores request guard applied and read back. Verify live canonical and blocked requests.")


if __name__ == "__main__":
    main()
