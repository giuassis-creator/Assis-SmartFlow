const http=require('http');
const target=process.env.OLLAMA_PROXY_TARGET || 'http://ollama:11434';
const hopByHop=new Set(['connection','keep-alive','proxy-authenticate','proxy-authorization','te','trailer','transfer-encoding','upgrade','host','content-length']);
const server=http.createServer((req,res)=>{
  let body=[]; req.on('data',c=>body.push(c)); req.on('end',()=>{
    const raw=Buffer.concat(body); const isEmbed=req.method==='POST' && /^\/api\/(embed|embeddings)$/.test(req.url||'');
    let payload=raw; if(isEmbed){ try { const j=JSON.parse(raw.toString('utf8')); j.keep_alive=0; payload=Buffer.from(JSON.stringify(j)); } catch { res.writeHead(400); return res.end(); } }
    const u=new URL(target+(req.url||'/')); const headers={};
    if(req.headers['content-type']) headers['content-type']=req.headers['content-type'];
    if(payload.length && req.method !== 'GET' && req.method !== 'HEAD') headers['content-length']=payload.length;
    const p=http.request({hostname:u.hostname,port:u.port,path:u.pathname+u.search,method:req.method,headers},r=>{
      const responseHeaders={};
      for(const [key,value] of Object.entries(r.headers)) if(!hopByHop.has(key)) responseHeaders[key]=value;
      res.writeHead(r.statusCode||502,responseHeaders); r.pipe(res);
    });
    p.on('error',()=>{if(!res.headersSent)res.writeHead(502);res.end()}); p.end(payload);
  });
});
server.listen(Number(process.env.OLLAMA_PROXY_PORT || 11434),'0.0.0.0');
