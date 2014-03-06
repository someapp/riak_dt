%% -------------------------------------------------------------------
%%
%% riak_dt_od_flag: a flag that can be enabled and disabled as many
%%     times as you want, enabling wins, starts disabled.
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
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

-module(riak_dt_od_flag).

-behaviour(riak_dt).

-export([new/0, value/1, value/2, update/3, merge/2, equal/2, from_binary/1, to_binary/1, stats/1, stat/2]).

-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-export([gen_op/0, init_state/0, update_expected/3, eqc_state_value/1, generate/0, size/1]).
-define(NUMTESTS, 1000).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export_type([od_flag/0, od_flag_op/0]).

-opaque od_flag() :: {riak_dt_vclock:vclock(), [riak_dt:dot()]}.
-type od_flag_op() :: enable | disable.

-spec new() -> od_flag().
new() ->
    {riak_dt_vclock:fresh(), []}.

-spec value(od_flag()) -> boolean().
value({_, []}) -> false;
value({_, _}) -> true.

-spec value(term(), od_flag()) -> boolean().
value(_, Flag) ->
    value(Flag).

-spec update(od_flag_op(), riak_dt:actor() | riak_dt:dot(), od_flag()) -> {ok, od_flag()}.
update(enable, Dot, {Clock, Dots}) when is_tuple(Dot) ->
    NewClock = riak_dt_vclock:merge([[Dot], Clock]),
    {ok, {NewClock, riak_dt_vclock:merge([[Dot], Dots])}};
update(enable, Actor, {Clock,Dots}) ->
    NewClock = riak_dt_vclock:increment(Actor, Clock),
    Dot = [{Actor, riak_dt_vclock:get_counter(Actor, NewClock)}],
    {ok, {NewClock, riak_dt_vclock:merge([Dot, Dots])}};
update(disable, _Actor, {Clock,_}=_Flag) ->
    {ok, {Clock, []}}.

-spec merge(od_flag(), od_flag()) -> od_flag().
merge({Clock, Entries}, {Clock, Entries}) ->
    %% When they are the same result why merge?
    {Clock, Entries};
merge({LHSClock, LHSDots}, {RHSClock, RHSDots}) ->
    NewClock = riak_dt_vclock:merge([LHSClock, RHSClock]),
    %% drop all the LHS dots that are dominated by the rhs clock
    %% drop all the RHS dots that dominated by the LHS clock
    %% keep all the dots that are in both
    %% save value as value of flag
    CommonDots = sets:intersection(sets:from_list(LHSDots), sets:from_list(RHSDots)),
    LHSUnique = sets:to_list(sets:subtract(sets:from_list(LHSDots), CommonDots)),
    RHSUnique = sets:to_list(sets:subtract(sets:from_list(RHSDots), CommonDots)),
    LHSKeep = riak_dt_vclock:subtract_dots(LHSUnique, RHSClock),
    RHSKeep = riak_dt_vclock:subtract_dots(RHSUnique, LHSClock),
    Flag = riak_dt_vclock:merge([sets:to_list(CommonDots), LHSKeep, RHSKeep]),
    %% Perfectly possible that an item in both sets should be dropped
    {NewClock, Flag}.

-spec equal(od_flag(), od_flag()) -> boolean().
equal({C1,D1},{C2,D2}) ->
    riak_dt_vclock:equal(C1,C2) andalso riak_dt_vclock:equal(D1, D2).

-spec stats(od_flag()) -> [{atom(), integer()}].
stats(ODF) ->
    [{actor_count, stat(actor_count, ODF)},
     {dot_length, stat(dot_length, ODF)}].

-spec stat(atom(), od_flag()) -> number() | undefined.
stat(actor_count, {C, _}) ->
    length(C);
stat(dot_length, {_, D}) ->
    length(D);
stat(_, _) -> undefined.


-define(TAG, 73).
-define(VSN1, 1).

-spec from_binary(binary()) -> od_flag().
from_binary(<<?TAG:8, ?VSN1:8, Bin/binary>>) ->
    binary_to_term(Bin).

