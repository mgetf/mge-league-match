#pragma semicolon 1
#pragma newdecls required

#if defined MAXPLAYERS
    #undef MAXPLAYERS
    #define MAXPLAYERS 101
#endif

#include <sourcemod>
#include <morecolors>
#include <ripext>
#include <mge>

#define PLUGIN_VERSION "0.1"
#define MAX_ARENAS 64
#define MAX_SEASONS 32
#define SIDE_MAX 8
#define STEAM64_LEN 22
#define NAME_LEN 64
#define WL_LEN 64
#define LINE_LEN 192
#define URL_LEN 256

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (GetEngineVersion() != Engine_TF2)
    {
        strcopy(error, err_max, "This plugin is for Team Fortress 2 only.");
        return APLRes_Failure;
    }

    return APLRes_Success;
}

public Plugin myinfo =
{
    name = "MGE League Match",
    author = "mge.tf",
    description = "Locks an MGE arena for a pending mge.tf league match",
    version = PLUGIN_VERSION,
    url = "https://mge.tf"
};

ConVar g_cvApi;
ConVar g_cvWhitelist;

int g_iSerial[MAXPLAYERS + 1];
bool g_bBusy[MAXPLAYERS + 1];
int g_iSeasonIds[MAXPLAYERS + 1][MAX_SEASONS];
int g_iSeasonCount[MAXPLAYERS + 1];

bool g_bLocked[MAX_ARENAS];
bool g_bOverride[MAX_ARENAS];
int g_iMatchId[MAX_ARENAS];
int g_iAllowedCount[MAX_ARENAS];
char g_sAllowed[MAX_ARENAS][SIDE_MAX][STEAM64_LEN];

public void OnPluginStart()
{
    g_cvApi = CreateConVar(
        "mge_league_match_api",
        "https://mge.tf",
        "Base URL of the mge.tf public league API",
        FCVAR_NONE
    );
    g_cvWhitelist = CreateConVar(
        "mge_league_match_whitelist",
        "",
        "whitelist.tf id used when the match payload has no whitelist",
        FCVAR_NONE
    );

    RegConsoleCmd("sm_match", Command_Match, "Show your pending league match and lock the arena if your opponent is in it");
    LoadTranslations("mge_league_match.phrases");
    AutoExecConfig(true, "mge_league_match");
}

public void OnPluginEnd()
{
    for (int arena = 1; arena < MAX_ARENAS; arena++)
    {
        if (g_bLocked[arena])
            UnlockArena(arena, false);
    }
}

public void OnMapEnd()
{
    for (int arena = 1; arena < MAX_ARENAS; arena++)
    {
        if (g_bLocked[arena])
            UnlockArena(arena, false);
    }
}

public void OnClientDisconnect(int client)
{
    g_iSerial[client]++;
    g_bBusy[client] = false;
    g_iSeasonCount[client] = 0;
}

public Action Command_Match(int client, int args)
{
    if (client == 0)
    {
        Reply(client, "ConsoleOnly");
        return Plugin_Handled;
    }

    if (!IsClientInGame(client))
        return Plugin_Handled;

    if (g_bBusy[client])
    {
        Reply(client, "Busy");
        return Plugin_Handled;
    }

    char steam[STEAM64_LEN];
    if (!GetClientAuthId(client, AuthId_SteamID64, steam, sizeof(steam)))
    {
        Reply(client, "NoSteamId");
        return Plugin_Handled;
    }

    char base[192];
    if (!ReadApiBase(base, sizeof(base)))
    {
        Reply(client, "ApiEmpty");
        return Plugin_Handled;
    }

    g_bBusy[client] = true;
    g_iSerial[client]++;
    g_iSeasonCount[client] = 0;

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_iSerial[client]);
    pack.WriteString(steam);

    char url[URL_LEN];
    FormatEx(url, sizeof(url), "%s/api/v1/seasons", base);
    HTTPRequest request = new HTTPRequest(url);
    request.ConnectTimeout = 5;
    request.Timeout = 10;
    request.SetHeader("Accept", "application/json");
    request.SetHeader("User-Agent", "mge_league_match/%s", PLUGIN_VERSION);
    request.AppendQueryParam("current", "true");
    request.Get(OnSeasons, pack);
    return Plugin_Handled;
}

