/*
	Plugin: 'Trial Access'

	Plugin author: http://t.me/blacksignature / https://dev-cs.ru/members/1111/

	Plugin thread: https://dev-cs.ru/resources/430/

	Description:
		This plugin will allow players to receive free of charge predefined access flags (privileges)
		with a limited duration (regulated daily / minutely). Issuance is carried out on SteamID, once.
		In this case, re-obtaining privileges on the same SteamID is excluded.

	Credits:
		* Javekson -> https://dev-cs.ru/members/6/
			* For idea and concept plugin

	Requirements:
		* Counter-Strike 1.6
		* Amx Mod X 1.9 - build 5241, or higher
		* ReAPI

	How to use:
		1) Install this plugin
		2) Run it
		3) Visit 'configs/plugins' to tweak config
		4) Change map to reload config
		5) Enjoy!

	Change history:
		27.03.18:
			* Initial public release
		29.03.18:
			Changed:
				* register_saycmd() stock replacement
			Fixed:
				* client_disconnected() -> client_disconnect() for AMXX < 183
		05.04.18:
			Added:
				* Minute mode
				* MultiLang support
			Fixed:
				* Minor bugfixes
		06.04.18:
			Added:
				* Support for 'amx_reloadadmins'
		10.04.18:
			Added:
				* 'RESTRICT_BY_TIME' option
				* 'FORCE_CHECK' option
				* 'REMOVE_FLAG' option
				* One more state for CHECK_NAME_TYPE (for 'client_admin' forward)
				* SubPlugin 'Simple Online Logger' for 'RESTRICT_BY_TIME' option
		23.05.19:
			Added:
				* Reapi module usage
				* Logging for receiving trial access
			Changed:
				* Refactoring. Most define-based options and #if branches replaced by cvars.
				* Dictionary was updated (only key 'TA_TIME_IS_OVER_2').
			Removed:
				* Old AMXX versions support. From now plugin requires AMXX 190+
			Fixed:
				* Minor bugfixes
		01.07.19:
			Added:
				* Offer free privileges to new players (cvars 'ta_offer_mode' and 'ta_offer_delay')
				* Constant 'SOUND__OFFER'
			Changed:
				* Dictionary was updated ('TA_OFFER_BY_CHAT', 'TA_OFFER_BY_MENU', 'TA_TIME_MONTH', 'TA_TIME_MIN')
		05.07.19:
			Added:
				* Limitation by minimal AES level (cvar 'ta_restrict_by_aes_lvl')
				* Cvar 'ta_annoying_offer' as additional behavior correction option for cvar 'ta_offer_mode'
				* Cvar 'ta_show_prune_date' as an option that allows the player to see the time remaining until
					the possibility of re-obtaining privileges
			Changed:
				* Cvar 'ta_prune_months' replaced by 'ta_prune_days'
				* Cvar description for 'ta_bypass_restrict_steam' and 'ta_bypass_restrict_flags'
				* Dictionary was updated ('TA_REST_BY_AES', 'TA_RETAKE_INFO')
		1.0.0 (18.01.2020):
			Changed:
				* Conversion to semantic versioning
			Fixed:
				* 'get_member: invalid or uninitialized entity' error
*/

new const PLUGIN_DATE[] = "1.0.0"

#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <nvault>
#include <time>

/* ---------------------- SETTINGS START ---------------------- */

// Create cvar config in 'amxmodx/configs/plugins', and execute it?
#define AUTO_CFG

// Client chat command (without '/') for getting trial access
new const CMD_NAME[] = "vip"

// Log filename (stored in 'addons/amxmodx/logs')
new const LOG_FILENAME[] = "trial_access.log"

// Vault name (stored in 'addons/amxmodx/data/vault')
new const VAULT_NAME[] = "trial_vip"

// NOTE: Custom sounds needs to be precached
new const SOUND__NOTICE[] = "events/friend_died.wav"
new const SOUND__GET_TRIAL[] = "events/tutor_msg.wav"
new const SOUND__OFFER[] = "events/tutor_msg.wav"

/* ---------------------- SETTINGS END ---------------------- */

#define chx charsmax

#define CheckFlag(%0,%1) (g_iPlayerFlags[%0] & (1 << %1))
#define SetFlag(%0,%1) (g_iPlayerFlags[%0] |= (1 << %1))
#define ClearFlag(%0,%1) (g_iPlayerFlags[%0] &= ~(1 << %1))

#define DATE_STRLEN 24
#define MENU_KEYS MENU_KEY_5|MENU_KEY_6
#define SECONDS_IN_MONTH_365 2628000 // (365 days * 86400 SECONDS_IN_DAY) / 12 months

