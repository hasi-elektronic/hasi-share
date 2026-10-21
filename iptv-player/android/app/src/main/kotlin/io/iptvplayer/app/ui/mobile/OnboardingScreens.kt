package io.iptvplayer.app.ui.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import io.iptvplayer.app.ui.common.ErrorCard
import io.iptvplayer.app.ui.common.findActivity
import io.iptvplayer.app.ui.common.formatDate
import io.iptvplayer.app.ui.common.progressLabel
import io.iptvplayer.app.ui.common.remainingText
import io.iptvplayer.app.ui.common.sourceErrorText
import io.iptvplayer.app.ui.theme.Tokens
import io.iptvplayer.core.error.ErrorAction
import io.iptvplayer.core.license.AccessState
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.shared.R
import io.iptvplayer.shared.billing.PurchaseEvent
import io.iptvplayer.shared.license.TrialStartResult
import io.iptvplayer.shared.vm.AddSourceState
import io.iptvplayer.shared.vm.AddSourceViewModel
import io.iptvplayer.shared.vm.MainViewModel
import io.iptvplayer.shared.vm.SourceFormValidation
import io.iptvplayer.shared.vm.ViewModelFactory

/** Welcome + trial card + add source (SCREENS §3.1). */
@Composable
fun WelcomeScreen(main: MainViewModel, onAdd: (String) -> Unit, onPaywall: () -> Unit) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(24.dp))
        AppLogo(72)
        Spacer(Modifier.height(16.dp))
        Text(stringResource(R.string.welcome_title), fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Tokens.TextPrimary, textAlign = TextAlign.Center)
        Text(stringResource(R.string.welcome_subtitle), color = Tokens.TextSecondary, textAlign = TextAlign.Center)
        Spacer(Modifier.height(20.dp))
        TrialCard(main, onPaywall)
        Spacer(Modifier.height(24.dp))
        Text(stringResource(R.string.add_source), fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Tokens.TextPrimary, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(8.dp))
        BigOption(Icons.Filled.Link, stringResource(R.string.add_source_m3u)) { onAdd("m3u") }
        Spacer(Modifier.height(8.dp))
        BigOption(Icons.Filled.Dns, stringResource(R.string.add_source_xtream)) { onAdd("xtream") }
        Spacer(Modifier.height(20.dp))
        Text(stringResource(R.string.legal_no_content), color = Tokens.TextSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
    }
}

@Composable
fun AppLogo(sizeDp: Int) {
    Box(Modifier.size(sizeDp.dp).clip(RoundedCornerShape(20.dp)).background(Tokens.PremiumGradient), contentAlignment = Alignment.Center) {
        Text("▶", color = Tokens.TextPrimary, fontSize = (sizeDp / 2).sp)
    }
}

@Composable
private fun BigOption(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(Tokens.CardRadius)) {
        Icon(icon, null)
        Spacer(Modifier.size(12.dp))
        Text(label, modifier = Modifier.weight(1f))
    }
}