public void OnSeasons(HTTPResponse response, DataPack pack, const char[] error)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int serial = pack.ReadCell();
    char steam[STEAM64_LEN];
    pack.ReadString(steam, sizeof(steam));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client == 0 || g_iSerial[client] != serial)
        return;

    if (response.Status != HTTPStatus_OK)
    {
        FailRequest(client, response.Status, error);
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    if (root == null || !root.HasKey("data") || root.IsNull("data"))
    {
        g_bBusy[client] = false;
        Reply(client, "SeasonsMissing");
        return;
    }

    if (root.HasKey("page") && !root.IsNull("page"))
    {
        JSONObject page = view_as<JSONObject>(root.Get("page"));
        if (page != null && page.HasKey("totalPages") && !page.IsNull("totalPages") && page.GetInt("totalPages") > 1)
            LogMessage("[mge_league_match] Current seasons span more than one page");
        delete page;
    }

    JSONArray data = view_as<JSONArray>(root.Get("data"));
    int length = data.Length;
    for (int i = 0; i < length && g_iSeasonCount[client] < MAX_SEASONS; i++)
    {
        if (data.IsNull(i))
            continue;

        JSONObject season = view_as<JSONObject>(data.Get(i));
        if (season != null && season.HasKey("id") && !season.IsNull("id"))
        {
            g_iSeasonIds[client][g_iSeasonCount[client]] = season.GetInt("id");
            g_iSeasonCount[client]++;
        }
        delete season;
    }
    delete data;

    if (g_iSeasonCount[client] == 0)
    {
        g_bBusy[client] = false;
        Reply(client, "NoActiveSeason");
        return;
    }

    char base[192];
    if (!ReadApiBase(base, sizeof(base)))
    {
        g_bBusy[client] = false;
        Reply(client, "ApiEmpty");
        return;
    }

    DataPack next = new DataPack();
    next.WriteCell(userid);
    next.WriteCell(serial);

    char url[URL_LEN];
    FormatEx(url, sizeof(url), "%s/api/v1/matches", base);
    HTTPRequest request = new HTTPRequest(url);
    request.ConnectTimeout = 5;
    request.Timeout = 10;
    request.SetHeader("Accept", "application/json");
    request.SetHeader("User-Agent", "mge_league_match/%s", PLUGIN_VERSION);
    request.AppendQueryParam("player", "%s", steam);
    request.AppendQueryParam("status", "unplayed");
    request.Get(OnMatches, next);
}

