package io.iptvplayer.app.ui.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import io.iptvplayer.app.ui.common.QrCode
import io.iptvplayer.app.ui.common.aspectLabel
import io.iptvplayer.app.ui.common.formatDate
import io.iptvplayer.app.ui.common.formatDateTime
import io.iptvplayer.app.ui.common.sourceErrorText
import io.iptvplayer.app.ui.theme.Tokens
import io.iptvplayer.core.backend.BackendError
import io.iptvplayer.core.model.Source
import io.iptvplayer.core.model.SourceType
import io.iptvplayer.core.xtream.LiveFormatPreference
import io.iptvplayer.shared.R
import io.iptvplayer.shared.player.AspectMode
import io.iptvplayer.shared.player.FormatResult
import io.iptvplayer.shared.settings.BufferMode
import io.iptvplayer.shared.vm.AccountViewModel
import io.iptvplayer.shared.vm.FormatTestViewModel
import io.iptvplayer.shared.vm.MainViewModel
import io.iptvplayer.shared.vm.SettingsViewModel
import io.iptvplayer.shared.vm.ViewModelFactory
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackTopBar(title: String, onBack: () -> Unit) {
    TopAppBar(
        title = { Text(title) },
        navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.action_back)) } },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Tokens.Bg),
            windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
    )
}

@Composable
fun SettingsSection(title: String, content: @Composable () -> Unit) {
    Text(title, color = Tokens.Primary, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 6.dp))
    Column(Modifier.padding(horizontal = 12.dp).fillMaxWidth().clip(RoundedCornerShape(Tokens.CardRadius)).background(Tokens.Surface)) { content() }
}

@Composable
fun SettingRow(title: String, value: String? = null, onClick: (() -> Unit)? = null, trailing: @Composable (() -> Unit)? = null) {
    Row(
        Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = Tokens.TextPrimary)
            value?.let { Text(it, color = Tokens.TextSecondary, fontSize = 13.sp) }
        }
        trailing?.invoke()
    }
}

/** A row that opens a menu with [options]. */
@Composable
fun <T> ChoiceRow(title: String, current: T, options: List<Pair<T, String>>, onPick: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column {
        SettingRow(title, options.firstOrNull { it.first == current }?.second, onClick = { open = true })
        DropdownMenu(open, onDismissRequest = { open = false }) {
            options.forEach { (v, l) -> DropdownMenuItem(text = { Text(l) }, onClick = { onPick(v); open = false }) }
        }
    }
}

private val languages = listOf("" to null, "tr" to "Türkçe", "en" to "English", "de" to "Deutsch", "ar" to "العربية", "fr" to "Français", "es" to "Español")

