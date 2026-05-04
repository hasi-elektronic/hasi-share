// Hasi Share — Cloudflare Worker
// Bindings: HASI_SHARE_R2 (R2), HASI_SHARE_DB (D1), ADMIN_PASSWORD (secret)

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Admin-Password',
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

function jsonErr(msg, status = 400) {
  return json({ ok: false, error: msg }, status);
}

// Random ID generator
function randomId(len = 12) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  let id = '';
  const arr = new Uint8Array(len);
  crypto.getRandomValues(arr);
  arr.forEach(b => id += chars[b % chars.length]);
  return id;
}

// Hash password with PBKDF2
async function hashPassword(password, salt) {
  const enc = new TextEncoder();
  const keyMaterial = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt: enc.encode(salt), iterations: 100000, hash: 'SHA-256' },
    keyMaterial, 256
  );
  return Array.from(new Uint8Array(bits)).map(b => b.toString(16).padStart(2,'0')).join('');
}

// Check admin password
function checkAdmin(request, env) {
  const pw = request.headers.get('X-Admin-Password');
  return pw === env.ADMIN_PASSWORD;
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS });
    }

    const url = new URL(request.url);
    const path = url.pathname;

    // ── ADMIN ROUTES ──────────────────────────────────────────────

    // POST /api/admin/login
    if (path === '/api/admin/login' && request.method === 'POST') {
      const body = await request.json();
      if (body.password === env.ADMIN_PASSWORD) {
        return json({ ok: true });
      }
      return json({ ok: false }, 401);
    }

    // POST /api/admin/upload-init
    if (path === '/api/admin/upload-init' && request.method === 'POST') {
      if (!checkAdmin(request, env)) return jsonErr('Unauthorized', 401);

      const body = await request.json();
      const { filename, size, password, expireDays, note } = body;

      if (!filename || !password) return jsonErr('filename and password required');

      const fileKey = `files/${randomId()}/${filename}`;
      const shareId = randomId(10);
      const salt = randomId(16);
      const pwHash = await hashPassword(password, salt);

      const expiresAt = expireDays > 0
        ? new Date(Date.now() + expireDays * 86400000).toISOString()
        : null;

      // Save to D1
      await env.HASI_SHARE_DB.prepare(`
        INSERT INTO shares (id, file_key, filename, size, pw_hash, salt, expires_at, note, downloads, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, datetime('now'))
      `).bind(shareId, fileKey, filename, size || 0, pwHash, salt, expiresAt, note || '').run();

      // Generate presigned R2 upload URL
      // R2 presigned URLs für PUT
      const uploadUrl = await env.HASI_SHARE_R2.createMultipartUpload
        ? null  // multipart for large files
        : null;

      // Direkte Upload-URL über Worker
      return json({
        ok: true,
        shareId,
        fileKey,
        uploadUrl: `/api/admin/upload/${shareId}`, // Worker proxied upload
        downloadUrl: `${url.origin}/d/${shareId}`,
      });
    }

    // PUT /api/admin/upload/:shareId — Datei direkt hochladen
    if (path.startsWith('/api/admin/upload/') && request.method === 'PUT') {
      if (!checkAdmin(request, env)) return jsonErr('Unauthorized', 401);

      const shareId = path.split('/').pop();
      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT file_key, size FROM shares WHERE id = ?'
      ).bind(shareId).first();

      if (!row) return jsonErr('Share not found', 404);

      const body = request.body;
      await env.HASI_SHARE_R2.put(row.file_key, body, {
        httpMetadata: { contentType: request.headers.get('Content-Type') || 'application/octet-stream' }
      });

      // Update size if not set
      const contentLength = request.headers.get('Content-Length');
      if (contentLength && !row.size) {
        await env.HASI_SHARE_DB.prepare(
          'UPDATE shares SET size = ? WHERE id = ?'
        ).bind(parseInt(contentLength), shareId).run();
      }

      return json({ ok: true });
    }

    // POST /api/admin/upload-finalize
    if (path === '/api/admin/upload-finalize' && request.method === 'POST') {
      if (!checkAdmin(request, env)) return jsonErr('Unauthorized', 401);
      const { fileKey } = await request.json();
      // Verify file exists in R2
      const obj = await env.HASI_SHARE_R2.head(fileKey);
      if (!obj) return jsonErr('File not found in R2', 404);
      return json({ ok: true });
    }

    // GET /api/admin/files
    if (path === '/api/admin/files' && request.method === 'GET') {
      if (!checkAdmin(request, env)) return jsonErr('Unauthorized', 401);

      const rows = await env.HASI_SHARE_DB.prepare(
        'SELECT id, filename, size, note, expires_at AS expiresAt, downloads, created_at FROM shares ORDER BY created_at DESC'
      ).all();

      return json({ ok: true, files: rows.results });
    }

    // DELETE /api/admin/files/:id
    if (path.startsWith('/api/admin/files/') && request.method === 'DELETE') {
      if (!checkAdmin(request, env)) return jsonErr('Unauthorized', 401);

      const id = path.split('/').pop();
      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT file_key FROM shares WHERE id = ?'
      ).bind(id).first();

      if (row) {
        // Delete from R2
        await env.HASI_SHARE_R2.delete(row.file_key);
        // Delete from D1
        await env.HASI_SHARE_DB.prepare('DELETE FROM shares WHERE id = ?').bind(id).run();
      }

      return json({ ok: true });
    }

    // ── PUBLIC ROUTES ─────────────────────────────────────────────

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

      // Check expiry
      if (row.expires_at && new Date(row.expires_at) < new Date()) {
        return json({ ok: false, error: 'expired' }, 410);
      }

      // Verify password
      const hash = await hashPassword(password, row.salt);
      if (hash !== row.pw_hash) {
        return json({ ok: false }, 401);
      }

      // Generate short-lived download token (valid 15 min)
      const token = randomId(32);
      const tokenExp = new Date(Date.now() + 15 * 60000).toISOString();

      await env.HASI_SHARE_DB.prepare(
        'UPDATE shares SET dl_token = ?, dl_token_exp = ? WHERE id = ?'
      ).bind(token, tokenExp, shareId).run();

      return json({
        ok: true,
        token,
        fileInfo: { filename: row.filename, size: row.size }
      });
    }

    // GET /api/share/:id/download?token=...
    if (path.match(/^\/api\/share\/[^/]+\/download$/) && request.method === 'GET') {
      const shareId = path.split('/')[3];
      const token = url.searchParams.get('token');

      const row = await env.HASI_SHARE_DB.prepare(
        'SELECT file_key, filename, dl_token, dl_token_exp, expires_at FROM shares WHERE id = ?'
      ).bind(shareId).first();

      if (!row) return jsonErr('Not found', 404);

      // Check share expiry
      if (row.expires_at && new Date(row.expires_at) < new Date()) {
        return jsonErr('Link expired', 410);
      }

      // Check download token
      if (!token || token !== row.dl_token || new Date(row.dl_token_exp) < new Date()) {
        return jsonErr('Invalid or expired download token', 401);
      }

      // Get from R2
      const obj = await env.HASI_SHARE_R2.get(row.file_key);
      if (!obj) return jsonErr('File not found', 404);

      // Increment download counter
      await env.HASI_SHARE_DB.prepare(
        'UPDATE shares SET downloads = downloads + 1 WHERE id = ?'
      ).bind(shareId).run();

      // Stream file
      return new Response(obj.body, {
        headers: {
          'Content-Type': obj.httpMetadata?.contentType || 'application/octet-stream',
          'Content-Disposition': `attachment; filename="${row.filename}"`,
          'Content-Length': obj.size?.toString() || '',
          ...CORS,
        },
      });
    }

    // ── STATIC FILES ─────────────────────────────────────────────

    // /d/:shareId → download page
    if (path.startsWith('/d/')) {
      // Serve download.html — CF Pages handles this
      return new Response(null, {
        status: 302,
        headers: { 'Location': `/download.html?id=${path.split('/').pop()}` }
      });
    }

    return jsonErr('Not found', 404);
  }
};