public void OnMatches(HTTPResponse response, DataPack pack, const char[] error)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int serial = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client == 0 || g_iSerial[client] != serial)
        return;

    g_bBusy[client] = false;

    if (response.Status != HTTPStatus_OK)
    {
        FailRequest(client, response.Status, error);
        return;
    }

    char steam[STEAM64_LEN];
    if (!GetClientAuthId(client, AuthId_SteamID64, steam, sizeof(steam)))
    {
        Reply(client, "NoSteamId");
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    if (root == null || !root.HasKey("data") || root.IsNull("data"))
    {
        Reply(client, "MatchesMissing");
        return;
    }

    if (root.HasKey("page") && !root.IsNull("page"))
    {
        JSONObject page = view_as<JSONObject>(root.Get("page"));
        if (page != null && page.HasKey("totalPages") && !page.IsNull("totalPages") && page.GetInt("totalPages") > 1)
            LogMessage("[mge_league_match] %N has more than one page of unplayed matches", client);
        delete page;
    }

    int shown = 0;
    bool chose = false;
    int lockMatchId = 0;
    int lockArena = 0;
    char lockNames[LINE_LEN];
    char lockWhitelist[WL_LEN];
    bool lockFromMatch = false;
    char lockAllowed[SIDE_MAX][STEAM64_LEN];
    int lockAllowedCount = 0;
    lockNames[0] = '\0';
    lockWhitelist[0] = '\0';

    int arena = 0;
    bool inArena = MGE_IsPlayerInArena(client);
    if (inArena)
        arena = MGE_GetPlayerArena(client);

    JSONArray data = view_as<JSONArray>(root.Get("data"));
    int length = data.Length;
    for (int i = 0; i < length; i++)
    {
        if (data.IsNull(i))
            continue;

        JSONObject match = view_as<JSONObject>(data.Get(i));
        if (match == null)
            continue;

        if (!MatchIsCurrent(client, match))
        {
            delete match;
            continue;
        }

        char homeSteam[SIDE_MAX][STEAM64_LEN];
        char awaySteam[SIDE_MAX][STEAM64_LEN];
        char homeNames[SIDE_MAX][NAME_LEN];
        char awayNames[SIDE_MAX][NAME_LEN];
        int homeCount = CollectSide(match, "home", homeSteam, homeNames);
        int awayCount = CollectSide(match, "away", awaySteam, awayNames);

        bool onHome = SteamInList(steam, homeSteam, homeCount);
        bool onAway = SteamInList(steam, awaySteam, awayCount);
        if (onHome == onAway)
        {
            delete match;
            continue;
        }

        char names[LINE_LEN];
        if (onHome)
            JoinNames(client, awayNames, awayCount, names, sizeof(names));
        else
            JoinNames(client, homeNames, homeCount, names, sizeof(names));

        AnnounceMatch(client, match, names);
        shown++;

        bool opponentsHere = false;
        if (inArena && arena >= 1 && arena < MAX_ARENAS)
        {
            if (onHome)
                opponentsHere = OpponentsInArena(arena, awaySteam, awayCount);
            else
                opponentsHere = OpponentsInArena(arena, homeSteam, homeCount);
        }

        if (!chose && opponentsHere)
        {
            chose = true;
            lockMatchId = match.HasKey("id") && !match.IsNull("id") ? match.GetInt("id") : 0;
            lockArena = arena;
            strcopy(lockNames, sizeof(lockNames), names);
            lockFromMatch = ResolveWhitelist(match, lockWhitelist, sizeof(lockWhitelist));
            lockAllowedCount = CopyAllowed(homeSteam, homeCount, awaySteam, awayCount, lockAllowed);
        }

        delete match;
    }
    delete data;

    if (shown == 0)
    {
        Reply(client, "NoPendingMatch");
        return;
    }

    if (!chose)
    {
        if (inArena)
            Reply(client, "RivalsMissing");
        else
            Reply(client, "EnterArena");
        return;
    }

    if (g_bLocked[lockArena])
    {
        Reply(client, "AlreadyLocked");
        return;
    }

    LockArena(client, lockArena, lockMatchId, lockNames, lockWhitelist, lockFromMatch, lockAllowed, lockAllowedCount);
}

public Action MGE_OnPlayerArenaAdd(int client, int arena, int slot)
{
    if (arena < 1 || arena >= MAX_ARENAS || !g_bLocked[arena])
        return Plugin_Continue;

    if (client >= 1 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client))
    {
        char steam[STEAM64_LEN];
        if (GetClientAuthId(client, AuthId_SteamID64, steam, sizeof(steam)) && SteamAllowed(arena, steam))
            return Plugin_Continue;
    }

    if (client >= 1 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client))
        Reply(client, "ArenaBlocked");

    return Plugin_Stop;
}

public void MGE_OnPlayerArenaRemoved(int client, int arena)
{
    if (arena < 1 || arena >= MAX_ARENAS || !g_bLocked[arena])
        return;

    if (!ArenaHasParticipant(arena))
        UnlockArena(arena, true);
}

void LockArena(int client, int arena, int matchId, const char[] names, const char[] whitelist, bool fromMatch, const char allowed[][STEAM64_LEN], int allowedCount)
{
    g_bLocked[arena] = true;
    g_bOverride[arena] = false;
    g_iMatchId[arena] = matchId;
    g_iAllowedCount[arena] = 0;

    int count = allowedCount;
    if (count > SIDE_MAX)
        count = SIDE_MAX;

    for (int i = 0; i < count; i++)
        strcopy(g_sAllowed[arena][i], STEAM64_LEN, allowed[i]);
    g_iAllowedCount[arena] = count;

    if (whitelist[0] != '\0')
    {
        MGE_SetArenaWhitelistOverride(arena, whitelist);
        g_bOverride[arena] = true;
    }

    EjectStrangers(arena);

    char arenaName[64];
    TellArenaLocked(arena, names);
    if (!ClientInArena(client, arena))
    {
        ArenaName(client, arena, arenaName, sizeof(arenaName));
        Reply(client, "ArenaLocked", arenaName, names);
    }

    if (whitelist[0] == '\0')
        Reply(client, "NoWhitelist");
    else if (!fromMatch)
        Reply(client, "DefaultWhitelist", whitelist);

    ArenaName(LANG_SERVER, arena, arenaName, sizeof(arenaName));
    LogMessage("[mge_league_match] Locked arena %d (%s) for match %d", arena, arenaName, matchId);
}

