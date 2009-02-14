%% Author: Peter
%% Created: Dec 24, 2008
%% Description: TODO: Add description to player
-module(player).
-behaviour(gen_server).

%%
%% Include files
%%

-include("game.hrl").
-include("packet.hrl").
-include("schema.hrl").

%%
%% Exported Functions
%%
-export([init/1, handle_call/3, handle_cast/2, 
         handle_info/2, terminate/2, code_change/3]).

-export([start/1, stop/1, stop/2, get_explored_map/1]).

%-export([create/4]).

%%
%% Records
%%

-record(module_data, {
          player_id,
          socket = none, 
          perception = [],      
          self
         }).

%%
%% API Functions
%%

start(Name) 
  when is_binary(Name) ->
    
    %% make sure player exist
    case db:index_read(player, Name, #player.name) of
        [PlayerInfo] ->
            PlayerId = PlayerInfo#player.id,
            gen_server:start({global, {player, PlayerId}}, player, [PlayerId], []);
        Any ->
            {error, Any}
    end.

init([ID]) 
  when is_integer(ID) ->
    process_flag(trap_exit, true),
    ok = create_runtime(ID, self()),
    {ok, #module_data{ player_id = ID, self = self() }}.

stop(ProcessId) 
  when is_pid(ProcessId) ->
    gen_server:cast(ProcessId, stop).

stop(ProcessId, Reason) 
  when is_pid(ProcessId) ->
    gen_server:cast(ProcessId, {stop, Reason}).

terminate(_Reason, Data) ->
    ok = db:delete(connection, Data#module_data.player_id).

handle_cast('DISCONNECT', Data) ->
    {noreply, Data};

handle_cast({'SOCKET', Socket}, Data) ->
    Data1 = Data#module_data{ socket = Socket },
    {noreply, Data1};

handle_cast('LOGOUT', Data) ->
    Self = self(),
    io:fwrite("player - logout.~n"),
    
    %Delete from game
    GamePID = global:whereis_name(game_pid),
    io:fwrite("player - LOGOUT  GamePID: ~w~n", [GamePID]),
    gen_server:cast(GamePID, {'DELETE_PLAYER', Data#module_data.player_id}),
    
    %Stop character and player servers
    spawn(fun() -> player:stop(Self) end),
    {noreply, Data};

handle_cast({'SEND_PERCEPTION', NewPerceptionWithCoords}, Data) ->
  	LastPerception = Data#module_data.perception,
    
    %io:fwrite("player: NewPerceptionWithCoords ~w~n", [NewPerceptionWithCoords]),
    
    NewPerception = remove_coords(NewPerceptionWithCoords, []),
    
    if 
        LastPerception =:= NewPerception ->
            NewData = Data;
            %io:fwrite("Perception Unchanged. ~n");
       
		true ->
            NewData = Data#module_data {perception = NewPerception },
            R = #perception {characters = NewPerceptionWithCoords },
            forward_to_client(R, NewData)
            
            %io:fwrite("Perception Modified. ~w~n", [NewPerception])   
   	end,
    
    {noreply, NewData};   

handle_cast(stop, Data) ->
    {stop, normal, Data};

handle_cast({stop, Reason}, Data) ->
    {stop, Reason, Data}.

handle_call('ID', _From, Data) ->
    {reply, Data#module_data.player_id, Data};

handle_call('SOCKET', _From, Data) ->
    {reply, Data#module_data.socket, Data};

handle_call(Event, From, Data) ->
    error_logger:info_report([{module, ?MODULE}, 
                              {line, ?LINE},
                              {self, self()}, 
                              {message, Event}, 
                              {from, From}
                             ]),
    {noreply, Data}.

handle_info({'EXIT', _Pid, _Reason}, Data) ->
    %% child exit?
    {noreply, Data};

handle_info(Info, Data) ->
    error_logger:info_report([{module, ?MODULE}, 
                              {line, ?LINE},
                              {self, self()}, 
                              {message, Info}]),
    {noreply, Data}.

code_change(_OldVsn, Data, _Extra) ->
    {ok, Data}.

get_explored_map(PlayerId) ->       
    StoredExploredMap = db:read(explored_map, PlayerId),
    EntityList = entity:entity_list(PlayerId), 
    
    ExploredMap = stored_explored_map(StoredExploredMap, []),
    TotalExploredMap = entity_explored_map(EntityList, ExploredMap),
	TotalExploredMap.

stored_explored_map([], ExploredMap) ->
  	ExploredMap;  

stored_explored_map(StoredExploredMap, ExploredMap) ->
  	[StoredItem | Rest ] = StoredExploredMap,
	
	Block = gen_server:call(global:whereis_name(map_pid), 
												{'GET_MAP_BLOCK', 
												StoredItem#explored_map.block_x, 
												StoredItem#explored_map.block_y}),
	NewExploredMap = [Block | ExploredMap],

	stored_explored_map(Rest, NewExploredMap).
	
entity_explored_map([], ExploredMap) ->
    ExploredMap;    
    
entity_explored_map(EntityList, ExploredMap) ->   
    [Entity | Rest] = EntityList,
  
    Block = gen_server:call(global:whereis_name(map_pid), {'GET_MAP_BLOCK', Entity#entity.x, Entity#entity.y}),

    NewExploredMap = [Block | ExploredMap],
    
    entity_explored_map(Rest, NewExploredMap).



%%
%% Local Functions
%%

create_runtime(ID, ProcessId) 
  when is_number(ID),
       is_pid(ProcessId) ->
    PlayerConn = #connection {
      player_id = ID,
      process = ProcessId
     },
    ok = db:write(PlayerConn).

forward_to_client(Event, Data) ->    
    if 
        Data#module_data.socket /= none ->
            Data#module_data.socket ! {packet, Event};
        true ->
            ok
    end.

remove_coords([], PerceptionList) ->
    PerceptionList;

remove_coords([PerceptionWithCoords | Rest], PerceptionList) ->
    {Id, State, X, Y} = PerceptionWithCoords,
    NewPerceptionList = [{Id, State} | PerceptionList],
    %io:fwrite("player: NewPerceptionList. ~w~n", [NewPerceptionList]),
    
    remove_coords(Rest, NewPerceptionList).



    