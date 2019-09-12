#include <amxmodx>
#include <sockets>
#include <tsx>
#include <amxmisc>

#define MAX_EVENT_NAME_LENGTH 128
#define MAX_COMMAND_LENGTH 512
#define MAX_BUFFER_LENGTH 1024
#define PLUGIN_NAME "AMXX-Server-Relay"

new g_sHostname[MAX_NAME_LENGTH];
new g_sHost[MAX_NAME_LENGTH];
new g_sToken[64];

// Randomly selected port
new g_iPort;

new g_cHost;
new g_cPort;
new g_cHostname;

// Event convars
new g_cPlayerEvent;
new g_cMapEvent;
new g_cPlayerReport;
new g_cPlayerEventDeath;

new g_hSocket;

enum MessageType
{
	MessageInvalid = 0,
	MessageAuthenticate,
	MessageAuthenticateResponse,
	MessageChat,
	MessageEvent,
	MessageTypeCount,
}

enum AuthenticateResponse
{
	AuthenticateInvalid = 0,
	AuthenticateSuccess,
	AuthenticateDenied,
	AuthenticateResponseCount,
}

enum IdentificationType
{
	IdentificationInvalid = 0,
	IdentificationSteam,
	IdentificationDiscord,
	IdentificationTypeCount,
}

enum
{
	TaskIdListen = 0,
	TaskIdReconnect,
	TaskIdReportNumPlayers,
	TaskIdAuth
}

public plugin_init()
{
	register_plugin("Discord Chat Relay", "1.0" ,"endnch")

	g_cMapEvent = create_cvar("rf_scr_event_map", "0", FCVAR_NONE, "Enable map start/end events", true, 0.0, true, 1.0);
	g_cPlayerEvent = create_cvar("rf_scr_event_player", "0", FCVAR_NONE, "Enable player connect/disconnect events", true, 0.0, true, 1.0);
	g_cPlayerEventDeath = create_cvar("rf_scr_event_player_death", "0", FCVAR_NONE, "Enable player death events", true, 0.0, true, 1.0);
	g_cPlayerReport = create_cvar("rf_scr_event_player_report", "0", FCVAR_NONE, "If event_player is enabled, report the number of players after connect/disconnect", true, 0.0, true, 1.0);
	g_cHost = create_cvar("rf_scr_host", "127.0.0.1", FCVAR_NONE, "Relay Server Host");
	g_cHostname = create_cvar("rf_scr_hostname", "", FCVAR_NONE, "The hostname/displayname to send with messages. If left empty, it will use the server's hostname");
	g_cPort = create_cvar("rf_scr_port", "57452", FCVAR_NONE, "Relay Server Port");

	AutoExecConfig(.name = PLUGIN_NAME);

	register_clcmd("say", "handleSay");
	register_clcmd("say_team", "handleSay");
}

public OnConfigsExecuted()
{
	bind_pcvar_string(g_cHost, g_sHost, charsmax(g_sHost));
	bind_pcvar_num(g_cPort, g_iPort);

	new hostname[MAX_NAME_LENGTH];
	get_pcvar_string(g_cHostname, hostname, charsmax(hostname));	
	if (strlen(hostname) == 0)
	{
		get_user_name(0, g_sHostname, charsmax(g_sHostname));
	}
	else
	{
		bind_pcvar_string(g_cHostname, g_sHostname, charsmax(g_sHostname));
	}

	establishConnection();
}

public establishConnection()
{
	new error = 0;

	g_hSocket = socket_open(g_sHost, g_iPort, SOCKET_TCP, error);
	if (error > 0)
	{
		switch (error)
		{
			case SOCK_ERROR_CREATE_SOCKET: { server_print("[%s] Error creating socket", PLUGIN_NAME); }
			case SOCK_ERROR_SERVER_UNKNOWN: { server_print("[%s] Error resolving remote hostname", PLUGIN_NAME); }
			case SOCK_ERROR_WHILE_CONNECTING: { server_print("[%s] Error connecting socket", PLUGIN_NAME); }
		}
	}
	else
	{
	    new sIp[MAX_NAME_LENGTH], sPort[MAX_NAME_LENGTH];
	    get_user_ip(0, sIp, charsmax(sIp));

	    strtok(sIp, sIp, charsmax(sIp), sPort, charsmax(sPort), ':');

	    new path[128];
	    get_datadir(path, 128);
	    format(path, 128, "%s/%s_%s.data", path, sIp, sPort);
	    
	    new file;
	    if (file_exists(path))
	    {
	    	file = fopen(path, "r");
	    	fgets(file, g_sToken, 64);
	    } else
	    {
	    	file = fopen(path, "w");
	    	GenerateRandomChars(g_sToken, sizeof g_sToken, 64);
	    	fputs(file, g_sToken);
	    }
	    fclose(file);

	    dispatchAuthenticationMessage();
	    authenticate();
	}
}

