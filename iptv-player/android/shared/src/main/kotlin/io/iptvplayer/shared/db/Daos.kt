package io.iptvplayer.shared.db

import androidx.paging.PagingSource
import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

private const val GEN = "(SELECT activeGen FROM sources WHERE id = :sourceId)"
private const val EPG_GEN = "(SELECT epgGen FROM sources WHERE id = :sourceId)"

private const val CHANNEL_ROW = """
SELECT c.*,
 (SELECT e.title FROM epg e WHERE e.sourceId = c.sourceId AND e.gen = $EPG_GEN AND e.channelEpgId = c.epgKey
    AND e.endMs > :nowMs AND e.startMs <= :nowMs ORDER BY e.startMs DESC LIMIT 1) AS nowTitle,
 (SELECT e.startMs FROM epg e WHERE e.sourceId = c.sourceId AND e.gen = $EPG_GEN AND e.channelEpgId = c.epgKey
    AND e.endMs > :nowMs AND e.startMs <= :nowMs ORDER BY e.startMs DESC LIMIT 1) AS nowStart,
 (SELECT e.endMs FROM epg e WHERE e.sourceId = c.sourceId AND e.gen = $EPG_GEN AND e.channelEpgId = c.epgKey
    AND e.endMs > :nowMs AND e.startMs <= :nowMs ORDER BY e.startMs DESC LIMIT 1) AS nowEnd,
 (SELECT e.title FROM epg e WHERE e.sourceId = c.sourceId AND e.gen = $EPG_GEN AND e.channelEpgId = c.epgKey
    AND e.startMs > :nowMs ORDER BY e.startMs LIMIT 1) AS nextTitle,
 (SELECT e.startMs FROM epg e WHERE e.sourceId = c.sourceId AND e.gen = $EPG_GEN AND e.channelEpgId = c.epgKey
    AND e.startMs > :nowMs ORDER BY e.startMs LIMIT 1) AS nextStart
FROM channels c"""

@Dao
interface SourceDao {
    @Query("SELECT * FROM sources ORDER BY sort, createdAtMs")
    fun observeAll(): Flow<List<SourceEntity>>

    @Query("SELECT * FROM sources ORDER BY sort, createdAtMs")
    suspend fun all(): List<SourceEntity>

    @Query("SELECT * FROM sources WHERE id = :id")
    suspend fun get(id: String): SourceEntity?

    @Query("SELECT * FROM sources WHERE id = :id")
    fun observe(id: String): Flow<SourceEntity?>

    @Query("SELECT * FROM sources WHERE fingerprint = :fingerprint LIMIT 1")
    suspend fun byFingerprint(fingerprint: String): SourceEntity?

    @Upsert
    suspend fun upsert(source: SourceEntity)

    @Query("DELETE FROM sources WHERE id = :id")
    suspend fun delete(id: String)

    @Query("UPDATE sources SET activeGen = :gen, lastRefreshAtMs = :atMs, statusJson = :statusJson, accountJson = COALESCE(:accountJson, accountJson), headerEpgUrls = :headerEpgUrls WHERE id = :id")
    suspend fun activate(id: String, gen: Int, atMs: Long, statusJson: String, accountJson: String?, headerEpgUrls: String?)

    @Query("UPDATE sources SET lastRefreshAtMs = :atMs, statusJson = :statusJson WHERE id = :id")
    suspend fun setStatus(id: String, atMs: Long, statusJson: String)

    @Query("UPDATE sources SET epgGen = :gen, lastEpgAtMs = :atMs WHERE id = :id")
    suspend fun activateEpg(id: String, gen: Int, atMs: Long)
}

