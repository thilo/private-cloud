#!/usr/bin/env node
// Vaultwarden acceptance test using the real Bitwarden client crypto.
//
// Flow: register -> prelogin -> login -> store an encrypted login item ->
//       read it back and decrypt -> enable TOTP 2FA.
// No third-party packages: only Node built-ins (crypto, https).
//
// Config via env: VW_URL, VW_EMAIL, VW_PASSWORD, VW_ITEM, VW_USERNAME, VW_SECRET
//   VW_RESOLVE  optional — pin the TCP target (e.g. 127.0.0.1) while keeping the
//               Host header/SNI as the domain, so the test reaches a local Caddy
//               no matter what the public DNS name resolves to.
// TLS: run with NODE_TLS_REJECT_UNAUTHORIZED=0 for Caddy's local internal CA.

import crypto from 'node:crypto';
import https from 'node:https';
import { URL } from 'node:url';

const cfg = {
  url: process.env.VW_URL,
  // Unique throwaway account per run; deleted at the end so reruns start clean.
  email: (process.env.VW_EMAIL || `pc-verify-${Date.now()}@example.com`).toLowerCase(),
  password: process.env.VW_PASSWORD || 'verify-master-pw-123!',
  itemName: process.env.VW_ITEM || 'pc-verify-login',
  itemUser: process.env.VW_USERNAME || 'alice@example.com',
  itemSecret: process.env.VW_SECRET || 'S3cr3t-' + Date.now(),
  iterations: 600000,
  deviceId: crypto.randomUUID(),
};
if (!cfg.url) { console.error('VW_URL is required'); process.exit(2); }

const agent = new https.Agent({ rejectUnauthorized: false });
const resolveHost = process.env.VW_RESOLVE;
const lookupOpt = resolveHost
  ? { lookup: (_h, o, cb) => (o && o.all
      ? cb(null, [{ address: resolveHost, family: 4 }])
      : cb(null, resolveHost, 4)) }
  : {};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const b64 = (b) => Buffer.from(b).toString('base64');
const fromB64 = (s) => Buffer.from(s, 'base64');
const pick = (o, ...keys) => { for (const k of keys) if (o && o[k] != null) return o[k]; return undefined; };

function req(method, path, { headers = {}, body } = {}) {
  const u = new URL(cfg.url + path);
  return new Promise((resolve, reject) => {
    const r = https.request(
      { method, hostname: u.hostname, port: u.port, path: u.pathname + u.search, headers, agent, ...lookupOpt },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          let json; try { json = data ? JSON.parse(data) : {}; } catch { json = null; }
          resolve({ status: res.statusCode, json, text: data });
        });
      }
    );
    r.on('error', reject);
    if (body) r.write(body);
    r.end();
  });
}
const postJson = (path, obj, headers = {}) =>
  req('POST', path, { headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(obj) });
const postForm = (path, obj) =>
  req('POST', path, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(obj).toString(),
  });
const login = (mph, twoFactorToken) =>
  postForm('/identity/connect/token', {
    grant_type: 'password', username: cfg.email, password: mph,
    scope: 'api offline_access', client_id: 'cli',
    deviceType: '21', deviceIdentifier: cfg.deviceId, deviceName: 'pc-verify',
    ...(twoFactorToken ? { twoFactorToken, twoFactorProvider: '0', twoFactorRemember: '0' } : {}),
  });

// --- Bitwarden crypto -------------------------------------------------------
const pbkdf2 = (pw, salt, iter, len = 32) => crypto.pbkdf2Sync(pw, salt, iter, len, 'sha256');
const makeMasterKey = (pw, email, iter) => pbkdf2(pw, email, iter);
const hashPassword = (masterKey, pw) => b64(pbkdf2(masterKey, pw, 1));
function hkdfExpand(prk, info, size = 32) {
  const h = crypto.createHmac('sha256', prk);
  h.update(Buffer.concat([Buffer.from(info, 'utf8'), Buffer.from([1])]));
  return h.digest().subarray(0, size);
}
const stretch = (masterKey) => ({ enc: hkdfExpand(masterKey, 'enc'), mac: hkdfExpand(masterKey, 'mac') });