void UnlockArena(int arena, bool announce)
{
    if (arena < 1 || arena >= MAX_ARENAS || !g_bLocked[arena])
        return;

    int matchId = g_iMatchId[arena];
    bool hadOverride = g_bOverride[arena];
    g_bLocked[arena] = false;
    g_bOverride[arena] = false;
    g_iMatchId[arena] = 0;
    g_iAllowedCount[arena] = 0;

    if (hadOverride && NativeReady("MGE_ClearArenaWhitelistOverride") && MGE_IsValidArena(arena))
        MGE_ClearArenaWhitelistOverride(arena);

    if (announce)
        TellArenaUnlocked(arena);

    LogMessage("[mge_league_match] Unlocked arena %d (match %d)", arena, matchId);
}

void EjectStrangers(int arena)
{
    int pending[MAXPLAYERS];
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;
        if (MGE_GetPlayerArena(client) != arena)
            continue;

        char steam[STEAM64_LEN];
        if (GetClientAuthId(client, AuthId_SteamID64, steam, sizeof(steam)) && SteamAllowed(arena, steam))
            continue;

        pending[count] = client;
        count++;
    }

    for (int i = 0; i < count; i++)
    {
        int client = pending[i];
        if (!IsClientInGame(client))
            continue;
        Reply(client, "ArenaBlocked");
        MGE_RemovePlayerFromArena(client);
    }
}

bool ArenaHasParticipant(int arena)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;
        if (MGE_GetPlayerArena(client) != arena)
            continue;

        char steam[STEAM64_LEN];
        if (GetClientAuthId(client, AuthId_SteamID64, steam, sizeof(steam)) && SteamAllowed(arena, steam))
            return true;
    }
    return false;
}

bool ClientInArena(int client, int arena)
{
    return IsClientInGame(client) && MGE_GetPlayerArena(client) == arena;
}

bool OpponentsInArena(int arena, const char steamIds[][STEAM64_LEN], int count)
{
    for (int i = 0; i < count; i++)
    {
        if (steamIds[i][0] == '\0')
            return false;
        if (FindClientInArena(arena, steamIds[i]) == 0)
            return false;
    }
    return count > 0;
}

int FindClientInArena(int arena, const char[] steamId)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;
        if (!MGE_IsPlayerInArena(client) || MGE_GetPlayerArena(client) != arena)
            continue;

        char steam[STEAM64_LEN];
        if (GetClientAuthId(client, AuthId_SteamID64, steam, sizeof(steam)) && StrEqual(steam, steamId))
            return client;
    }
    return 0;
}

bool SteamAllowed(int arena, const char[] steamId)
{
    for (int i = 0; i < g_iAllowedCount[arena]; i++)
    {
        if (StrEqual(g_sAllowed[arena][i], steamId))
            return true;
    }
    return false;
}

bool SteamInList(const char[] steamId, const char list[][STEAM64_LEN], int count)
{
    for (int i = 0; i < count; i++)
    {
        if (StrEqual(list[i], steamId))
            return true;
    }
    return false;
}

bool MatchIsCurrent(int client, JSONObject match)
{
    if (!match.HasKey("season") || match.IsNull("season"))
        return false;

    JSONObject season = view_as<JSONObject>(match.Get("season"));
    int seasonId = 0;
    if (season != null && season.HasKey("id") && !season.IsNull("id"))
        seasonId = season.GetInt("id");
    delete season;

    for (int i = 0; i < g_iSeasonCount[client]; i++)
    {
        if (g_iSeasonIds[client][i] == seasonId)
            return true;
    }
    return false;
}