/** Settings & source management (SCREENS §3.9) – always accessible, also when locked. */
@Composable
fun SettingsScreen(factory: ViewModelFactory, main: MainViewModel, nav: NavHostController) {
    val vm: SettingsViewModel = viewModel(factory = factory)
    val s by vm.settings.collectAsState()
    val sources by vm.sources.collectAsState()
    val account by main.account.collectAsState()
    val lic by main.license.collectAsState()
    val ctx = LocalContext.current
    val system = stringResource(R.string.system_default)
    val langOptions = languages.map { (code, name) -> code to (name ?: system) }
    Column(Modifier.fillMaxSize()) {
        BackTopBar(stringResource(R.string.nav_settings)) { nav.popBackStack() }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 32.dp)) {
            SettingsSection(stringResource(R.string.settings_sources)) {
                sources.forEach { src -> SourceRow(src) { nav.navigate(Routes.source(src.id)) } }
                HorizontalDivider(color = Tokens.Bg)
                SettingRow("+ " + stringResource(R.string.add_source_m3u), onClick = { nav.navigate(Routes.add("m3u")) })
                SettingRow("+ " + stringResource(R.string.add_source_xtream), onClick = { nav.navigate(Routes.add("xtream")) })
            }
            SettingsSection(stringResource(R.string.settings_playback)) {
                ChoiceRow(stringResource(R.string.pref_audio_lang), s.audioLanguage, langOptions) { v -> vm.update { it.copy(audioLanguage = v) } }
                ChoiceRow(stringResource(R.string.pref_subtitle_lang), s.subtitleLanguage, listOf("" to stringResource(R.string.off)) + langOptions.drop(1)) { v -> vm.update { it.copy(subtitleLanguage = v) } }
                ChoiceRow(stringResource(R.string.pref_default_aspect), s.aspect, AspectMode.entries.map { it to aspectLabel(it) }) { v -> vm.update { it.copy(aspect = v) } }
                ChoiceRow(
                    stringResource(R.string.pref_live_format), s.liveFormat,
                    listOf(LiveFormatPreference.AUTO to stringResource(R.string.automatic), LiveFormatPreference.TS to "MPEG-TS", LiveFormatPreference.HLS to "HLS"),
                ) { v -> vm.update { it.copy(liveFormat = v) } }
                ChoiceRow(stringResource(R.string.pref_buffer), s.buffer, listOf(BufferMode.NORMAL to stringResource(R.string.buffer_normal), BufferMode.LARGE to stringResource(R.string.buffer_large))) { v -> vm.update { it.copy(buffer = v) } }
            }
            SettingsSection(stringResource(R.string.settings_appearance)) {
                ChoiceRow(stringResource(R.string.pref_app_language), s.appLanguage, listOf("" to system) + io.iptvplayer.app.ui.common.AppLocale.SUPPORTED) { v ->
                    vm.update { it.copy(appLanguage = v) }
                    io.iptvplayer.app.ui.common.AppLocale.apply(ctx, v)
                }
                ChoiceRow(stringResource(R.string.pref_epg_timezone), s.epgTimezone, listOf("" to stringResource(R.string.timezone_device), "UTC" to "UTC", "Europe/Istanbul" to "Europe/Istanbul", "Europe/Berlin" to "Europe/Berlin")) { v -> vm.update { it.copy(epgTimezone = v) } }
                SettingRow(stringResource(R.string.pref_24h), trailing = { Switch(s.use24h, onCheckedChange = { v -> vm.update { it.copy(use24h = v) } }) })
            }
            SettingsSection(stringResource(R.string.settings_account)) {
                SettingRow(
                    account.account?.let { stringResource(R.string.account_signed_in_as, it.email) } ?: stringResource(R.string.account_sign_in),
                    stringResource(R.string.account_why),
                    onClick = { nav.navigate(Routes.ACCOUNT) },
                )
            }
            SettingsSection(stringResource(R.string.settings_purchase)) {
                SettingRow(
                    when {
                        lic.decision.canPlay && lic.purchaseSource != null -> stringResource(R.string.purchase_owned)
                        lic.decision.trialEndMs != null && lic.canPlay -> stringResource(R.string.trial_active_until, ctx.formatDate(lic.decision.trialEndMs!!))
                        lic.decision.trialEndMs != null -> stringResource(R.string.trial_expired)
                        else -> stringResource(R.string.trial_not_started)
                    },
                    onClick = { nav.navigate(Routes.PAYWALL) },
                )
                SettingRow(stringResource(R.string.purchase_restore), onClick = { main.restore() })
            }
            SettingsSection(stringResource(R.string.settings_advanced)) {
                SettingRow(stringResource(R.string.diagnostics_format_test), onClick = { nav.navigate(Routes.FORMAT_TEST) })
                SettingRow(stringResource(R.string.diagnostics_clear_epg), onClick = { vm.clearEpg() })
                SettingRow(stringResource(R.string.about_version, "${vm.versionName} (${vm.versionCode})"))
                SettingRow(stringResource(R.string.privacy))
            }
        }
    }
}

@Composable
fun SourceRow(src: Source, onClick: () -> Unit) {
    val ctx = LocalContext.current
    val st = src.lastRefreshResult
    val status = when {
        st == null -> null
        st.ok -> stringResource(R.string.source_status_ok)
        else -> st.error?.let { ctx.sourceErrorText(it)?.title }
    }
    SettingRow(
        src.name,
        listOfNotNull(
            if (src.type == SourceType.XTREAM) "Xtream" else "M3U",
            src.displayHost,
            src.lastRefreshAtMs?.let { stringResource(R.string.source_last_refresh, ctx.formatDateTime(it)) } ?: stringResource(R.string.source_never_refreshed),
            src.xtreamAccount?.expiresAtMs?.let { stringResource(R.string.source_expires, ctx.formatDate(it)) },
        ).joinToString(" · "),
        onClick = onClick,
        trailing = { status?.let { Text(it, color = if (st?.ok == true) Tokens.Success else Tokens.Error, fontSize = 13.sp) } },
    )
}