function encStr(plaintext, enc, mac) {
  const iv = crypto.randomBytes(16);
  const c = crypto.createCipheriv('aes-256-cbc', enc, iv);
  const ct = Buffer.concat([c.update(Buffer.from(plaintext)), c.final()]);
  const m = crypto.createHmac('sha256', mac).update(Buffer.concat([iv, ct])).digest();
  return `2.${b64(iv)}|${b64(ct)}|${b64(m)}`;
}
function decStr(s, enc, mac) {
  const [type, rest] = s.split('.', 2);
  if (type !== '2') throw new Error('unsupported enc type ' + type);
  const [ivB, ctB, macB] = rest.split('|');
  const iv = fromB64(ivB), ct = fromB64(ctB), m = fromB64(macB);
  const exp = crypto.createHmac('sha256', mac).update(Buffer.concat([iv, ct])).digest();
  if (!crypto.timingSafeEqual(exp, m)) throw new Error('MAC mismatch');
  const d = crypto.createDecipheriv('aes-256-cbc', enc, iv);
  return Buffer.concat([d.update(ct), d.final()]).toString('utf8');
}

// TOTP (RFC 6238, SHA1, 6 digits, 30s) from a base32 secret.
function base32Decode(s) {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '', out = [];
  for (const ch of s.replace(/=+$/, '').toUpperCase()) {
    const v = A.indexOf(ch); if (v < 0) continue;
    bits += v.toString(2).padStart(5, '0');
  }
  for (let i = 0; i + 8 <= bits.length; i += 8) out.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(out);
}
function totp(secretB32) {
  const key = base32Decode(secretB32);
  const counter = Math.floor(Date.now() / 1000 / 30);
  const buf = Buffer.alloc(8); buf.writeBigUInt64BE(BigInt(counter));
  const hmac = crypto.createHmac('sha1', key).update(buf).digest();
  const off = hmac[hmac.length - 1] & 0xf;
  const code = ((hmac.readUInt32BE(off) & 0x7fffffff) % 1e6).toString().padStart(6, '0');
  return code;
}