/** Trial information card: duration, what gets locked, one-time price → Start trial / Buy / Restore. */
@Composable
fun TrialCard(main: MainViewModel, onPaywall: () -> Unit) {
    val lic by main.license.collectAsState()
    val bill by main.billing.collectAsState()
    val busy by main.busy.collectAsState()
    var message by remember { mutableStateOf<String?>(null) }
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    val activity = findActivity()
    LaunchedEffect(Unit) {
        main.trialResult.collect { r ->
            message = when (r) {
                TrialStartResult.Started -> null
                TrialStartResult.AlreadyUsed -> res.getString(R.string.trial_used_on_device)
                is TrialStartResult.BackendUnavailable -> res.getString(R.string.trial_backend_unavailable)
            }
        }
    }
    PurchaseEventsMessage(main) { message = it }
    val price = bill.formattedPrice ?: "—"
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Tokens.CardRadius)).background(Tokens.Surface).padding(20.dp),
    ) {
        when (lic.decision.state) {
            AccessState.PURCHASED -> StatusLine(stringResource(R.string.purchase_owned), Tokens.Success)
            AccessState.TRIAL_ACTIVE -> StatusLine(stringResource(R.string.trial_active_until, ctx.formatDate(lic.decision.trialEndMs ?: 0)) + " · " + stringResource(R.string.trial_remaining, remainingText(lic.trialRemainingMs)), Tokens.Success)
            AccessState.TRIAL_EXPIRED -> StatusLine(stringResource(R.string.trial_expired), Tokens.Warning)
            AccessState.TRIAL_NOT_STARTED -> {
                Text(pluralStringResource(R.plurals.trial_info, lic.trialDays, lic.trialDays, price), color = Tokens.TextPrimary)
                Spacer(Modifier.height(16.dp))
                Button(onClick = { message = null; main.startTrial() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
                    if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text(stringResource(R.string.trial_start))
                }
            }
        }
        if (lic.decision.pendingPurchase) {
            Spacer(Modifier.height(8.dp))
            StatusLine(stringResource(R.string.purchase_pending), Tokens.Warning)
        }
        if (lic.decision.state != AccessState.PURCHASED) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { activity?.let { main.buy(it) } }) { Text(stringResource(R.string.purchase_buy, price)) }
                TextButton(onClick = { main.restore() }) { Text(stringResource(R.string.purchase_restore)) }
            }
        }
        message?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = Tokens.Warning, fontSize = 14.sp)
        }
    }
}

@Composable
fun StatusLine(text: String, color: androidx.compose.ui.graphics.Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.CheckCircle, null, tint = color, modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(8.dp))
        Text(text, color = Tokens.TextPrimary)
    }
}

/** Maps purchase events to messages (cancel = silent, SCREENS §3.8). */
@Composable
fun PurchaseEventsMessage(main: MainViewModel, onMessage: (String?) -> Unit) {
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    LaunchedEffect(Unit) {
        main.purchaseEvents.collect { e ->
            onMessage(
                when (e) {
                    PurchaseEvent.Purchased -> res.getString(R.string.purchase_owned)
                    PurchaseEvent.Pending -> res.getString(R.string.purchase_pending)
                    PurchaseEvent.Cancelled -> null
                    PurchaseEvent.AlreadyOwned, PurchaseEvent.Restored -> res.getString(R.string.purchase_restored)
                    PurchaseEvent.NothingToRestore -> res.getString(R.string.purchase_nothing_to_restore)
                    PurchaseEvent.Unavailable -> res.getString(R.string.purchase_unavailable)
                    is PurchaseEvent.Failed -> res.getString(R.string.purchase_failed, e.message)
                },
            )
        }
    }
}

