package io.iptvplayer.core.m3u

import io.iptvplayer.core.model.CatchupInfo
import io.iptvplayer.core.model.CatchupType
import io.iptvplayer.core.model.Category
import io.iptvplayer.core.model.Channel
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.Episode
import io.iptvplayer.core.model.Movie
import io.iptvplayer.core.model.Series
import io.iptvplayer.core.util.ContentKeys
import io.iptvplayer.core.util.Sha256
import io.iptvplayer.core.util.UrlNormalizer
import java.util.Locale

/**
 * Domain objects produced from one batch of M3U entries by [M3uMapper].
 * [categories] and [series] contain only items first seen in this batch.
 */
public data class M3uMappedBatch(
    val categories: List<Category>,
    val channels: List<Channel>,
    val movies: List<Movie>,
    val series: List<Series>,
    val episodes: List<Episode>,
)

/**
 * Converts [M3uEntry] batches into the domain model (stateful across batches of one refresh):
 *
 * * item ids: `"u" + sha256(url)[0..16]` (CONTRACT §1.1), so content keys are stable;
 * * category id = group title (per kind: live → LIVE, movie → MOVIE, episode → SERIES);
 *   entries without group get `categoryId = null` (UI shows "Other");
 * * episodes are grouped into series by the detected series name
 *   (fallback: group title, then entry name); series id = `"s" + sha256(lowercase name)[0..16]`;
 * * `sort` keeps playlist order.
 */
public class M3uMapper(private val sourceId: String) {
    private val categories = HashMap<String, Category>()
    private val series = HashMap<String, Series>()
    private var channelSort = 0
    private var movieSort = 0
    private var seriesSort = 0
    private val categorySort = HashMap<ContentKind, Int>()

    /** Number of distinct categories seen so far. */
    public val categoryCount: Int get() = categories.size

    /** Number of distinct series seen so far. */
    public val seriesCount: Int get() = series.size

    /** Maps one batch. */
    public fun map(batch: List<M3uEntry>): M3uMappedBatch {
        val newCategories = ArrayList<Category>()
        val channels = ArrayList<Channel>()
        val movies = ArrayList<Movie>()
        val newSeries = ArrayList<Series>()
        val episodes = ArrayList<Episode>()
        for (e in batch) {
            val itemId = ContentKeys.m3uItemId(e.url)
            when (e.kind) {
                ContentKind.LIVE -> {
                    val cat = category(ContentKind.LIVE, e.group, newCategories)
                    channels += Channel(
                        sourceId = sourceId,
                        id = itemId,
                        name = e.name,
                        number = e.chno,
                        logoUrl = e.logo,
                        categoryId = cat,
                        epgId = e.tvgId,
                        catchup = e.catchup?.let {
                            CatchupInfo(CatchupType.fromWire(it.type), it.days, it.source)
                        } ?: CatchupInfo.NONE,
                        url = e.url,
                        userAgent = e.userAgent,
                        referrer = e.referrer,
                        drm = e.drm,
                        sort = channelSort++,
                        tvgShiftHours = e.tvgShiftHours,
                    )
                }
                ContentKind.MOVIE -> {
                    val cat = category(ContentKind.MOVIE, e.group, newCategories)
                    movies += Movie(
                        sourceId = sourceId,
                        id = itemId,
                        name = e.name,
                        posterUrl = e.logo,
                        categoryId = cat,
                        year = YEAR_IN_TITLE.find(e.name)?.groupValues?.get(1)?.toIntOrNull(),
                        containerExt = UrlNormalizer.pathExtension(e.url),
                        url = e.url,
                        sort = movieSort++,
                    )
                }
                ContentKind.EPISODE, ContentKind.SERIES -> {
                    val cat = category(ContentKind.SERIES, e.group, newCategories)
                    val seriesName = e.series?.name?.takeIf { it.isNotBlank() } ?: e.group ?: e.name
                    val seriesId = seriesId(seriesName)
                    if (!series.containsKey(seriesId)) {
                        val s = Series(
                            sourceId = sourceId,
                            id = seriesId,
                            name = seriesName,
                            posterUrl = e.logo,
                            categoryId = cat,
                            sort = seriesSort++,
                        )
                        series[seriesId] = s
                        newSeries += s
                    }
                    episodes += Episode(
                        sourceId = sourceId,
                        id = itemId,
                        seriesId = seriesId,
                        season = e.series?.season ?: 1,
                        number = e.series?.episode ?: 0,
                        title = e.name,
                        containerExt = UrlNormalizer.pathExtension(e.url),
                        durationSec = e.duration.takeIf { it > 0 }?.toInt(),
                        posterUrl = e.logo,
                        url = e.url,
                    )
                }
            }
        }
        return M3uMappedBatch(newCategories, channels, movies, newSeries, episodes)
    }

    private fun category(kind: ContentKind, group: String?, out: MutableList<Category>): String? {
        val name = group?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val key = kind.wire + "\u0000" + name
        if (!categories.containsKey(key)) {
            val sort = categorySort.getOrElse(kind) { 0 }
            categorySort[kind] = sort + 1
            val c = Category(sourceId = sourceId, id = name, kind = kind, name = name, sort = sort)
            categories[key] = c
            out += c
        }
        return name
    }

    public companion object {
        private val YEAR_IN_TITLE = Regex("""\((19\d{2}|20\d{2})\)""")

        /** Stable M3U series id for a series name. */
        public fun seriesId(name: String): String = "s" + Sha256.hex(name.trim().lowercase(Locale.ROOT)).substring(0, 16)
    }
}
