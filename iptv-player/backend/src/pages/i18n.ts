export type Lang = "de" | "tr" | "en";

/** Supported page languages with their endonyms, in switcher order. */
export const LANGS: readonly { lang: Lang; name: string }[] = [
  { lang: "de", name: "Deutsch" },
  { lang: "tr", name: "Türkçe" },
  { lang: "en", name: "English" },
];

const isLang = (s: string | null): s is Lang => s === "de" || s === "tr" || s === "en";

/** `?lang=de|tr|en` overrides `Accept-Language`; default English. */
export function pickLang(req: Request, url: URL): Lang {
  const q = url.searchParams.get("lang");
  if (isLang(q)) return q;
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
    const primary = p.tag.split("-")[0] ?? "";
    if (isLang(primary)) return primary;
  }
  return "en";
}

type Dict = Record<string, Record<Lang, string>>;

/** Strings shared by the pages ({APP} is replaced with APP_NAME). */
export const STRINGS = {
  // pairing page
  pair_title: { en: "Add a source to your TV", tr: "TV'nize kaynak ekleyin", de: "Quelle zum TV hinzufügen" },
  pair_intro: {
    en: "Enter the code shown on your TV. Your source details are encrypted on this phone and only your TV can read them.",
    tr: "TV'nizde görünen kodu girin. Kaynak bilgileriniz bu telefonda şifrelenir ve yalnızca TV'niz okuyabilir.",
    de: "Geben Sie den Code ein, der auf Ihrem TV angezeigt wird. Ihre Quelldaten werden auf diesem Smartphone verschlüsselt und können nur von Ihrem TV gelesen werden.",
  },
  pair_code: { en: "Code from your TV", tr: "TV'nizdeki kod", de: "Code von Ihrem TV" },
  pair_continue: { en: "Continue", tr: "Devam", de: "Weiter" },
  pair_for_code: { en: "Code", tr: "Kod", de: "Code" },
  pair_type: { en: "Source type", tr: "Kaynak türü", de: "Quelltyp" },
  pair_m3u: { en: "M3U link", tr: "M3U bağlantısı", de: "M3U-Link" },
  pair_xtream: { en: "Xtream Codes", tr: "Xtream Codes", de: "Xtream Codes" },
  field_name: { en: "Name", tr: "Ad", de: "Name" },
  field_m3u_url: { en: "Playlist URL", tr: "Liste URL'si", de: "Playlist-URL" },
  field_epg_url: { en: "EPG URL (optional)", tr: "EPG URL'si (isteğe bağlı)", de: "EPG-URL (optional)" },
  field_server: { en: "Server (http://host:port)", tr: "Sunucu (http://host:port)", de: "Server (http://host:port)" },
  field_username: { en: "Username", tr: "Kullanıcı adı", de: "Benutzername" },
  field_password: { en: "Password", tr: "Şifre", de: "Passwort" },
  show_password: { en: "Show password", tr: "Şifreyi göster", de: "Passwort anzeigen" },
  pair_send: { en: "Send to TV", tr: "TV'ye gönder", de: "An TV senden" },
  pair_sending: { en: "Encrypting and sending…", tr: "Şifreleniyor ve gönderiliyor…", de: "Wird verschlüsselt und gesendet…" },
  pair_done_title: { en: "Sent!", tr: "Gönderildi!", de: "Gesendet!" },
  pair_done: {
    en: "Your TV will add the source in a few seconds. You can close this page.",
    tr: "TV'niz kaynağı birkaç saniye içinde ekleyecek. Bu sayfayı kapatabilirsiniz.",
    de: "Ihr TV fügt die Quelle in wenigen Sekunden hinzu. Sie können diese Seite schließen.",
  },
  pair_e2e: {
    en: "Your credentials are end-to-end encrypted; our server cannot read them.",
    tr: "Bilgileriniz uçtan uca şifrelenir; sunucumuz bunları okuyamaz.",
    de: "Ihre Zugangsdaten sind Ende-zu-Ende-verschlüsselt – unser Server kann sie nicht lesen.",
  },
  legal_no_content: {
    en: "This app does not provide any content. It only plays M3U / Xtream sources that you own or are authorized to use.",
    tr: "Uygulama içerik sağlamaz; yalnızca size ait veya kullanım hakkınız olan M3U / Xtream kaynaklarını oynatır.",
    de: "Diese App stellt keine Inhalte bereit. Sie spielt nur M3U-/Xtream-Quellen ab, die Ihnen gehören oder für die Sie eine Nutzungsberechtigung haben.",
  },
  err_code_format: { en: "Enter the 6-character code (e.g. ABC-123).", tr: "6 karakterlik kodu girin (ör. ABC-123).", de: "Bitte den 6-stelligen Code eingeben (z. B. ABC-123)." },
  err_code_unknown: { en: "This code is unknown. Check the code on your TV.", tr: "Bu kod bulunamadı. TV'nizdeki kodu kontrol edin.", de: "Dieser Code ist unbekannt. Bitte den Code auf Ihrem TV prüfen." },
  err_code_expired: { en: "The code has expired. Get a new code on your TV.", tr: "Kodun süresi doldu. TV'nizden yeni kod alın.", de: "Der Code ist abgelaufen. Bitte auf dem TV einen neuen Code anfordern." },
  err_code_used: { en: "A source was already sent with this code.", tr: "Bu kodla zaten bir kaynak gönderildi.", de: "Mit diesem Code wurde bereits eine Quelle gesendet." },
  err_required: { en: "Please fill in all required fields.", tr: "Lütfen tüm zorunlu alanları doldurun.", de: "Bitte alle Pflichtfelder ausfüllen." },
  err_url: { en: "Enter a valid http(s) URL", tr: "Geçerli bir http(s) adresi girin", de: "Gültige http(s)-URL eingeben" },
  err_network: { en: "Connection problem. Please try again.", tr: "Bağlantı sorunu. Lütfen tekrar deneyin.", de: "Verbindungsproblem. Bitte erneut versuchen." },
  err_too_many: { en: "Too many attempts. Wait a minute and try again.", tr: "Çok fazla deneme. Bir dakika bekleyip tekrar deneyin.", de: "Zu viele Versuche. Bitte eine Minute warten und erneut versuchen." },
  err_crypto: {
    en: "This browser cannot encrypt securely (WebCrypto missing). Use an up-to-date browser over HTTPS.",
    tr: "Bu tarayıcı güvenli şifreleme yapamıyor (WebCrypto yok). Güncel bir tarayıcı ve HTTPS kullanın.",
    de: "Dieser Browser kann nicht sicher verschlüsseln (WebCrypto fehlt). Bitte einen aktuellen Browser über HTTPS verwenden.",
  },
  // link page
  link_title: { en: "Sign in on your TV", tr: "TV'nizde oturum açın", de: "Auf dem TV anmelden" },
  link_intro: {
    en: "Sign in with your e-mail, then confirm the code shown on your TV.",
    tr: "E-posta adresinizle giriş yapın, ardından TV'nizde görünen kodu onaylayın.",
    de: "Melden Sie sich mit Ihrer E-Mail-Adresse an und bestätigen Sie dann den Code auf Ihrem TV.",
  },
  email: { en: "E-mail", tr: "E-posta", de: "E-Mail" },
  send_code: { en: "Send code", tr: "Kod gönder", de: "Code senden" },
  code_sent: { en: "We sent a 6-digit code to {0}.", tr: "{0} adresine 6 haneli bir kod gönderdik.", de: "Wir haben einen 6-stelligen Code an {0} gesendet." },
  enter_code: { en: "6-digit code", tr: "6 haneli kod", de: "6-stelliger Code" },
  verify: { en: "Sign in", tr: "Giriş yap", de: "Anmelden" },
  signed_in_as: { en: "Signed in as {0}", tr: "{0} olarak giriş yapıldı", de: "Angemeldet als {0}" },
  sign_out: { en: "Sign out", tr: "Çıkış yap", de: "Abmelden" },
  tv_code: { en: "Code on your TV (ABCD-EFGH)", tr: "TV'nizdeki kod (ABCD-EFGH)", de: "Code auf Ihrem TV (ABCD-EFGH)" },
  approve: { en: "Confirm TV sign-in", tr: "TV girişini onayla", de: "TV-Anmeldung bestätigen" },
  approved: { en: "Done! Your TV is now signed in.", tr: "Tamam! TV'nizde oturum açıldı.", de: "Fertig! Ihr TV ist jetzt angemeldet." },
  err_invalid_code: { en: "The code is invalid.", tr: "Kod geçersiz.", de: "Der Code ist ungültig." },
  err_code_expired_login: { en: "The code has expired. Request a new one.", tr: "Kodun süresi doldu. Yeni kod isteyin.", de: "Der Code ist abgelaufen. Bitte einen neuen anfordern." },
  err_too_many_attempts: { en: "Too many wrong codes. Request a new code.", tr: "Çok fazla hatalı kod. Yeni kod isteyin.", de: "Zu viele falsche Codes. Bitte einen neuen Code anfordern." },
  err_email: { en: "Enter a valid e-mail address.", tr: "Geçerli bir e-posta adresi girin.", de: "Bitte eine gültige E-Mail-Adresse eingeben." },
  err_tv_code: { en: "Unknown or expired TV code.", tr: "TV kodu bulunamadı veya süresi doldu.", de: "TV-Code unbekannt oder abgelaufen." },
  err_mail: { en: "The e-mail could not be sent. Try again later.", tr: "E-posta gönderilemedi. Daha sonra tekrar deneyin.", de: "Die E-Mail konnte nicht gesendet werden. Bitte später erneut versuchen." },
  // admin page
  admin_title: { en: "Admin", tr: "Yönetim", de: "Verwaltung" },
  admin_token: { en: "Admin token", tr: "Yönetici anahtarı", de: "Admin-Token" },
  admin_save_token: { en: "Use token", tr: "Anahtarı kullan", de: "Token verwenden" },
  admin_forget: { en: "Forget token", tr: "Anahtarı unut", de: "Token vergessen" },
  admin_config: { en: "Configuration", tr: "Yapılandırma", de: "Konfiguration" },
  admin_trial_days: { en: "Trial length (days, 1–90, new trials only)", tr: "Deneme süresi (gün, 1–90, yalnızca yeni denemeler)", de: "Testphase (Tage, 1–90, nur neue Testphasen)" },
  admin_min_android: { en: "Min. version Android", tr: "Min. sürüm Android", de: "Mindestversion Android" },
  admin_min_apple: { en: "Min. version Apple", tr: "Min. sürüm Apple", de: "Mindestversion Apple" },
  admin_features: { en: "Features", tr: "Özellikler", de: "Funktionen" },
  admin_save: { en: "Save", tr: "Kaydet", de: "Speichern" },
  admin_saved: { en: "Saved.", tr: "Kaydedildi.", de: "Gespeichert." },
  admin_extend: { en: "Extend / shorten a trial", tr: "Deneme süresini uzat / kısalt", de: "Testphase verlängern / verkürzen" },
  admin_target: { en: "Device key or account id (acc_…)", tr: "Cihaz anahtarı veya hesap kimliği (acc_…)", de: "Geräteschlüssel oder Konto-ID (acc_…)" },
  admin_days: { en: "Days (negative to shorten)", tr: "Gün (kısaltmak için negatif)", de: "Tage (negativ zum Verkürzen)" },
  admin_apply: { en: "Apply", tr: "Uygula", de: "Anwenden" },
  admin_licenses: { en: "Licenses", tr: "Lisanslar", de: "Lizenzen" },
  admin_search_hint: {
    en: "E-mail, account id, device key, order id, transaction id or license id (empty = latest)",
    tr: "E-posta, hesap kimliği, cihaz anahtarı, sipariş no, işlem no veya lisans kimliği (boş = en yeniler)",
    de: "E-Mail, Konto-ID, Geräteschlüssel, Bestell-ID, Transaktions-ID oder Lizenz-ID (leer = neueste)",
  },
  admin_search: { en: "Search", tr: "Ara", de: "Suchen" },
  admin_revoke: { en: "Revoke", tr: "İptal et", de: "Widerrufen" },
  admin_restore: { en: "Restore", tr: "Geri yükle", de: "Wiederherstellen" },
  admin_grant: { en: "Grant a license (support / promo)", tr: "Lisans ver (destek / promosyon)", de: "Lizenz vergeben (Support / Aktion)" },
  admin_note: { en: "Note", tr: "Not", de: "Notiz" },
  admin_none: { en: "No results.", tr: "Sonuç yok.", de: "Keine Ergebnisse." },
  admin_unauthorized: { en: "Token rejected.", tr: "Anahtar reddedildi.", de: "Token abgelehnt." },
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