int CollectSide(JSONObject match, const char[] key, char steam[][STEAM64_LEN], char names[][NAME_LEN])
{
    for (int i = 0; i < SIDE_MAX; i++)
    {
        steam[i][0] = '\0';
        names[i][0] = '\0';
    }

    if (!match.HasKey(key) || match.IsNull(key))
        return 0;

    JSONObject side = view_as<JSONObject>(match.Get(key));
    if (side == null || !side.HasKey("players") || side.IsNull("players"))
    {
        delete side;
        return 0;
    }

    JSONArray players = view_as<JSONArray>(side.Get("players"));
    delete side;
    if (players == null)
        return 0;

    int count = 0;
    int length = players.Length;
    for (int i = 0; i < length && count < SIDE_MAX; i++)
    {
        if (players.IsNull(i))
            continue;

        JSONObject player = view_as<JSONObject>(players.Get(i));
        if (player == null)
            continue;

        steam[count][0] = '\0';
        names[count][0] = '\0';
        ReadOptionalString(player, "steamId", steam[count], STEAM64_LEN);
        ReadOptionalString(player, "name", names[count], NAME_LEN);
        delete player;

        if (steam[count][0] != '\0')
            count++;
    }
    delete players;
    return count;
}

int CopyAllowed(const char home[][STEAM64_LEN], int homeCount, const char away[][STEAM64_LEN], int awayCount, char allowed[][STEAM64_LEN])
{
    int count = 0;
    count = AppendUnique(home, homeCount, allowed, count);
    count = AppendUnique(away, awayCount, allowed, count);
    return count;
}

int AppendUnique(const char source[][STEAM64_LEN], int sourceCount, char dest[][STEAM64_LEN], int destCount)
{
    for (int i = 0; i < sourceCount && destCount < SIDE_MAX; i++)
    {
        if (source[i][0] == '\0' || SteamInList(source[i], dest, destCount))
            continue;
        strcopy(dest[destCount], STEAM64_LEN, source[i]);
        destCount++;
    }
    return destCount;
}

void JoinNames(int client, const char names[][NAME_LEN], int count, char[] out, int maxlen)
{
    char separator[24];
    SetGlobalTransTarget(client);
    Format(separator, sizeof(separator), "%t", "NameSeparator");

    out[0] = '\0';
    for (int i = 0; i < count; i++)
    {
        if (names[i][0] == '\0')
            continue;
        if (out[0] != '\0')
            StrCat(out, maxlen, separator);
        StrCat(out, maxlen, names[i]);
    }
    if (out[0] == '\0')
    {
        SetGlobalTransTarget(client);
        Format(out, maxlen, "%t", "UnknownOpponent");
    }
}

void AnnounceMatch(int client, JSONObject match, const char[] names)
{
    int week = 0;
    if (match.HasKey("week") && !match.IsNull("week"))
        week = match.GetInt("week");

    char formatCode[16];
    formatCode[0] = '\0';
    if (match.HasKey("season") && !match.IsNull("season"))
    {
        JSONObject season = view_as<JSONObject>(match.Get("season"));
        if (season != null && season.HasKey("format") && !season.IsNull("format"))
        {
            JSONObject format = view_as<JSONObject>(season.Get("format"));
            if (format != null)
                ReadOptionalString(format, "code", formatCode, sizeof(formatCode));
            delete format;
        }
        delete season;
    }

    char formatBit[24];
    formatBit[0] = '\0';
    if (formatCode[0] != '\0')
        FormatEx(formatBit, sizeof(formatBit), ", %s", formatCode);

    char division[NAME_LEN];
    division[0] = '\0';
    if (match.HasKey("division") && !match.IsNull("division"))
    {
        JSONObject divisionObj = view_as<JSONObject>(match.Get("division"));
        if (divisionObj != null)
            ReadOptionalString(divisionObj, "name", division, sizeof(division));
        delete divisionObj;
    }

    char divisionBit[NAME_LEN + 4];
    divisionBit[0] = '\0';
    if (division[0] != '\0')
        FormatEx(divisionBit, sizeof(divisionBit), ", %s", division);

    Reply(client, "PendingMatch", names, week, formatBit, divisionBit);
}

