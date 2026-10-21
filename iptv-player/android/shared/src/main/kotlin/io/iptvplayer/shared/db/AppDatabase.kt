package io.iptvplayer.shared.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [
        SourceEntity::class, CategoryEntity::class,
        ChannelEntity::class, ChannelFts::class,
        MovieEntity::class, MovieFts::class,
        SeriesEntity::class, SeriesFts::class,
        EpisodeEntity::class, EpgEntity::class, LibraryEntity::class,
    ],
    version = 1,
    exportSchema = true,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun sources(): SourceDao
    abstract fun catalog(): CatalogDao
    abstract fun library(): LibraryDao

    companion object {
        /** Database file name (`databases/iptv.db`, excluded from backups). */
        const val NAME = "iptv.db"

        fun create(context: Context): AppDatabase =
            Room.databaseBuilder(context.applicationContext, AppDatabase::class.java, NAME)
                // Content is a cache of the user's sources; a schema change simply re-downloads.
                // Library (favorites/progress) is synced when an account exists.
                .fallbackToDestructiveMigration(dropAllTables = true)
                .setJournalMode(JournalMode.WRITE_AHEAD_LOGGING)
                .build()

        fun inMemory(context: Context): AppDatabase =
            Room.inMemoryDatabaseBuilder(context.applicationContext, AppDatabase::class.java)
                .allowMainThreadQueries()
                .build()
    }
}
