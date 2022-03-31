#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <socket> // https://github.com/JoinedSenses/sm-ext-socket/
#include <regex>
#define BYTEREADER_BUFFERMAX 2048
#include <bytereader> // https://github.com/JoinedSenses/SourceMod-IncludeLibrary/blob/master/include/bytereader.inc
#include <queue> // https://github.com/JoinedSenses/SourceMod-IncludeLibrary/blob/master/include/queue.inc

#define PLUGIN_NAME "A2SQuery"
#define PLUGIN_AUTHOR "JoinedSenses"
#define PLUGIN_DESCRIPTION "Sends A2S queries to a Valve game server"
#define PLUGIN_VERSION "1.0.0"
#define PLUGIN_URL "https://github.com/JoinedSenses"

// https://developer.valvesoftware.com/wiki/Server_queries

public Plugin myinfo = {
	name = PLUGIN_NAME,
	author = PLUGIN_AUTHOR,
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION,
	url = PLUGIN_URL
}

#define COMMAND_INFO "sm_a2sinfo"
#define COMMAND_PLAYER "sm_a2splayer"
#define COMMAND_RULES "sm_a2srules"

#define A2S_REQUEST_INFO "\xFF\xFF\xFF\xFF\x54Source Engine Query"
#define A2S_REQUEST_PLAYER "\xFF\xFF\xFF\xFF\x55" // ... "\xFF\xFF\xFF\xFF"
#define A2S_REQUEST_RULES "\xFF\xFF\xFF\xFF\x56" // ... "\xFF\xFF\xFF\xFF"

#define A2S_SIZE_INFO 25
#define A2S_SIZE_PLAYER 9
#define A2S_SIZE_RULES 9

#define SINGLE_PACKET 0xFFFFFFFF // -1
#define MULTI_PACKET 0xFFFFFFFE // -2

#if !defined MAX_CONSOLE_LENGTH
  #define MAX_CONSOLE_LENGTH 1024
#endif

#define DEBUG 0

// Matches IP:Port
Regex g_Regex;
// Message printing queue
Queue g_Queue;

enum GameId {
	TheShip = 2400,
}

enum A2SQueryType {
	A2S_Invalid = -1,
	A2S_Info,
	A2S_Player,
	A2S_Rules,
}

A2SQueryType GetQueryType(const char[] command) {
	if (StrEqual(command, COMMAND_INFO)) {
		return A2S_Info;
	}
	if (StrEqual(command, COMMAND_PLAYER)) {
		return A2S_Player;
	}
	if (StrEqual(command, COMMAND_RULES)) {
		return A2S_Rules;
	}
	return A2S_Invalid;
}

public void OnPluginStart() {
	CreateConVar(
		"sm_a2squery_version",
		PLUGIN_VERSION,
		PLUGIN_DESCRIPTION,
		FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_DONTRECORD
	).SetString(PLUGIN_VERSION);

	RegAdminCmd(COMMAND_INFO,   cmdQuery, ADMFLAG_ROOT);
	RegAdminCmd(COMMAND_PLAYER, cmdQuery, ADMFLAG_ROOT);
	RegAdminCmd(COMMAND_RULES,  cmdQuery, ADMFLAG_ROOT);

	g_Regex = new Regex("(\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3})(?:[ \\t]+|:)(\\d{1,5})");
	g_Queue = new Queue(ByteCountToCells(MAX_CONSOLE_LENGTH));
}