// from aes_v.inc
#define AES_MAX_LEVEL_LENGTH 64

const TASKID__SAVE_VAULT = 1337
const TASKID__REVOKE = 7331
const TASKID__OFFER = 666

new const MENU_IDENT_STRING[] = "TA Menu"

enum { _KEY1_, _KEY2_, _KEY3_, _KEY4_, _KEY5_, _KEY6_, _KEY7_, _KEY8_, _KEY9_, _KEY0_ }

enum {
	HAS_AUTH,
	IS_CONNECTED,
	IN_LIST,
	HAS_VIP,
	GOT_OFFER
}

enum _:CVAR_ENUM {
	CVAR__TRIAL_MODE,
	CVAR__TRIAL_TIME,
	CVAR__REMOVE_ALL_FLAGS,
	CVAR__RESTRICT_TIME_MODE,
	CVAR__RESTRICT_TIME,
	CVAR__BYPASS_RESTRICT_STEAM,
	CVAR__CHECK_MODE,
	CVAR__EXTENDED_CMD,
	Float:CVAR_F__RELOAD_DELAY,
	Float:CVAR_F__SAVE_INTERVAL,
	Float:CVAR_F__CHECK_DELAY,
	CVAR__PRUNE_DAYS,
	CVAR__OFFER_MODE,
	Float:CVAR__OFFER_DELAY,
	CVAR__RESTRICT_AES,
	CVAR__ANNOYING_OFFER,
	CVAR__SHOW_PRUNE_DATE
}

// from aes_main.inc
enum _: {
	AES_ST_EXP,
	AES_ST_LEVEL,
	AES_ST_BONUSES,
	AES_ST_NEXTEXP,
	AES_ST_END
}

new g_eCvar[CVAR_ENUM]
new g_iPlayerFlags[MAX_PLAYERS + 1]
new g_hVault = INVALID_HANDLE
new g_szTrialFlags[32]
new g_szRemoveFlags[32]
new g_szBypassFlags[32]
new g_szCheckFlags[32]
new g_iPrevFlags[MAX_PLAYERS + 1]
new g_iEndTime[MAX_PLAYERS + 1]
new g_iRevokeTime
new g_iRevokeID
new g_szLogFile[PLATFORM_MAX_PATH]
new g_szMenu[MAX_MENU_LENGTH]

/* -------------------- */

// Simple Online Logger
native sol_get_user_time(id)

// CSstatsX SQL by serfreeman1337
native get_user_gametime(id)

// CSstats MySQL by SKAJIbnEJIb
#define GAMETIME 14
native csstats_get_user_value(id, iType)
native csstats_is_user_connected(id)

// AES
native aes_get_player_stats(id, data[4])
native aes_get_level_name(level, level_name[], len, idLang = LANG_SERVER)

/* -------------------- */

public plugin_init() {
	register_plugin("Trial Access", PLUGIN_DATE, "mx?!")

	func_OpenVault()

	register_dictionary("trial_access.txt")

	func_RegCvars()

	register_concmd("amx_reloadadmins", "concmd_ReloadAdmins")

	RegisterHookChain(RG_CBasePlayer_SetClientUserInfoName, "OnSetClientUserInfoName_Post", true)

	new iLen = get_localinfo("amxx_logs", g_szLogFile, chx(g_szLogFile))
	formatex(g_szLogFile[iLen], chx(g_szLogFile) - iLen, "/%s", LOG_FILENAME)

	register_menucmd(register_menuid(MENU_IDENT_STRING), MENU_KEYS, "func_Menu_Handler")
}

/* -------------------- */

public OnConfigsExecuted() {
	if(g_eCvar[CVAR_F__SAVE_INTERVAL]) {
		set_task(g_eCvar[CVAR_F__SAVE_INTERVAL] * 60.0, "task_SaveVault", TASKID__SAVE_VAULT)
	}

	if(g_eCvar[CVAR__PRUNE_DAYS]) {
		nvault_prune(g_hVault, 0, func_GetPruneTime())
	}

	if(g_eCvar[CVAR__EXTENDED_CMD]) {
		register_saycmd(CMD_NAME, "clcmd_GetTrial")
	}
	else {
		register_clcmd(fmt("say /%s", CMD_NAME), "clcmd_GetTrial")
		register_clcmd(fmt("say_team /%s", CMD_NAME), "clcmd_GetTrial")
	}
}

/* -------------------- */

