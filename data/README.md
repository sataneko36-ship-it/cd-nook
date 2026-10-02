# Anime name index

`AnimeTitles.json` contains titles, aliases and the Bangumi key-visual path of each
subject, extracted from the locally installed [AnimeGarden bgmd](https://github.com/AnimeGarden/bgmd)
snapshot `0.20260707.1`. The titles are used for on-device name matching. `poster` is only
the path part of the Bangumi image URL (`https://lain.bgm.tv/pic/cover/l/<poster>`); the
image itself is downloaded once, when a CD of that series has no sleeve of its own, and
kept in the library's `.series-artwork` folder. The `bgmd` package declares the MIT
license. Regenerate from a newer local snapshot before shipping a future version if the
user's installed data is updated.
