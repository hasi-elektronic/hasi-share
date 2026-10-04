package io.iptvplayer.shared.repo

import androidx.room.withTransaction
import io.iptvplayer.core.error.NetworkErrorClassifier
import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.m3u.M3uClient
import io.iptvplayer.core.m3u.M3uMapper
import io.iptvplayer.core.model.Source
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.core.model.SourceStatus
import io.iptvplayer.core.model.SourceType
import io.iptvplayer.core.model.XtreamAccountInfo
import io.iptvplayer.core.net.SourceHttp
import io.iptvplayer.core.util.ContentKeys
import io.iptvplayer.core.util.Redactor
import io.iptvplayer.core.util.UrlNormalizer
import io.iptvplayer.core.xmltv.EpgClient
import io.iptvplayer.core.xmltv.EpgMatcher
import io.iptvplayer.core.xmltv.EpgRetention
import io.iptvplayer.core.xmltv.XmltvChannel
import io.iptvplayer.core.xmltv.XmltvOptions
import io.iptvplayer.core.xmltv.XmltvParser
import io.iptvplayer.core.xtream.XtreamClient
import io.iptvplayer.shared.db.AppDatabase
import io.iptvplayer.shared.db.EpgEntity
import io.iptvplayer.shared.db.SourceEntity
import io.iptvplayer.shared.db.toEntity
import io.iptvplayer.shared.db.toJson
import io.iptvplayer.shared.db.toModel
import io.iptvplayer.shared.log.SafeLog
import io.iptvplayer.shared.secure.SecretKeys
import io.iptvplayer.shared.secure.SecretStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.xmlpull.v1.XmlPullParser
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException

/** Step-by-step progress of add/refresh (SCREENS §3.1). */
sealed interface RefreshProgress {
    data object Connecting : RefreshProgress
    data object VerifyingAccount : RefreshProgress
    data class Channels(val count: Int) : RefreshProgress
    data class Movies(val count: Int) : RefreshProgress
    data class Series(val count: Int) : RefreshProgress
    data object Epg : RefreshProgress
}

/** Outcome of add / refresh. */
sealed interface RefreshOutcome {
    data class Success(val source: Source, val status: SourceStatus) : RefreshOutcome
    data class Failure(val error: SourceError) : RefreshOutcome
}

/**
 * Sources: metadata in Room, secrets in the [SecretStore] (CONTRACT §1, SECURITY §1), catalog
 * refresh with batched writes (≤ 1000 rows per transaction) into a new generation that is
 * activated atomically ([io.iptvplayer.shared.db.SourceEntity.activeGen]).
 */
