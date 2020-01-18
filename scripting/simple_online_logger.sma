// Addon for plugin 'Trial Access', that allows you to restrict getting trial access by total player online time

new const PLUGIN_DATE[] = "23.05.19"

/* ---------------------- SETTINGS START ---------------------- */

// Vault name (stored in 'addons/amxmodx/data/vault')
new const VAULT_NAME[] = "sol_online"

/* ---------------------- SETTINGS END ---------------------- */

#include <amxmodx>
#include <nvault>
#include <time>

#define chx charsmax

#define CheckBit(%0,%1) (%0 & (1 << %1))
#define SetOneBit(%0,%1) (%0 |= (1 << %1))
#define ClearBit(%0,%1) (%0 &= ~(1 << %1))

new g_iTime[MAX_PLAYERS + 1]
new g_hVault = INVALID_HANDLE
new g_iConnPlayers
new g_iAuthPlayers
new g_iCheckPlayers
new g_iPruneDays

/* -------------------- */

public plugin_init() {
	register_plugin("Simple Online Logger", PLUGIN_DATE, "mx?!")

	g_hVault = nvault_open(VAULT_NAME)

	if(g_hVault == INVALID_HANDLE) {
		set_fail_state("Error opening vault!")
	}

	bind_pcvar_num( create_cvar("sol_prune_days", "30",
		.has_min = true, .min_val = 0.0,
		.description = "Clear nvault from records older that # days" ),
		g_iPruneDays );
}

/* -------------------- */

public OnConfigsExecuted() {
	if(g_iPruneDays) {
		nvault_prune(g_hVault, 0, get_systime() - (g_iPruneDays * SECONDS_IN_DAY))
	}
}

/* -------------------- */

public client_authorized(pPlayer) {
	SetOneBit(g_iAuthPlayers, pPlayer);
}

/* -------------------- */

public client_putinserver(pPlayer) {
	SetOneBit(g_iConnPlayers, pPlayer);
}

/* -------------------- */

public client_disconnected(pPlayer) {
	if(CheckBit(g_iConnPlayers, pPlayer) && CheckBit(g_iAuthPlayers, pPlayer)) {
		new szAuthID[MAX_AUTHID_LENGTH]
		get_user_authid(pPlayer, szAuthID, chx(szAuthID))

		if(szAuthID[0] == 'S' || szAuthID[0] == 'V') {
			new iTime = get_user_time(pPlayer, 1)

			if(!CheckBit(g_iCheckPlayers, pPlayer)) {
				iTime += nvault_get(g_hVault, szAuthID)
			}
			else {
				iTime += g_iTime[pPlayer]
			}

			nvault_set(g_hVault, szAuthID, fmt("%i", iTime))
		}

		g_iTime[pPlayer] = 0
	}

	ClearBit(g_iConnPlayers, pPlayer);
	ClearBit(g_iAuthPlayers, pPlayer);
	ClearBit(g_iCheckPlayers, pPlayer);
}

/* -------------------- */

public plugin_end() {
	if(g_hVault != INVALID_HANDLE)
		nvault_close(g_hVault)
	}

/* -------------------- */

public plugin_natives() {
	register_native("sol_get_user_time", "_sol_get_user_time")
}

/* -------------------- */

public _sol_get_user_time(iPluginID, iParamCount) {
	new pPlayer = get_param(1)

	if(!CheckBit(g_iCheckPlayers, pPlayer)) {
		if(!CheckBit(g_iAuthPlayers, pPlayer))
			return INVALID_HANDLE;

		SetOneBit(g_iCheckPlayers, pPlayer);

		new szAuthID[MAX_AUTHID_LENGTH]
		get_user_authid(pPlayer, szAuthID, chx(szAuthID))
		g_iTime[pPlayer] = nvault_get(g_hVault, szAuthID)
	}

	return g_iTime[pPlayer] + get_user_time(pPlayer, 1)
}