public Action cmdQuery(int client, int args) {
	char command[16]; // The command used to trigger function
	GetCmdArg(0, command, sizeof(command));

	if (!args) { // If no args, reply usage
		Print(client, "Usage: %s <ip:port>", command);
		return Plugin_Handled;
	}

	/**
	 * Retrieve query type based on command used.
	 * This allows us to register everything under a single command callback.
	 */
	SocketConnectCB socketCallbackConnect;
	SocketReceiveCB socketCallbackReceive;
	switch (GetQueryType(command)) {
		case A2S_Info: {
			socketCallbackConnect = socketInfoConnect;
			socketCallbackReceive = socketInfoReceive;
		}
		case A2S_Player: {
			socketCallbackConnect = socketPlayerConnect;
			socketCallbackReceive = socketPlayerReceive;
		}
		case A2S_Rules: {
			socketCallbackConnect = socketRulesConnect;
			socketCallbackReceive = socketRulesReceive;
		}
		default: { // This wont happen unless this plugin is edited, but whatever.
			ThrowError("Invalid a2squery command %s", command);
		}
	}

	char arg[32];
	GetCmdArgString(arg, sizeof(arg));

	RegexError e = REGEX_ERROR_NONE;
	int ret = g_Regex.Match(arg, e);
	if (e != REGEX_ERROR_NONE) {
		ThrowError("Regex failure on IP:Port match (%i)", e);
	}
	if (ret == -1) { // Used to extract ip/port from arg
		Print(client, "Invalid IP:Port %s", arg);
		return Plugin_Handled;
	}

	char ip[24];
	g_Regex.GetSubString(1, ip, sizeof(ip));

	char port[8];
	g_Regex.GetSubString(2, port, sizeof(port));

	int portValue = StringToInt(port);

#if DEBUG
	Print(client, "Attempting to connect to %s:%i", ip, portValue);
#endif

	Socket socket = new Socket(SOCKET_UDP, socketError);
	socket.SetArg(client);
	socket.Connect(socketCallbackConnect, socketCallbackReceive, socketDisconnect, ip, portValue);

	return Plugin_Handled;
}

public void socketInfoConnect(Socket socket, any arg) {
#if DEBUG
	Print(arg, "Socket connected: Info");
#endif

	socket.Send(A2S_REQUEST_INFO, A2S_SIZE_INFO);
}

public void socketPlayerConnect(Socket socket, any arg) {
#if DEBUG
	Print(arg, "Socket connected: Player");
#endif

	socket.Send(A2S_REQUEST_PLAYER ... "\xFF\xFF\xFF\xFF", A2S_SIZE_PLAYER);
}

public void socketRulesConnect(Socket socket, any arg) {
#if DEBUG
	Print(arg, "Socket connected: Rules");
#endif

	socket.Send(A2S_REQUEST_RULES ... "\xFF\xFF\xFF\xFF", A2S_SIZE_RULES);
}

