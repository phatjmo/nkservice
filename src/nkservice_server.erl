%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(nkservice_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([find_name/1, get_srv_id/1, get_cache/2]).
-export([start_link/1, stop/1]).
-export([pending_msgs/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-include("nkservice.hrl").

-type service_select() :: nkservice:id() | nkservice:name().


%% ===================================================================
%% Public
%% ===================================================================

%% @private Finds a service's id from its name
-spec find_name(nkservice:name()) ->
    {ok, nkservice:id()} | not_found.

find_name(Name) ->
    case nklib_proc:values({?MODULE, Name}) of
        [] -> not_found;
        [{Id, _Pid}|_] -> {ok, Id}
    end.


%% @doc Gets the internal name of an existing service
-spec get_srv_id(service_select()) ->
    {ok, nkservice:id(), pid()} | not_found.

get_srv_id(Srv) ->
    case 
        is_atom(Srv) andalso erlang:function_exported(Srv, service_init, 2) 
    of
        true ->
            {ok, Srv};
        false ->
            find_name(Srv)
    end.


%% @doc Gets current service configuration
-spec get_cache(service_select(), atom()) ->
    term().

get_cache(Srv, Field) ->
    case get_srv_id(Srv) of
        {ok, Id} -> 
            case Id:Field() of
                {map, Bin} -> binary_to_term(Bin);
                Other -> Other
            end;
        not_found ->
            error({service_not_found, Srv})
    end.




%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec start_link(nkservice:spec()) ->
    {ok, pid()} | {error, term()}.

start_link(#{id:=Id}=Spec) ->
    gen_server:start_link({local, Id}, ?MODULE, Spec, []).



%% @private
-spec stop(pid()) ->
    ok.

stop(Pid) ->
    gen_server:cast(Pid, nkservice_stop).


%% @private
pending_msgs() ->
    lists:map(
        fun({_Id, Name, _Class, Pid}) ->
            {_, Len} = erlang:process_info(Pid, message_queue_len),
            {Name, Len}
        end,
        nkservice:get_all()).



%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    id :: nkservice:id(),
    user = #{}
}).

-define(P1, #state.id).
-define(P2, #state.user).


%% @private
init(#{id:=Id, name:=Name}=Spec) ->
    process_flag(trap_exit, true),          % Allow receiving terminate/2
    Class = maps:get(class, Spec, undefined),
    nklib_proc:put(?MODULE, {Id, Class}),   
    nklib_proc:put({?MODULE, Name}, Id),   
    case do_start(Spec) of
        {ok, Spec2} ->
            case Id:service_init(Spec2, #{id=>Id}) of
                {ok, User} -> 
                    {ok, #state{id=Id, user=User}};
                {ok, User, Timeout} -> 
                    {ok, #state{id=Id, user=User}, Timeout};
                {stop, Reason} -> 
                    {stop, Reason}
            end;
        {error, Error} ->
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), nklib_util:gen_server_from(), #state{}) ->
    nklib_util:gen_server_call(#state{}).

handle_call({nkservice_update, Spec}, _From, #state{id=Id}=State) ->
    {reply, do_update(Spec#{id=>Id}), State};

handle_call(nkservice_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) ->
    nklib_gen_server:handle_call(service_handle_call, Msg, From, State, ?P1, ?P2).


%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast(nkservice_stop, State)->
    {stop, normal, State};

handle_cast(Msg, State) ->
    nklib_gen_server:handle_cast(service_handle_cast, Msg, State, ?P1, ?P2).


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info(Msg, State) ->
    nklib_gen_server:handle_info(service_handle_info, Msg, State, ?P1, ?P2).
    

%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}} | {error, term()}.

code_change(OldVsn, State, Extra) ->
    nklib_gen_server:code_change(service_code_change, OldVsn, State, Extra, ?P1, ?P2).


%% @private
-spec terminate(term(), #state{}) ->
    nklib_util:gen_server_terminate().

terminate(Reason, #state{id=Id}=State) ->  
	Plugins = lists:reverse(Id:plugins()),
    lager:debug("Service terminated (~p): ~p", [Reason, Plugins]),
    do_stop_plugins(Plugins, nkservice:get_spec(Id)),
    catch nklib_gen_server:terminate(service_terminate, Reason, State, ?P1, ?P2).
    


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
do_start(Spec) ->
    try
        Plugins1 = maps:get(plugins, Spec, []),
        Plugins2 = case Spec of
            #{callback:=CallBack} -> [{CallBack, all}|Plugins1];
            _ -> Plugins1
        end,
        Plugins3 = case nkservice_cache:get_plugins(Plugins2) of
            {ok, AllPlugins} -> AllPlugins;
            {error, PlugError} -> throw(PlugError)
        end,
        ok = do_init_plugins(lists:reverse(Plugins3)),
        Spec1 = Spec#{plugins=>Plugins3},
        Spec2 = do_syntax(Plugins3, Spec1),
        Spec3 = do_start_plugins(Plugins3, Spec2, []),
        case nkservice_cache:make_cache(Spec3) of
            ok -> 
                {ok, Spec3};
            {error, Error} -> 
                throw(Error)
        end
    catch
        throw:Throw -> {error, Throw}
    end.

      
%% @private
do_init_plugins([]) ->
    ok;

do_init_plugins([Plugin|Rest]) ->
    case nklib_util:apply(Plugin, plugin_init, []) of
        not_exported ->
            do_init_plugins(Rest);
        ok ->
            do_init_plugins(Rest);
        {error, Error} ->
            throw({plugin_init_error, {Plugin, Error}});
        Other ->
            lager:warning("Invalid response from ~p:plugin_init/1: ~p", [Plugin, Other]),
            throw({invalid_plugin, {Plugin, invalid_init}})
    end.


%% @private
do_start_plugins([], Spec, _Started) ->
    Spec;

do_start_plugins([Plugin|Rest], Spec, Started) ->
    lager:debug("Service ~p starting plugin ~p", [maps:get(id, Spec), Plugin]),
    code:ensure_loaded(Plugin),
    case nklib_util:apply(Plugin, plugin_start, [Spec]) of
        not_exported ->
            do_start_plugins(Rest, Spec, [Plugin|Started]);
        {ok, Spec1} ->
            do_start_plugins(Rest, Spec1, [Plugin|Started]);
        {stop, Reason} ->
            _Spec2 = do_stop_plugins(Started, Spec),
            throw({could_not_start_plugin, {Plugin, Reason}});
        Other ->
            _Spec2 = do_stop_plugins(Started, Spec),
            lager:error("Invalid response from plugin_start: ~p", [Other]),
            throw({could_not_start_plugin, Plugin})
    end.


%% @private
do_stop_plugins([], Spec) ->
    Spec;

do_stop_plugins([Plugin|Rest], Spec) ->
    lager:debug("Service ~p stopping plugin ~p", [maps:get(id, Spec), Plugin]),
    case nklib_util:apply(Plugin, plugin_stop, [Spec]) of
    	{ok, Spec1} ->
    		do_stop_plugins(Rest, Spec1);
    	_ ->
    		do_stop_plugins(Rest, Spec)
    end.


%% @private
do_update(#{id:=Id}=Spec) ->
    try
        OldSpec = nkservice:get_spec(Id),
        Syntax = nkservice_syntax:syntax(),
        % We don't use OldSpec as a default, since values not in syntax()
        % would be taken from OldSpec insted than from Spec
        Spec1 = case nkservice_util:parse_syntax(Spec, Syntax) of
            {ok, Parsed} -> Parsed;
            {error, ParseError} -> throw(ParseError)
        end,
        Spec2 = maps:merge(OldSpec, Spec1),
        OldPlugins = Id:plugins(),
        NewPlugins1 = maps:get(plugins, Spec2),
        NewPlugins2 = case Spec2 of
            #{callback:=CallBack} -> 
                [{CallBack, all}|NewPlugins1];
            _ ->
                NewPlugins1
        end,
        ToStart = case nkservice_cache:get_plugins(NewPlugins2) of
            {ok, AllPlugins} -> AllPlugins;
            {error, GetError} -> throw(GetError)
        end,
        ToStop = lists:reverse(OldPlugins--ToStart),
        lager:info("Server ~p plugins to stop: ~p, start: ~p", 
                   [Id, ToStop, ToStart]),
        CacheKeys = maps:keys(nkservice_syntax:defaults()),
        Spec3 = Spec2#{
            plugins => ToStart,
            cache => maps:with(CacheKeys, Spec2)
        },
        Spec4 = do_stop_plugins(ToStop, Spec3),
        Spec5 = do_syntax(ToStart, Spec4),
        Spec6 = do_start_plugins(ToStart, Spec5, []),
        case Spec6 of
            #{transports:=Transports} ->
                case 
                    nkservice_transp_sup:start_transports(Transports, Spec6) 
                of
                    ok -> 
                        ok;
                    {error, Error} ->
                        throw(Error)
                end;
            _ ->
                ok
        end,
        {Added, Removed} = get_diffs(Spec6, OldSpec),
        lager:info("Added config: ~p", [Added]),
        lager:info("Removed config: ~p", [Removed]),
        nkservice_cache:make_cache(Spec6)
    catch
        throw:Throw -> {error, Throw}
    end.


%% @private
do_syntax([], Spec) ->
    Spec;

do_syntax([Plugin|Rest], Spec) ->
    Spec1 = case nklib_util:apply(Plugin, plugin_syntax, []) of
        not_exported -> 
            Spec;
        Syntax when is_map(Syntax) ->
            Defaults = case nklib_util:apply(Plugin, plugin_defaults, []) of
                not_exported -> #{};
                Defs when is_map(Defs) -> Defs;
                Other -> throw({invalid_plugin_defaults, {Plugin, Other}})
            end,
            Opts = #{return=>map, defaults=>Defaults},
            case nklib_config:parse_config(Spec, Syntax, Opts) of
                {ok, Parsed, _} ->
                    maps:merge(Spec, Parsed);
                {error, Error} ->
                    throw({syntax_error, {Plugin, Error}})
            end;
        {error, Error} ->
            throw({invalid_plugin, {syntax, Error}})
    end,
    do_syntax(Rest, Spec1).


%% private
get_diffs(Map1, Map2) ->
    Add = get_diffs(nklib_util:to_list(Map1), Map2, []),
    Rem = get_diffs(nklib_util:to_list(Map2), Map1, []),
    {maps:from_list(Add), maps:from_list(Rem)}.


%% private
get_diffs([], _, Acc) ->
    Acc;

get_diffs([{cache, _}|Rest], Map, Acc) ->
    get_diffs(Rest, Map, Acc);

get_diffs([{Key, Val}|Rest], Map, Acc) ->
    Acc1 = case maps:find(Key, Map) of
        {ok, Val} -> Acc;
        _ -> [{Key, Val}|Acc]
    end,
    get_diffs(Rest, Map, Acc1).