public clcmd_GetTrial(pPlayer) {
	if(!CheckFlag(pPlayer, IS_CONNECTED) || !CheckFlag(pPlayer, HAS_AUTH)) {
		return PLUGIN_CONTINUE
	}

	new iEndTime, szAuthID[MAX_AUTHID_LENGTH]

	if(g_iEndTime[pPlayer]) {
		iEndTime = g_iEndTime[pPlayer]
	}
	else {
		get_user_authid(pPlayer, szAuthID, chx(szAuthID))
		g_iEndTime[pPlayer] = iEndTime = nvault_get(g_hVault, szAuthID)
	}

	if(iEndTime) {
		rg_send_audio(pPlayer, SOUND__NOTICE)

		if(iEndTime < get_systime()) {
			if(!g_eCvar[CVAR__SHOW_PRUNE_DATE] || !g_eCvar[CVAR__PRUNE_DAYS]) {
				client_print_color(pPlayer, print_team_red, "%l", "TA_EXPIRED_MSG_1")
				client_print_color(pPlayer, print_team_red, "%l", "TA_EXPIRED_MSG_2")
				client_print_color(pPlayer, print_team_red, "%l", "TA_EXPIRED_MSG_3")
				return PLUGIN_CONTINUE
			}

			new iPruneTime = func_GetPruneTime()

			if(iEndTime > iPruneTime) {
				new szBuffer[64]
				_get_time_length(pPlayer, iEndTime - iPruneTime, szBuffer, chx(szBuffer))
				client_print_color(pPlayer, print_team_red, "%l", "TA_RETAKE_INFO", szBuffer)
				return PLUGIN_CONTINUE
			}
		}
		else {
			new szDate[DATE_STRLEN]
			func_FormatTime(iEndTime, szDate, chx(szDate))
			client_print_color(pPlayer, print_team_default, "%l", "TA_ALREADY_HAVE_MSG", szDate)

			func_ShowUsage(pPlayer)
			return PLUGIN_CONTINUE
		}
	}

	new iFlags = get_user_flags(pPlayer)

	new iCheckFlags = read_flags(g_szCheckFlags)

	if(
		( g_eCvar[CVAR__CHECK_MODE] == 1 && !(iFlags & iCheckFlags) )
			||
		( g_eCvar[CVAR__CHECK_MODE] == 2 && (iFlags & iCheckFlags) )
	) {
		client_print_color(pPlayer, print_team_red, "%l", "TA_HAVE_EXTERNAL_MSG")
		rg_send_audio(pPlayer, SOUND__NOTICE)
		return PLUGIN_CONTINUE
	}

	new iBypassFlags = read_flags(g_szBypassFlags)

	if(
		(!g_eCvar[CVAR__BYPASS_RESTRICT_STEAM] || !is_user_steam(pPlayer))
			&&
		(!iBypassFlags || !(iFlags & iBypassFlags))
	) {
		if(g_eCvar[CVAR__RESTRICT_AES]) {
			new eStats[AES_ST_END]
			aes_get_player_stats(pPlayer, eStats)

			if(eStats[AES_ST_LEVEL] < g_eCvar[CVAR__RESTRICT_AES]) {
				new szAesLvl[AES_MAX_LEVEL_LENGTH]
				aes_get_level_name(g_eCvar[CVAR__RESTRICT_AES], szAesLvl, chx(szAesLvl), LANG_SERVER)
				client_print_color(pPlayer, print_team_red, "%l", "TA_REST_BY_AES", szAesLvl)
				rg_send_audio(pPlayer, SOUND__NOTICE)
				return PLUGIN_CONTINUE
			}
		}

		if(g_eCvar[CVAR__RESTRICT_TIME_MODE]) {
			new iTime

			switch(g_eCvar[CVAR__RESTRICT_TIME_MODE]) {
				case 1: {
					iTime = sol_get_user_time(pPlayer)
				}
				case 2: {
					iTime = get_user_gametime(pPlayer)
				}
				case 3: {
					iTime = csstats_get_user_value(pPlayer, GAMETIME)
				}
			}

			if(iTime == INVALID_HANDLE || (g_eCvar[CVAR__RESTRICT_TIME_MODE] == 3 && !csstats_is_user_connected(pPlayer))) {
				rg_send_audio(pPlayer, SOUND__NOTICE)
				client_print_color(pPlayer, print_team_red, "%l", "TA_NOT_AUTHORIZED")
				return PLUGIN_CONTINUE
			}

			if(iTime / SECONDS_IN_MINUTE < g_eCvar[CVAR__RESTRICT_TIME]) {
				rg_send_audio(pPlayer, SOUND__NOTICE)
				client_print_color(pPlayer, print_team_red, "%l", "TA_REST_BY_TIME_1")

				new szBuffer[64]
				_get_time_length(pPlayer, iTime, szBuffer, chx(szBuffer))
				client_print_color(pPlayer, print_team_red, "%l", "TA_REST_BY_TIME_2", szBuffer)

				_get_time_length(pPlayer, g_eCvar[CVAR__RESTRICT_TIME] * SECONDS_IN_MINUTE, szBuffer, chx(szBuffer))
				client_print_color(pPlayer, print_team_red, "%l", "TA_REST_BY_TIME_3", szBuffer)

				return PLUGIN_CONTINUE
			}
		}
	}

	new iSysTime = get_systime()

	if(!g_eCvar[CVAR__TRIAL_MODE]) {
		iEndTime = iSysTime + SECONDS_IN_DAY * g_eCvar[CVAR__TRIAL_TIME]
	}
	else {
		iEndTime = iSysTime + SECONDS_IN_MINUTE * g_eCvar[CVAR__TRIAL_TIME]
	}

	nvault_set(g_hVault, szAuthID, fmt("%i", iEndTime))

	func_SetVip(pPlayer, iFlags, iSysTime, iEndTime)

	new szDate[DATE_STRLEN]
	func_FormatTime(iEndTime, szDate, chx(szDate))
	client_print_color(pPlayer, print_team_default, "%l", "TA_GET_MSG", szDate)

	func_ShowUsage(pPlayer)
	rg_send_audio(pPlayer, SOUND__GET_TRIAL)

	new szIP[MAX_IP_LENGTH]
	get_user_ip(pPlayer, szIP, chx(szIP), .without_port = 1)
	log_to_file(g_szLogFile, "%N<%s>", pPlayer, szIP)

	return PLUGIN_CONTINUE
}

