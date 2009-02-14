%% Author: Peter
%% Created: Dec 15, 2008
%% Description: TODO: Add description to server
-module(server).

%%
%% Include files
%%
-include("packet.hrl").

-import(pickle, [pickle/2, unpickle/2, byte/0, 
                 short/0, sshort/0, int/0, sint/0, 
                 long/0, slong/0, list/2, choice/2, 
                 optional/1, wrap/2, tuple/1, record/2, 
                 binary/1, string/0, wstring/0
                ]).

-import(login, [login/3]).
-import(lists, [reverse/1, foreach/2]).
-import(string, [len/1]).

%%
%% Records
%%

-record(client, {
          server_pid = none,
          player_pid = none,
          clock_sync = none,
          ready = none
         }).

%%
%% Exported Functions
%%
-export([start/0]).

%%
%% API Functions
%%

start() ->
    
    % Create schema and load db data
    io:fwrite("Creating schema and loading db data..."),
    db:create_schema(),
    db:start(),
    db:reset_tables(),
    
    % Load map data
    io:fwrite("Loading map data...~n"),    
    {ok, MapPid} = map:start(),
       
    % Create game loop
    io:fwrite("Starting game loop...~n"),  
    {ok, GamePid} = game:start(),    
	TotalMS = util:now_to_milliseconds(erlang:now()), 
    spawn(fun() -> game_loop:loop(0, TotalMS, global:whereis_name(game_pid)) end),
     
    {ok, ListenSocket} = gen_tcp:listen(2345, [binary, {packet, 0},  
					 			 {reuseaddr, true},
								 {active, once},
                                 {nodelay, true}]),
    Client = #client{ server_pid = self() },
    io:fwrite("Server listening...~n"),
    do_accept(ListenSocket, Client).

%%
%% Local Functions
%%

do_accept(ListenSocket, Client) ->	
    {ok, Socket} = gen_tcp:accept(ListenSocket),  
    io:fwrite("Socket accepted.~n"),
    spawn(fun() -> do_accept(ListenSocket, Client) end),
    handle_client(Socket, Client).

handle_client(Socket, Client) ->
    receive
        {tcp, Socket, Bin} ->
			
			io:fwrite("Status: Data accepted: ~w~n", [Bin]),
            NewClient = case catch packet:read(Bin) of
                    		{'EXIT', Error} ->
                            	error_logger:error_report(
                            	[{module, ?MODULE},
                            	{line, ?LINE},
                            	{message, "Could not parse command"},
                            	{Bin, Bin},
                            	{error, Error},
                            	{now, now()}]),
                            	Client;                    
                			#login{ name = Name, pass = Pass} ->
                        		process_login(Client, Socket, Name, Pass);   
                    		#logout{} ->
                        		process_logout(Client, Socket);
                            #move{ coords = Direction} ->
                                process_move(Client, Socket, Direction);                            
                            policy_request ->
                                process_policy_request(Client, Socket);
                            clocksync ->
                                process_clocksync(Client, Socket);    
                            clientready ->
                                process_clientready(Client, Socket)
           				end,
            inet:setopts(Socket,[{active, once}]),
			handle_client(Socket, NewClient);

		{tcp_closed, Socket} ->
			io:fwrite("server: Socket disconnected.~n"),
            io:fwrite("server: handle_client - self() -> ~w~n", [self()]),
            io:fwrite("server: handle_client - Client#client.player_pid -> ~w~n", [Client#client.player_pid]),
            gen_server:cast(Client#client.player_pid, 'LOGOUT'),
    		handle_client(Socket, Client);
    
        {packet, Packet} ->
            ok = packet:send(Socket, Packet),
            handle_client(Socket, Client)   
    
    end.

process_login(Client, Socket, Name, Pass) ->
    case login:login(Name, Pass, self()) of
        {error, Error} ->
            ok = packet:send(Socket, #bad{ cmd = ?CMD_LOGIN, error = Error});
        {ok, PlayerPID} ->
            io:fwrite("server: process_login - ok.~n"),
            PlayerId = gen_server:call(PlayerPID, 'ID'),
            io:fwrite("server: process_login - PlayerPID -> ~w~n", [PlayerPID]),
            ok = packet:send(Socket, #player_id{ id = PlayerId }),
            
            EntityList = entity:entity_list(PlayerId),
            gen_server:cast(global:whereis_name(game_pid), {'ADD_PLAYER', PlayerId, PlayerPID, EntityList}),
            
			%io:fwrite("server: process_login - PlayerX -> ~w~n", [CharX]),
    		NewClient = Client#client{ player_pid = PlayerPID },
            io:fwrite("server: process_login - self() -> ~w~n", [self()]),
            io:fwrite("server: process_login - Client#client.player_pid -> ~w~n", [NewClient]),            
    		NewClient
    end.	

process_logout(Client, _Socket) ->
    gen_server:cast(Client#client.player_pid, 'LOGOUT'),
	Client.

process_clocksync(Client, Socket) ->
    io:fwrite("server: process_clocksync~n"),
    ok = packet:send_clocksync(Socket),
	Client.

process_clientready(Client, Socket) ->
    PlayerPID = Client#client.player_pid,    
    PlayerId = gen_server:call(PlayerPID, 'ID'),    
    
	Blocks = player:get_explored_map(PlayerId),
    io:fwrite("server: process_client_ready() -> ~w~n", [Blocks]),
	ok = packet:send(Socket, #map{blocks = Blocks}),
	Client.

process_move(Client, _Socket, DirectionNumber) ->
    
    %requires check if player is logged in
    
    case DirectionNumber of
        0 ->
            Direction = move_north;
        1 ->
    		Direction = move_east;
        2 ->
            Direction = move_south;
        3 ->
            Direction = move_west;
        _ ->
            Direction = none
    end,
    
    PlayerPID = Client#client.player_pid,    
    PlayerId = gen_server:call(PlayerPID, 'ID'),
    gen_server:cast(global:whereis_name({character, PlayerId}), {'SET_ACTION', Direction}),
    Client.    

process_policy_request(Client, Socket) ->
    ok = packet:send_policy(Socket),
	Client.