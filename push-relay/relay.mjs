// Agentgram push relay: Telegram Web Push → Apple Push Notification service.
//
// Telegram sends pushes to a third-party iOS app only by Web Push, to an address the app gives it. The app builds
// that address itself: its APNs token, sealed with this relay's public key, is part of the path. So the relay keeps
// no list of devices and never hears from the phones. Telegram encrypts each push twice: for this relay (Web Push,
// RFC 8291) and, inside, with the account's own key, which only the phone has. The relay opens the outer layer,
// passes the inner ciphertext to Apple and keeps nothing.
//
//   node relay.mjs keygen      a new key pair: the private key for this relay, the public key and auth for the app
//   node relay.mjs             run (settings from the environment, see README.md)
import http from 'node:http';
import http2 from 'node:http2';
import crypto from 'node:crypto';
import fs from 'node:fs';

const b64u = (b) => Buffer.from(b).toString('base64url');
const fromB64u = (s) => Buffer.from(String(s || ''), 'base64url');
const hkdf = (salt, ikm, info, n) => Buffer.from(crypto.hkdfSync('sha256', ikm, salt, info, n));

if (process.argv[2] === 'keygen') {
  const ecdh = crypto.createECDH('prime256v1'); ecdh.generateKeys();
  console.log('RELAY_PRIVATE_KEY=' + b64u(ecdh.getPrivateKey()));
  console.log('push_relay_key (app) = ' + b64u(ecdh.getPublicKey()));
  console.log('push_relay_auth (app) = ' + b64u(crypto.randomBytes(16)));
  process.exit(0);
}

const env = (name, fallback) => {
  const value = process.env[name] ?? fallback;
  if (value === undefined) { console.error('missing ' + name); process.exit(1); }
  return value;
};
const PORT = Number(env('PORT', '8096'));
const relay = crypto.createECDH('prime256v1'); relay.setPrivateKey(fromB64u(env('RELAY_PRIVATE_KEY')));
const RELAY_PUB = relay.getPublicKey(), AUTH = fromB64u(env('RELAY_AUTH'));
const APNS_KEY = fs.readFileSync(env('APNS_KEY_FILE'), 'utf8'), KID = env('APNS_KEY_ID'), TEAM = env('APNS_TEAM_ID'), TOPIC = env('APNS_TOPIC');

// The address: ephemeral public key (65) + AES-256-GCM (nonce 12, ciphertext, tag 16) of [sandbox byte] + APNs token.
// The app does the same (AgentgramPush.swift); a changed byte fails the tag.
function openAddress(sealed) {
  const data = fromB64u(sealed);
  if (data.length < 65 + 12 + 16 + 2) return null;
  const shared = relay.computeSecret(data.subarray(0, 65));
  const key = hkdf(Buffer.alloc(0), shared, Buffer.from('agentgram push token'), 32);
  const d = crypto.createDecipheriv('aes-256-gcm', key, data.subarray(65, 77));
  d.setAuthTag(data.subarray(-16));
  const plain = Buffer.concat([d.update(data.subarray(77, -16)), d.final()]);
  return { sandbox: plain[0] === 1, token: plain.subarray(1).toString('hex') };
}