/* -------------------- */

func_SetVip(pPlayer, iFlags, iSysTime, iEndTime) {
	g_iPrevFlags[pPlayer] = iFlags
	//g_iEndTime[pPlayer] = iEndTime

	if(iEndTime < g_iRevokeTime || !g_iRevokeTime) {
		g_iRevokeTime = iEndTime
		func_SetRevoke(pPlayer, iSysTime)
	}

	SetFlag(pPlayer, HAS_VIP);

	if(g_eCvar[CVAR__REMOVE_ALL_FLAGS]) {
		remove_user_flags(pPlayer)
	}
	else {
		new iFlags = read_flags(g_szRemoveFlags)

		if(iFlags) {
			remove_user_flags(pPlayer, iFlags)
		}
	}

	set_user_flags(pPlayer, read_flags(g_szTrialFlags))
}

/* -------------------- */

public client_authorized(pPlayer) {
	SetFlag(pPlayer, HAS_AUTH)

	if(CheckFlag(pPlayer, IS_CONNECTED)) {
		func_SetCheck(pPlayer)
	}
}

/* -------------------- */

public client_putinserver(pPlayer) {
	SetFlag(pPlayer, IS_CONNECTED)

	if(CheckFlag(pPlayer, HAS_AUTH)) {
		func_SetCheck(pPlayer)
	}
}

/* -------------------- */

public client_disconnected(pPlayer) {
	if(!CheckFlag(pPlayer, IS_CONNECTED)) {
		g_iPlayerFlags[pPlayer] = 0
		return
	}

	remove_task(pPlayer) // task_CheckPlayer()
	remove_task(pPlayer + TASKID__OFFER)

	if(pPlayer == g_iRevokeID && !func_CalcRevoke()) {
		remove_task(TASKID__REVOKE)
	}

	g_iPlayerFlags[pPlayer] = 0
	g_iEndTime[pPlayer] = 0
	// For safety (probably redundant)
	g_iPrevFlags[pPlayer] = 0

}

/* -------------------- */

func_SetCheck(pPlayer) {
	if(!is_user_bot(pPlayer)) {
		set_task(g_eCvar[CVAR_F__CHECK_DELAY], "task_CheckPlayer", pPlayer)
	}
}

/* -------------------- */