public void socketInfoReceive(Socket socket, char[] data, const int dataSize, any arg) {
#if DEBUG
	Print(arg, "Received data: %s Size: %i", data, dataSize);
#endif

	/** ==== Request Format
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'T' -------------------- | Byte
	 * Payload: "Source Engine Query\0" | String
	 * Challenge if response header 'A' | Long
	 */

	/** ==== Challenge Response
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'A' -------------------- | Byte
	 * Challenge ---------------------- | Long
	 */

	/** ==== Normal Response
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'I' -------------------- | Byte
	 * Protocol ----------------------- | Byte
	 * Name --------------------------- | String
	 * Map ---------------------------- | String
	 * Folder ------------------------- | String
	 * Game --------------------------- | String
	 * ID ----------------------------- | Short
	 * Players ------------------------ | Byte
	 * Max Players -------------------- | Byte
	 * Bots --------------------------- | Byte
	 * Server type -------------------- | Byte
	 * Environment -------------------- | Byte
	 * Visibility --------------------- | Byte
	 * VAC ---------------------------- | Byte
	 * if The Ship: Mode -------------- | Byte
	 * if The Ship: Witnesses --------- | Byte
	 * if The Ship: Duration ---------- | Byte
	 * Version ------------------------ | String
	 * Extra Data Flag ---------------- | Byte
	 * if EDF & 0x80: Port ------------ | Short
	 * if EDF & 0x10: SteamID --------- | Long Long
	 * if EDF & 0x40: STV Port -------- | Short
	 * if EDF & 0x40: STV Name -------- | String
	 * if EDF & 0x20: Tags ------------ | String
	 * if EDF & 0x01: GameID ---------- | Long Long
	 */

	ByteReader byteReader;
	byteReader.SetData(data, dataSize);

#if DEBUG
	int packetHeader = byteReader.GetLong();
	Print(arg, "Packet Header: %i", packetHeader);
#else
	byteReader.offset += 4;
#endif

	int header = byteReader.GetByte();

	if (header == 'A') { // We received a challenge and must handle it with another request.
		static char reply[A2S_SIZE_INFO + 4] = A2S_REQUEST_INFO;

		for (int i = A2S_SIZE_INFO, j = byteReader.offset; i < sizeof(reply); ++i, ++j) {
#if DEBUG
			Print(arg, "%i", (reply[i] = data[j]));
#else
			reply[i] = data[j];
#endif
		}
		
		socket.Send(reply, sizeof(reply));

#if DEBUG
		Print(arg, "Sent challenge response: %s%s", reply, reply[A2S_SIZE_INFO]);
#endif

		return;
	}

	byteReader.offset += 1; // Protocol | Byte

	char srvName[64];
	byteReader.GetString(srvName, sizeof(srvName));

	char mapName[80];
	byteReader.GetString(mapName, sizeof(mapName));

	char gameDir[16];
	byteReader.GetString(gameDir, sizeof(gameDir));

	char gameDesc[64];
	byteReader.GetString(gameDesc, sizeof(gameDesc));

	GameId gameid = view_as<GameId>(byteReader.GetShort());

	int players = byteReader.GetByte();

	int maxPlayers = byteReader.GetByte();

	int bots = byteReader.GetByte();

	char serverType[16];
	switch (byteReader.GetByte()) {
		case 'd': strcopy(serverType, sizeof(serverType), "Dedicated");
		case 'l': strcopy(serverType, sizeof(serverType), "Non-Dedicated");
		case 'p': strcopy(serverType, sizeof(serverType), "STV Relay");
	}

	char environment[8];
	switch (byteReader.GetByte()) {
		case 'l':      strcopy(environment, sizeof(environment), "Linux");
		case 'w':      strcopy(environment, sizeof(environment), "Windows");
		case 'm', 'o': strcopy(environment, sizeof(environment), "Mac");
	}

	int visibility = byteReader.GetByte();

	int vac = byteReader.GetByte();

	char theShip[64];
	if (gameid == TheShip) {
		char mode[17];

		switch (byteReader.GetByte()) {
			case 0: strcopy(mode, sizeof(mode), "Hunt");
			case 1: strcopy(mode, sizeof(mode), "Elimination");
			case 2: strcopy(mode, sizeof(mode), "Duel");
			case 3: strcopy(mode, sizeof(mode), "Deathmatch");
			case 4: strcopy(mode, sizeof(mode), "VIP Team");
			case 5: strcopy(mode, sizeof(mode), "Team Elimination");
		}

		int witnesses = byteReader.GetByte();
		int duration = byteReader.GetByte();

		FormatEx(
			theShip,
			sizeof(theShip),
			"Mode: %s\n" ...
			"Witnesses: %i\n" ...
			"Duration: %i\n",
			mode,
			witnesses,
			duration
		);
	}

	char version[16];
	byteReader.GetString(version, sizeof(version));

	int EDF = byteReader.GetByte();

	int port;
	if (EDF & 0x80) {
		port = byteReader.GetShort();
	}

	char steamid[24];
	if (EDF & 0x10) {
		byteReader.GetLongLong(steamid, sizeof(steamid));
	}

	int stvport;
	char stvserver[64];
	if (EDF & 0x40) {
		stvport = byteReader.GetShort();
		byteReader.GetString(stvserver, sizeof(stvserver));
	}

	char tags[128];
	if (EDF & 0x20) {
		byteReader.GetString(tags, sizeof(tags));
	}

	char gameid64[24];
	if (EDF & 0x01) {
		byteReader.GetLongLong(gameid64, sizeof(gameid64));
	}
	// end

	Print(
		arg,
		"Server: %s\n" ...
		"Map: %s\n" ...
		"Game Dir: %s\n" ...
		"Game Description: %s\n" ...
		"Game ID: %i\n" ...
		"Number of players: %i\n" ...
		"MaxPlayers: %i\n" ...
		"Humans: %i\n" ...
		"Bots: %i\n" ...
		"Server Type: %s\n" ...
		"Environment: %s\n" ...
		"Visibility: %s\n" ...
		"VAC: %i\n" ...
		"%s" ... // theShip
		"Version: %s\n" ...
		"Port: %i\n" ...
		"Server SteamID: %s\n" ...
		"STV Port: %i\n" ...
		"STV Server: %s\n" ...
		"Tags: %s\n" ...
		"GameID64: %s",
		srvName,
		mapName,
		gameDir,
		gameDesc,
		gameid,
		players,
		maxPlayers,
		players - bots, // humans
		bots,
		serverType,
		environment,
		visibility ? "Private" : "Public",
		vac,
		theShip,
		version,
		port,
		steamid,
		stvport,
		stvserver,
		tags,
		gameid64
	);

	delete socket;
}