@Dao
interface CatalogDao {
    // ------------------------------------------------------------ writes (batched by callers)
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertCategories(items: List<CategoryEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertChannels(items: List<ChannelEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertMovies(items: List<MovieEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertSeries(items: List<SeriesEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertEpisodes(items: List<EpisodeEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertEpg(items: List<EpgEntity>)

    @Query("DELETE FROM categories WHERE sourceId = :sourceId AND gen != :keepGen")
    suspend fun purgeCategories(sourceId: String, keepGen: Int)

    @Query("DELETE FROM channels WHERE sourceId = :sourceId AND gen != :keepGen")
    suspend fun purgeChannels(sourceId: String, keepGen: Int)

    @Query("DELETE FROM movies WHERE sourceId = :sourceId AND gen != :keepGen")
    suspend fun purgeMovies(sourceId: String, keepGen: Int)

    @Query("DELETE FROM series WHERE sourceId = :sourceId AND gen != :keepGen")
    suspend fun purgeSeries(sourceId: String, keepGen: Int)

    @Query("DELETE FROM episodes WHERE sourceId = :sourceId AND gen != :keepGen")
    suspend fun purgeEpisodes(sourceId: String, keepGen: Int)

    @Query("DELETE FROM epg WHERE sourceId = :sourceId AND gen != :keepGen")
    suspend fun purgeEpg(sourceId: String, keepGen: Int)

    @Query("DELETE FROM epg WHERE sourceId = :sourceId AND endMs < :beforeMs")
    suspend fun purgeEpgBefore(sourceId: String, beforeMs: Long)

    @Query("DELETE FROM epg")
    suspend fun clearEpg()

    @Query("DELETE FROM episodes WHERE sourceId = :sourceId AND gen = $GEN AND seriesId = :seriesId")
    suspend fun deleteEpisodes(sourceId: String, seriesId: String)

    @Query("UPDATE channels SET epgKey = :epgKey WHERE rowId = :rowId")
    suspend fun setEpgKey(rowId: Long, epgKey: String?)

    // ------------------------------------------------------------ categories
    @Query("SELECT * FROM categories WHERE sourceId = :sourceId AND gen = $GEN AND kind = :kind ORDER BY sort")
    fun observeCategories(sourceId: String, kind: String): Flow<List<CategoryEntity>>

    // ------------------------------------------------------------ channels
    @Query("$CHANNEL_ROW WHERE c.sourceId = :sourceId AND c.gen = $GEN AND (:categoryId IS NULL OR c.categoryId = :categoryId) ORDER BY c.sort")
    fun channelRows(sourceId: String, categoryId: String?, nowMs: Long): PagingSource<Int, ChannelRow>

    @Query("$CHANNEL_ROW WHERE c.sourceId = :sourceId AND c.gen = $GEN AND c.id IN (:ids) ORDER BY c.sort")
    suspend fun channelRowsByIds(sourceId: String, ids: List<String>, nowMs: Long): List<ChannelRow>

    @Query("$CHANNEL_ROW WHERE c.sourceId = :sourceId AND c.gen = $GEN AND (:categoryId IS NULL OR c.categoryId = :categoryId) ORDER BY c.sort LIMIT :limit")
    suspend fun channelRowList(sourceId: String, categoryId: String?, nowMs: Long, limit: Int): List<ChannelRow>

    @Query("SELECT * FROM channels WHERE sourceId = :sourceId AND gen = $GEN AND (:categoryId IS NULL OR categoryId = :categoryId) ORDER BY sort")
    suspend fun channelList(sourceId: String, categoryId: String?): List<ChannelEntity>

    @Query("SELECT * FROM channels WHERE sourceId = :sourceId AND gen = $GEN AND id = :id")
    suspend fun channel(sourceId: String, id: String): ChannelEntity?

    @Query("SELECT rowId, epgId, name FROM channels WHERE sourceId = :sourceId AND gen = $GEN")
    suspend fun channelsForMatching(sourceId: String): List<ChannelMatchRow>

    /** Row counts of a (not yet active) generation – duplicates (same content key) collapse. */
    @Query("SELECT (SELECT COUNT(*) FROM channels WHERE sourceId = :sourceId AND gen = :gen) AS live, (SELECT COUNT(*) FROM movies WHERE sourceId = :sourceId AND gen = :gen) AS movies, (SELECT COUNT(*) FROM series WHERE sourceId = :sourceId AND gen = :gen) AS series")
    suspend fun genCounts(sourceId: String, gen: Int): GenCounts

    @Query("SELECT COUNT(*) FROM channels WHERE sourceId = :sourceId AND gen = $GEN")
    suspend fun channelCount(sourceId: String): Int

    @Query(
        """SELECT c.* FROM channels c JOIN channels_fts f ON c.rowId = f.rowid
           WHERE channels_fts MATCH :match AND c.sourceId = :sourceId AND c.gen = $GEN ORDER BY c.sort LIMIT :limit""",
    )
    suspend fun searchChannels(sourceId: String, match: String, limit: Int): List<ChannelEntity>

    // ------------------------------------------------------------ movies
    @Query("SELECT * FROM movies WHERE sourceId = :sourceId AND gen = $GEN AND (:categoryId IS NULL OR categoryId = :categoryId) ORDER BY addedAtMs DESC, sort")
    fun moviesByAdded(sourceId: String, categoryId: String?): PagingSource<Int, MovieEntity>

    @Query("SELECT * FROM movies WHERE sourceId = :sourceId AND gen = $GEN AND (:categoryId IS NULL OR categoryId = :categoryId) ORDER BY name COLLATE NOCASE")
    fun moviesByName(sourceId: String, categoryId: String?): PagingSource<Int, MovieEntity>

    @Query("SELECT * FROM movies WHERE sourceId = :sourceId AND gen = $GEN AND (:categoryId IS NULL OR categoryId = :categoryId) ORDER BY rating DESC, sort")
    fun moviesByRating(sourceId: String, categoryId: String?): PagingSource<Int, MovieEntity>

    @Query("SELECT * FROM movies WHERE sourceId = :sourceId AND gen = $GEN ORDER BY addedAtMs DESC, sort DESC LIMIT :limit")
    suspend fun recentMovies(sourceId: String, limit: Int): List<MovieEntity>

    @Query("SELECT * FROM movies WHERE sourceId = :sourceId AND gen = $GEN AND id = :id")
    suspend fun movie(sourceId: String, id: String): MovieEntity?

    @Query(
        """SELECT m.* FROM movies m JOIN movies_fts f ON m.rowId = f.rowid
           WHERE movies_fts MATCH :match AND m.sourceId = :sourceId AND m.gen = $GEN ORDER BY m.sort LIMIT :limit""",
    )
    suspend fun searchMovies(sourceId: String, match: String, limit: Int): List<MovieEntity>

    // ------------------------------------------------------------ series
    @Query("SELECT * FROM series WHERE sourceId = :sourceId AND gen = $GEN AND (:categoryId IS NULL OR categoryId = :categoryId) ORDER BY lastModifiedMs DESC, sort")
    fun seriesByAdded(sourceId: String, categoryId: String?): PagingSource<Int, SeriesEntity>

    @Query("SELECT * FROM series WHERE sourceId = :sourceId AND gen = $GEN AND (:categoryId IS NULL OR categoryId = :categoryId) ORDER BY name COLLATE NOCASE")
    fun seriesByName(sourceId: String, categoryId: String?): PagingSource<Int, SeriesEntity>

    @Query("SELECT * FROM series WHERE sourceId = :sourceId AND gen = $GEN AND (:categoryId IS NULL OR categoryId = :categoryId) ORDER BY rating DESC, sort")
    fun seriesByRating(sourceId: String, categoryId: String?): PagingSource<Int, SeriesEntity>

    @Query("SELECT * FROM series WHERE sourceId = :sourceId AND gen = $GEN ORDER BY lastModifiedMs DESC, sort DESC LIMIT :limit")
    suspend fun recentSeries(sourceId: String, limit: Int): List<SeriesEntity>

    @Query("SELECT * FROM series WHERE sourceId = :sourceId AND gen = $GEN AND id = :id")
    suspend fun series(sourceId: String, id: String): SeriesEntity?

    @Query(
        """SELECT s.* FROM series s JOIN series_fts f ON s.rowId = f.rowid
           WHERE series_fts MATCH :match AND s.sourceId = :sourceId AND s.gen = $GEN ORDER BY s.sort LIMIT :limit""",
    )
    suspend fun searchSeries(sourceId: String, match: String, limit: Int): List<SeriesEntity>

    @Query("SELECT * FROM episodes WHERE sourceId = :sourceId AND gen = $GEN AND seriesId = :seriesId ORDER BY season, number")
    suspend fun episodes(sourceId: String, seriesId: String): List<EpisodeEntity>

    @Query("SELECT * FROM episodes WHERE sourceId = :sourceId AND gen = $GEN AND id = :id")
    suspend fun episode(sourceId: String, id: String): EpisodeEntity?

    @Query("SELECT COUNT(*) FROM movies WHERE sourceId = :sourceId AND gen = $GEN")
    suspend fun movieCount(sourceId: String): Int

    @Query("SELECT COUNT(*) FROM series WHERE sourceId = :sourceId AND gen = $GEN")
    suspend fun seriesCount(sourceId: String): Int

    // ------------------------------------------------------------ EPG
    @Query(
        """SELECT * FROM epg WHERE sourceId = :sourceId AND gen = $EPG_GEN AND channelEpgId = :epgKey
           AND endMs > :fromMs AND startMs < :toMs ORDER BY startMs""",
    )
    suspend fun programmes(sourceId: String, epgKey: String, fromMs: Long, toMs: Long): List<EpgEntity>

    @Query(
        """SELECT * FROM epg WHERE sourceId = :sourceId AND gen = $EPG_GEN AND channelEpgId IN (:epgKeys)
           AND endMs > :fromMs AND startMs < :toMs ORDER BY channelEpgId, startMs""",
    )
    suspend fun programmesFor(sourceId: String, epgKeys: List<String>, fromMs: Long, toMs: Long): List<EpgEntity>
}

@Dao
interface LibraryDao {
    @Upsert
    suspend fun upsert(items: List<LibraryEntity>)

    @Query("SELECT * FROM library WHERE `key` = :key")
    suspend fun get(key: String): LibraryEntity?

    @Query("SELECT * FROM library WHERE `key` IN (:keys)")
    suspend fun getAll(keys: List<String>): List<LibraryEntity>

    @Query("SELECT * FROM library WHERE kind = 'favorite' AND deleted = 0 ORDER BY sortOrder, updatedAt DESC")
    fun observeFavorites(): Flow<List<LibraryEntity>>

    @Query("SELECT * FROM library WHERE kind = 'progress' AND deleted = 0 ORDER BY updatedAt DESC LIMIT :limit")
    fun observeProgress(limit: Int): Flow<List<LibraryEntity>>

    @Query("SELECT * FROM library WHERE kind = 'progress' AND deleted = 0 AND seriesKey = :seriesKey ORDER BY updatedAt DESC")
    suspend fun progressForSeries(seriesKey: String): List<LibraryEntity>

    @Query("SELECT * FROM library WHERE dirty = 1 ORDER BY updatedAt LIMIT :limit")
    suspend fun dirty(limit: Int): List<LibraryEntity>

    @Query("UPDATE library SET dirty = 0 WHERE `key` = :key AND updatedAt = :updatedAt")
    suspend fun markClean(key: String, updatedAt: Long)

    @Query("SELECT COUNT(*) FROM library WHERE dirty = 1")
    suspend fun dirtyCount(): Int

    @Query("SELECT * FROM library")
    suspend fun all(): List<LibraryEntity>

    @Query("DELETE FROM library")
    suspend fun clear()
}
