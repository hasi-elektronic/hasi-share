package io.iptvplayer.shared.repo

import androidx.room.withTransaction
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.sync.SyncItem
import io.iptvplayer.core.sync.SyncItemData
import io.iptvplayer.core.sync.SyncKind
import io.iptvplayer.core.sync.SyncMerge
import io.iptvplayer.core.sync.WatchHistory
import io.iptvplayer.shared.db.AppDatabase
import io.iptvplayer.shared.db.LibraryEntity
import io.iptvplayer.shared.sync.SyncStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.map

/**
 * Favorites and watch progress, stored locally as sync items (CONTRACT §8) so they survive
 * refreshes (keyed by content key) and can be synchronized last-writer-wins.
 */
class LibraryRepository(
    private val db: AppDatabase,
    private val nowMs: () -> Long = System::currentTimeMillis,
) : SyncStore {
    private val dao get() = db.library()
    private val _changes = MutableSharedFlow<Unit>(extraBufferCapacity = 16)

    /** Emits after every local change (SyncManager schedules a debounced push). */
    val localChanges: SharedFlow<Unit> = _changes

    val favorites: Flow<List<LibraryEntity>> = dao.observeFavorites()
    val favoriteKeys: Flow<Set<String>> = favorites.map { l -> l.mapTo(HashSet()) { it.contentKey } }

    /** "Continue watching" (5 % < progress < 95 %). */
    val continueWatching: Flow<List<LibraryEntity>> = dao.observeProgress(200).map { list ->
        val items = list.map { it.toSyncItem() }
        val keep = WatchHistory.continueWatching(items).mapTo(HashSet()) { it.key }
        list.filter { it.key in keep && it.contentKind != ContentKind.LIVE.wire }
    }

    /** Recently watched live channels (max 50). */
    val recentChannels: Flow<List<LibraryEntity>> = dao.observeProgress(WatchHistory.RECENT_LIMIT * 2).map { l ->
        l.filter { it.contentKind == ContentKind.LIVE.wire }.take(WatchHistory.RECENT_LIMIT)
    }

    suspend fun isFavorite(contentKey: String): Boolean = dao.get(SyncItem.favoriteKey(contentKey))?.deleted == false

    suspend fun toggleFavorite(contentKey: String, title: String, kind: ContentKind, posterUrl: String?): Boolean {
        val now = isFavorite(contentKey)
        setFavorite(contentKey, title, kind, posterUrl, !now)
        return !now
    }

    suspend fun setFavorite(contentKey: String, title: String, kind: ContentKind, posterUrl: String?, favorite: Boolean) {
        val item = SyncItem.favorite(contentKey, title, kind, posterUrl, nowMs(), deleted = !favorite)
        dao.upsert(listOf(item.toEntity(dirty = true)))
        _changes.tryEmit(Unit)
    }

    suspend fun progress(contentKey: String): LibraryEntity? = dao.get(SyncItem.progressKey(contentKey))?.takeUnless { it.deleted }

    suspend fun saveProgress(
        contentKey: String,
        title: String,
        kind: ContentKind,
        positionMs: Long,
        durationMs: Long,
        posterUrl: String? = null,
        seriesKey: String? = null,
    ) {
        val item = SyncItem.progress(contentKey, title, kind, positionMs, durationMs, nowMs(), posterUrl, seriesKey)
        dao.upsert(listOf(item.toEntity(dirty = true)))
        _changes.tryEmit(Unit)
    }

    suspend fun progressForSeries(seriesKey: String): List<LibraryEntity> = dao.progressForSeries(seriesKey)

    // ------------------------------------------------------------------ sync plumbing

    /** Applies server items with the LWW rule; returns how many were applied. */
    override suspend fun applyRemote(items: List<SyncItem>): Int = db.withTransaction {
        if (items.isEmpty()) return@withTransaction 0
        val local = dao.getAll(items.map { it.key }.distinct()).associate { it.key to it.toSyncItem() }
        val r = SyncMerge.merge(local, items)
        dao.upsert(r.applied.map { it.toEntity(dirty = false) })
        r.applied.size
    }

    override suspend fun pendingPush(limit: Int): List<SyncItem> = dao.dirty(limit).map { it.toSyncItem() }

    override suspend fun markPushed(items: List<SyncItem>) = db.withTransaction {
        for (i in items) dao.markClean(i.key, i.updatedAt)
    }

    suspend fun pendingCount(): Int = dao.dirtyCount()

    /** Marks everything dirty (first sync after sign-in uploads the local library). */
    suspend fun markAllDirty() = db.withTransaction { dao.upsert(dao.all().map { it.copy(dirty = true) }) }
}

fun LibraryEntity.toSyncItem() = SyncItem(
    key = key,
    kind = if (kind == SyncKind.FAVORITE.wire) SyncKind.FAVORITE else SyncKind.PROGRESS,
    data = SyncItemData(title, ContentKind.fromWire(contentKind), posterUrl, positionMs, durationMs, seriesKey),
    updatedAt = updatedAt,
    deleted = deleted,
)

fun SyncItem.toEntity(dirty: Boolean) = LibraryEntity(
    key = key,
    kind = kind.wire,
    contentKey = contentKey,
    contentKind = data.contentKind?.wire,
    title = data.title,
    posterUrl = data.posterUrl,
    positionMs = data.positionMs,
    durationMs = data.durationMs,
    seriesKey = data.seriesKey,
    updatedAt = updatedAt,
    deleted = deleted,
    dirty = dirty,
)