public void socketPlayerReceive(Socket socket, char[] data, const int dataSize, any arg) {
#if DEBUG
	Print(arg, "Received data: %s Size: %i", data, dataSize);
#endif

	/** ==== Request Format
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'V' -------------------- | Byte
	 * Challenge if response header 'A' | Long
	 */

	/** ==== Challenge Response
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'A' -------------------- | Byte
	 * Challenge ---------------------- | Long
	 */

	/** ==== Normal Response
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'D' -------------------- | Byte
	 * Players ------------------------ | Byte
	 * -------------------------------- |
	 * Loop until end of data --------- |
	 * Index -------------------------- | Byte
	 * Name --------------------------- | String
	 * Score -------------------------- | Long
	 * Duration ----------------------- | Float
	 */

	ByteReader byteReader;
	byteReader.SetData(data, dataSize);

#if DEBUG
	int packetType = byteReader.GetLong();
	Print(arg, "Packet Header: %i", packetType);
#else
	byteReader.offset += 4; // PacketType | Long
#endif

	int header = byteReader.GetByte();

	if (header == 'A') { // We received a challenge and must handle it with another request.
		static char reply[A2S_SIZE_PLAYER + 1] = A2S_REQUEST_PLAYER;

		for (int i = A2S_SIZE_PLAYER - 4, j = byteReader.offset; i < A2S_SIZE_PLAYER; ++i, ++j) {
#if DEBUG
			Print(arg, "%X", (reply[i] = data[j]));
#else
			reply[i] = data[j];
#endif
		}
		
		socket.Send(reply, A2S_SIZE_PLAYER);
#if DEBUG
		Print(arg, "Sent challenge response: %s", reply);
#endif
		return;
	}

	/**
	 * Number of players whose information was gathered.
	 * 
	 * Note: When a player is trying to connect to a server, they are recorded in the number
	 * of players. However, they will not be in the list of player information chunks.
	 * (This is why we check ByteReader::Remaining() instead of looping count)
	 * 
	 * Warning: CS:GO Server by default returns only max players and server uptime.
	 * You have to change server cvar "host_players_show" in server.cfg to value "2" if you
	 * want to revert to old format with players list.
	 */
	int players = byteReader.GetByte();

	Print(
		arg,
		"Players: %i\n" ...
		"Idx | Score |  Time  | Name",
		players
	);

	int index; // Index of player chunk starting from 0.
	char name[32]; // Name of the player.
	int score; // Player's score (usually "frags" or "kills".)
	float duration; // Time (in seconds) player has been connected to the server.

	int count = 0, responseLen = 0;
	static const int CountMax = 10;

	char response[MAX_CONSOLE_LENGTH];

	while (byteReader.Remaining() > 0) {
		index = byteReader.GetByte();
		byteReader.GetString(name, sizeof(name));
		score = byteReader.GetLong();
		duration = byteReader.GetFloat();

		responseLen += FormatEx(
			response[responseLen],
			sizeof(response) - responseLen,
			"%s %02i |  %03i  | %06.0f | %s",
			count ? "\n" : "",
			index,
			score,
			duration,
			name
		);

		if (++count == CountMax) {
			Print(arg, "%s", response);

			count = 0;
			responseLen = 0;
		}
	}

	if (count) {
		Print(arg, "%s", response);
	}

	delete socket;
}