/** Source detail: refresh · edit · EPG shift · auto refresh · delete (confirmed). */
@Composable
fun SourceDetailScreen(factory: ViewModelFactory, nav: NavHostController, id: String) {
    val vm: SettingsViewModel = viewModel(factory = factory)
    val sources by vm.sources.collectAsState()
    val refreshing by vm.refreshing.collectAsState()
    val src = sources.firstOrNull { it.id == id }
    var confirm by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        BackTopBar(src?.name ?: "") { nav.popBackStack() }
        if (src == null) return@Column
        Column(Modifier.verticalScroll(rememberScrollState())) {
            SettingsSection(src.displayHost) {
                SourceRow(src) {}
                SettingRow(
                    stringResource(R.string.action_refresh),
                    src.lastRefreshResult?.let { stringResource(R.string.source_summary, "%,d".format(it.liveCount), "%,d".format(it.movieCount), "%,d".format(it.seriesCount)) },
                    onClick = { vm.refresh(id) },
                    trailing = { if (id in refreshing) CircularProgressIndicator(Modifier.width(20.dp).height(20.dp), strokeWidth = 2.dp) },
                )
                SettingRow(stringResource(R.string.action_edit), onClick = { nav.navigate(Routes.add(if (src.type == SourceType.XTREAM) "xtream" else "m3u", id)) })
                ChoiceRow(
                    stringResource(R.string.source_epg_shift), src.epgShiftMinutes,
                    (-12 * 4..12 * 4).map { it * 15 }.map { m -> m to (if (m > 0) "+" else "") + stringResource(R.string.minutes_short, m.toString()) },
                ) { v -> vm.updateSource(id) { it.copy(epgShiftMinutes = v) } }
                ChoiceRow(
                    stringResource(R.string.source_auto_refresh), src.autoRefreshHours,
                    listOf(0 to stringResource(R.string.off)) + listOf(6, 12, 24).map { it to stringResource(R.string.every_n_hours, it.toString()) },
                ) { v -> vm.updateSource(id) { it.copy(autoRefreshHours = v) } }
                SettingRow(stringResource(R.string.action_delete), onClick = { confirm = true })
            }
        }
    }
    if (confirm && src != null) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            text = { Text(stringResource(R.string.source_delete_confirm, src.name)) },
            confirmButton = { TextButton(onClick = { confirm = false; vm.delete(id); nav.popBackStack() }) { Text(stringResource(R.string.action_delete)) } },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

/** Optional account: e-mail code login, sync status, sign out, delete (SCREENS §3.9). */
@Composable
fun AccountScreen(factory: ViewModelFactory, onBack: () -> Unit, tvDeviceLogin: Boolean = false) {
    val vm: AccountViewModel = viewModel(factory = factory)
    val st by vm.state.collectAsState()
    val sync by vm.sync.collectAsState()
    val ctx = LocalContext.current
    var email by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var confirmDelete by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        BackTopBar(stringResource(R.string.settings_account), onBack)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (!vm.backendAvailable) {
                Text(stringResource(R.string.account_not_configured), color = Tokens.Warning)
                return@Column
            }
            Text(stringResource(R.string.account_why), color = Tokens.TextSecondary)
            val acct = st.account
            when {
                acct != null -> {
                    Text(stringResource(R.string.account_signed_in_as, acct.email), color = Tokens.TextPrimary, fontWeight = FontWeight.SemiBold)
                    sync.lastSyncMs?.let { Text(stringResource(R.string.last_synced, ctx.formatDateTime(it)), color = Tokens.TextSecondary) }
                    OutlinedButton(onClick = { vm.syncNow() }) { Text(stringResource(R.string.sync_now)) }
                    OutlinedButton(onClick = { vm.signOut() }) { Text(stringResource(R.string.account_sign_out)) }
                    TextButton(onClick = { confirmDelete = true }) { Text(stringResource(R.string.account_delete), color = Tokens.Error) }
                }
                tvDeviceLogin -> DeviceLoginPanel(vm)
                st.codeSentTo != null -> {
                    Text(stringResource(R.string.account_code_sent, st.codeSentTo!!), color = Tokens.TextPrimary)
                    if (vm.showDevCode) st.devCode?.let { Text(stringResource(R.string.account_dev_code, it), color = Tokens.Warning) }
                    OutlinedTextField(code, { code = it.filter(Char::isDigit).take(6) }, label = { Text(stringResource(R.string.account_enter_code)) }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword), modifier = Modifier.fillMaxWidth())
                    Button(onClick = { vm.verify(code) }, enabled = code.length == 6 && !st.busy) { Text(stringResource(R.string.account_verify)) }
                    TextButton(onClick = { vm.resetEmail() }) { Text(stringResource(R.string.action_back)) }
                }
                else -> {
                    OutlinedTextField(email, { email = it }, label = { Text(stringResource(R.string.account_field_email)) }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), modifier = Modifier.fillMaxWidth())
                    Button(onClick = { vm.sendCode(email, Locale.getDefault().language.takeIf { it == "de" || it == "tr" } ?: "en") }, enabled = email.contains('@') && !st.busy) {
                        Text(stringResource(R.string.account_send_code))
                    }
                }
            }
            if (st.busy) CircularProgressIndicator()
            st.error?.let { Text(backendErrorText(it), color = Tokens.Error) }
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            text = { Text(stringResource(R.string.account_delete_confirm)) },
            confirmButton = { TextButton(onClick = { confirmDelete = false; vm.delete() }) { Text(stringResource(R.string.action_delete)) } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

/** TV: device-code login with QR (BACKEND_API device flow). */
@Composable
fun DeviceLoginPanel(vm: AccountViewModel) {
    val st by vm.state.collectAsState()
    LaunchedEffect(Unit) { if (st.deviceLogin == null) vm.startDeviceLogin() }
    val dl = st.deviceLogin
    if (dl != null) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            QrCode(dl.verificationUrlComplete, 220.dp)
            Spacer(Modifier.width(24.dp))
            Column {
                Text(stringResource(R.string.account_sign_in_tv), color = Tokens.TextPrimary, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
                Text(stringResource(R.string.device_login_title, dl.verificationUrl.removeSuffix("/link")), color = Tokens.TextSecondary)
                Text(stringResource(R.string.device_login_code, dl.userCode), color = Tokens.Primary, fontSize = 30.sp, fontWeight = FontWeight.Bold)
            }
        }
    } else if (st.deviceLoginExpired) {
        Text(stringResource(R.string.pair_expired), color = Tokens.Warning)
        Button(onClick = { vm.startDeviceLogin() }) { Text(stringResource(R.string.action_new_code)) }
    }
}

