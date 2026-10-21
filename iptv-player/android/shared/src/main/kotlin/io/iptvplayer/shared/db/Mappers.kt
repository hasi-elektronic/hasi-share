package io.iptvplayer.shared.db

import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.model.CatchupInfo
import io.iptvplayer.core.model.CatchupType
import io.iptvplayer.core.model.Category
import io.iptvplayer.core.model.Channel
import io.iptvplayer.core.model.Episode
import io.iptvplayer.core.model.EpgProgram
import io.iptvplayer.core.model.Movie
import io.iptvplayer.core.model.Series
import io.iptvplayer.core.model.Source
import io.iptvplayer.core.model.SourceStatus
import io.iptvplayer.core.model.SourceType
import io.iptvplayer.core.model.XtreamAccountInfo

fun Category.toEntity(gen: Int) = CategoryEntity(sourceId, gen, kind.wire, id, name, sort)

fun Channel.toEntity(gen: Int) = ChannelEntity(
    sourceId = sourceId, gen = gen, id = id, name = name, number = number, logoUrl = logoUrl,
    categoryId = categoryId, epgId = epgId, catchupType = catchup.type.wire, catchupDays = catchup.days,
    catchupSource = catchup.source, url = url, userAgent = userAgent, referrer = referrer, drm = drm,
    sort = sort, tvgShiftHours = tvgShiftHours,
)

fun ChannelEntity.toModel() = Channel(
    sourceId = sourceId, id = id, name = name, number = number, logoUrl = logoUrl, categoryId = categoryId,
    epgId = epgId, catchup = CatchupInfo(CatchupType.fromWire(catchupType), catchupDays, catchupSource),
    url = url, userAgent = userAgent, referrer = referrer, drm = drm, sort = sort, tvgShiftHours = tvgShiftHours,
)

fun Movie.toEntity(gen: Int) = MovieEntity(
    sourceId = sourceId, gen = gen, id = id, name = name, posterUrl = posterUrl, categoryId = categoryId,
    rating = rating, year = year, plot = plot, containerExt = containerExt, url = url, addedAtMs = addedAtMs, sort = sort,
)

fun Series.toEntity(gen: Int) = SeriesEntity(
    sourceId = sourceId, gen = gen, id = id, name = name, posterUrl = posterUrl, categoryId = categoryId,
    plot = plot, rating = rating, year = year, sort = sort, lastModifiedMs = lastModifiedMs,
)

fun Episode.toEntity(gen: Int) = EpisodeEntity(
    sourceId = sourceId, gen = gen, id = id, seriesId = seriesId, season = season, number = number, title = title,
    containerExt = containerExt, durationSec = durationSec, plot = plot, posterUrl = posterUrl, url = url,
)

fun EpgEntity.toModel() = EpgProgram(sourceId, channelEpgId, startMs, endMs, title, description, category)

fun SourceEntity.toModel(): Source = Source(
    id = id,
    name = name,
    type = SourceType.valueOf(type),
    displayHost = displayHost,
    fingerprint = fingerprint,
    epgUrlOverride = epgUrlOverride,
    epgShiftMinutes = epgShiftMinutes,
    autoRefreshHours = autoRefreshHours,
    createdAtMs = createdAtMs,
    lastRefreshAtMs = lastRefreshAtMs,
    lastRefreshResult = statusJson?.let { runCatching { CoreJson.decodeFromString(SourceStatus.serializer(), it) }.getOrNull() },
    xtreamAccount = accountJson?.let { runCatching { CoreJson.decodeFromString(XtreamAccountInfo.serializer(), it) }.getOrNull() },
)

fun SourceStatus.toJson(): String = CoreJson.encodeToString(SourceStatus.serializer(), this)
fun XtreamAccountInfo.toJson(): String = CoreJson.encodeToString(XtreamAccountInfo.serializer(), this)