public void socketRulesReceive(Socket socket, char[] data, const int dataSize, any arg) {
#if DEBUG
	Print(arg, "Received data: %s Size: %i", data, dataSize);
#endif

	/** ==== Request Format
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'V' -------------------- | Byte
	 * Challenge if response header 'A' | Long
	 */

	/** ==== Challenge Response
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'A' -------------------- | Byte
	 * Challenge ---------------------- | Long
	 */

	/** ==== Normal Response Single Packet
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'E' -------------------- | Byte
	 * Rules -------------------------- | Short
	 * -------------------------------- |
	 * For every rule in Rules: ------- |
	 * Name --------------------------- | String
	 * Value -------------------------- | String
	 */

	/** ==== Normal Response Multi Packet
	 * \xFE\xFF\XFF\XFF -------------- | Long
	 * ID ---------------------------- | Long
	 * Total Packets ----------------- | Byte
	 * Packet Number ----------------- | Byte
	 * Size -------------------------- | Short
	 */

	ByteReader byteReader;
	byteReader.SetData(data, dataSize);

	int packetHeader = byteReader.GetLong();
#if DEBUG
	Print(arg, "Packet Header: %i", packetHeader);
#endif

	if (packetHeader == SINGLE_PACKET) {
		int header = byteReader.GetByte();

		if (header == 'A') {
			static char reply[A2S_REQUEST_RULES + 1] = A2S_REQUEST_RULES;

			for (int i = A2S_REQUEST_RULES - 4, j = byteReader.offset; i < A2S_REQUEST_RULES; ++i, ++j) {
#if DEBUG
				Print(arg, "%X", (reply[i] = data[j]));
#else
				reply[i] = data[j];
#endif
			}
			
			socket.Send(reply, A2S_REQUEST_RULES);
#if DEBUG
			Print(arg, "Sent challenge response: %s", reply);
#endif
			return;
		}
	}
	else if (packetHeader == MULTI_PACKET) {
#if DEBUG
		int id = byteReader.GetLong();
		int totalPackets = byteReader.GetByte();
		int packetNumber = byteReader.GetByte();
		int size = byteReader.GetShort();

		Print(arg, "MultiPacket %X (%i of %i) Size: %i", id, packetNumber + 1, totalPackets, size);
#else
		byteReader.offset += 4; // Id | Long
		int totalPackets = byteReader.GetByte();
		int packetNumber = byteReader.GetByte();
		byteReader.offset += 2; // Size | Short
#endif

		if (packetNumber == 0) {
			byteReader.offset += 7; // PacketType | Long - SubHeader? | Byte - Rules | Short
		}	
		
		static char name[64]; // Rule name
		static char value[64]; // Rule value
		static bool isNameIncomplete = false; // name incomplete from last packet? true if null terminator not found
		static bool isValueIncomplete = false; // value incomplete from last packet? true if null terminator not found
		static int count = 0; // Used to count number of consolidated results
		static const int CountMax = 10; // Max results before printing to client

		static char response[MAX_CONSOLE_LENGTH];
		static int responseLen = 0;

		if (isNameIncomplete) {
			/**
			 * If there was an incomplete name from the previous packet,
			 * then finish up the rest of the name, and retrieve the value.
			 * Bump up the count and if it hit our limit, then print and 
			 * reset some values.
			 */
			isNameIncomplete = false;

			int len = strlen(name);
			byteReader.GetString(name[len], sizeof(name) - len);
			byteReader.GetString(value, sizeof(value));

			responseLen += FormatEx(
				response[responseLen],
				sizeof(response) - responseLen,
				"%s%s: %s",
				count ? "\n" : "",
				name,
				value
			);

			if (++count == CountMax) {
				count = 0;
				responseLen = 0;

				Print(arg, "%s", response);
			}
		}
		else if (isValueIncomplete) {
			/**
			 * If there was an incomplete value from the previous packet,
			 * then finish up the rest of the value.
			 * Bump up the count and if it hit our limit, then print and
			 * reset some values.
			 */
			isValueIncomplete = false;

			int len = strlen(value);
			byteReader.GetString(value[len], sizeof(value) - len);

			responseLen += FormatEx(
				response[responseLen],
				sizeof(response) - responseLen,
				"%s%s: %s",
				count ? "\n" : "",
				name,
				value
			);

			if (++count == CountMax) {
				count = 0;
				responseLen = 0;

				Print(arg, "%s", response);
			}
		}

		// Continue as long as there is data to read
		while (byteReader.Remaining() > 0) {
			if (!byteReader.GetString(name, sizeof(name))) {
				// Reached end of packet data and did not finish name
#if DEBUG
				Print(arg, "  -- Incomplete Name --");
#endif
				isNameIncomplete = true;
				break;
			}
			if (!byteReader.GetString(value, sizeof(value))) {
				// Reached end of packet data and did not finish value
#if DEBUG
				Print(arg, "  -- Incomplete Value --");
#endif
				isValueIncomplete = true;
				break;
			}

			responseLen += FormatEx(
				response[responseLen],
				sizeof(response) - responseLen,
				"%s%s: %s",
				count ? "\n" : "",
				name,
				value
			);

			if (++count == CountMax) {
				count = 0;
				responseLen = 0;

				Print(arg, "%s", response);
			}
		}

		if (packetNumber + 1 == totalPackets) {
			// We've retrieved all packets
			if (count) {
				Print(arg, "%s", response);
			}

			isNameIncomplete = false;
			isValueIncomplete = false;
			count = 0;
			responseLen = 0;

			Print(arg, "----- End of data -----");
			delete socket;
		}

		return;
	}
	else {
		delete socket;
		ThrowError("Invalid packet header %X", packetHeader);
	}

	delete socket;
}

public void socketDisconnect(Socket socket, any arg) {
#if DEBUG
	Print(arg, "Socket disconnected");
#endif

	delete socket;
}

public void socketError(Socket socket, const int errorType, const int errorNum, any arg) {
	Print(arg, "Socket error. Type: %i Num %i", errorType, errorNum);

	delete socket;
}

void Print(int client, char[] fmt, any ...) {
	char output[MAX_CONSOLE_LENGTH];
	VFormat(output, sizeof(output), fmt, 3);

	g_Queue.PushString(output);
	if (g_Queue.Length == 1) {
		RequestFrame(framePrint, client);
	}
}

void framePrint(int client) {
	// Counter used to wait a specific number of frames before printing.
	static int count = 0;
	static const int FrameMax = 2;

	if (count++ == 0) {
		char output[MAX_CONSOLE_LENGTH];
		g_Queue.PopString(output, sizeof(output));

		if (client) {
			PrintToConsole(client, "%s", output);
		}
		else {
			PrintToServer("%s", output);
		}
	}

	if (g_Queue.Length) {
		if (count == FrameMax) {
			count = 0;
		}

		RequestFrame(framePrint, client);
	}
	else {
		count = 0;
	}
}