GenerateRandomChars(buffer[], buffersize, len)
{
	new charset[] = "adefghijstuv6789!@#$%^^klmwxyz01bc2345nopqr&+=";
	
	for (new i = 0; i < len; i++)
		format(buffer, buffersize, "%s%c", buffer, charset[random(sizeof charset)]);
}

public authenticate() {
	if (socket_is_readable(g_hSocket, 0))
	{
		new authResponse[16];
		socket_recv(g_hSocket, authResponse, 16);

		switch(authResponse[7])
		{
			case AuthenticateInvalid: {
				server_print("[%s] Invalid authentication", PLUGIN_NAME);
			}
			case AuthenticateSuccess: {
				server_print("[%s] Successfully authenticated", PLUGIN_NAME);
				set_task(1.0, "listen", TaskIdListen, .flags = "b");
				OnMapStart();
			}
			case AuthenticateDenied: {
				server_print("[%s] Authentication denied", PLUGIN_NAME);
			}
			default: {
				server_print("[%s] Invalid authenticacion response code", PLUGIN_NAME);
			}
		}
	}
	else if (g_hSocket > 0)
	{
		set_task(1.0, "authenticate", TaskIdAuth);
	}
	else
	{
		server_print("[%s] Socket disconnected", PLUGIN_NAME);
	}
}

public listen() {
	if (socket_is_readable(g_hSocket, 0)) {
		new data[MAX_COMMAND_LENGTH];
		new bytesReceived = socket_recv(g_hSocket, data, MAX_COMMAND_LENGTH);

		if (bytesReceived != -1)
		{
			switch(data[0])
			{
				case MessageChat: {
					new dataIndex = 1;

					new sHostname[MAX_NAME_LENGTH];
					rd(data, sHostname, dataIndex);

					readByte(data, dataIndex);

					new sId[MAX_NAME_LENGTH];
					rd(data, sId, dataIndex);

					new sPlayerName[MAX_NAME_LENGTH];
					rd(data, sPlayerName, dataIndex);

					new result = 0;
					do {
						new sMessage[MAX_COMMAND_LENGTH];
						result = rd(data, sMessage, dataIndex);
						client_print_color(0, print_chat, "[#%s] ^4%s^1: %s", sHostname, sPlayerName, sMessage);
					} while(result == 1);
				}
				case MessageEvent: {
					new dataIndex = 1;

					new sHostname[MAX_NAME_LENGTH];
					rd(data, sHostname, dataIndex);

					new sEventName[MAX_NAME_LENGTH];
					rd(data, sEventName, dataIndex);

					new sEventData[MAX_NAME_LENGTH];
					rd(data, sEventData, dataIndex);

					client_print_color(0, print_chat, "[#%s] ^4%s^1: %s", sHostname, sEventName, sEventData);
				}
				default: {
					server_print("[%s] Invalid messagetype code: %c", PLUGIN_NAME, data[0]);
				}
			}
		}
		else
		{
			server_print("[%s] Error receiving bytes", PLUGIN_NAME);
			remove_task(TaskIdListen);
			set_task(5.0, "tryToReconnect", TaskIdReconnect, .flags = "b");
		}
	}
}

public tryToReconnect()
{
	server_print("[%s] Trying to reconnect", PLUGIN_NAME);

	socket_close(g_hSocket);

	new error = 0;
	// Port must be retrieved like this because g_iPort == 0
	new port = get_pcvar_num(g_cPort);
	g_hSocket = socket_open(g_sHost, port, SOCKET_TCP, error);

	if (error > 0)
	{
		switch (error)
		{
			case SOCK_ERROR_CREATE_SOCKET: { server_print("[%s] Error creating socket", PLUGIN_NAME); }
			case SOCK_ERROR_SERVER_UNKNOWN: { server_print("[%s] Error resolving remote hostname", PLUGIN_NAME); }
			case SOCK_ERROR_WHILE_CONNECTING: { server_print("[%s] Error connecting socket", PLUGIN_NAME); }
		}
	}
	else
	{
		server_print("[%s] Successfully reconnected", PLUGIN_NAME);
		remove_task(TaskIdReconnect);
		dispatchAuthenticationMessage();
		authenticate();
	}
}

