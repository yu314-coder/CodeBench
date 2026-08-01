#!/usr/bin/env python3
"""Print recent App Store Connect build states for CodeBench (read-only)."""
import json, time, base64, subprocess, sys, urllib.request
KID="68L7XZ4K92"; ISS="affeed72-2585-4742-b885-300a28f95d1a"
KEY="/Users/euler/.private_keys/AuthKey_68L7XZ4K92.p8"; APP="6764480001"
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=")
now=int(time.time())
si=(b64u(json.dumps({"alg":"ES256","kid":KID,"typ":"JWT"},separators=(",",":")).encode())+b"."+
    b64u(json.dumps({"iss":ISS,"iat":now,"exp":now+900,"aud":"appstoreconnect-v1"},separators=(",",":")).encode()))
der=subprocess.run(["openssl","dgst","-sha256","-sign",KEY],input=si,capture_output=True).stdout
def raw(d):
    i=2
    if d[1]&0x80: i=2+(d[1]&0x7f)
    rl=d[i+1]; r=d[i+2:i+2+rl]; i=i+2+rl
    sl=d[i+1]; s=d[i+2:i+2+sl]
    return r.lstrip(b"\0").rjust(32,b"\0")+s.lstrip(b"\0").rjust(32,b"\0")
jwt=(si+b"."+b64u(raw(der))).decode()
u=(f"https://api.appstoreconnect.apple.com/v1/builds?filter[app]={APP}"
   "&limit=5&sort=-version&fields[builds]=version,processingState,uploadedDate")
try:
    d=json.load(urllib.request.urlopen(urllib.request.Request(u,headers={"Authorization":f"Bearer {jwt}"}),timeout=30))
except urllib.error.HTTPError as e:
    print("HTTP",e.code,e.read().decode()[:300]); sys.exit(1)
for b in d.get("data",[]):
    a=b["attributes"]
    print(f"  build {a.get('version'):>4}: {a.get('processingState'):<12} uploaded={a.get('uploadedDate')}")