// Web Push (RFC 8291 «aes128gcm», and the older «aesgcm» draft that Telegram uses)
function openWebPush(body, headers) {
  if (headers['content-encoding'] === 'aesgcm') {
    const param = (h, name) => { for (const p of String(h || '').split(/[;,]/)) { const [k, ...v] = p.trim().split('='); if (k === name) return fromB64u(v.join('=').replace(/"/g, '')); } };
    const dh = param(headers['crypto-key'], 'dh'), salt = param(headers['encryption'], 'salt');
    const ikm = hkdf(AUTH, relay.computeSecret(dh), Buffer.from('Content-Encoding: auth\0'), 32);
    const len = (b) => Buffer.from([b.length >> 8, b.length & 255]);
    const ctx = Buffer.concat([Buffer.from('P-256\0'), len(RELAY_PUB), RELAY_PUB, len(dh), dh]);
    const cek = hkdf(salt, ikm, Buffer.concat([Buffer.from('Content-Encoding: aesgcm\0'), ctx]), 16);
    const nonce = hkdf(salt, ikm, Buffer.concat([Buffer.from('Content-Encoding: nonce\0'), ctx]), 12);
    const d = crypto.createDecipheriv('aes-128-gcm', cek, nonce); d.setAuthTag(body.subarray(-16));
    const pt = Buffer.concat([d.update(body.subarray(0, -16)), d.final()]);
    return pt.subarray(2 + pt.readUInt16BE(0));
  }
  const salt = body.subarray(0, 16), idlen = body[20], keyid = body.subarray(21, 21 + idlen), ct = body.subarray(21 + idlen);
  const ikm = hkdf(AUTH, relay.computeSecret(keyid), Buffer.concat([Buffer.from('WebPush: info\0'), RELAY_PUB, keyid]), 32);
  const cek = hkdf(salt, ikm, Buffer.from('Content-Encoding: aes128gcm\0'), 16), nonce = hkdf(salt, ikm, Buffer.from('Content-Encoding: nonce\0'), 12);
  const d = crypto.createDecipheriv('aes-128-gcm', cek, nonce); d.setAuthTag(ct.subarray(-16));
  const pt = Buffer.concat([d.update(ct.subarray(0, -16)), d.final()]);
  return pt.subarray(0, pt.lastIndexOf(2));
}

// APNs: a token signed with the team's key, made again every 50 minutes; one HTTP/2 connection per environment
let jwt = null, jwtAt = 0; const conns = {};
const bearer = () => {
  if (jwt && Date.now() - jwtAt < 50 * 60e3) return jwt;
  const head = b64u(JSON.stringify({ alg: 'ES256', kid: KID })) + '.' + b64u(JSON.stringify({ iss: TEAM, iat: Math.floor(Date.now() / 1000) }));
  jwt = head + '.' + crypto.sign('sha256', Buffer.from(head), { key: APNS_KEY, dsaEncoding: 'ieee-p1363' }).toString('base64url'); jwtAt = Date.now(); return jwt;
};
const conn = (sandbox) => {
  const e = sandbox ? 'sandbox' : 'prod', c = conns[e]; if (c && !c.closed && !c.destroyed) return c;
  const n = http2.connect(sandbox ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com', { family: 4 });
  n.on('error', () => {}); n.on('close', () => { if (conns[e] === n) delete conns[e]; }); conns[e] = n; return n;
};
const apns = (device, payload) => new Promise((ok) => {
  try {
    const r = conn(device.sandbox).request({ ':method': 'POST', ':path': '/3/device/' + device.token, authorization: 'bearer ' + bearer(), 'apns-topic': TOPIC, 'apns-push-type': 'alert', 'apns-priority': '10', 'content-type': 'application/json' });
    let data = ''; r.setTimeout(10000, () => { r.close(); ok({ status: 0 }); });
    r.on('response', (h) => { r.on('data', (c) => { data += c; }); r.on('end', () => ok({ status: h[':status'], data })); });
    r.on('error', (e) => ok({ status: 0, data: e.message })); r.end(JSON.stringify(payload));
  } catch (e) { ok({ status: 0, data: e.message }); }
});

// At most 120 pushes a minute to one phone, counted in memory only
const counts = new Map();
setInterval(() => counts.clear(), 60e3).unref();
const allowed = (token) => { const n = (counts.get(token) || 0) + 1; counts.set(token, n); return n <= 120; };

const read = (req) => new Promise((ok) => { const c = []; let size = 0; req.on('data', (d) => { size += d.length; if (size < 16384) c.push(d); }); req.on('end', () => ok(Buffer.concat(c))); });

http.createServer(async (req, res) => {
  const done = (code) => { res.writeHead(code); res.end(); };
  try {
    const m = req.method === 'POST' && req.url.match(/^\/p\/([A-Za-z0-9_-]{100,400})$/);
    if (!m) return done(404);
    const body = await read(req);
    const device = openAddress(m[1]);
    if (!device) return done(404);
    if (body.length < 20) return done(201);   // Telegram's first, empty check
    if (!allowed(device.token)) return done(429);
    const inner = JSON.parse(openWebPush(body, req.headers).toString('utf8'));
    // Only the account-encrypted payload goes on; a push Telegram did not encrypt for the account is not passed on.
    if (typeof inner.p !== 'string') { console.error('push without the account layer, keys:', Object.keys(inner).join(',')); return done(201); }
    const r = await apns(device, { aps: { alert: { body: 'New message' }, sound: 'agentgram.caf', 'mutable-content': 1 }, p: inner.p });
    // one line per push, without anything from it: the time, Apple's answer, the size of the ciphertext
    console.log(new Date().toISOString(), 'apns', r.status, device.sandbox ? 'sandbox' : 'production', inner.p.length, (r.data || '').slice(0, 80));
    done(r.status === 410 ? 410 : 201);
  } catch (e) { console.error('relay', e.message); done(400); }
}).listen(PORT, () => console.log('agentgram push relay on', PORT));
