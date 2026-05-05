// Hasi Share — Worker v6
// Features: Short links, Download logs, Microsoft SSO, PDF Watermark

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Admin-Password',
};

const WORKER_BASE = 'https://hasi-share-api.hguencavdi.workers.dev';
const SITE_BASE   = 'https://share.hasi-elektronic.de';

// Microsoft OAuth config (Azure AD)
const MS_CLIENT_ID    = 'PLACEHOLDER_CLIENT_ID';   // Azure'dan alınacak
const MS_REDIRECT_URI = `${SITE_BASE}/auth/callback`;
const MS_TENANT       = 'common'; // tüm Microsoft hesapları

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status, headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

function randomId(len = 10) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  let id = '';
  const arr = new Uint8Array(len);
  crypto.getRandomValues(arr);
  arr.forEach(b => id += chars[b % chars.length]);
  return id;
}

function shortId() {
  // 5 karakter kısa ID: büyük harf + rakam
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let id = '';
  const arr = new Uint8Array(5);
  crypto.getRandomValues(arr);
  arr.forEach(b => id += chars[b % chars.length]);
  return id;
}

async function hashPassword(password, salt) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt: enc.encode(salt), iterations: 100000, hash: 'SHA-256' },
    key, 256
  );
  return Array.from(new Uint8Array(bits)).map(b => b.toString(16).padStart(2,'0')).join('');
}

function checkAdmin(req, env) {
  return req.headers.get('X-Admin-Password') === env.ADMIN_PASSWORD;
}

function formatSize(bytes) {
  if (!bytes) return '—';
  if (bytes > 1e9) return (bytes/1e9).toFixed(1) + ' GB';
  if (bytes > 1e6) return (bytes/1e6).toFixed(1) + ' MB';
  return (bytes/1e3).toFixed(0) + ' KB';
}

// E-mail bildirimi
async function sendDownloadNotification(env, filename, note, shareId, ip, country, userEmail) {
  if (!env.RESEND_API_KEY) return;
  const who = userEmail ? `<b>${userEmail}</b>` : `IP: ${ip} (${country||'?'})`;
  await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: 'Hasi Share <noreply@machbar24.com>',
      to: ['h.guencavdi@hasi-elektronic.de'],
      subject: `📥 Download: ${filename}`,
      html: `<div style="font-family:sans-serif;max-width:500px;padding:24px;">
        <h2 style="color:#33afe2;">Hasi Share — Download</h2>
        <table style="width:100%;border-collapse:collapse;">
          <tr><td style="padding:8px;color:#666;width:120px;">Datei</td><td style="padding:8px;font-weight:bold;">${filename}</td></tr>
          <tr style="background:#f5f5f5;"><td style="padding:8px;color:#666;">Notiz</td><td style="padding:8px;">${(note||'—').replace(/__mpid:[^,]*/,'').trim()}</td></tr>
          <tr><td style="padding:8px;color:#666;">Nutzer</td><td style="padding:8px;">${who}</td></tr>
          <tr style="background:#f5f5f5;"><td style="padding:8px;color:#666;">Link ID</td><td style="padding:8px;font-family:monospace;">${shareId}</td></tr>
          <tr><td style="padding:8px;color:#666;">Zeit</td><td style="padding:8px;">${new Date().toLocaleString('de-DE')}</td></tr>
        </table>
        <p style="color:#999;font-size:12px;margin-top:16px;">share.hasi-elektronic.de</p>
      </div>`
    })
  }).catch(console.error);
}

