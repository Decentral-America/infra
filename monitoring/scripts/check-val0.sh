#!/usr/bin/env bash
echo "=== Val-0 addresses ==="
curl -sf http://localhost:16871/addresses 2>/dev/null | python3 -c "
import json,sys
addrs = json.load(sys.stdin)
for a in addrs: print(a)
" || echo "(REST API not responding)"

echo "=== Val-0 balances ==="
curl -sf http://localhost:16871/addresses 2>/dev/null | python3 -c "
import json,sys,urllib.request
addrs=json.load(sys.stdin)
for addr in addrs:
    try:
        r=urllib.request.urlopen('http://localhost:16871/addresses/balance/'+addr,timeout=5)
        b=json.load(r)
        print(addr+': '+str(b['balance']//100000000)+' DCC')
    except Exception as e: print(addr+': error '+str(e))
" 2>/dev/null || echo "(balance query failed)"

echo "=== Val-0 height ==="
curl -sf http://localhost:16871/node/status 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin); print('height:', d.get('blockchainHeight','?'))
" || echo "(unavailable)"
