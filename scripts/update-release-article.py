#!/usr/bin/env python3
"""Update the existing Dayu release article, retaining its cover and access rules.
Only --publish performs writes. Credentials stay in memory and go only to Dayu.
"""
import argparse, base64, hashlib, html, json, pathlib, ssl, subprocess, urllib.parse, urllib.request, uuid, zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--version', required=True)
parser.add_argument('--post-id', type=int, default=15593)
parser.add_argument('--publish', action='store_true')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
release = root / 'releases' / args.version
work = root / 'build' / ('publish-' + args.version)
work.mkdir(parents=True, exist_ok=True)
state_path = work / 'operation.json'
state = json.loads(state_path.read_text()) if state_path.exists() else {'idempotencyKey': str(uuid.uuid4())}
def save():
    state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')
save()
secret = subprocess.run(['security', 'find-generic-password', '-s', 'dayu-article-publisher', '-a', 'dayu', '-w'], text=True, capture_output=True, check=True).stdout.strip()
auth = 'Basic ' + base64.b64encode(('dayu:' + secret).encode()).decode()
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None
opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile='/etc/ssl/cert.pem')))
def request(path, method='GET', body=None, headers=None):
    assert path.startswith(('/wp/v2/', '/dayu-publisher/v1/')) and '\n' not in path
    h = {'Authorization': auth, 'Accept': 'application/json'}
    h.update(headers or {})
    if isinstance(body, dict):
        body = json.dumps(body, ensure_ascii=False).encode()
        h['Content-Type'] = 'application/json'
    with opener.open(urllib.request.Request('https://dayu.media/wp-json' + path, data=body, headers=h, method=method), timeout=180) as response:
        return json.load(response)
def public_bytes(url):
    assert urllib.parse.urlparse(url).hostname == 'dayu.media'
    with urllib.request.urlopen(url, context=ssl.create_default_context(cafile='/etc/ssl/cert.pem'), timeout=180) as response:
        return response.read()
digest = lambda data: hashlib.sha256(data).hexdigest()
route = '/dayu-publisher/v1/posts/' + str(args.post_id)
status = request('/dayu-publisher/v1/status')
assert status['can_publish'] and status['can_upload'] and 'seo' in status['fields']
before = request(route)['article']
assert before['id'] == args.post_id and before['status'] == 'publish'
if not args.publish:
    (work / 'article-before.json').write_text(json.dumps({'article': before}, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'id': before['id'], 'url': before['url'], 'status': before['status'], 'writePerformed': False}))
    raise SystemExit(0)
baseline = json.loads((work / 'article-before.json').read_text())['article']
payload = json.loads((release / 'article-payload.json').read_text())
package = release / ('大鱼人像美化-' + args.version + '.pkg')
source = root / 'build' / ('Dayu-Portrait-' + args.version + '-source.zip')
with zipfile.ZipFile(source) as z:
    assert z.testzip() is None and any(n.endswith('/Wrapper Application/AppDelegate.m') for n in z.namelist())
    assert not any(n.endswith(('.app', '.pkg', '.p12', '.key', '.env')) for n in z.namelist())
operation_digest = digest(package.read_bytes() + source.read_bytes() + json.dumps(payload, sort_keys=True, ensure_ascii=False).encode())
assert state.get('digest', operation_digest) == operation_digest, 'Prepared release changed; use a new reviewed operation state'
state['digest'] = operation_digest
save()
if not state.get('response'):
    assert before == baseline, 'Article changed since review; reconcile the current article first'
if 'source' not in state:
    title = 'Dayu Portrait ' + args.version + ' source'
    matches = request('/wp/v2/media?context=edit&per_page=100&search=' + urllib.parse.quote(title))
    for item in matches:
        if item['title'].get('raw', item['title'].get('rendered')) == title and digest(public_bytes(item['source_url'])) == digest(source.read_bytes()):
            state['source'] = {'id': item['id'], 'url': item['source_url']}
            break
    if 'source' not in state:
        item = request('/wp/v2/media?title=' + urllib.parse.quote(title), 'POST', source.read_bytes(), {'Content-Type': 'application/zip', 'Content-Disposition': 'attachment; filename="' + source.name + '"'})
        state['source'] = {'id': item['id'], 'url': item['source_url']}
    save()
assert digest(public_bytes(state['source']['url'])) == digest(source.read_bytes())
payload['content'] = payload['content'].replace('{{source_url}}', html.escape(state['source']['url'], quote=True))
assert '{{' not in payload['content']
if not state.get('response'):
    boundary = 'DayuRelease' + state['idempotencyKey'].replace('-', '')
    parts = []
    for name, data, filename, mime in [('payload', json.dumps(payload, ensure_ascii=False).encode(), None, 'application/json'), ('package', package.read_bytes(), 'Dayu-Portrait-' + args.version + '.pkg', 'application/octet-stream')]:
        head = '--' + boundary + '\r\nContent-Disposition: form-data; name="' + name + '"'
        if filename:
            head += '; filename="' + filename + '"'
        parts.append((head + '\r\nContent-Type: ' + mime + '\r\n\r\n').encode() + data + b'\r\n')
    state['response'] = request(route, 'POST', b''.join(parts) + ('--' + boundary + '--\r\n').encode(), {'Content-Type': 'multipart/form-data; boundary=' + boundary, 'Idempotency-Key': state['idempotencyKey']})
    save()
after = request(route)['article']
for key in ['author', 'categories', 'tags', 'featured_media']:
    assert after[key] == baseline[key], key
for key, value in baseline['resource'].items():
    if key not in ['cao_downurl', 'cao_original_filename', 'cao_info']:
        assert after['resource'][key] == value, key
assert after['status'] == 'publish' and after['title'] == payload['title']
assert after['seo'] == payload['seo'] and after['resource']['cao_info'] == payload['resource']['cao_info']
assert after['content'].count('<!-- wp:code -->') == 1
assert state['source']['url'] in after['content'] and ('/releases/tag/v' + args.version) in after['content']
assert digest(public_bytes(after['resource']['cao_downurl'])) == digest(package.read_bytes())
(work / 'article-after.json').write_text(json.dumps({'article': after}, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'id': after['id'], 'url': after['url'], 'status': after['status'], 'packageHashVerified': True, 'sourceHashVerified': True, 'coverAndAccessPreserved': True}, ensure_ascii=False))
