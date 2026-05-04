// Hasi Share — Cloudflare Worker v5
// Yenilikler: E-mail bildirimi, İndirme limiti, Dosya önizleme token

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Admin-Password',
};

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

async function hashPassword(password, salt) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt: enc.encode(salt), iterations: 100000, hash: 'SHA-256' },
    key, 256
  );
  return Array.from(new Uint8Array(bits)).map(b => b.toString(16).padStart(2,'0')).join('');
}

function checkAdmin(request, env) {
  return request.headers.get('X-Admin-Password') === env.ADMIN_PASSWORD;
}

function formatSize(bytes) {
  if (!bytes) return '—';
  if (bytes > 1e9) return (bytes/1e9).toFixed(1) + ' GB';
  if (bytes > 1e6) return (bytes/1e6).toFixed(1) + ' MB';
  if (bytes > 1e3) return (bytes/1e3).toFixed(0) + ' KB';
  return bytes + ' B';
}

// E-mail bildirimi (Resend)
async function sendDownloadNotification(env, filename, note, shareId, ip) {
  if (!env.RESEND_API_KEY) return;
  const body = {
    from: 'Hasi Share <noreply@machbar24.com>',
    to: ['h.guencavdi@hasi-elektronic.de'],
    subject: `📥 Download: ${filename}`,
    html: `
      <div style="font-family:sans-serif;max-width:480px;margin:0 auto;padding:24px;">
        <h2 style="color:#33afe2;margin-bottom:8px;">Hasi Share — Download Benachrichtigung</h2>
        <p>Eine Datei wurde heruntergeladen:</p>
        <table style="width:100%;border-collapse:collapse;margin:16px 0;">
          <tr><td style="padding:8px;color:#666;">Datei</td><td style="padding:8px;font-weight:bold;">${filename}</td></tr>
          <tr style="background:#f5f5f5;"><td style="padding:8px;color:#666;">Notiz</td><td style="padding:8px;">${note || '—'}</td></tr>
          <tr><td style="padding:8px;color:#666;">Link ID</td><td style="padding:8px;font-family:monospace;">${shareId}</td></tr>
          <tr style="background:#f5f5f5;"><td style="padding:8px;color:#666;">IP</td><td style="padding:8px;font-family:monospace;">${ip || '—'}</td></tr>
          <tr><td style="padding:8px;color:#666;">Zeit</td><td style="padding:8px;">${new Date().toLocaleString('de-DE')}</td></tr>
        </table>
        <p style="color:#999;font-size:12px;">Hasi Elektronic — share.hasi-elektronic.de</p>
      </div>
    `
  };
  try {
    await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
  } catch(e) {
    console.error('Email notification failed:', e);
  }
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS });
    }

    const url = new URL(request.url);
    const path = url.pathname;

    // GET /assets/*
    if (path.startsWith('/assets/') && request.method === 'GET') {
      const key = path.slice(1);
      const obj = await env.HASI_SHARE_R2.get(key);
      if (!obj) return json({ error: 'Not found' }, 404);
      const ext = key.split('.').pop().toLowerCase();
      const mimeMap = { png: 'image/png', jpg: 'image/jpeg', svg: 'image/svg+xml' };
      return new Response(obj.body, {
        headers: {
          'Content-Type': mimeMap[ext] || 'application/octet-stream',
          'Cache-Control': 'public, max-age=86400',
          'Access-Control-Allow-Origin': '*',
        }
      });
    }

    // POST /api/admin/login
    if (path === '/api/admin/login' && request.method === 'POST') {
      const body = await request.json();
      return json({ ok: body.password === env.ADMIN_PASSWORD });
    }

    // POST /api/admin/upload-init
    if (path === '/api/admin/upload-init' && request.method === 'POST') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const { filename, size, password, expireDays, note, maxDownloads } = await request.json();
      if (!filename || !password) return json({ ok: false, error: 'Missing fields' }, 400);

      const shareId = randomId(10);
      const fileKey = `files/${shareId}/${filename}`;
      const salt = randomId(16);
      const pwHash = await hashPassword(password, salt);
      const expiresAt = expireDays > 0
        ? new Date(Date.now() + expireDays * 86400000).toISOString() : null;
      const maxDl = parseInt(maxDownloads) || 0;

      await env.HASI_SHARE_DB.prepare(
        `INSERT INTO shares (id, file_key, filename, size, pw_hash, salt, expires_at, note, downloads, max_downloads, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, datetime('now'))`
      ).bind(shareId, fileKey, filename, size || 0, pwHash, salt, expiresAt, note || '', maxDl).run();

      const workerBase = 'https://hasi-share-api.hguencavdi.workers.dev';
      const isLarge = size && size > 95 * 1024 * 1024;
      let extra = {};

      if (isLarge) {
        const mp = await env.HASI_SHARE_R2.createMultipartUpload(fileKey, {
          httpMetadata: { contentType: 'application/octet-stream' }
        });
        extra = {
          multipart: true,
          uploadId: mp.uploadId,
          uploadPartUrl: `${workerBase}/api/admin/upload-part/${shareId}`,
          uploadCompleteUrl: `${workerBase}/api/admin/upload-complete/${shareId}`,
        };
      }

      return json({
        ok: true, shareId, fileKey,
        uploadUrl: `${workerBase}/api/admin/upload/${shareId}`,
        downloadUrl: `https://share.hasi-elektronic.de/download/?id=${shareId}`,
        ...extra,
      });
    }

    // PUT /api/admin/upload/:shareId
    if (path.startsWith('/api/admin/upload/') && !path.includes('part') && !path.includes('complete') && request.method === 'PUT') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const shareId = path.replace('/api/admin/upload/', '').split('/')[0];
      const row = await env.HASI_SHARE_DB.prepare('SELECT file_key FROM shares WHERE id = ?').bind(shareId).first();
      if (!row) return json({ ok: false, error: 'Not found' }, 404);
      const contentType = request.headers.get('Content-Type') || 'application/octet-stream';
      await env.HASI_SHARE_R2.put(row.file_key, request.body, { httpMetadata: { contentType } });
      const cl = request.headers.get('Content-Length');
      if (cl) {
        await env.HASI_SHARE_DB.prepare('UPDATE shares SET size = ? WHERE id = ?').bind(parseInt(cl), shareId).run();
      } else {
        const obj = await env.HASI_SHARE_R2.head(row.file_key);
        if (obj) await env.HASI_SHARE_DB.prepare('UPDATE shares SET size = ? WHERE id = ?').bind(obj.size, shareId).run();
      }
      return json({ ok: true, shareId });
    }

    // PUT /api/admin/upload-part/:shareId
    if (path.startsWith('/api/admin/upload-part/') && request.method === 'PUT') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const shareId = path.replace('/api/admin/upload-part/', '');
      const partNumber = parseInt(url.searchParams.get('partNumber') || '1');
      const uploadId = url.searchParams.get('uploadId');
      if (!uploadId) return json({ ok: false, error: 'Missing uploadId' }, 400);
      const row = await env.HASI_SHARE_DB.prepare('SELECT file_key FROM shares WHERE id = ?').bind(shareId).first();
      if (!row) return json({ ok: false }, 404);
      const upload = env.HASI_SHARE_R2.resumeMultipartUpload(row.file_key, uploadId);
      const part = await upload.uploadPart(partNumber, request.body);
      return json({ ok: true, partNumber, etag: part.etag });
    }

    // POST /api/admin/upload-complete/:shareId
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

    // GET /api/admin/files
    if (path === '/api/admin/files' && request.method === 'GET') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const rows = await env.HASI_SHARE_DB.prepare(
        'SELECT id, filename, size, note, expires_at AS expiresAt, downloads, max_downloads AS maxDownloads, created_at FROM shares ORDER BY created_at DESC'
      ).all();
      const files = rows.results.map(r => ({
        ...r, note: (r.note || '').replace(/__mpid:[^,]*/, '').trim()
      }));
      return json({ ok: true, files });
    }

    // DELETE /api/admin/files/:id
    if (path.startsWith('/api/admin/files/') && request.method === 'DELETE') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const id = path.replace('/api/admin/files/', '');
      const row = await env.HASI_SHARE_DB.prepare('SELECT file_key FROM shares WHERE id = ?').bind(id).first();
      if (row) {
        await env.HASI_SHARE_R2.delete(row.file_key);
        await env.HASI_SHARE_DB.prepare('DELETE FROM shares WHERE id = ?').bind(id).run();
      }
      return json({ ok: true });
    }

    // GET /api/share/:id/info
    if (path.match(/^\/api\/share\/[^/]+\/info$/) && request.method === 'GET') {
      const shareId = path.split('/')[3];
      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT id, filename, size, expires_at AS expiresAt, downloads, max_downloads AS maxDownloads FROM shares WHERE id = ?'
      ).bind(shareId).first();
      if (!row) return json({ exists: false });
      const expired = row.expiresAt && new Date(row.expiresAt) < new Date();
      const limitReached = row.maxDownloads > 0 && row.downloads >= row.maxDownloads;
      return json({ exists: true, expired, limitReached, filename: row.filename, size: row.size, expiresAt: row.expiresAt });
    }

    // POST /api/share/:id/unlock
    if (path.match(/^\/api\/share\/[^/]+\/unlock$/) && request.method === 'POST') {
      const shareId = path.split('/')[3];
      const { password } = await request.json();
      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT id, filename, size, pw_hash, salt, expires_at, downloads, max_downloads FROM shares WHERE id = ?'
      ).bind(shareId).first();
      if (!row) return json({ ok: false }, 404);
      if (row.expires_at && new Date(row.expires_at) < new Date()) return json({ ok: false, error: 'expired' }, 410);
      if (row.max_downloads > 0 && row.downloads >= row.max_downloads) return json({ ok: false, error: 'limit_reached' }, 410);
      const hash = await hashPassword(password, row.salt);
      if (hash !== row.pw_hash) return json({ ok: false }, 401);

      // Preview token da üret (PDF/resim için)
      const token = randomId(32);
      const previewToken = randomId(32);
      const tokenExp = new Date(Date.now() + 15 * 60000).toISOString();

      await env.HASI_SHARE_DB.prepare('UPDATE shares SET dl_token = ?, dl_token_exp = ?, preview_token = ? WHERE id = ?')
        .bind(token, tokenExp, previewToken, shareId).run();

      const ext = row.filename.split('.').pop().toLowerCase();
      const previewable = ['pdf', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'].includes(ext);

      return json({
        ok: true, token, previewToken: previewable ? previewToken : null,
        fileInfo: { filename: row.filename, size: row.size },
        previewable
      });
    }

    // GET /api/share/:id/preview?token=... — Dosya önizleme (inline)
    if (path.match(/^\/api\/share\/[^/]+\/preview$/) && request.method === 'GET') {
      const shareId = path.split('/')[3];
      const token = url.searchParams.get('token');
      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT file_key, filename, preview_token, dl_token_exp FROM shares WHERE id = ?'
      ).bind(shareId).first();
      if (!row) return json({ error: 'Not found' }, 404);
      if (!token || token !== row.preview_token || new Date(row.dl_token_exp) < new Date()) {
        return json({ error: 'Invalid token' }, 401);
      }
      const obj = await env.HASI_SHARE_R2.get(row.file_key);
      if (!obj) return json({ error: 'Not found' }, 404);
      const ext = row.filename.split('.').pop().toLowerCase();
      const mimeMap = {
        pdf: 'application/pdf', png: 'image/png', jpg: 'image/jpeg',
        jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', svg: 'image/svg+xml'
      };
      return new Response(obj.body, {
        headers: {
          'Content-Type': mimeMap[ext] || 'application/octet-stream',
          'Content-Disposition': 'inline',
          'Access-Control-Allow-Origin': '*',
        }
      });
    }

    // GET /api/share/:id/download?token=...
    if (path.match(/^\/api\/share\/[^/]+\/download$/) && request.method === 'GET') {
      const shareId = path.split('/')[3];
      const token = url.searchParams.get('token');
      const ip = request.headers.get('CF-Connecting-IP') || request.headers.get('X-Forwarded-For') || '—';

      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT file_key, filename, note, dl_token, dl_token_exp, expires_at, downloads, max_downloads FROM shares WHERE id = ?'
      ).bind(shareId).first();
      if (!row) return json({ error: 'Not found' }, 404);
      if (row.expires_at && new Date(row.expires_at) < new Date()) return json({ error: 'Expired' }, 410);
      if (row.max_downloads > 0 && row.downloads >= row.max_downloads) return json({ error: 'Download limit reached' }, 410);
      if (!token || token !== row.dl_token || new Date(row.dl_token_exp) < new Date()) {
        return json({ error: 'Invalid token' }, 401);
      }

      const obj = await env.HASI_SHARE_R2.get(row.file_key);
      if (!obj) return json({ error: 'File not found in storage' }, 404);

      // Download sayacını artır
      await env.HASI_SHARE_DB.prepare('UPDATE shares SET downloads = downloads + 1 WHERE id = ?').bind(shareId).run();

      // E-mail bildirimi gönder (async, download'ı bekletme)
      const notifNote = (row.note || '').replace(/__mpid:[^,]*/, '').trim();
      env.ctx?.waitUntil?.(sendDownloadNotification(env, row.filename, notifNote, shareId, ip));

      const encodedFilename = encodeURIComponent(row.filename);
      return new Response(obj.body, {
        headers: {
          'Content-Type': obj.httpMetadata?.contentType || 'application/octet-stream',
          'Content-Disposition': `attachment; filename*=UTF-8''${encodedFilename}`,
          'Content-Length': String(obj.size || ''),
          ...CORS,
        },
      });
    }

    return json({ error: 'Not found' }, 404);
  }
};
