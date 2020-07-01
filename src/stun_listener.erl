%%%----------------------------------------------------------------------
%%% File    : stun_listener.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Purpose : 
%%% Created : 9 Jan 2011 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% Copyright (C) 2002-2020 ProcessOne, SARL. All Rights Reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%%----------------------------------------------------------------------

-module(stun_listener).

-behaviour(gen_server).

%% API
-export([start_link/0, add_listener/4, del_listener/3, start_listener/5]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TCP_SEND_TIMEOUT, 10000).
-record(state, {listeners = #{}}).

-ifdef(USE_OLD_LOGGER).
-define(LOG_DEBUG(Str), error_logger:info_msg(Str)).
-define(LOG_DEBUG(Str, Args), error_logger:info_msg(Str, Args)).
-define(LOG_INFO(Str), error_logger:info_msg(Str)).
-define(LOG_INFO(Str, Args), error_logger:info_msg(Str, Args)).
-define(LOG_NOTICE(Str), error_logger:info_msg(Str)).
-define(LOG_NOTICE(Str, Args), error_logger:info_msg(Str, Args)).
-define(LOG_WARNING(Str), error_logger:warning_msg(Str)).
-define(LOG_WARNING(Str, Args), error_logger:warning_msg(Str, Args)).
-define(LOG_ERROR(Str), error_logger:error_msg(Str)).
-define(LOG_ERROR(Str, Args), error_logger:error_msg(Str, Args)).
-else. % Use new logging API.
-include_lib("kernel/include/logger.hrl").
-endif.

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add_listener(IP, Port, Transport, Opts) ->
    gen_server:call(?MODULE, {add_listener, IP, Port, Transport, Opts}).

del_listener(IP, Port, Transport) ->
    gen_server:call(?MODULE, {del_listener, IP, Port, Transport}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    ok = init_logger(),
    {ok, #state{}}.

handle_call({add_listener, IP, Port, Transport, Opts}, _From, State) ->
    case maps:find({IP, Port, Transport}, State#state.listeners) of
	{ok, _} ->
	    Err = {error, already_started},
	    {reply, Err, State};
	error ->
	    {Pid, MRef} = spawn_monitor(?MODULE, start_listener,
					[IP, Port, Transport, Opts, self()]),
	    receive
		{'DOWN', MRef, _Type, _Object, Info} ->
		    Res = {error, Info},
		    format_listener_error(IP, Port, Transport, Opts, Res),
		    {reply, Res, State};
		{Pid, Reply} ->
		    case Reply of
			{error, _} = Err ->
			    format_listener_error(IP, Port, Transport, Opts,
						  Err),
			    {reply, Reply, State};
			ok ->
			    Listeners = maps:put(
					  {IP, Port, Transport},
					  {MRef, Pid, Opts},
					  State#state.listeners),
			    {reply, ok, State#state{listeners = Listeners}}
		    end
	    end
    end;
handle_call({del_listener, IP, Port, Transport}, _From, State) ->
    case maps:find({IP, Port, Transport}, State#state.listeners) of
	{ok, {MRef, Pid, _Opts}} ->
	    catch erlang:demonitor(MRef, [flush]),
	    catch exit(Pid, kill),
	    Listeners = maps:remove({IP, Port, Transport},
				    State#state.listeners),
	    {reply, ok, State#state{listeners = Listeners}};
	error ->
	    {reply, {error, notfound}, State}
    end;
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, _Type, _Pid, Info}, State) ->
    Listeners = maps:filter(
		  fun({IP, Port, Transport}, {Ref, _, _}) when Ref == MRef ->
			  ?LOG_ERROR("listener on ~p/~p failed: ~p",
				     [IP, Port, Transport, Info]),
			  false;
		     (_, _) ->
			  true
		  end, State#state.listeners),
    {noreply, State#state{listeners = Listeners}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
start_listener(IP, Port, Transport, Opts, Owner)
  when Transport == tcp; Transport == tls ->
    OptsWithTLS = case Transport of
		      tls -> [tls|Opts];
		      tcp -> Opts
		  end,
    case gen_tcp:listen(Port, [binary,
                               {ip, IP},
                               {packet, 0},
                               {active, false},
                               {reuseaddr, true},
                               {nodelay, true},
                               {keepalive, true},
			       {send_timeout, ?TCP_SEND_TIMEOUT},
			       {send_timeout_close, true}]) of
        {ok, ListenSocket} ->
            Owner ! {self(), ok},
	    OptsWithTLS1 = stun:tcp_init(ListenSocket, OptsWithTLS),
            accept(ListenSocket, OptsWithTLS1);
        Err ->
            Owner ! {self(), Err}
    end;
start_listener(IP, Port, udp, Opts, Owner) ->
    case gen_udp:open(Port, [binary,
			     {ip, IP},
			     {active, false},
			     {reuseaddr, true}]) of
	{ok, Socket} ->
	    Owner ! {self(), ok},
	    Opts1 = stun:udp_init(Socket, Opts),
	    udp_recv(Socket, Opts1);
	Err ->
	    Owner ! {self(), Err}
    end.

accept(ListenSocket, Opts) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            case {inet:peername(Socket),
                  inet:sockname(Socket)} of
                {{ok, {PeerAddr, PeerPort}}, {ok, {Addr, Port}}} ->
		    ?LOG_INFO("accepted connection: ~s:~p -> ~s:~p",
			      [inet_parse:ntoa(PeerAddr), PeerPort,
			       inet_parse:ntoa(Addr), Port]),
                    case stun:start({gen_tcp, Socket}, Opts) of
                        {ok, Pid} ->
                            gen_tcp:controlling_process(Socket, Pid);
                        Err ->
                            Err
                    end;
                Err ->
                    ?LOG_ERROR("unable to fetch peername: ~p", [Err]),
                    Err
            end,
            accept(ListenSocket, Opts);
        Err ->
            Err
    end.

udp_recv(Socket, Opts) ->
    case gen_udp:recv(Socket, 0) of
	{ok, {Addr, Port, Packet}} ->
	    case catch stun:udp_recv(Socket, Addr, Port, Packet, Opts) of
		{'EXIT', Reason} ->
		    ?LOG_ERROR("failed to process UDP packet:~n"
			       "** Source: {~p, ~p}~n"
			       "** Reason: ~p~n** Packet: ~p",
			       [Addr, Port, Reason, Packet]),
		    udp_recv(Socket, Opts);
		NewOpts ->
		    udp_recv(Socket, NewOpts)
	    end;
	{error, Reason} ->
	    ?LOG_ERROR("unexpected UDP error: ~s", [inet:format_error(Reason)]),
	    erlang:error(Reason)
    end.

format_listener_error(IP, Port, Transport, Opts, Err) ->
    ?LOG_ERROR("failed to start listener:~n"
	       "** IP: ~p~n"
	       "** Port: ~p~n"
	       "** Transport: ~p~n"
	       "** Options: ~p~n"
	       "** Reason: ~p",
	       [IP, Port, Transport, Opts, Err]).

-ifdef(USE_OLD_LOGGER).
init_logger() ->
    ok.
-else.
init_logger() ->
    logger:update_process_metadata(#{domain => [stun, listener]}).
-endif.
