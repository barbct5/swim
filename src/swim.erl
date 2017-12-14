%%% ----------------------------------------------------------------------------
%%% Copyright (c) 2015-2017 All Rights Reserved.
%%%
%%% Licensed under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file except in compliance
%%% with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitiations under the License.
%%% ----------------------------------------------------------------------------

%%% @copyright 2015-2017
%%% @version {@version}

-module(swim).
-behavior(gen_server).

-include("swim.hrl").

-export([start_link/2]).
-export([members/0]).
-export([local_member/0]).
-export([alive/2]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

-record(state, {
          protocol_period        :: pos_integer(),
          ack_timeout            :: pos_integer(),
          num_proxies            :: pos_integer(),
          current_ping           :: member(),
          ping_targets    = []   :: [{member(), incarnation()}],
          sequence        = 0    :: non_neg_integer(),
          membership             :: pid()
         }).

start_link(LocalMember, Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [LocalMember, Opts], []).

local_member() ->
    gen_server:call(?MODULE, local_member).

members() ->
    gen_server:call(?MODULE, members).

alive(Peer, Incarnation) ->
    gen_server:cast(?MODULE, {alive, Peer, Incarnation}).

%% @private
init([LocalMember, Opts]) ->
    State =
        #state{
           membership      = swim_membership:new(LocalMember),
           ack_timeout     = maps:get(ack_timeout, Opts),
           protocol_period = maps:get(protocol_period, Opts),
           num_proxies     = maps:get(num_proxies, Opts, 3),
           sequence        = maps:get(sequence, Opts, 0)
          },
    self() ! protocol_period,
    {ok, State}.


%% @private
handle_call(local_member, _From, State) ->
    #state{membership = Membership} = State,
    {reply, swim_membership:local_member(Membership), State};
handle_call(members, _From, State) ->
    #state{membership = Membership} = State,
    {reply, swim_membership:members(Membership), State};
handle_call(_Msg, _From, State) ->
    {noreply, State}.

%% @private
handle_cast({alive, Peer, Incarnation}, State) ->
    {_Events, Membership} = swim_membership:alive(Peer, Incarnation, State#state.membership),
    {noreply, State#state{membership = Membership}};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(protocol_period, State) ->
    NewState = handle_protocol_period(State),
    ok = schedule_next_protocol_period(NewState),
    {noreply, NewState};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

handle_protocol_period(#state{current_ping = undefined} = State) ->
    send_next_ping(State);
handle_protocol_period(#state{current_ping = Target} = State) ->
    #state{membership = Membership} = State,
    _ = swim_membership:set_status(Membership, Target, suspect),
    send_next_ping(State#state{current_ping = undefined}).

send_next_ping(#state{ping_targets=[]} = State) ->
    case ping_targets(State) of
        [] ->
            State;
        PingTargets ->
            send_next_ping(State#state{ping_targets = PingTargets})
    end;
send_next_ping(#state{ping_targets = [{PingTarget, Incarnation} | PingTargets]} = State) ->
    Proxies = lists:sublist([M || {M, _I} <- ping_targets(State),
                                  M /= PingTarget], State#state.num_proxies),
    ok = swim_transport:ping(PingTarget, Incarnation, State#state.sequence, Proxies),
    State#state{current_ping = PingTarget, ping_targets = PingTargets}.

ping_targets(State) ->
    #state{membership = Membership} = State,
    Members = swim_membership:members(Membership),
    [{M, I} || {_, {M, _S, I}} <- lists:keysort(1, [{rand_compat:uniform(), N} || N <- Members])].

schedule_next_protocol_period(State) ->
    #state{protocol_period = Timeout} = State,
    _TRef = time_compat:send_after(Timeout, self(), protocol_period),
    ok.
