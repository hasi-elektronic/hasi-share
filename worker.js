// Hasi Share — Cloudflare Worker v4
// Bindings: HASI_SHARE_R2 (R2), HASI_SHARE_DB (D1), ADMIN_PASSWORD (secret)

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

// R2 Multipart Upload helpers
async function startMultipartUpload(env, fileKey, contentType) {
  const upload = await env.HASI_SHARE_R2.createMultipartUpload(fileKey, {
    httpMetadata: { contentType: contentType || 'application/octet-stream' }
  });
  return { uploadId: upload.uploadId, key: upload.key };
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS });
    }

    const url = new URL(request.url);
    const path = url.pathname;

    // GET /assets/* — R2'den statik dosyaları sun
    if (path.startsWith('/assets/') && request.method === 'GET') {
      const key = path.slice(1);
      const obj = await env.HASI_SHARE_R2.get(key);
      if (!obj) return json({ error: 'Not found' }, 404);
      const ext = key.split('.').pop().toLowerCase();
      const mimeMap = { png: 'image/png', jpg: 'image/jpeg', svg: 'image/svg+xml', ico: 'image/x-icon' };
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
    // Küçük dosyalar (<100MB): uploadUrl = Worker PUT endpoint
    // Büyük dosyalar (≥100MB): multipart upload başlatır, parça URL'leri döner
    if (path === '/api/admin/upload-init' && request.method === 'POST') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const { filename, size, password, expireDays, note } = await request.json();
      if (!filename || !password) return json({ ok: false, error: 'Missing fields' }, 400);

      const shareId = randomId(10);
      const fileKey = `files/${shareId}/${filename}`;
      const salt = randomId(16);
      const pwHash = await hashPassword(password, salt);
      const expiresAt = expireDays > 0
        ? new Date(Date.now() + expireDays * 86400000).toISOString() : null;

      await env.HASI_SHARE_DB.prepare(
        `INSERT INTO shares (id, file_key, filename, size, pw_hash, salt, expires_at, note, downloads, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, datetime('now'))`
      ).bind(shareId, fileKey, filename, size || 0, pwHash, salt, expiresAt, note || '').run();

      const workerBase = 'https://hasi-share-api.hguencavdi.workers.dev';
      const isLarge = size && size > 95 * 1024 * 1024; // 95MB threshold

      let extra = {};
      if (isLarge) {
        // Multipart upload başlat
        const contentType = 'application/octet-stream';
        const mp = await startMultipartUpload(env, fileKey, contentType);
        // uploadId'yi D1'e kaydet
        await env.HASI_SHARE_DB.prepare(
          'UPDATE shares SET note = ? WHERE id = ?'
        ).bind((note || '') + `__mpid:${mp.uploadId}`, shareId).run();
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

    // PUT /api/admin/upload/:shareId — Normal upload (≤100MB)
    if (path.startsWith('/api/admin/upload/') && !path.includes('part') && !path.includes('complete') && request.method === 'PUT') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const shareId = path.replace('/api/admin/upload/', '').split('/')[0];
      const row = await env.HASI_SHARE_DB.prepare('SELECT file_key FROM shares WHERE id = ?').bind(shareId).first();
      if (!row) return json({ ok: false, error: 'Share not found' }, 404);

      const contentType = request.headers.get('Content-Type') || 'application/octet-stream';
      await env.HASI_SHARE_R2.put(row.file_key, request.body, { httpMetadata: { contentType } });

      const contentLength = request.headers.get('Content-Length');
      if (contentLength) {
        await env.HASI_SHARE_DB.prepare('UPDATE shares SET size = ? WHERE id = ?')
          .bind(parseInt(contentLength), shareId).run();
      } else {
        const obj = await env.HASI_SHARE_R2.head(row.file_key);
        if (obj) await env.HASI_SHARE_DB.prepare('UPDATE shares SET size = ? WHERE id = ?').bind(obj.size, shareId).run();
      }
      return json({ ok: true, shareId });
    }

    // PUT /api/admin/upload-part/:shareId — Multipart parça yükle
    // Query: ?partNumber=1&uploadId=xxx
    if (path.startsWith('/api/admin/upload-part/') && request.method === 'PUT') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const shareId = path.replace('/api/admin/upload-part/', '');
      const partNumber = parseInt(url.searchParams.get('partNumber') || '1');
      const uploadId = url.searchParams.get('uploadId');
      if (!uploadId) return json({ ok: false, error: 'Missing uploadId' }, 400);

      const row = await env.HASI_SHARE_DB.prepare('SELECT file_key FROM shares WHERE id = ?').bind(shareId).first();
      if (!row) return json({ ok: false, error: 'Not found' }, 404);

      // R2 multipart upload nesnesini yeniden aç
      const upload = env.HASI_SHARE_R2.resumeMultipartUpload(row.file_key, uploadId);
      const part = await upload.uploadPart(partNumber, request.body);

      return json({ ok: true, partNumber, etag: part.etag });
    }

    // POST /api/admin/upload-complete/:shareId — Multipart tamamla
    if (path.startsWith('/api/admin/upload-complete/') && request.method === 'POST') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const shareId = path.replace('/api/admin/upload-complete/', '');
      const { uploadId, parts, size } = await request.json();

      const row = await env.HASI_SHARE_DB.prepare('SELECT file_key FROM shares WHERE id = ?').bind(shareId).first();
      if (!row) return json({ ok: false, error: 'Not found' }, 404);

      const upload = env.HASI_SHARE_R2.resumeMultipartUpload(row.file_key, uploadId);
      await upload.complete(parts); // parts: [{partNumber, etag}]

      if (size) {
        await env.HASI_SHARE_DB.prepare('UPDATE shares SET size = ? WHERE id = ?').bind(size, shareId).run();
      }
      return json({ ok: true, shareId });
    }

    // GET /api/admin/files
    if (path === '/api/admin/files' && request.method === 'GET') {
      if (!checkAdmin(request, env)) return json({ ok: false }, 401);
      const rows = await env.HASI_SHARE_DB.prepare(
        'SELECT id, filename, size, note, expires_at AS expiresAt, downloads, created_at FROM shares ORDER BY created_at DESC'
      ).all();
      // note'tan __mpid: kısmını temizle
      const files = rows.results.map(r => ({
        ...r,
        note: (r.note || '').replace(/__mpid:[^,]*/, '').trim()
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
        'SELECT id, filename, size, expires_at AS expiresAt FROM shares WHERE id = ?'
      ).bind(shareId).first();
      if (!row) return json({ exists: false });
      const expired = row.expiresAt && new Date(row.expiresAt) < new Date();
      return json({ exists: true, expired, filename: row.filename, size: row.size, expiresAt: row.expiresAt });
    }

    // POST /api/share/:id/unlock
    if (path.match(/^\/api\/share\/[^/]+\/unlock$/) && request.method === 'POST') {
      const shareId = path.split('/')[3];
      const { password } = await request.json();
      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT id, filename, size, pw_hash, salt, expires_at FROM shares WHERE id = ?'
      ).bind(shareId).first();
      if (!row) return json({ ok: false }, 404);
      if (row.expires_at && new Date(row.expires_at) < new Date()) return json({ ok: false, error: 'expired' }, 410);
      const hash = await hashPassword(password, row.salt);
      if (hash !== row.pw_hash) return json({ ok: false }, 401);
      const token = randomId(32);
      const tokenExp = new Date(Date.now() + 15 * 60000).toISOString();
      await env.HASI_SHARE_DB.prepare('UPDATE shares SET dl_token = ?, dl_token_exp = ? WHERE id = ?')
        .bind(token, tokenExp, shareId).run();
      return json({ ok: true, token, fileInfo: { filename: row.filename, size: row.size } });
    }

    // GET /api/share/:id/download?token=...
    if (path.match(/^\/api\/share\/[^/]+\/download$/) && request.method === 'GET') {
      const shareId = path.split('/')[3];
      const token = url.searchParams.get('token');
      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT file_key, filename, dl_token, dl_token_exp, expires_at FROM shares WHERE id = ?'
      ).bind(shareId).first();
      if (!row) return json({ error: 'Not found' }, 404);
      if (row.expires_at && new Date(row.expires_at) < new Date()) return json({ error: 'Expired' }, 410);
      if (!token || token !== row.dl_token || new Date(row.dl_token_exp) < new Date()) {
        return json({ error: 'Invalid token' }, 401);
      }
      const obj = await env.HASI_SHARE_R2.get(row.file_key);
      if (!obj) return json({ error: 'File not found in storage' }, 404);
      await env.HASI_SHARE_DB.prepare('UPDATE shares SET downloads = downloads + 1 WHERE id = ?').bind(shareId).run();
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