public task_CheckPlayer(pPlayer) {
	if(
		!CheckFlag(pPlayer, IS_CONNECTED)
			||
		!CheckFlag(pPlayer, HAS_AUTH)
			||
		(CheckFlag(pPlayer, IN_LIST) && !CheckFlag(pPlayer, HAS_VIP))
	) {
		return
	}

	new iFlags = get_user_flags(pPlayer)

	new iCheckFlags = read_flags(g_szCheckFlags)

	if(
		( g_eCvar[CVAR__CHECK_MODE] == 1 && !(iFlags & iCheckFlags) )
			||
		( g_eCvar[CVAR__CHECK_MODE] == 2 && (iFlags & iCheckFlags) )
	) {
		return
	}

	new iEndTime

	if(g_iEndTime[pPlayer]) {
		iEndTime = g_iEndTime[pPlayer]
	}
	else {
		new szAuthID[MAX_AUTHID_LENGTH]
		get_user_authid(pPlayer, szAuthID, chx(szAuthID))
		g_iEndTime[pPlayer] = iEndTime = nvault_get(g_hVault, szAuthID)
	}

	if(iEndTime) {
		SetFlag(pPlayer, IN_LIST);

		new iSysTime = get_systime()

		if(iEndTime > iSysTime) {
			func_SetVip(pPlayer, iFlags, iSysTime, iEndTime)
			return
		}

		if(!g_eCvar[CVAR__PRUNE_DAYS] || iEndTime > func_GetPruneTime()) {
			return
		}
	}

	if(CheckFlag(pPlayer, GOT_OFFER) || !g_eCvar[CVAR__OFFER_MODE]) {
		return
	}

	if(!g_eCvar[CVAR__ANNOYING_OFFER]) {
		new iBypassFlags = read_flags(g_szBypassFlags)

		if(
			(!g_eCvar[CVAR__BYPASS_RESTRICT_STEAM] || !is_user_steam(pPlayer))
				&&
			(!iBypassFlags || !(iFlags & iBypassFlags))
		) {
			if(g_eCvar[CVAR__RESTRICT_AES]) {
				new eStats[AES_ST_END]
				aes_get_player_stats(pPlayer, eStats)

				if(eStats[AES_ST_LEVEL] < g_eCvar[CVAR__RESTRICT_AES]) {
					return
				}
			}

			if(g_eCvar[CVAR__RESTRICT_TIME_MODE]) {
				new iTime

				switch(g_eCvar[CVAR__RESTRICT_TIME_MODE]) {
					case 1: {
						iTime = sol_get_user_time(pPlayer)
					}
					case 2: {
						iTime = get_user_gametime(pPlayer)
					}
					case 3: {
						iTime = csstats_get_user_value(pPlayer, GAMETIME)
					}
				}

				if(
					iTime / SECONDS_IN_MINUTE < g_eCvar[CVAR__RESTRICT_TIME]
						||
					(g_eCvar[CVAR__RESTRICT_TIME_MODE] == 3 && !csstats_is_user_connected(pPlayer))
				) {
					return
				}
			}
		}
	}

	SetFlag(pPlayer, GOT_OFFER)
	set_task(g_eCvar[CVAR__OFFER_DELAY], "task_Offer", pPlayer + TASKID__OFFER, .flags = "b")
}

/* -------------------- */

public task_Offer(pPlayer) {
	pPlayer -= TASKID__OFFER

	if(!CheckFlag(pPlayer, IS_CONNECTED)) {
		return
	}

	if(g_eCvar[CVAR__OFFER_MODE] == 2) {
		new iMenuID, iKeys
		get_user_menu(pPlayer, iMenuID, iKeys)

		if(iMenuID || get_member(pPlayer, m_iTeam) == TEAM_UNASSIGNED) {
			return
		}
	}

	remove_task(pPlayer + TASKID__OFFER)

	rg_send_audio(pPlayer, SOUND__OFFER)

	new iTime

	if(!g_eCvar[CVAR__TRIAL_MODE]) {
		iTime = SECONDS_IN_DAY * g_eCvar[CVAR__TRIAL_TIME]
	}
	else {
		iTime = SECONDS_IN_MINUTE * g_eCvar[CVAR__TRIAL_TIME]
	}

	new szBuffer[64]
	_get_time_length(pPlayer, iTime, szBuffer, chx(szBuffer))

	if(g_eCvar[CVAR__OFFER_MODE] == 1) {
		client_print_color(pPlayer, print_team_default, "%l", "TA_OFFER_BY_CHAT", szBuffer, CMD_NAME)
		return
	}

	formatex(g_szMenu, chx(g_szMenu), "%L", pPlayer, "TA_OFFER_BY_MENU", szBuffer)
	show_menu(pPlayer, MENU_KEYS, g_szMenu, -1, MENU_IDENT_STRING)
}

/* -------------------- */

public func_Menu_Handler(pPlayer, iKey) {
	if(iKey == _KEY5_) {
		clcmd_GetTrial(pPlayer)
	}
}

