#!/usr/bin/env python3
import json, os, sys, urllib.request, urllib.error

endpoint = os.environ['SDL_READ_ENDPOINT'].rstrip('/')
if not endpoint.endswith('/api/query'):
    endpoint = endpoint + '/api/query'
token = os.environ['SDL_READ_TOKEN']
filter_expr = sys.argv[1] if len(sys.argv) > 1 else 'SDL_VALIDATION'
start = sys.argv[2] if len(sys.argv) > 2 else '-30m'
count = int(sys.argv[3]) if len(sys.argv) > 3 else 100
payload = {
    'token': token,
    'queryType': 'log',
    'filter': filter_expr,
    'startTime': start,
    'maxCount': count,
    'pageMode': 'tail',
    'priority': 'low',
}
req = urllib.request.Request(
    endpoint,
    data=json.dumps(payload).encode(),
    headers={'Content-Type': 'application/json'},
    method='POST',
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode(errors='replace')
except urllib.error.HTTPError as e:
    print('HTTP_ERROR', e.code, e.read().decode(errors='replace')[:2000])
    raise
print(raw)