-spec to_binary(od_flag()) -> binary().
to_binary(Flag) ->
    Bin = term_to_binary(Flag),
    <<?TAG:8, ?VSN1:8, Bin/binary>>.


%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

-ifdef(EQC).
eqc_value_test_() ->
    crdt_statem_eqc:run(?MODULE, ?NUMTESTS).

bin_roundtrip_test_() ->
    crdt_statem_eqc:run_binary_rt(?MODULE, ?NUMTESTS).

% EQC generator
gen_op() ->
    oneof([disable,enable]).

size({Clock,_}) ->
    length(Clock).

init_state() ->
    orddict:new().

generate() ->
    ?LET(Ops, non_empty(list({gen_op(), binary(16)})),
         lists:foldl(fun({Op, Actor}, Flag) ->
                             {ok, F} = ?MODULE:update(Op, Actor, Flag),
                             F
                     end,
                     ?MODULE:new(),
                     Ops)).

update_expected(ID, create, Dict) ->
    orddict:store(ID, false, Dict);
update_expected(ID, enable, Dict) ->
    orddict:store(ID, true, Dict);
update_expected(ID, disable, Dict) ->
    orddict:store(ID, false, Dict);
update_expected(ID, {merge, SourceID}, Dict) ->
    Mine = orddict:fetch(ID, Dict),
    Theirs = orddict:fetch(SourceID, Dict),
    Merged = Mine or Theirs,
    orddict:store(ID, Merged, Dict).

eqc_state_value(Dict) ->
    orddict:fold(fun(_K, V, Acc) -> V or Acc end, false, Dict).
-endif.

disable_test() ->
    {ok, A} = update(enable, a, new()),
    {ok, B} = update(enable, b, new()),
    C = A,
    {ok, A2} = update(disable, a, A),
    A3 = merge(A2, B),
    {ok, B2} = update(disable, b, B),
    Merged = merge(merge(C, A3), B2),
    ?assertEqual(false, value(Merged)).

new_test() ->
    ?assertEqual(false, value(new())).

update_enable_test() ->
    F0 = new(),
    {ok, F1} = update(enable, 1, F0),
    ?assertEqual(true, value(F1)).

update_enable_multi_test() ->
    F0 = new(),
    {ok, F1} = update(enable, 1, F0),
    {ok, F2} = update(disable, 1, F1),
    {ok, F3} = update(enable, 1, F2),
    ?assertEqual(true, value(F3)).

merge_offs_test() ->
    F0 = new(),
    ?assertEqual(false, value(merge(F0, F0))).

merge_simple_test() ->
    F0 = new(),
    {ok, F1} = update(enable, 1, F0),
    ?assertEqual(true, value(merge(F1, F0))),
    ?assertEqual(true, value(merge(F0, F1))),
    ?assertEqual(true, value(merge(F1, F1))).

merge_concurrent_test() ->
    F0 = new(),
    {ok, F1} = update(enable, 1, F0),
    {ok, F2} = update(disable, 1, F1),
    {ok, F3} = update(enable, 1, F1),
    ?assertEqual(true, value(merge(F1,F3))),
    ?assertEqual(false, value(merge(F1,F2))),
    ?assertEqual(true, value(merge(F2,F3))).

binary_roundtrip_test() ->
    F0 = new(),
    {ok, F1} = update(enable, 1, F0),
    {ok, F2} = update(disable, 1, F1),
    {ok, F3} = update(enable, 2, F2),
    ?assert(equal(from_binary(to_binary(F3)), F3)).

stat_test() ->
    {ok, F0} = update(enable, 1, new()),
    {ok, F1} = update(enable, 1, F0),
    {ok, F2} = update(enable, 2, F1),
    {ok, F3} = update(enable, 3, F2),
    ?assertEqual([{actor_count, 3}, {dot_length, 3}], stats(F3)),
    {ok, F4} = update(disable, 4, F3), %% Observed-disable doesn't add an actor
    ?assertEqual([{actor_count, 3}, {dot_length, 0}], stats(F4)),
    ?assertEqual(3, stat(actor_count, F4)),
    ?assertEqual(undefined, stat(max_dot_length, F4)).
-endif.