/* -------------------- */

stock func_SetRevoke(pPlayer, iSysTime) {
	remove_task(TASKID__REVOKE)
	g_iRevokeID = pPlayer
	set_task(floatmax(0.1, float(g_iRevokeTime - iSysTime) + 1.0), "task_RevokeTrial", TASKID__REVOKE)
}

/* -------------------- */

public task_RevokeTrial() {
	if(CheckFlag(g_iRevokeID, IS_CONNECTED)) {
		ClearFlag(g_iRevokeID, HAS_VIP);
		remove_user_flags(g_iRevokeID, read_flags(g_szTrialFlags))
		set_user_flags(g_iRevokeID, g_iPrevFlags[g_iRevokeID])
		rg_send_audio(g_iRevokeID, SOUND__NOTICE)
		client_print_color(g_iRevokeID, print_team_red, "%l", "TA_TIME_IS_OVER_1")
		client_print_color(g_iRevokeID, print_team_red, "%l", "TA_TIME_IS_OVER_2", CMD_NAME)
	}

	func_CalcRevoke()
}

/* -------------------- */

bool:func_CalcRevoke() {
	g_iRevokeTime = 0
	g_iRevokeID = 0

	new pPlayers[MAX_PLAYERS], iPlayerCount, pPlayer, iLastMatchID
	get_players_ex(pPlayers, iPlayerCount, GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV)

	for(new i; i < iPlayerCount; i++) {
		pPlayer = pPlayers[i]

		if(
			CheckFlag(pPlayer, HAS_VIP)
				&&
			(g_iEndTime[pPlayer] < g_iRevokeTime || !g_iRevokeTime)
			/*	&&
			pPlayer != g_iRevokeID*/ // + g_iRevokeID = 0
				&&
			(!g_eCvar[CVAR__CHECK_MODE] || (get_user_flags(pPlayer) & read_flags(g_szTrialFlags)))
		) {
			iLastMatchID = pPlayer
			g_iRevokeTime = g_iEndTime[pPlayer]
		}
	}

	if(!iLastMatchID) {
		//g_iRevokeID = 0 // + g_iRevokeID = 0
		return false
	}

	func_SetRevoke(iLastMatchID, get_systime())
	return true
}

/* -------------------- */

public concmd_ReloadAdmins(pPlayer, iAccess) {
	static Float:fNextUseTime
	new Float:fGameTime = get_gametime()

	if(fNextUseTime < fGameTime) {
		fNextUseTime = fGameTime + SECONDS_IN_MINUTE.0
		set_task(g_eCvar[CVAR_F__RELOAD_DELAY], "task_ReloadAdmins")
	}

	return PLUGIN_CONTINUE
}

/* -------------------- */

public task_ReloadAdmins() {
	new pPlayers[MAX_PLAYERS], iPlayerCount

	get_players_ex(pPlayers, iPlayerCount, GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV)

	for(new i; i < iPlayerCount; i++) {
		task_CheckPlayer(pPlayers[i])
	}
}

/* -------------------- */

public OnSetClientUserInfoName_Post(pPlayer, szInfoBuffer[], szNewName[]) {
	func_SetCheck(pPlayer)
}

/* -------------------- */

stock register_saycmd(const szSayCmd[], szFunc[]) {
	new const szPrefix[][] = { "say /", "say_team /", "say .", "say_team ." }

	for(new i, szTemp[32]; i < sizeof(szPrefix); i++) {
		formatex(szTemp, chx(szTemp), "%s%s", szPrefix[i], szSayCmd)
		register_clcmd(szTemp, szFunc)
	}
}

/* -------------------- */