class SourceRepository(
    private val db: AppDatabase,
    private val secrets: SecretStore,
    private val http: SourceHttp,
    private val xmlParserFactory: () -> XmlPullParser,
    private val redactor: Redactor = Redactor.default,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val newId: () -> String = { UUID.randomUUID().toString() },
    private val batchSize: Int = 1000,
) {
    private val locks = ConcurrentHashMap<String, Mutex>()
    private fun lock(id: String) = locks.getOrPut(id) { Mutex() }

    val sources: Flow<List<Source>> = db.sources().observeAll().map { list -> list.map { it.toModel() } }

    suspend fun all(): List<Source> = db.sources().all().map { it.toModel() }
    suspend fun get(id: String): Source? = db.sources().get(id)?.toModel()
    fun observe(id: String): Flow<Source?> = db.sources().observe(id).map { it?.toModel() }
    suspend fun byFingerprint(fp: String): Source? = db.sources().byFingerprint(fp)?.toModel()

    /** Secrets of [sourceId] (decrypted), registered with the log redactor. */
    fun secrets(sourceId: String): SourceSecrets? =
        secrets.get(SecretKeys.source(sourceId))?.let { runCatching { SourceSecrets.fromJson(it) }.getOrNull() }

    /** Registers all stored source secrets with the redactor (call once at startup). */
    suspend fun registerSecretsForRedaction() {
        for (s in db.sources().all()) secrets(s.id)?.let { redactor.register(*it.secretValues().toTypedArray()) }
    }

    /**
     * Validates and loads a new source. The source is persisted only when its catalog loaded
     * successfully; on failure nothing is stored (the form stays open with a specific error).
     */
    suspend fun add(name: String, sourceSecrets: SourceSecrets, onProgress: (RefreshProgress) -> Unit = {}): RefreshOutcome {
        val id = newId()
        redactor.register(*sourceSecrets.secretValues().toTypedArray())
        val gen = 1
        return try {
            val result = loadCatalog(id, sourceSecrets, gen, onProgress)
            val host = when (sourceSecrets) {
                is SourceSecrets.M3u -> UrlNormalizer.displayHost(sourceSecrets.url)
                is SourceSecrets.Xtream -> UrlNormalizer.displayHost(UrlNormalizer.xtreamBase(sourceSecrets.serverUrl))
            }
            val entity = SourceEntity(
                id = id,
                name = name.trim().ifEmpty { host },
                type = sourceSecrets.type.name,
                displayHost = host,
                fingerprint = ContentKeys.fingerprint(sourceSecrets),
                epgUrlOverride = sourceSecrets.epgUrl != null,
                createdAtMs = nowMs(),
                lastRefreshAtMs = nowMs(),
                statusJson = result.status.toJson(),
                accountJson = result.account?.toJson(),
                headerEpgUrls = result.headerEpgUrls.joinToString(",").ifEmpty { null },
                activeGen = gen,
                sort = db.sources().all().size,
            )
            secrets.put(SecretKeys.source(id), sourceSecrets.toJson())
            db.sources().upsert(entity)
            RefreshOutcome.Success(entity.toModel(), result.status)
        } catch (t: Throwable) {
            purgeGeneration(id, keepGen = -1)
            redactor.unregister(*sourceSecrets.secretValues().toTypedArray())
            val err = NetworkErrorClassifier.toSourceError(t)
            if (t is CancellationException) throw t
            SafeLog.w(TAG, "add failed: ${err.code}")
            RefreshOutcome.Failure(err)
        }
    }

    /** Replaces the secrets of an existing source (edit form) and refreshes. */
    suspend fun updateSecrets(sourceId: String, name: String, s: SourceSecrets, onProgress: (RefreshProgress) -> Unit = {}): RefreshOutcome {
        val old = secrets(sourceId)
        secrets.put(SecretKeys.source(sourceId), s.toJson())
        old?.let { redactor.unregister(*it.secretValues().toTypedArray()) }
        redactor.register(*s.secretValues().toTypedArray())
        db.sources().get(sourceId)?.let {
            db.sources().upsert(it.copy(name = name.trim().ifEmpty { it.name }, epgUrlOverride = s.epgUrl != null))
        }
        return refresh(sourceId, onProgress)
    }

    /** Full refresh of an existing source (atomic swap of the catalog). */
    suspend fun refresh(sourceId: String, onProgress: (RefreshProgress) -> Unit = {}): RefreshOutcome = lock(sourceId).withLock {
        val src = db.sources().get(sourceId) ?: return RefreshOutcome.Failure(SourceError.NotFound)
        val s = secrets(sourceId) ?: return RefreshOutcome.Failure(SourceError.InvalidCredentials)
        val gen = src.activeGen + 1
        purgeGeneration(sourceId, keepGen = src.activeGen) // leftovers of an interrupted refresh
        try {
            val result = loadCatalog(sourceId, s, gen, onProgress)
            db.withTransaction {
                db.sources().activate(
                    sourceId, gen, nowMs(), result.status.toJson(), result.account?.toJson(),
                    result.headerEpgUrls.joinToString(",").ifEmpty { null },
                )
                purgeGenerationInTx(sourceId, gen)
            }
            RefreshOutcome.Success(db.sources().get(sourceId)!!.toModel(), result.status)
        } catch (t: Throwable) {
            purgeGeneration(sourceId, keepGen = src.activeGen)
            if (t is CancellationException) throw t
            val err = NetworkErrorClassifier.toSourceError(t)
            SafeLog.w(TAG, "refresh failed: ${err.code}")
            // Keep the old catalog visible; only record the failure.
            db.sources().setStatus(sourceId, nowMs(), SourceStatus.failed(err).toJson())
            RefreshOutcome.Failure(err)
        }
    }

    suspend fun update(sourceId: String, transform: (SourceEntity) -> SourceEntity) {
        db.sources().get(sourceId)?.let { db.sources().upsert(transform(it)) }
    }

    suspend fun delete(sourceId: String) = lock(sourceId).withLock {
        secrets(sourceId)?.let { redactor.unregister(*it.secretValues().toTypedArray()) }
        db.withTransaction {
            db.sources().delete(sourceId)
            purgeGenerationInTx(sourceId, keepGen = -1)
            db.catalog().purgeEpg(sourceId, keepGen = -1)
        }
        secrets.remove(SecretKeys.source(sourceId))
    }

    // ---------------------------------------------------------------------------------- catalog

    private class CatalogResult(val status: SourceStatus, val account: XtreamAccountInfo?, val headerEpgUrls: List<String>)

    private suspend fun loadCatalog(sourceId: String, s: SourceSecrets, gen: Int, onProgress: (RefreshProgress) -> Unit): CatalogResult {
        onProgress(RefreshProgress.Connecting)
        val dao = db.catalog()
        return when (s) {
            is SourceSecrets.M3u -> {
                val mapper = M3uMapper(sourceId)
                var channels = 0
                var movies = 0
                val parse = M3uClient(http).fetch(s.url, s.userAgent, batchSize) { batch ->
                    val m = mapper.map(batch)
                    db.withTransaction {
                        dao.insertCategories(m.categories.map { it.toEntity(gen) })
                        dao.insertChannels(m.channels.map { it.toEntity(gen) })
                        dao.insertMovies(m.movies.map { it.toEntity(gen) })
                        dao.insertSeries(m.series.map { it.toEntity(gen) })
                        dao.insertEpisodes(m.episodes.map { it.toEntity(gen) })
                    }
                    channels += m.channels.size
                    movies += m.movies.size
                    onProgress(RefreshProgress.Channels(channels))
                }
                val c = dao.genCounts(sourceId, gen)
                SafeLog.d(TAG, "m3u parsed live=$channels movies=$movies stored live=${c.live} movies=${c.movies}")
                CatalogResult(
                    SourceStatus(ok = true, liveCount = c.live, movieCount = c.movies, seriesCount = c.series),
                    null,
                    parse.epgUrls,
                )
            }
            is SourceSecrets.Xtream -> {
                val client = XtreamClient(http, sourceId, s, nowMs = nowMs)
                onProgress(RefreshProgress.VerifyingAccount)
                val account = client.authenticate()
                val cats = client.liveCategories() + client.vodCategories() + client.seriesCategories()
                db.withTransaction { dao.insertCategories(cats.map { it.toEntity(gen) }) }
                var live = 0
                client.liveStreams(batchSize) { b ->
                    db.withTransaction { dao.insertChannels(b.map { it.toEntity(gen) }) }
                    live += b.size
                    onProgress(RefreshProgress.Channels(live))
                }
                var movies = 0
                client.vodStreams(batchSize) { b ->
                    db.withTransaction { dao.insertMovies(b.map { it.toEntity(gen) }) }
                    movies += b.size
                    onProgress(RefreshProgress.Movies(movies))
                }
                var series = 0
                client.series(batchSize) { b ->
                    db.withTransaction { dao.insertSeries(b.map { it.toEntity(gen) }) }
                    series += b.size
                    onProgress(RefreshProgress.Series(series))
                }
                if (live == 0 && movies == 0 && series == 0) throw SourceException(SourceError.Empty)
                CatalogResult(SourceStatus(ok = true, liveCount = live, movieCount = movies, seriesCount = series), account, emptyList())
            }
        }
    }

    private suspend fun purgeGeneration(sourceId: String, keepGen: Int) = db.withTransaction { purgeGenerationInTx(sourceId, keepGen) }

    private suspend fun purgeGenerationInTx(sourceId: String, keepGen: Int) {
        val dao = db.catalog()
        dao.purgeCategories(sourceId, keepGen)
        dao.purgeChannels(sourceId, keepGen)
        dao.purgeMovies(sourceId, keepGen)
        dao.purgeSeries(sourceId, keepGen)
        dao.purgeEpisodes(sourceId, keepGen)
    }

    /** Loads the episodes of an Xtream series on demand (M3U episodes come with the playlist). */
    suspend fun loadXtreamEpisodes(sourceId: String, seriesId: String) {
        val s = secrets(sourceId) as? SourceSecrets.Xtream ?: return
        val src = db.sources().get(sourceId) ?: return
        val info = XtreamClient(http, sourceId, s, nowMs = nowMs).seriesInfo(seriesId)
        db.withTransaction {
            db.catalog().deleteEpisodes(sourceId, seriesId)
            db.catalog().insertEpisodes(info.episodes.map { it.toEntity(src.activeGen) })
        }
    }

    // ---------------------------------------------------------------------------------- EPG

    /**
     * Imports the XMLTV guide of [sourceId] (CONTRACT §5): streaming parse, only programmes of
     * channels of this source and inside the retention window, written to a new EPG generation
     * that replaces the old one atomically. Returns the error (EPG failures never fail a refresh).
     */
    suspend fun importEpg(sourceId: String, onProgress: (RefreshProgress) -> Unit = {}): SourceError? = lock("epg:$sourceId").withLock {
        val src = db.sources().get(sourceId) ?: return null
        val s = secrets(sourceId) ?: return null
        val url = s.epgUrl
            ?: (s as? SourceSecrets.Xtream)?.let { XtreamClient(http, sourceId, it).xmltvUrl() }
            ?: src.headerEpgUrls?.split(',')?.map { it.trim() }?.firstOrNull { it.isNotEmpty() }
            ?: return null
        onProgress(RefreshProgress.Epg)
        val dao = db.catalog()
        val gen = src.epgGen + 1
        dao.purgeEpg(sourceId, keepGen = src.epgGen)
        val channels = dao.channelsForMatching(sourceId)
        val now = nowMs()
        val window = EpgRetention.window(now, CATCHUP_DAYS_KEPT)
        val xmlChannels = ArrayList<XmltvChannel>()
        var keep: Set<String>? = null
        return try {
            val result = EpgClient(http, XmltvParser(xmlParserFactory)).fetch(
                url = url,
                options = XmltvOptions(
                    preferredLanguage = Locale.getDefault().language,
                    shiftMinutes = src.epgShiftMinutes,
                    batchSize = batchSize,
                    window = window,
                ),
                onChannels = { xmlChannels += it },
            ) { programmes ->
                if (keep == null && xmlChannels.isNotEmpty()) {
                    val m = EpgMatcher(xmlChannels)
                    keep = channels.mapNotNull { m.match(it.epgId, it.name) }.toSet()
                }
                val k = keep
                val rows = programmes.asSequence()
                    .filter { k == null || it.channel in k }
                    .map { EpgEntity(sourceId, gen, it.channel, it.startMs, it.endMs, it.title, it.description, it.category) }
                    .toList()
                if (rows.isNotEmpty()) db.withTransaction { dao.insertEpg(rows) }
            }
            val matcher = EpgMatcher(xmlChannels, result.programmeChannelIds)
            db.withTransaction {
                for (c in channels) dao.setEpgKey(c.rowId, matcher.match(c.epgId, c.name))
                db.sources().activateEpg(sourceId, gen, now)
                dao.purgeEpg(sourceId, keepGen = gen)
            }
            updateStatus(sourceId) { it.copy(epgProgrammeCount = result.programmeCount, epgErrorCode = null) }
            null
        } catch (t: Throwable) {
            dao.purgeEpg(sourceId, keepGen = src.epgGen)
            if (t is CancellationException) throw t
            val err = NetworkErrorClassifier.toSourceError(t)
            SafeLog.w(TAG, "EPG import failed: ${err.code}")
            updateStatus(sourceId) { it.copy(epgErrorCode = err.code) }
            err
        }
    }

    private suspend fun updateStatus(sourceId: String, f: (SourceStatus) -> SourceStatus) {
        val e = db.sources().get(sourceId) ?: return
        val st = e.toModel().lastRefreshResult ?: return
        db.sources().upsert(e.copy(statusJson = f(st).toJson()))
    }

    companion object {
        private const val TAG = "Sources"

        /** Past EPG kept for catch-up (CONTRACT §5 uses max(catchupDays, 1)); Xtream archives are ≤ 7 days. */
        const val CATCHUP_DAYS_KEPT = 3
    }
}

/** True when [type] lists M3U. */
val Source.isM3u: Boolean get() = type == SourceType.M3U
