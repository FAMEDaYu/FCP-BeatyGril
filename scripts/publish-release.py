#!/usr/bin/env python3
"""Publish this reviewed release through the connected Dayu article publisher.
Secrets are read from macOS Keychain into memory; no auth material is persisted.
"""
from pathlib import Path
import base64,hashlib,html,json,mimetypes,ssl,subprocess,urllib.error,urllib.parse,urllib.request,uuid
ROOT=Path(__file__).resolve().parent.parent
STATE=ROOT/'build/publish-operation.json';STATE.parent.mkdir(exist_ok=True)
state=json.loads(STATE.read_text()) if STATE.exists() else {'operation':str(uuid.uuid4())}
def save():STATE.write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
save()
secret=subprocess.run(['security','find-generic-password','-s','dayu-article-publisher','-a','dayu','-w'],text=True,capture_output=True,check=True).stdout.strip()
auth='Basic '+base64.b64encode(('dayu:'+secret).encode()).decode()
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args,**kwargs):return None
opener=urllib.request.build_opener(NoRedirect,urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile='/etc/ssl/cert.pem')))
def request(path,method='GET',body=None,headers=None):
 assert path.startswith(('/wp/v2/','/dayu-publisher/v1/')) and '\n' not in path
 h={'Authorization':auth,'Accept':'application/json'};h.update(headers or {})
 if isinstance(body,dict):body=json.dumps(body,ensure_ascii=False).encode();h['Content-Type']='application/json'
 req=urllib.request.Request('https://dayu.media/wp-json'+path,data=body,headers=h,method=method)
 with opener.open(req,timeout=180) as f:return json.load(f)
def upload(name,path,mime):
 if name in state:return state[name]
 filename=path.name
 matches=request('/wp/v2/media?search='+urllib.parse.quote(path.stem)+'&per_page=30&context=edit')
 for item in matches:
  if urllib.parse.unquote(item.get('source_url','')).endswith('/'+filename):
   # Only reuse a byte-identical previous upload.
   with urllib.request.urlopen(item['source_url'],context=ssl.create_default_context(cafile='/etc/ssl/cert.pem'),timeout=90) as r:data=r.read()
   if hashlib.sha256(data).digest()==hashlib.sha256(path.read_bytes()).digest():
    state[name]={'id':item['id'],'url':item['source_url']};save();return state[name]
 result=request('/wp/v2/media','POST',path.read_bytes(),{'Content-Type':mime,'Content-Disposition':'attachment; filename="'+filename+'"'})
 state[name]={'id':result['id'],'url':result['source_url']};save();return state[name]
status=request('/dayu-publisher/v1/status');assert status['can_publish'] and status['can_upload'] and 'seo' in status['fields']
source=upload('source',ROOT/'build/Dayu-Portrait-1.2.0-source.zip','application/zip')
card=upload('card',ROOT/'beatygril/beatygril/Wrapper Application/Resources/LauncherInfo.png','image/png')
content=(ROOT/'releases/1.2.0/article.html').read_text().replace('{{source_url}}',html.escape(source['url'],quote=True)).replace('{{card_url}}',html.escape(card['url'],quote=True))
seo={
 'title':{'enabled':True,'value':'大鱼人像美化 1.2.0｜FCP / Motion 免费开源自动美颜插件'},
 'description':{'enabled':True,'value':'大鱼人像美化是适用于 Final Cut Pro 和 Motion 的免费开源 FxPlug4 插件，支持磨皮、美白、自动人脸跟随及瘦脸调整。提供 Apple 签名公证 PKG 安装包和源码，安装自动注册，无需激活码，并附具体安装、使用及红色警告排查说明。'},
 'keywords':{'enabled':True,'value':'大鱼人像美化,FCP美颜插件,Motion磨皮,自动瘦脸,自动跟随,FxPlug4,免费开源'}
}
payload={'title':'大鱼人像美化 1.2.0：FCP / Motion 免费开源自动美颜插件','slug':'dayu-portrait-beauty','status':'publish','content':content,'excerpt':'磨皮、美白、瘦脸与自动人脸跟随，原生卡片面板实时预览。免费开源，自动注册，无需激活码；提供签名公证安装包和源码。','categories':[3],'tags':[], 'resource':{'cao_status':True,'cao_price':0,'cao_vip_rate':1,'cao_close_novip_pay':False,'cao_expire_day':0,'cao_pwd':'','cao_info':[{'title':'版本','desc':'1.2.0（14）'},{'title':'宿主','desc':'Final Cut Pro / Motion'},{'title':'系统','desc':'macOS 13 或更高版本'},{'title':'架构','desc':'Apple Silicon / Intel'},{'title':'授权','desc':'免费开源，无需激活码'}]},'seo':seo}
(ROOT/'releases/1.2.0/article-payload.json').write_text(json.dumps(payload,ensure_ascii=False,indent=2)+'\n')
if 'post_id' not in state:
 existing=request('/wp/v2/posts?slug=dayu-portrait-beauty&context=edit');assert not existing,'Matching post exists; inspect and continue its ID instead of creating a duplicate'
 boundary='DayuRelease'+uuid.uuid4().hex;parts=[]
 def part(name,data,filename=None,mime=None):
  head='--'+boundary+'\r\nContent-Disposition: form-data; name="'+name+'"'
  if filename:head+='; filename="'+filename+'"'
  head+='\r\n'
  if mime:head+='Content-Type: '+mime+'\r\n'
  parts.append(head.encode()+b'\r\n'+data+b'\r\n')
 part('payload',json.dumps(payload,ensure_ascii=False).encode())
 part('package',(ROOT/'releases/1.2.0/大鱼人像美化-1.2.0.pkg').read_bytes(),'Dayu-Portrait-1.2.0.pkg','application/octet-stream')
 part('cover',(ROOT/'Assets/Artwork/portrait-cover.png').read_bytes(),'Dayu-Portrait-Cover.png','image/png')
 body=b''.join(parts)+('--'+boundary+'--\r\n').encode()
 result=request('/dayu-publisher/v1/posts','POST',body,{'Content-Type':'multipart/form-data; boundary='+boundary,'Idempotency-Key':state['operation']})
 state['response']=result;save()
 # Response schema may vary; resolve the exact saved slug through standard REST.
 rows=request('/wp/v2/posts?slug=dayu-portrait-beauty&context=edit');assert len(rows)==1
 state['post_id']=rows[0]['id'];state['url']=rows[0]['link'];save()
saved=request('/dayu-publisher/v1/posts/'+str(state['post_id']))
(ROOT/'docs/verification/v1.2.0/published-article.json').write_text(json.dumps(saved,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'post_id':state['post_id'],'url':state['url'],'source':source,'card':card,'snapshot_saved':True},ensure_ascii=False))
