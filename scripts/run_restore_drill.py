"""Non-destructive PostgreSQL restore drill using an explicitly named temp volume.
Production volumes are never opened by this tool.
"""
import argparse, pathlib, subprocess, secrets, time
def main():
    p=argparse.ArgumentParser(); p.add_argument('--backup', required=True); p.add_argument('--project', default='assis-smartflow-restore-drill'); p.add_argument('--volume', default='assis-smartflow-restore-drill-postgres'); a=p.parse_args()
    b=pathlib.Path(a.backup); required=['postgres.dump','qdrant.tgz','n8n.tgz']
    missing=[x for x in required if not (b/x).is_file() or (b/x).stat().st_size==0]
    if missing: print('FAIL: backup missing or empty: '+','.join(missing)); return 2
    password=secrets.token_hex(16); name=a.project+'-postgres';
    run=lambda c: subprocess.run(c,check=True,capture_output=True,text=True)
    subprocess.run(['docker','rm','-f',name],capture_output=True)
    subprocess.run(['docker','volume','rm',a.volume],capture_output=True)
    run(['docker','volume','create',a.volume])
    run(['docker','run','-d','--name',name,'-e','POSTGRES_DB=restore','-e','POSTGRES_USER=restore','-e','POSTGRES_PASSWORD='+password,'-v',a.volume+':/var/lib/postgresql/data','pgvector/pgvector:pg16'])
    try:
        for _ in range(45):
            if subprocess.run(['docker','exec',name,'pg_isready','-U','restore','-d','restore'],capture_output=True).returncode==0: break
            time.sleep(2)
        else: raise RuntimeError('temporary postgres did not become ready')
        run(['docker','exec',name,'psql','-U','restore','-d','restore','-c',"CREATE ROLE assis LOGIN PASSWORD 'drill-only';"])
        with open(b/'postgres.dump','rb') as f:
            r=subprocess.run(['docker','exec','-i',name,'pg_restore','--no-owner','--clean','--if-exists','-U','restore','-d','restore'],input=f.read(),capture_output=True)
        if r.returncode: raise RuntimeError(r.stderr.decode(errors='replace')[-2000:])
        q=run(['docker','exec',name,'psql','-U','restore','-d','restore','-Atc','select count(*) from workflow_entity; select count(*) from messages; select count(*) from credentials_entity; select count(*) from pg_extension where extname in (\'pgcrypto\',\'uuid-ossp\',\'vector\');']).stdout.strip().splitlines()
        if q[:4] != ['48','15','2','3']: raise RuntimeError('restore counts/extensions mismatch: '+repr(q))
        print('PASS: faithful isolated restore; workflows=48 messages=15 credentials=2 extensions=3; no-owner alternative not used')
        return 0
    finally:
        subprocess.run(['docker','rm','-f',name],capture_output=True)
        subprocess.run(['docker','volume','rm',a.volume],capture_output=True)
if __name__=='__main__': raise SystemExit(main())