public handleSay(id)
{
	new sMessage[MAX_COMMAND_LENGTH];
	read_argv(1, sMessage, charsmax(sMessage));

	if (strlen(sMessage) == 0)
	{
		return PLUGIN_CONTINUE;
	}

	new sPlayerName[MAX_NAME_LENGTH];
	get_user_name(id, sPlayerName, charsmax(sPlayerName));

	new sAuthId[MAX_NAME_LENGTH];
	get_user_authid(id, sAuthId, charsmax(sAuthId));

	new sDump[MAX_BUFFER_LENGTH];
	new index = 0;

	addByte(sDump, index, _:MessageChat);
	cp(g_sHostname, sDump, index);
	addByte(sDump, index, _:IdentificationSteam);
	cp(sAuthId, sDump, index);
	cp(sPlayerName, sDump, index);
	cp(sMessage, sDump, index);
	socket_send2(g_hSocket, sDump, index);

	return PLUGIN_CONTINUE;
}

public client_putinserver(id)
{
	if (!get_pcvar_bool(g_cPlayerEvent))
		return;

	new sPlayerName[MAX_NAME_LENGTH];
	get_user_name(id, sPlayerName, charsmax(sPlayerName));

	dispatchEventMessage("Player Connected", sPlayerName);

	if (!get_pcvar_bool(g_cPlayerReport))
		return;

	reportNumberOfPlayers();
}

public client_disconnected(id)
{
	if (!get_pcvar_bool(g_cPlayerEvent))
		return;

	new sPlayerName[MAX_NAME_LENGTH];
	get_user_name(id, sPlayerName, charsmax(sPlayerName));

	dispatchEventMessage("Player Disonnected", sPlayerName);

	if (!get_pcvar_bool(g_cPlayerReport))
		return;
	
	set_task(1.0, "reportNumberOfPlayers", TaskIdReportNumPlayers);
}

public reportNumberOfPlayers()
{
	new sPlayersNum[8];
	formatex(sPlayersNum, charsmax(sPlayersNum), "%d", get_playersnum());

	dispatchEventMessage("Players Online", sPlayersNum);
}

public client_death(killer, victim, wpnindex, hitplace, TK)
{
	if (!get_pcvar_bool(g_cPlayerEventDeath))
		return;

	new sWpnName[MAX_NAME_LENGTH];
	xmod_get_wpnname(wpnindex, sWpnName, charsmax(sWpnName));

	new sMessage[MAX_COMMAND_LENGTH];
	if (hitplace == HIT_HEAD)
	{
		formatex(sMessage, charsmax(sMessage), "\*\*\* %n killed %n with a headshot from %s \*\*\*", killer, victim, sWpnName);
	}
	else
	{
		formatex(sMessage, charsmax(sMessage), "%n killed %n with %s", killer, victim, sWpnName);
	}

	dispatchEventMessage("Player Death", sMessage);
}

public plugin_end()
{
	OnMapEnd();
}

OnMapStart()
{
	if (!get_pcvar_bool(g_cMapEvent))
		return;

	new sMapName[MAX_NAME_LENGTH];
	get_mapname(sMapName, charsmax(sMapName));

	dispatchEventMessage("Map Start", sMapName);
}

OnMapEnd()
{
	if (!get_pcvar_bool(g_cMapEvent))
		return;

	new sMapName[MAX_NAME_LENGTH];
	get_mapname(sMapName, charsmax(sMapName));

	dispatchEventMessage("Map Ended", sMapName);
}

cp(source[], dest[], &i)
{
	for (new j = 0; source[j] != '^0'; j++)
	{
		if (i >= MAX_BUFFER_LENGTH) return;
		dest[i++] = source[j];
	}
	dest[i++] = '^0';
}

rd(source[], dest[], &i)
{
	new j = 0;
	while (source[i] != '^0' && source[i] != '^x0a')
	{
		if (i >= MAX_BUFFER_LENGTH) return -1;
		dest[j++] = source[i++];
	}
	dest[j] = '^0';
	return source[i++] == '^x0a';
}

public addByte(array[], &i, c)
{
	if (i >= MAX_BUFFER_LENGTH) return;
	array[i++] = c;
}

public readByte(array[], &i)
{
	return array[i++];
}

dispatchEventMessage(eventName[], eventData[])
{
	new sDump[MAX_BUFFER_LENGTH];
	new index = 0;

	addByte(sDump, index, _:MessageEvent);
	cp(g_sHostname, sDump, index);
	cp(eventName, sDump, index);
	cp(eventData, sDump, index);
	socket_send2(g_hSocket, sDump, index);
}

dispatchAuthenticationMessage()
{
	new sDump[MAX_BUFFER_LENGTH];
	new index = 0;
	addByte(sDump, index, _:MessageAuthenticate);
	cp(g_sHostname, sDump, index);
	cp(g_sToken, sDump, index);
	socket_send2(g_hSocket, sDump, index);
}