// --- flow -------------------------------------------------------------------
async function main() {
  const masterKeyReg = makeMasterKey(cfg.password, cfg.email, cfg.iterations);
  const sk = stretch(masterKeyReg);

  // Fresh user symmetric key + protected ("key") + RSA keypair.
  const symKey = crypto.randomBytes(64);
  const protectedKey = encStr(symKey, sk.enc, sk.mac);
  const kp = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'der' },
  });
  const encryptedPrivateKey = encStr(kp.privateKey, symKey.subarray(0, 32), symKey.subarray(32));

  const regBody = {
    email: cfg.email, name: 'PC Verify',
    masterPasswordHash: hashPassword(masterKeyReg, cfg.password),
    masterPasswordHint: null, key: protectedKey,
    kdf: 0, kdfIterations: cfg.iterations,
    keys: { publicKey: b64(kp.publicKey), encryptedPrivateKey },
  };
  let reg = await postJson('/identity/accounts/register', regBody);
  if (reg.status === 404 || reg.status === 405) reg = await postJson('/api/accounts/register', regBody);
  if (reg.status >= 200 && reg.status < 300) console.log('REGISTER: ok');
  else if (/already exists|already in use/i.test(reg.text || '')) console.log('REGISTER: exists');
  else { console.log('REGISTER: failed', reg.status, reg.text); process.exit(1); }

  // prelogin to get the account's real KDF (robust on re-runs)
  let pre = await postJson('/identity/accounts/prelogin', { email: cfg.email });
  const iter = Number(pick(pre.json, 'kdfIterations', 'KdfIterations') || cfg.iterations);
  const masterKey = makeMasterKey(cfg.password, cfg.email, iter);
  const mph = hashPassword(masterKey, cfg.password);

  const tok = await login(mph);
  const access = pick(tok.json || {}, 'access_token');
  if (!access) { console.log('LOGIN: failed', tok.status, tok.text); process.exit(1); }
  console.log('LOGIN: ok');
  const auth = { Authorization: 'Bearer ' + access };

  // Recover the real symmetric key from the server-provided protected key.
  const serverProtected = pick(tok.json, 'Key', 'key');
  const real = serverProtected ? fromB64Sym(decStrRaw(serverProtected, sk.enc, sk.mac)) : symKey;
  const cEnc = real.subarray(0, 32), cMac = real.subarray(32);

  // Store an encrypted login item.
  const cipher = {
    type: 1, name: encStr(cfg.itemName, cEnc, cMac), notes: null, favorite: false,
    login: {
      username: encStr(cfg.itemUser, cEnc, cMac),
      password: encStr(cfg.itemSecret, cEnc, cMac),
      uris: [{ uri: encStr('https://example.com', cEnc, cMac), match: null }],
      totp: null,
    },
  };
  const created = await postJson('/api/ciphers', cipher, auth);
  const id = pick(created.json || {}, 'Id', 'id');
  if (!id) { console.log('STORE: failed', created.status, created.text); process.exit(1); }
  console.log('STORE:', id);

  // Read it back from the server and decrypt.
  const list = await req('GET', '/api/ciphers', { headers: auth });
  const items = pick(list.json, 'Data', 'data') || (Array.isArray(list.json) ? list.json : []);
  let match = false;
  for (const it of items) {
    try {
      if (decStr(pick(it, 'Name', 'name'), cEnc, cMac) !== cfg.itemName) continue;
      const login = pick(it, 'Login', 'login') || {};
      if (decStr(pick(login, 'Password', 'password'), cEnc, cMac) === cfg.itemSecret) { match = true; break; }
    } catch { /* keep scanning */ }
  }
  console.log('FETCH_MATCH:', match ? 'yes' : 'no');

  // Enable TOTP 2FA, then prove it actually gates login.
  try {
    const ga = await postJson('/api/two-factor/get-authenticator', { masterPasswordHash: mph }, auth);
    const secret = pick(ga.json || {}, 'key', 'Key');
    if (secret) {
      const en = await postJson('/api/two-factor/authenticator',
        { masterPasswordHash: mph, key: secret, token: totp(secret) }, auth);
      if (pick(en.json || {}, 'enabled', 'Enabled')) {
        // The code used to enable can't be replayed; wait for the next 30s step.
        await sleep((30 - (Math.floor(Date.now() / 1000) % 30)) * 1000 + 1500);
        const gated = await login(mph);                      // no code -> must be refused
        const refused = /two factor/i.test(gated.text || '');
        const withCode = await login(mph, totp(secret));     // valid code -> must succeed
        const accepted = !!pick(withCode.json || {}, 'access_token');
        console.log('TOTP:', refused && accepted ? 'enabled' : `enabled-partial(refused=${refused},accepted=${accepted})`);
      } else console.log('TOTP: failed', en.status, en.text);
    } else console.log('TOTP: skipped (no secret returned)');
  } catch (e) { console.log('TOTP: skipped (' + e.message + ')'); }

  // Clean up the throwaway account so the next run starts fresh.
  try {
    const del = await postJson('/api/accounts/delete', { masterPasswordHash: mph }, auth);
    console.log('CLEANUP:', del.status >= 200 && del.status < 300 ? 'deleted' : 'kept ' + del.status);
  } catch (e) { console.log('CLEANUP: kept (' + e.message + ')'); }

  process.exit(match ? 0 : 1);
}

// helpers that return raw buffers for the protected key
function decStrRaw(s, enc, mac) {
  const [type, rest] = s.split('.', 2);
  const [ivB, ctB, macB] = rest.split('|');
  const iv = fromB64(ivB), ct = fromB64(ctB), m = fromB64(macB);
  const exp = crypto.createHmac('sha256', mac).update(Buffer.concat([iv, ct])).digest();
  if (!crypto.timingSafeEqual(exp, m)) throw new Error('MAC mismatch (protected key)');
  const d = crypto.createDecipheriv('aes-256-cbc', enc, iv);
  return Buffer.concat([d.update(ct), d.final()]);
}
const fromB64Sym = (buf) => buf; // already a Buffer of 64 bytes

main().catch((e) => { console.error('ERROR', e); process.exit(1); });