/** Paywall (SCREENS §3.8). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaywallScreen(main: MainViewModel, onBack: () -> Unit, onAccount: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = {},
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.action_back)) } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Tokens.Bg),
            windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
        )
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp)) {
            Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(Tokens.CardRadius)).background(Tokens.PremiumGradient).padding(24.dp)) {
                Column {
                    Text(stringResource(R.string.paywall_title), fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Tokens.TextPrimary)
                    Text(stringResource(R.string.paywall_subtitle), color = Tokens.TextPrimary)
                }
            }
            Spacer(Modifier.height(16.dp))
            listOf(R.string.paywall_benefit_1, R.string.paywall_benefit_2, R.string.paywall_benefit_3).forEach {
                StatusLine(stringResource(it), Tokens.Primary)
                Spacer(Modifier.height(8.dp))
            }
            Spacer(Modifier.height(8.dp))
            PaywallActions(main)
            Spacer(Modifier.height(24.dp))
            Text(stringResource(R.string.paywall_other_platform), color = Tokens.TextSecondary)
            TextButton(onClick = onAccount) { Text(stringResource(R.string.account_sign_in)) }
            Row {
                TextButton(onClick = {}) { Text(stringResource(R.string.terms)) }
                TextButton(onClick = {}) { Text(stringResource(R.string.privacy)) }
            }
        }
    }
}

@Composable
fun PaywallActions(main: MainViewModel) {
    val lic by main.license.collectAsState()
    val bill by main.billing.collectAsState()
    val busy by main.busy.collectAsState()
    val activity = findActivity()
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    var message by remember { mutableStateOf<String?>(null) }
    PurchaseEventsMessage(main) { message = it }
    LaunchedEffect(Unit) {
        main.trialResult.collect { r ->
            message = when (r) {
                TrialStartResult.Started -> null
                TrialStartResult.AlreadyUsed -> res.getString(R.string.trial_used_on_device)
                is TrialStartResult.BackendUnavailable -> res.getString(R.string.trial_backend_unavailable)
            }
        }
    }
    val status = when (lic.decision.state) {
        AccessState.PURCHASED -> stringResource(R.string.purchase_owned)
        AccessState.TRIAL_ACTIVE -> stringResource(R.string.trial_remaining, remainingText(lic.trialRemainingMs))
        AccessState.TRIAL_EXPIRED -> stringResource(R.string.trial_expired)
        AccessState.TRIAL_NOT_STARTED -> stringResource(R.string.trial_not_started)
    }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(Tokens.CardRadius)).background(Tokens.Surface).padding(16.dp)) {
        Text(status, color = Tokens.TextPrimary, fontWeight = FontWeight.SemiBold)
        if (lic.decision.pendingPurchase) Text(stringResource(R.string.purchase_pending), color = Tokens.Warning)
        if (lic.backendError != null && lic.hasToken) Text(stringResource(R.string.license_server_unreachable), color = Tokens.TextSecondary, fontSize = 13.sp)
    }
    Spacer(Modifier.height(16.dp))
    if (lic.decision.state != AccessState.PURCHASED) {
        Button(
            onClick = { activity?.let { main.buy(it) } },
            modifier = Modifier.fillMaxWidth().height(52.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Tokens.Primary),
        ) { Text(stringResource(R.string.purchase_buy, bill.formattedPrice ?: "—"), fontSize = 17.sp) }
        if (lic.decision.state == AccessState.TRIAL_NOT_STARTED) {
            Spacer(Modifier.height(8.dp))
            OutlinedButton(onClick = { main.startTrial() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.trial_start)) }
        }
    }
    TextButton(onClick = { main.restore() }, enabled = !busy) { Text(stringResource(R.string.purchase_restore)) }
    message?.let { Text(it, color = Tokens.Warning) }
}

/** M3U / Xtream form with stepwise progress, success summary and specific errors (SCREENS §3.1). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddSourceScreen(factory: ViewModelFactory, type: String, editId: String?, onBack: () -> Unit, onDone: () -> Unit) {
    val vm: AddSourceViewModel = viewModel(factory = factory)
    val state by vm.state.collectAsState()
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    val existing = remember(editId) { editId?.let { vm.existingSecrets(it) } }
    var name by rememberSaveable { mutableStateOf("") }
    var url by rememberSaveable { mutableStateOf((existing as? SourceSecrets.M3u)?.url ?: "") }
    var epg by rememberSaveable { mutableStateOf(existing?.epgUrl ?: "") }
    var ua by rememberSaveable { mutableStateOf((existing as? SourceSecrets.M3u)?.userAgent ?: "") }
    var server by rememberSaveable { mutableStateOf((existing as? SourceSecrets.Xtream)?.serverUrl ?: "") }
    var user by rememberSaveable { mutableStateOf((existing as? SourceSecrets.Xtream)?.username ?: "") }
    var pass by rememberSaveable { mutableStateOf((existing as? SourceSecrets.Xtream)?.password ?: "") }
    var showPass by remember { mutableStateOf(false) }
    var advanced by remember { mutableStateOf(false) }
    val xtream = type == "xtream"
    val valid = if (xtream) SourceFormValidation.xtreamValid(server, user, pass) else SourceFormValidation.m3uValid(url, epg)

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(stringResource(if (xtream) R.string.add_source_xtream else R.string.add_source_m3u)) },
            navigationIcon = { IconButton(onClick = { vm.cancel(); onBack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.action_back)) } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Tokens.Bg),
            windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
        )
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp)) {
            when (val s = state) {
                is AddSourceState.Running -> Column(Modifier.fillMaxWidth().padding(top = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(16.dp))
                    Text(progressLabel(s.progress), color = Tokens.TextPrimary)
                    TextButton(onClick = { vm.cancel() }) { Text(stringResource(R.string.action_cancel)) }
                }
                is AddSourceState.Success -> Column(Modifier.fillMaxWidth().padding(top = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Filled.CheckCircle, null, tint = Tokens.Success, modifier = Modifier.size(56.dp))
                    Text(stringResource(R.string.source_added_title), fontSize = 22.sp, color = Tokens.TextPrimary, fontWeight = FontWeight.SemiBold)
                    Text(stringResource(R.string.source_summary, "%,d".format(s.status.liveCount), "%,d".format(s.status.movieCount), "%,d".format(s.status.seriesCount)), color = Tokens.TextSecondary)
                    s.source.xtreamAccount?.let { a ->
                        Text(a.expiresAtMs?.let { stringResource(R.string.source_expires, ctx.formatDate(it)) } ?: stringResource(R.string.source_unlimited), color = Tokens.TextSecondary)
                    }
                    Spacer(Modifier.height(24.dp))
                    Button(onClick = { vm.reset(); onDone() }) { Text(stringResource(R.string.action_continue)) }
                }
                else -> {
                    if (s is AddSourceState.Failure) {
                        ctx.sourceErrorText(s.error)?.let { t ->
                            ErrorCard(t, onAction = { a ->
                                when (a) {
                                    ErrorAction.RETRY, ErrorAction.REFRESH -> if (xtream) vm.addXtream(name, server, user, pass, editId) else vm.addM3u(name, url, epg, ua, editId)
                                    ErrorAction.BACK -> onBack()
                                    else -> vm.reset()
                                }
                            }, modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp))
                        }
                    }
                    Field(name, { name = it }, stringResource(R.string.field_name))
                    if (xtream) {
                        Field(server, { server = it }, stringResource(R.string.field_server), KeyboardType.Uri, required = true)
                        Field(user, { user = it }, stringResource(R.string.field_username), required = true)
                        OutlinedTextField(
                            value = pass, onValueChange = { pass = it }, label = { Text(stringResource(R.string.field_password)) },
                            singleLine = true, modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                            visualTransformation = if (showPass) VisualTransformation.None else PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                            trailingIcon = {
                                IconButton(onClick = { showPass = !showPass }) {
                                    Icon(
                                        if (showPass) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                                        stringResource(if (showPass) R.string.action_hide_password else R.string.action_show_password),
                                    )
                                }
                            },
                        )
                    } else {
                        Field(url, { url = it }, stringResource(R.string.field_m3u_url), KeyboardType.Uri, required = true, error = url.isNotBlank() && !SourceFormValidation.isHttpUrl(url))
                        Field(epg, { epg = it }, stringResource(R.string.field_epg_url), KeyboardType.Uri, error = !SourceFormValidation.optionalUrl(epg))
                        TextButton(onClick = { advanced = !advanced }) { Text(stringResource(R.string.field_advanced)) }
                        if (advanced) Field(ua, { ua = it }, stringResource(R.string.field_user_agent))
                    }
                    Spacer(Modifier.height(16.dp))
                    Button(
                        onClick = { if (xtream) vm.addXtream(name, server, user, pass, editId) else vm.addM3u(name, url, epg, ua, editId) },
                        enabled = valid,
                        modifier = Modifier.fillMaxWidth().height(52.dp),
                    ) { Text(stringResource(R.string.action_connect)) }
                    Spacer(Modifier.height(12.dp))
                    Text(stringResource(R.string.legal_no_content), color = Tokens.TextSecondary, fontSize = 13.sp)
                }
            }
        }
    }
}

@Composable
fun Field(
    value: String,
    onChange: (String) -> Unit,
    label: String,
    keyboard: KeyboardType = KeyboardType.Text,
    required: Boolean = false,
    error: Boolean = false,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        isError = error,
        supportingText = if (error) ({ Text(stringResource(R.string.validation_url)) }) else if (required && value.isBlank()) ({ Text(stringResource(R.string.validation_required)) }) else null,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard),
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    )
}
