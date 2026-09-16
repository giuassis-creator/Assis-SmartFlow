"""Fail-closed simulated load probe with structured latency/error metrics."""
import argparse, concurrent.futures, json, time, urllib.error, urllib.request
from dataclasses import dataclass

@dataclass
class Sample:
    status: int
    latency_ms: float
    error: str | None = None

def request(url, body, headers):
    started = time.perf_counter()
    req = urllib.request.Request(url, json.dumps(body).encode(), headers=headers, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            response.read(); return Sample(response.status, (time.perf_counter()-started)*1000)
    except urllib.error.HTTPError as exc:
        return Sample(exc.code, (time.perf_counter()-started)*1000, 'http')
    except Exception as exc:
        return Sample(599, (time.perf_counter()-started)*1000, type(exc).__name__)

def percentile(values, p):
    if not values: return 0.0
    values = sorted(values)
    return values[min(len(values)-1, max(0, int(round((p/100)*(len(values)-1)))))]

def summarize(samples, duration_s):
    lat = [s.latency_ms for s in samples]; errors = [s for s in samples if s.status >= 400]
    classes = {}
    for sample in errors:
        key = sample.error or f'http_{sample.status}'; classes[key] = classes.get(key, 0) + 1
    return {'requests':len(samples), 'duration_s':round(duration_s,3),
        'throughput_rps':round(len(samples)/duration_s,3) if duration_s else 0,
        'latency_ms':{'min':min(lat) if lat else 0, 'max':max(lat) if lat else 0,
            'p50':percentile(lat,50), 'p95':percentile(lat,95), 'p99':percentile(lat,99)},
        'errors':len(errors), 'error_rate':len(errors)/len(samples) if samples else 0,
        'error_classes':classes, 'statuses':{str(s):sum(x.status==s for x in samples) for s in sorted({x.status for x in samples})}}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--url',required=True); ap.add_argument('--token',required=True)
    ap.add_argument('--secret',required=True); ap.add_argument('--isolated-marker',required=True)
    ap.add_argument('--requests',type=int,default=20); ap.add_argument('--concurrency',type=int,default=4); a=ap.parse_args()
    if a.isolated_marker!='ASSIS_E2E_SIMULATED' or not (a.url.startswith('http://n8n:') or a.url.startswith('http://127.0.0.1:')): raise SystemExit('Refusing non-isolated destination')
    headers={'content-type':'application/json','x-assis-auth-scope':a.secret,'x-assis-internal-token':a.token}
    body={'event':'message','session':'simulated','simulation':True,'organization_slug':'load-org','conversation_id':'load-conversation','message_id':'load-'+str(time.time_ns()),'text':'carga simulada'}
    started=time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.concurrency) as pool: results=list(pool.map(lambda _:request(a.url,body,headers),range(a.requests)))
    out={'profile':'ingress_persistence_idempotency','concurrency':a.concurrency,'baseline':'local_hardware_only',**summarize(results,time.perf_counter()-started),'metrics_unavailable':{'cpu_memory_swap_io':'requires Docker stats collector','postgres_redis':'requires isolated service endpoints','ollama':'planner profile separate'}}
    print(json.dumps(out,sort_keys=True)); return 1 if out['errors'] else 0
if __name__=='__main__': raise SystemExit(main())