_get_time_length(pPlayer, iSec, szBuffer[], iMaxLen) {
	enum _:TIME_TYPES { TYPE_MONTH, TYPE_WEEK, TYPE_DAY, TYPE_HOUR, TYPE_MIN, TYPE_SEC }

	new iCount, iType[TIME_TYPES], szElement[TIME_TYPES][12]

	iType[TYPE_MONTH] = iSec / SECONDS_IN_MONTH_365
	iSec -= (iType[TYPE_MONTH] * SECONDS_IN_MONTH_365)

	iType[TYPE_WEEK] = iSec / SECONDS_IN_WEEK
	iSec -= (iType[TYPE_WEEK] * SECONDS_IN_WEEK)

	iType[TYPE_DAY] = iSec / SECONDS_IN_DAY
	iSec -= (iType[TYPE_DAY] * SECONDS_IN_DAY)

	iType[TYPE_HOUR] = iSec / SECONDS_IN_HOUR
	iSec -= (iType[TYPE_HOUR] * SECONDS_IN_HOUR)

	iType[TYPE_MIN] = iSec / SECONDS_IN_MINUTE
	iType[TYPE_SEC] = iSec -= (iType[TYPE_MIN] * SECONDS_IN_MINUTE)

	new const szLang[][] = { "TA_TIME_MONTH", "TA_TIME_WEEK", "TA_TIME_DAY",
		"TA_TIME_HOUR", "TA_TIME_MIN", "TA_TIME_SEC" };

	SetGlobalTransTarget(pPlayer)

	for(new i; i < sizeof(iType); i++) {
		if(iType[i] > 0) {
			formatex(szElement[iCount++], chx(szElement[]), "%d %l", iType[i], szLang[i])
		}
	}

	new const szAndChar[] = "TA_TIME_AND"

	switch(iCount) {
		case 0: formatex(szBuffer, iMaxLen, "0 %l", szLang[TYPE_SEC])
		case 1: copy(szBuffer, iMaxLen, szElement[0])
		case 2: formatex(szBuffer, iMaxLen, "%s %l %s", szElement[0], szAndChar, szElement[1])
		case 3: formatex(szBuffer, iMaxLen, "%s, %s, %l %s", szElement[0], szElement[1], szAndChar, szElement[2])
		case 4: formatex(szBuffer, iMaxLen, "%s, %s, %s, %l %s", szElement[0], szElement[1], szElement[2], szAndChar, szElement[3])
		case 5: formatex(szBuffer, iMaxLen, "%s, %s, %s, %s, %l %s", szElement[0], szElement[1], szElement[2], szElement[3], szAndChar, szElement[4])
		case 6: formatex(szBuffer, iMaxLen, "%s, %s, %s, %s, %s, %l %s", szElement[0], szElement[1], szElement[2], szElement[3], szElement[4], szAndChar, szElement[5])
	}
}

/* -------------------- */

func_ShowUsage(pPlayer) {
	client_print_color(pPlayer, print_team_blue, "%l", "TA_USAGE_MSG_1")
	client_print_color(pPlayer, print_team_blue, "%l", "TA_USAGE_MSG_2")
}

/* -------------------- */

public task_SaveVault() {
	nvault_close(g_hVault)
	func_OpenVault()
}

/* -------------------- */

func_OpenVault() {
	g_hVault = nvault_open(VAULT_NAME)

	if(g_hVault == INVALID_HANDLE) {
		set_fail_state("Error opening vault!")
	}
}

/* -------------------- */

stock func_GetPruneTime() {
	return get_systime() - (g_eCvar[CVAR__PRUNE_DAYS] * SECONDS_IN_DAY)
}

/* -------------------- */

func_FormatTime(iTime, szDate[], iMaxLen) {
	format_time(szDate, iMaxLen, "%d.%m.%Y - %H:%M", iTime)
}

/* -------------------- */