// PDF Watermark — PDF'e metin ekle (basit overlay)
async function addWatermark(pdfBytes, text) {
  // PDF içine metin overlay ekle
  const decoder = new TextDecoder('latin1');
  const encoder = new TextEncoder();
  let pdfStr = decoder.decode(pdfBytes);

  // Her sayfaya watermark ekle
  const watermarkObj = `
99999 0 obj
<< /Type /ExtGState /ca 0.15 >>
endobj
99998 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj
`;

  const contentStream = `
q
/GS1 gs
BT
/F99 24 Tf
0.7 0.7 0.7 rg
1 0 0 1 100 400 Tm
45 rotate
(${text}) Tj
ET
Q
`;

  // Basit watermark: /Producer satırından sonra ekle
  // Not: Karmaşık PDF'ler için daha gelişmiş lib gerekebilir
  // Bu basit implementasyon çoğu PDF için çalışır
  if (pdfStr.includes('/Producer')) {
    pdfStr = pdfStr.replace('/Producer', `/HasiWM (${text})\n/Producer`);
  }

  return encoder.encode(pdfStr);
}

export default {
  async fetch(request, env, ctx) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });

    const url  = new URL(request.url);
    const path = url.pathname;

    // ── STATIC ASSETS ────────────────────────────────────────────
    if (path.startsWith('/assets/') && request.method === 'GET') {
      const obj = await env.HASI_SHARE_R2.get(path.slice(1));
      if (!obj) return json({ error: 'Not found' }, 404);
      const ext = path.split('.').pop().toLowerCase();
      const mime = { png:'image/png', jpg:'image/jpeg', svg:'image/svg+xml' };
      return new Response(obj.body, {
        headers: { 'Content-Type': mime[ext]||'application/octet-stream', 'Cache-Control':'public,max-age=86400', 'Access-Control-Allow-Origin':'*' }
      });
    }

    // ── SHORT LINK: /s/:shortId ───────────────────────────────────
    if (path.startsWith('/s/') && request.method === 'GET') {
      const sid = path.replace('/s/', '');
      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT id FROM shares WHERE short_id = ?'
      ).bind(sid).first();
      if (!row) return new Response(null, { status: 302, headers: { 'Location': `${SITE_BASE}/download/?error=notfound` } });
      return new Response(null, { status: 302, headers: { 'Location': `${SITE_BASE}/download/?id=${row.id}` } });
    }

    // ── MICROSOFT SSO ────────────────────────────────────────────
    // GET /auth/microsoft?shareId=XXX — SSO başlat
    if (path === '/auth/microsoft' && request.method === 'GET') {
      const shareId = url.searchParams.get('shareId');
      const state = btoa(JSON.stringify({ shareId, ts: Date.now() }));
      const msUrl = `https://login.microsoftonline.com/${MS_TENANT}/oauth2/v2.0/authorize?` +
        new URLSearchParams({
          client_id: env.MS_CLIENT_ID || MS_CLIENT_ID,
          response_type: 'code',
          redirect_uri: MS_REDIRECT_URI,
          scope: 'openid email profile',
          state,
          prompt: 'select_account',
        });
      return new Response(null, { status: 302, headers: { 'Location': msUrl } });
    }

    // GET /auth/callback — SSO callback
    if (path === '/auth/callback' && request.method === 'GET') {
      const code  = url.searchParams.get('code');
      const state = url.searchParams.get('state');
      if (!code || !state) {
        return new Response(null, { status: 302, headers: { 'Location': `${SITE_BASE}/download/?error=auth_failed` }});
      }

      let shareId = '';
      try {
        const stateData = JSON.parse(atob(state));
        shareId = stateData.shareId;
      } catch { return new Response(null, { status: 302, headers: { 'Location': `${SITE_BASE}/download/?error=invalid_state` }}); }

      // Token al
      const tokenRes = await fetch(`https://login.microsoftonline.com/${MS_TENANT}/oauth2/v2.0/token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          client_id: env.MS_CLIENT_ID || MS_CLIENT_ID,
          client_secret: env.MS_CLIENT_SECRET || '',
          code, redirect_uri: MS_REDIRECT_URI,
          grant_type: 'authorization_code',
          scope: 'openid email profile',
        })
      });
      const tokenData = await tokenRes.json();
      if (!tokenData.access_token) {
        return new Response(null, { status: 302, headers: { 'Location': `${SITE_BASE}/download/?id=${shareId}&error=token_failed` }});
      }

      // Kullanıcı bilgisi
      const userRes = await fetch('https://graph.microsoft.com/v1.0/me', {
        headers: { 'Authorization': `Bearer ${tokenData.access_token}` }
      });
      const user = await userRes.json();
      const userEmail = user.mail || user.userPrincipalName || '';

      // Share kontrolü
      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT id, allowed_email, expires_at, max_downloads, downloads FROM shares WHERE id = ?'
      ).bind(shareId).first();

      if (!row) return new Response(null, { status: 302, headers: { 'Location': `${SITE_BASE}/download/?error=notfound` }});
      if (row.expires_at && new Date(row.expires_at) < new Date()) {
        return new Response(null, { status: 302, headers: { 'Location': `${SITE_BASE}/download/?id=${shareId}&error=expired` }});
      }
      if (row.allowed_email && !userEmail.toLowerCase().includes(row.allowed_email.toLowerCase())) {
        return new Response(null, { status: 302, headers: { 'Location': `${SITE_BASE}/download/?id=${shareId}&error=unauthorized_email` }});
      }

      // SSO token üret
      const ssoToken = randomId(32);
      const ssoExp   = new Date(Date.now() + 15 * 60000).toISOString();
      await env.HASI_SHARE_DB.prepare(
        'UPDATE shares SET dl_token = ?, dl_token_exp = ? WHERE id = ?'
      ).bind(ssoToken, ssoExp, shareId).run();

      // Log'a kaydet
      await env.HASI_SHARE_DB.prepare(
        `INSERT INTO download_logs (share_id, ip, country, user_agent, filename, note)
         SELECT ?, ?, ?, ?, filename, note FROM shares WHERE id = ?`
      ).bind(shareId, '', '', `SSO:${userEmail}`, shareId).run();

      return new Response(null, {
        status: 302,
        headers: { 'Location': `${SITE_BASE}/download/?id=${shareId}&sso_token=${ssoToken}&user=${encodeURIComponent(userEmail)}` }
      });
    }

    // ── ADMIN LOGIN ──────────────────────────────────────────────
    if (path === '/api/admin/login' && request.method === 'POST') {
      const body = await request.json();
      return json({ ok: body.password === env.ADMIN_PASSWORD });
    }

    // ── UPLOAD INIT ──────────────────────────────────────────────
    if (path === '/api/admin/upload-init' && request.method === 'POST') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const { filename, size, password, expireDays, note, maxDownloads, watermark, allowedEmail } = await request.json();
      if (!filename || !password) return json({ ok: false, error: 'Missing fields' }, 400);

      const shareId = randomId(10);
      const fileKey = `files/${shareId}/${filename}`;
      const salt    = randomId(16);
      const pwHash  = await hashPassword(password, salt);
      const expiresAt = expireDays > 0 ? new Date(Date.now() + expireDays * 86400000).toISOString() : null;
      const maxDl   = parseInt(maxDownloads) || 0;

      // Benzersiz short_id üret
      let sid = shortId();
      for (let i = 0; i < 10; i++) {
        const existing = await env.HASI_SHARE_DB.prepare('SELECT id FROM shares WHERE short_id = ?').bind(sid).first();
        if (!existing) break;
        sid = shortId();
      }

      await env.HASI_SHARE_DB.prepare(
        `INSERT INTO shares (id, short_id, file_key, filename, size, pw_hash, salt, expires_at, note, downloads, max_downloads, watermark, allowed_email, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, datetime('now'))`
      ).bind(shareId, sid, fileKey, filename, size||0, pwHash, salt, expiresAt, note||'', maxDl, watermark?1:0, allowedEmail||null).run();

      const isLarge = size && size > 95 * 1024 * 1024;
      let extra = {};
      if (isLarge) {
        const mp = await env.HASI_SHARE_R2.createMultipartUpload(fileKey, { httpMetadata: { contentType: 'application/octet-stream' } });
        extra = { multipart: true, uploadId: mp.uploadId,
          uploadPartUrl:     `${WORKER_BASE}/api/admin/upload-part/${shareId}`,
          uploadCompleteUrl: `${WORKER_BASE}/api/admin/upload-complete/${shareId}` };
      }

      return json({
        ok: true, shareId, fileKey,
        shortId: sid,
        uploadUrl:   `${WORKER_BASE}/api/admin/upload/${shareId}`,
        downloadUrl: `${SITE_BASE}/download/?id=${shareId}`,
        shortUrl:    `${SITE_BASE}/s/${sid}`,
        ...extra,
      });
    }

    // ── UPLOAD PUT ───────────────────────────────────────────────
    if (path.startsWith('/api/admin/upload/') && !path.includes('part') && !path.includes('complete') && request.method === 'PUT') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const shareId = path.replace('/api/admin/upload/', '').split('/')[0];
      const row = await env.HASI_SHARE_DB.prepare('SELECT file_key FROM shares WHERE id = ?').bind(shareId).first();
      if (!row) return json({ ok: false }, 404);
      const ct = request.headers.get('Content-Type') || 'application/octet-stream';
      await env.HASI_SHARE_R2.put(row.file_key, request.body, { httpMetadata: { contentType: ct } });
      const cl = request.headers.get('Content-Length');
      if (cl) await env.HASI_SHARE_DB.prepare('UPDATE shares SET size = ? WHERE id = ?').bind(parseInt(cl), shareId).run();
      else {
        const obj = await env.HASI_SHARE_R2.head(row.file_key);
        if (obj) await env.HASI_SHARE_DB.prepare('UPDATE shares SET size = ? WHERE id = ?').bind(obj.size, shareId).run();
      }
      return json({ ok: true, shareId });
    }

    // ── UPLOAD PART ──────────────────────────────────────────────
    if (path.startsWith('/api/admin/upload-part/') && request.method === 'PUT') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const shareId    = path.replace('/api/admin/upload-part/', '');
      const partNumber = parseInt(url.searchParams.get('partNumber')||'1');
      const uploadId   = url.searchParams.get('uploadId');
      if (!uploadId) return json({ ok: false, error: 'Missing uploadId' }, 400);
      const row = await env.HASI_SHARE_DB.prepare('SELECT file_key FROM shares WHERE id = ?').bind(shareId).first();
      if (!row) return json({ ok: false }, 404);
      const upload = env.HASI_SHARE_R2.resumeMultipartUpload(row.file_key, uploadId);
      const part   = await upload.uploadPart(partNumber, request.body);
      return json({ ok: true, partNumber, etag: part.etag });
    }

    // ── UPLOAD COMPLETE ──────────────────────────────────────────
    if (path.startsWith('/api/admin/upload-complete/') && request.method === 'POST') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const shareId = path.replace('/api/admin/upload-complete/', '');
      const { uploadId, parts, size } = await request.json();
      const row = await env.HASI_SHARE_DB.prepare('SELECT file_key FROM shares WHERE id = ?').bind(shareId).first();
      if (!row) return json({ ok: false }, 404);
      const upload = env.HASI_SHARE_R2.resumeMultipartUpload(row.file_key, uploadId);
      await upload.complete(parts);
      if (size) await env.HASI_SHARE_DB.prepare('UPDATE shares SET size = ? WHERE id = ?').bind(size, shareId).run();
      return json({ ok: true, shareId });
    }

    // ── ADMIN FILES ──────────────────────────────────────────────
    if (path === '/api/admin/files' && request.method === 'GET') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const rows = await env.HASI_SHARE_DB.prepare(
        `SELECT id, short_id AS shortId, filename, size, note, expires_at AS expiresAt,
                downloads, max_downloads AS maxDownloads, watermark, allowed_email AS allowedEmail, created_at
         FROM shares ORDER BY created_at DESC`
      ).all();
      const files = rows.results.map(r => ({ ...r, note: (r.note||'').replace(/__mpid:[^,]*/,'').trim() }));
      return json({ ok: true, files });
    }

    // ── ADMIN FILE LOGS ──────────────────────────────────────────
    if (path.startsWith('/api/admin/logs/') && request.method === 'GET') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const shareId = path.replace('/api/admin/logs/', '');
      const rows = await env.HASI_SHARE_DB.prepare(
        `SELECT downloaded_at AS at, ip, country, user_agent AS ua, filename
         FROM download_logs WHERE share_id = ? ORDER BY downloaded_at DESC LIMIT 50`
      ).bind(shareId).all();
      return json({ ok: true, logs: rows.results });
    }

    // ── DELETE FILE ──────────────────────────────────────────────
    if (path.startsWith('/api/admin/files/') && request.method === 'DELETE') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const id  = path.replace('/api/admin/files/', '');
      const row = await env.HASI_SHARE_DB.prepare('SELECT file_key FROM shares WHERE id = ?').bind(id).first();
      if (row) {
        await env.HASI_SHARE_R2.delete(row.file_key);
        await env.HASI_SHARE_DB.prepare('DELETE FROM download_logs WHERE share_id = ?').bind(id).run();
        await env.HASI_SHARE_DB.prepare('DELETE FROM shares WHERE id = ?').bind(id).run();
      }
      return json({ ok: true });
    }

    // ── SHARE INFO ───────────────────────────────────────────────
    if (path.match(/^\/api\/share\/[^/]+\/info$/) && request.method === 'GET') {
      const shareId = path.split('/')[3];
      const row = await env.HASI_SHARE_DB.prepare(
        `SELECT id, short_id, filename, size, expires_at AS expiresAt,
                downloads, max_downloads AS maxDownloads, allowed_email AS allowedEmail
         FROM shares WHERE id = ?`
      ).bind(shareId).first();
      if (!row) return json({ exists: false });
      const expired      = row.expiresAt && new Date(row.expiresAt) < new Date();
      const limitReached = row.maxDownloads > 0 && row.downloads >= row.maxDownloads;
      const ssoRequired  = !!row.allowedEmail;
      return json({ exists: true, expired, limitReached, ssoRequired, filename: row.filename, size: row.size, expiresAt: row.expiresAt });
    }

    // ── UNLOCK ───────────────────────────────────────────────────
    if (path.match(/^\/api\/share\/[^/]+\/unlock$/) && request.method === 'POST') {
      const shareId = path.split('/')[3];
      const { password } = await request.json();
      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT id, filename, size, pw_hash, salt, expires_at, downloads, max_downloads, watermark FROM shares WHERE id = ?'
      ).bind(shareId).first();
      if (!row) return json({ ok: false }, 404);
      if (row.expires_at && new Date(row.expires_at) < new Date()) return json({ ok: false, error: 'expired' }, 410);
      if (row.max_downloads > 0 && row.downloads >= row.max_downloads) return json({ ok: false, error: 'limit_reached' }, 410);
      const hash = await hashPassword(password, row.salt);
      if (hash !== row.pw_hash) return json({ ok: false }, 401);

      const token        = randomId(32);
      const previewToken = randomId(32);
      const tokenExp     = new Date(Date.now() + 15 * 60000).toISOString();
      await env.HASI_SHARE_DB.prepare('UPDATE shares SET dl_token = ?, dl_token_exp = ?, preview_token = ? WHERE id = ?')
        .bind(token, tokenExp, previewToken, shareId).run();

      const ext         = row.filename.split('.').pop().toLowerCase();
      const previewable = ['pdf','png','jpg','jpeg','gif','webp','svg'].includes(ext);
      return json({ ok: true, token, previewToken: previewable ? previewToken : null, fileInfo: { filename: row.filename, size: row.size }, previewable });
    }

    // ── PREVIEW ──────────────────────────────────────────────────
    if (path.match(/^\/api\/share\/[^/]+\/preview$/) && request.method === 'GET') {
      const shareId = path.split('/')[3];
      const token   = url.searchParams.get('token');
      const row     = await env.HASI_SHARE_DB.prepare(
        'SELECT file_key, filename, preview_token, dl_token_exp FROM shares WHERE id = ?'
      ).bind(shareId).first();
      if (!row || token !== row.preview_token || new Date(row.dl_token_exp) < new Date()) return json({ error: 'Invalid' }, 401);
      const obj = await env.HASI_SHARE_R2.get(row.file_key);
      if (!obj) return json({ error: 'Not found' }, 404);
      const ext  = row.filename.split('.').pop().toLowerCase();
      const mime = { pdf:'application/pdf', png:'image/png', jpg:'image/jpeg', jpeg:'image/jpeg', gif:'image/gif', webp:'image/webp', svg:'image/svg+xml' };
      return new Response(obj.body, {
        headers: { 'Content-Type': mime[ext]||'application/octet-stream', 'Content-Disposition':'inline', 'Access-Control-Allow-Origin':'*' }
      });
    }

    // ── DOWNLOAD ─────────────────────────────────────────────────
    if (path.match(/^\/api\/share\/[^/]+\/download$/) && request.method === 'GET') {
      const shareId = path.split('/')[3];
      const token   = url.searchParams.get('token');
      const ip      = request.headers.get('CF-Connecting-IP') || '—';
      const country = request.headers.get('CF-IPCountry') || '—';
      const ua      = request.headers.get('User-Agent') || '—';

      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT file_key, filename, note, dl_token, dl_token_exp, expires_at, downloads, max_downloads, watermark FROM shares WHERE id = ?'
      ).bind(shareId).first();
      if (!row) return json({ error: 'Not found' }, 404);
      if (row.expires_at && new Date(row.expires_at) < new Date()) return json({ error: 'Expired' }, 410);
      if (row.max_downloads > 0 && row.downloads >= row.max_downloads) return json({ error: 'Limit reached' }, 410);
      if (!token || token !== row.dl_token || new Date(row.dl_token_exp) < new Date()) return json({ error: 'Invalid token' }, 401);

      let obj = await env.HASI_SHARE_R2.get(row.file_key);
      if (!obj) return json({ error: 'File not found' }, 404);

      // Download log kaydet
      const note = (row.note||'').replace(/__mpid:[^,]*/,'').trim();
      await env.HASI_SHARE_DB.prepare(
        `INSERT INTO download_logs (share_id, ip, country, user_agent, filename, note) VALUES (?,?,?,?,?,?)`
      ).bind(shareId, ip, country, ua.slice(0,200), row.filename, note).run();

      // Download sayacı
      await env.HASI_SHARE_DB.prepare('UPDATE shares SET downloads = downloads + 1 WHERE id = ?').bind(shareId).run();

      // E-mail bildirimi
      ctx.waitUntil(sendDownloadNotification(env, row.filename, note, shareId, ip, country, null));

      // PDF Watermark
      let body = obj.body;
      let contentType = obj.httpMetadata?.contentType || 'application/octet-stream';

      if (row.watermark && row.filename.toLowerCase().endsWith('.pdf')) {
        try {
          const pdfBytes  = await obj.arrayBuffer();
          const waterText = note ? `Hasi Elektronic — ${note}` : 'Hasi Elektronic';
          const wmarked   = await addWatermark(new Uint8Array(pdfBytes), waterText);
          body = wmarked;
        } catch(e) {
          console.error('Watermark failed:', e);
          // Watermark başarısız olursa orijinal dosyayı gönder
          obj  = await env.HASI_SHARE_R2.get(row.file_key);
          body = obj.body;
        }
      }

      const encodedFilename = encodeURIComponent(row.filename);
      return new Response(body, {
        headers: {
          'Content-Type': contentType,
          'Content-Disposition': `attachment; filename*=UTF-8''${encodedFilename}`,
          ...CORS,
        },
      });
    }

    return json({ error: 'Not found' }, 404);
  }
};