@Composable
fun backendErrorText(e: BackendError): String = when (e) {
    is BackendError.Network -> stringResource(R.string.err_unreachable_title)
    is BackendError.Api -> when (e.apiCode) {
        "invalid_code" -> stringResource(R.string.account_enter_code)
        "code_expired" -> stringResource(R.string.pair_expired)
        else -> stringResource(R.string.error_backend_generic, e.apiCode)
    }
    else -> stringResource(R.string.error_backend_generic, e.code)
}

/** Diagnostics → format test with `stream-samples.json` (STREAM_COMPATIBILITY §3.2). */
@Composable
fun FormatTestScreen(factory: ViewModelFactory, onBack: () -> Unit) {
    val vm: FormatTestViewModel = viewModel(factory = factory)
    val rows by vm.rows.collectAsState()
    val running by vm.running.collectAsState()
    val ctx = LocalContext.current
    var host by remember { mutableStateOf("10.0.2.2") }
    LaunchedEffect(Unit) { vm.load(ctx.assets) }
    Column(Modifier.fillMaxSize()) {
        BackTopBar(stringResource(R.string.diagnostics_format_test), onBack)
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(host, { host = it }, label = { Text(stringResource(R.string.format_test_host)) }, singleLine = true, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(12.dp))
            Button(onClick = { vm.runAll(host.trim().ifEmpty { null }) }, enabled = !running) {
                Text(stringResource(R.string.format_test_run))
            }
        }
        LazyColumn(Modifier.fillMaxSize().padding(top = 8.dp)) {
            items(rows, key = { it.sample.id }) { r ->
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Text(r.sample.name, color = Tokens.TextPrimary)
                    Text("${r.sample.container} · ${r.sample.expect}", color = Tokens.TextSecondary, fontSize = 12.sp)
                    val (text, color) = when (val res = r.result) {
                        FormatResult.Pending -> stringResource(R.string.format_test_pending) to Tokens.TextSecondary
                        FormatResult.Running -> stringResource(R.string.loading) to Tokens.Primary
                        FormatResult.Playing -> stringResource(R.string.format_test_result_ok) to Tokens.Success
                        is FormatResult.ExpectedError -> stringResource(R.string.format_test_result_expected_error, res.code) to Tokens.Success
                        is FormatResult.Unexpected -> stringResource(R.string.format_test_result_fail, res.detail) to Tokens.Error
                        FormatResult.Skipped -> stringResource(R.string.format_test_skipped) to Tokens.Warning
                    }
                    Text(text, color = color, fontSize = 14.sp)
                }
                HorizontalDivider(color = Tokens.Surface)
            }
        }
    }
}