func_RegCvars() {
	bind_pcvar_num( create_cvar( "ta_trial_mode", "0",
		.description = "Trial mode: 0 - days, 1 - minutes" ),
		g_eCvar[CVAR__TRIAL_MODE] );

	bind_pcvar_num( create_cvar( "ta_trial_time", "31",
		.description = "Trial time in days/minutes (see 'ta_trial_mode')" ),
		g_eCvar[CVAR__TRIAL_TIME] );

	bind_pcvar_string( create_cvar( "ta_trial_flags", "t",
		.description = "Determines which flags will be granted as trial access" ),
		g_szTrialFlags, chx(g_szTrialFlags)	);

	bind_pcvar_num( create_cvar( "ta_remove_all_flags", "0",
		.description = "Remove all flags from player before giving him a trial access?" ),
		g_eCvar[CVAR__REMOVE_ALL_FLAGS] );

	bind_pcvar_string( create_cvar( "ta_remove_flags", "z",
		.description = "Remove specified flags from player before giving him a trial access" ),
		g_szRemoveFlags, chx(g_szRemoveFlags) );

	bind_pcvar_num( create_cvar( "ta_restrict_time_mode", "0",
		.has_min = true, .min_val = 0.0,
		.has_max = true, .max_val = 3.0,
		.description = "Restrict by time mode (see 'ta_restrict_time'):^n\
		0 - Off^n\
		1 - Use 'Simple Online Logger'^n\
		2 - Use 'CSstatsX SQL' by serfreeman1337^n\
		3 - Use 'CSstats MySQL' by SKAJIbnEJIb" ),
		g_eCvar[CVAR__RESTRICT_TIME_MODE] );

	bind_pcvar_num( create_cvar( "ta_restrict_time", "120",
		.description = "How many minutes new players need to play to get access to trial function" ),
		g_eCvar[CVAR__RESTRICT_TIME] );

	bind_pcvar_num( create_cvar( "ta_restrict_by_aes_lvl", "0",
		.description = "Minimal AES level to get access to trial function" ),
		g_eCvar[CVAR__RESTRICT_AES] );

	bind_pcvar_num( create_cvar( "ta_bypass_restrict_steam", "1",
		.description = "Steam players will ignore time and AES level restrictions?" ),
		g_eCvar[CVAR__BYPASS_RESTRICT_STEAM] );

	bind_pcvar_string( create_cvar( "ta_bypass_restrict_flags", "",
		.description = "Players with any of the specified flags will ignore time and AES level restrictions" ),
		g_szBypassFlags, chx(g_szBypassFlags) );

	bind_pcvar_num( create_cvar( "ta_check_mode", "0",
		.has_min = true, .min_val = 0.0,
		.has_max = true, .max_val = 2.0,
		.description = "Flags check mode:^n\
		0 - Off^n\
		1 - Block getting trial for those who DO NOT HAVE any of the specified flags^n\
		2 - Block getting trial for those who HAVE any of the specified flags" ),
		g_eCvar[CVAR__CHECK_MODE] );

	bind_pcvar_string( create_cvar( "ta_check_flags", "z",
		.description = "Flags to check for 'ta_check_mode'" ),
		g_szCheckFlags, chx(g_szCheckFlags) );

	bind_pcvar_num( create_cvar( "ta_extended_cmd", "0",
		.description = "Extended cmd registration ('say' & 'say_team', both '/' & '.')" ),
		g_eCvar[CVAR__EXTENDED_CMD] );

	bind_pcvar_float( create_cvar( "ta_reload_delay", "5",
		.has_min = true, .min_val = 0.1,
		.description = "Delay (in seconds) between 'amx_reloadadmins' and reloading trial access" ),
		g_eCvar[CVAR_F__RELOAD_DELAY] );

	bind_pcvar_float( create_cvar( "ta_save_interval", "0",
		.has_min = true, .min_val = 0.0,
		.description = "nVault saving interval in minutes (useful if server regularly crashing)" ),
		g_eCvar[CVAR_F__SAVE_INTERVAL] );

	bind_pcvar_float( create_cvar( "ta_check_delay", "0.2",
		.has_min = true, .min_val = 0.2,
		.description = "Player check delay (compatibility feature)" ),
		g_eCvar[CVAR_F__CHECK_DELAY] );

	bind_pcvar_num( create_cvar( "ta_prune_days", "365",
		.has_min = true, .min_val = 0.0,
		.description = "Clear nvault from records older that # days" ),
		g_eCvar[CVAR__PRUNE_DAYS] );

	bind_pcvar_num( create_cvar( "ta_offer_mode", "2",
		.has_min = true, .min_val = 0.0,
		.has_max = true, .max_val = 2.0,
		.description = "Offer free privileges for those players who can get them:^n\
		0 - Off^n\
		1 - Offer by chat^n\
		2 - Offer by menu" ),
		g_eCvar[CVAR__OFFER_MODE] );

	bind_pcvar_num( create_cvar( "ta_annoying_offer", "0",
		.description = "Annoying offer mode:^n\
		0 - Don't offer for those who can't get privilegies by played time or by AES level restriction^n\
		1 - Offer anyway" ),
		g_eCvar[CVAR__ANNOYING_OFFER] );

	bind_pcvar_float( create_cvar( "ta_offer_delay", "10.0",
		.has_min = true, .min_val = 3.0,
		.description = "Offer delay (in seconds)" ),
		g_eCvar[CVAR__OFFER_DELAY] );

	bind_pcvar_num( create_cvar( "ta_show_prune_date", "1",
		.description = "If not 0, The player will be notified how much time is left^n\
		until the moment when he can get the privileges again" ),
		g_eCvar[CVAR__SHOW_PRUNE_DATE] );

#if defined AUTO_CFG
	AutoExecConfig()
#endif
}

/* -------------------- */

public plugin_end() {
	if(g_hVault != INVALID_HANDLE) {
		nvault_close(g_hVault)
	}
}

/* -------------------- */

public plugin_natives() {
	set_native_filter("native_filter")
}

/* -------------------- */

public native_filter(szNativeName[], iNativeID, iTrapMode) {
	return PLUGIN_HANDLED
}