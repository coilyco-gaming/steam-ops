# Tool result shapes

Every Web API response keeps `{source, count, items}`, and every plane adds an
explicit `provenance.plane` of `web_api`, `storefront`, or `client_pics`.

Web API items are normalized game records: `appid`, `name`,
`playtime_forever_minutes`, `playtime_forever_hours`,
`playtime_2weeks_minutes`, and `last_played_unix`, which is `None` when Steam
reports no last-play or the profile is private.

`get_owned_games` reads `IPlayerService/GetOwnedGames` with
`include_appinfo=1&include_played_free_games=1`. `get_recently_played` reads
`IPlayerService/GetRecentlyPlayedGames`.

The storefront calls are unauthenticated on purpose: no Web API key and no
account cookie travels to the storefront. The PICS calls are authenticated and
read-only, and package access tokens are not included in tool results.

## See also

- [FEATURES.md](FEATURES.md) - the capability inventory.
