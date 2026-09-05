from __future__ import annotations
import json, os, sys, urllib.request, urllib.error

BASE=os.getenv('ASSIS_STAGING_URL','').rstrip('/')
SECRET=os.getenv('ASSIS_STAGING_SECRET','')

def post(path,payload):
    if not BASE: raise RuntimeError('ASSIS_STAGING_URL is required')
    data=json.dumps(payload).encode()
    headers={'Content-Type':'application/json'}
    if SECRET: headers['x-assis-secret']=SECRET
    req=urllib.request.Request(BASE+path,data=data,headers=headers,method='POST')
    with urllib.request.urlopen(req,timeout=20) as r:
        return r.status, r.read().decode('utf-8','replace')

cases=[
 ('/webhook/assis/v1/message',{'organization_slug':'default','channel':'test','conversation_id':'e2e-1','message_id':'e2e-1-1','text':'Olá, gostaria de agendar um horário','contact':{'external_id':'e2e-contact'}}),
 ('/webhook/assis/v1/secretary',{'text':'Quero falar com uma pessoa','conversation_id':'e2e-1'}),
]

if __name__=='__main__':
    failures=[]
    for path,payload in cases:
        try:
            status,body=post(path,payload)
            print(path,status,body[:300])
            if status>=400: failures.append((path,status))
        except Exception as e:
            failures.append((path,str(e)))
    if failures:
        print('FAIL',failures);sys.exit(1)
    print('PASS: staging smoke')
