export type Lang = "tr" | "en";

/** `?lang=tr|en` overrides `Accept-Language`; default English. */
export function pickLang(req: Request, url: URL): Lang {
  const q = url.searchParams.get("lang");
  if (q === "tr" || q === "en") return q;
  const header = req.headers.get("accept-language") ?? "";
  const prefs = header
    .split(",")
    .map((part, i) => {
      const [tag, ...params] = part.trim().split(";");
      const qp = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
      const weight = qp ? Number(qp.slice(2)) : 1;
      return { tag: (tag ?? "").toLowerCase(), q: Number.isFinite(weight) ? weight : 0, i };
    })
    .filter((p) => p.tag && p.q > 0)
    .sort((a, b) => b.q - a.q || a.i - b.i);
  for (const p of prefs) {
    if (p.tag === "tr" || p.tag.startsWith("tr-")) return "tr";
    if (p.tag === "en" || p.tag.startsWith("en-")) return "en";
  }
  return "en";
}

type Dict = Record<string, { tr: string; en: string }>;

/** Strings shared by the pages ({APP} is replaced with APP_NAME). */
export const STRINGS = {
  // pairing page
  pair_title: { en: "Add a source to your TV", tr: "TV'nize kaynak ekleyin" },
  pair_intro: {
    en: "Enter the code shown on your TV. Your source details are encrypted on this phone and only your TV can read them.",
    tr: "TV'nizde görünen kodu girin. Kaynak bilgileriniz bu telefonda şifrelenir ve yalnızca TV'niz okuyabilir.",
  },
  pair_code: { en: "Code from your TV", tr: "TV'nizdeki kod" },
  pair_continue: { en: "Continue", tr: "Devam" },
  pair_for_code: { en: "Code", tr: "Kod" },
  pair_type: { en: "Source type", tr: "Kaynak türü" },
  pair_m3u: { en: "M3U link", tr: "M3U bağlantısı" },
  pair_xtream: { en: "Xtream Codes", tr: "Xtream Codes" },
  field_name: { en: "Name", tr: "Ad" },
  field_m3u_url: { en: "Playlist URL", tr: "Liste URL'si" },
  field_epg_url: { en: "EPG URL (optional)", tr: "EPG URL'si (isteğe bağlı)" },
  field_server: { en: "Server (http://host:port)", tr: "Sunucu (http://host:port)" },
  field_username: { en: "Username", tr: "Kullanıcı adı" },
  field_password: { en: "Password", tr: "Şifre" },
  show_password: { en: "Show password", tr: "Şifreyi göster" },
  pair_send: { en: "Send to TV", tr: "TV'ye gönder" },
  pair_sending: { en: "Encrypting and sending…", tr: "Şifreleniyor ve gönderiliyor…" },
  pair_done_title: { en: "Sent!", tr: "Gönderildi!" },
  pair_done: {
    en: "Your TV will add the source in a few seconds. You can close this page.",
    tr: "TV'niz kaynağı birkaç saniye içinde ekleyecek. Bu sayfayı kapatabilirsiniz.",
  },
  pair_e2e: {
    en: "Your credentials are end-to-end encrypted; our server cannot read them.",
    tr: "Bilgileriniz uçtan uca şifrelenir; sunucumuz bunları okuyamaz.",
  },
  legal_no_content: {
    en: "This app does not provide any content. It only plays M3U / Xtream sources that you own or are authorized to use.",
    tr: "Uygulama içerik sağlamaz; yalnızca size ait veya kullanım hakkınız olan M3U / Xtream kaynaklarını oynatır.",
  },
  err_code_format: { en: "Enter the 6-character code (e.g. ABC-123).", tr: "6 karakterlik kodu girin (ör. ABC-123)." },
  err_code_unknown: { en: "This code is unknown. Check the code on your TV.", tr: "Bu kod bulunamadı. TV'nizdeki kodu kontrol edin." },
  err_code_expired: { en: "The code has expired. Get a new code on your TV.", tr: "Kodun süresi doldu. TV'nizden yeni kod alın." },
  err_code_used: { en: "A source was already sent with this code.", tr: "Bu kodla zaten bir kaynak gönderildi." },
  err_required: { en: "Please fill in all required fields.", tr: "Lütfen tüm zorunlu alanları doldurun." },
  err_url: { en: "Enter a valid http(s) URL", tr: "Geçerli bir http(s) adresi girin" },
  err_network: { en: "Connection problem. Please try again.", tr: "Bağlantı sorunu. Lütfen tekrar deneyin." },
  err_too_many: { en: "Too many attempts. Wait a minute and try again.", tr: "Çok fazla deneme. Bir dakika bekleyip tekrar deneyin." },
  err_crypto: {
    en: "This browser cannot encrypt securely (WebCrypto missing). Use an up-to-date browser over HTTPS.",
    tr: "Bu tarayıcı güvenli şifreleme yapamıyor (WebCrypto yok). Güncel bir tarayıcı ve HTTPS kullanın.",
  },
  // link page
  link_title: { en: "Sign in on your TV", tr: "TV'nizde oturum açın" },
  link_intro: {
    en: "Sign in with your e-mail, then confirm the code shown on your TV.",
    tr: "E-posta adresinizle giriş yapın, ardından TV'nizde görünen kodu onaylayın.",
  },
  email: { en: "E-mail", tr: "E-posta" },
  send_code: { en: "Send code", tr: "Kod gönder" },
  code_sent: { en: "We sent a 6-digit code to {0}.", tr: "{0} adresine 6 haneli bir kod gönderdik." },
  enter_code: { en: "6-digit code", tr: "6 haneli kod" },
  verify: { en: "Sign in", tr: "Giriş yap" },
  signed_in_as: { en: "Signed in as {0}", tr: "{0} olarak giriş yapıldı" },
  sign_out: { en: "Sign out", tr: "Çıkış yap" },
  tv_code: { en: "Code on your TV (ABCD-EFGH)", tr: "TV'nizdeki kod (ABCD-EFGH)" },
  approve: { en: "Confirm TV sign-in", tr: "TV girişini onayla" },
  approved: { en: "Done! Your TV is now signed in.", tr: "Tamam! TV'nizde oturum açıldı." },
  err_invalid_code: { en: "The code is invalid.", tr: "Kod geçersiz." },
  err_code_expired_login: { en: "The code has expired. Request a new one.", tr: "Kodun süresi doldu. Yeni kod isteyin." },
  err_too_many_attempts: { en: "Too many wrong codes. Request a new code.", tr: "Çok fazla hatalı kod. Yeni kod isteyin." },
  err_email: { en: "Enter a valid e-mail address.", tr: "Geçerli bir e-posta adresi girin." },
  err_tv_code: { en: "Unknown or expired TV code.", tr: "TV kodu bulunamadı veya süresi doldu." },
  err_mail: { en: "The e-mail could not be sent. Try again later.", tr: "E-posta gönderilemedi. Daha sonra tekrar deneyin." },
  // admin page
  admin_title: { en: "Admin", tr: "Yönetim" },
  admin_token: { en: "Admin token", tr: "Yönetici anahtarı" },
  admin_save_token: { en: "Use token", tr: "Anahtarı kullan" },
  admin_forget: { en: "Forget token", tr: "Anahtarı unut" },
  admin_config: { en: "Configuration", tr: "Yapılandırma" },
  admin_trial_days: { en: "Trial length (days, 1–90, new trials only)", tr: "Deneme süresi (gün, 1–90, yalnızca yeni denemeler)" },
  admin_min_android: { en: "Min. version Android", tr: "Min. sürüm Android" },
  admin_min_apple: { en: "Min. version Apple", tr: "Min. sürüm Apple" },
  admin_features: { en: "Features", tr: "Özellikler" },
  admin_save: { en: "Save", tr: "Kaydet" },
  admin_saved: { en: "Saved.", tr: "Kaydedildi." },
  admin_extend: { en: "Extend / shorten a trial", tr: "Deneme süresini uzat / kısalt" },
  admin_target: { en: "Device key or account id (acc_…)", tr: "Cihaz anahtarı veya hesap kimliği (acc_…)" },
  admin_days: { en: "Days (negative to shorten)", tr: "Gün (kısaltmak için negatif)" },
  admin_apply: { en: "Apply", tr: "Uygula" },
  admin_licenses: { en: "Licenses", tr: "Lisanslar" },
  admin_search_hint: {
    en: "E-mail, account id, device key, order id, transaction id or license id (empty = latest)",
    tr: "E-posta, hesap kimliği, cihaz anahtarı, sipariş no, işlem no veya lisans kimliği (boş = en yeniler)",
  },
  admin_search: { en: "Search", tr: "Ara" },
  admin_revoke: { en: "Revoke", tr: "İptal et" },
  admin_restore: { en: "Restore", tr: "Geri yükle" },
  admin_grant: { en: "Grant a license (support / promo)", tr: "Lisans ver (destek / promosyon)" },
  admin_note: { en: "Note", tr: "Not" },
  admin_none: { en: "No results.", tr: "Sonuç yok." },
  admin_unauthorized: { en: "Token rejected.", tr: "Anahtar reddedildi." },
} satisfies Dict;

export type StringKey = keyof typeof STRINGS;

export function t(lang: Lang, key: StringKey, ...args: string[]): string {
  let s: string = STRINGS[key][lang];
  args.forEach((a, i) => {
    s = s.split(`{${i}}`).join(a);
  });
  return s;
}

/** Subset of strings for client-side scripts. */
export function clientStrings(lang: Lang, keys: StringKey[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const k of keys) out[k] = STRINGS[k][lang];
  return out;
}