bool ResolveWhitelist(JSONObject match, char[] out, int maxlen)
{
    out[0] = '\0';
    if (ReadWhitelistFields(match, out, maxlen))
        return true;

    if (match.HasKey("season") && !match.IsNull("season"))
    {
        JSONObject season = view_as<JSONObject>(match.Get("season"));
        if (season != null)
        {
            if (ReadWhitelistFields(season, out, maxlen))
            {
                delete season;
                return true;
            }
            if (season.HasKey("format") && !season.IsNull("format"))
            {
                JSONObject format = view_as<JSONObject>(season.Get("format"));
                bool found = format != null && ReadWhitelistFields(format, out, maxlen);
                delete format;
                if (found)
                {
                    delete season;
                    return true;
                }
            }
        }
        delete season;
    }

    if (match.HasKey("division") && !match.IsNull("division"))
    {
        JSONObject division = view_as<JSONObject>(match.Get("division"));
        bool found = division != null && ReadWhitelistFields(division, out, maxlen);
        delete division;
        if (found)
            return true;
    }

    g_cvWhitelist.GetString(out, maxlen);
    TrimString(out);
    return false;
}

bool ReadWhitelistFields(JSONObject obj, char[] out, int maxlen)
{
    if (obj == null)
        return false;
    if (ReadOptionalString(obj, "whitelistId", out, maxlen))
        return true;
    if (ReadOptionalString(obj, "whitelist_id", out, maxlen))
        return true;
    if (ReadOptionalString(obj, "whitelist", out, maxlen))
        return true;
    return false;
}

bool ReadOptionalString(JSONObject obj, const char[] key, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (obj == null || !obj.HasKey(key) || obj.IsNull(key))
        return false;
    if (!obj.GetString(key, buffer, maxlen))
        return false;
    TrimString(buffer);
    return buffer[0] != '\0';
}

bool ReadApiBase(char[] buffer, int maxlen)
{
    g_cvApi.GetString(buffer, maxlen);
    TrimString(buffer);
    int length = strlen(buffer);
    if (length > 0 && buffer[length - 1] == '/')
        buffer[length - 1] = '\0';
    return buffer[0] != '\0';
}

void FailRequest(int client, HTTPStatus status, const char[] error)
{
    g_bBusy[client] = false;
    if (status == HTTPStatus_TooManyRequests)
        Reply(client, "RateLimited");
    else
        Reply(client, "ApiFailed");

    LogError("[mge_league_match] HTTP %d: %s", status, error);
}

void TellArenaLocked(int arena, const char[] names)
{
    char arenaName[64];
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;
        if (MGE_GetPlayerArena(client) != arena)
            continue;

        ArenaName(client, arena, arenaName, sizeof(arenaName));
        MC_PrintToChat(client, "%t", "ArenaLocked", arenaName, names);
    }
}

void TellArenaUnlocked(int arena)
{
    char arenaName[64];
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;
        if (MGE_GetPlayerArena(client) != arena)
            continue;

        ArenaName(client, arena, arenaName, sizeof(arenaName));
        MC_PrintToChat(client, "%t", "ArenaUnlocked", arenaName);
    }
}

void ArenaName(int client, int arena, char[] buffer, int maxlen)
{
    if (NativeReady("MGE_GetArenaInfo") && MGE_IsValidArena(arena))
    {
        MGEArenaInfo info;
        if (MGE_GetArenaInfo(arena, info) && info.name[0] != '\0')
        {
            strcopy(buffer, maxlen, info.name);
            return;
        }
    }

    if (client > 0)
        SetGlobalTransTarget(client);
    else
        SetGlobalTransTarget(LANG_SERVER);
    Format(buffer, maxlen, "%t", "ThisArena");
}

bool NativeReady(const char[] name)
{
    return GetFeatureStatus(FeatureType_Native, name) == FeatureStatus_Available;
}

void Reply(int client, const char[] phrase, any ...)
{
    #pragma unused phrase
    char buffer[256];
    if (client > 0 && IsClientInGame(client))
        SetGlobalTransTarget(client);
    else
        SetGlobalTransTarget(LANG_SERVER);

    VFormat(buffer, sizeof(buffer), "%t", 2);

    if (client > 0 && IsClientInGame(client))
        MC_PrintToChat(client, "%s", buffer);
    else
    {
        MC_RemoveTags(buffer, sizeof(buffer));
        PrintToServer("%s", buffer);
    }
}
