%% -------------------------------------------------------------------
%%
%% riak_dt_map: OR-Set schema based multi CRDT container
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

%% @doc a multi CRDT holder. A Struct/Document-ish thing. Uses the
%% same tombstone-less, Observed Remove semantics as `riak_dt_orswot'.
%% A Map is set of `Field's a `Field' is a two-tuple of:
%% `{Name::binary(), CRDTModule::module()}' where the second element
%% is the name of a crdt module that confirms to the `riak_dt'
%% behaviour. CRDTs stored inside the Map will have their `update/3'
%% function called, but the second argument will be a `riak_dt:dot()',
%% so that they share the causal context of the map, even when fields
%% are removed, and subsequently re-added.
%%
%% The contents of the Map are modelled as a set of `{field(),
%% value(), dot()}' tuples, where `dot()' is the last event that
%% occurred on the field. When merging fields of the same name, but
%% different `dot' are _not_ merged. On updating a field, all the
%% elements in the set for that field are merged, updated, and
%% replaced with a new `dot' for the update event. This means that in
%% a divergent Map with many concurrent updates, a merged map will
%% have duplicate entries for any update fields until and update event
%% occurs. There is a paper on this implementation forthcoming at
%% PaPEC 2014, we will provide a reference when we have one.
%%
%% Attempting to remove a `field' that is not present in the map will
%% lead to a precondition error. An operation on a field value that
%% generates a precondition error will cause the Map operation to
%% return a precondition error. See `update/3' for details on
%% operations the Map accepts.
%%
%% @see riak_dt_orswot for more on the OR semantic
%% @end

-module(riak_dt_tsmap).

-behaviour(riak_dt).

-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([new/0, value/1, value/2, update/3, merge/2,
         equal/2, to_binary/1, from_binary/1, precondition_context/1, stats/1, stat/2]).

%% EQC API
-ifdef(EQC).
-export([gen_op/0, update_expected/3, eqc_state_value/1,
         init_state/0, gen_field/0, generate/0, size/1]).
-endif.

-type map() :: {riak_dt_vclock:vclock(), entries()}.
-type entries() :: ordsets:ordset(entry()).
-type entry() :: {Field :: field(), CRDT :: riak_dt:crdt(), Tag :: riak_dt:dot()}.
-type field() :: {Name :: binary(), CRDTModule :: module()}.

%% @doc Create a new, empty Map.
-spec new() -> map().
new() ->
    {riak_dt_vclock:fresh(), ordsets:new()}.

%% @doc get the current set of values for this Map
-spec value(map()) -> [{field(), term()}].
value({_Clock, Values}) ->
    Remaining = [{Field, CRDT} || {Field, CRDT, _Tag} <- ordsets:to_list(Values)],
    Res = lists:foldl(fun({{_Name, Type}=Key, Value}, Acc) ->
                              %% if key is in Acc merge with it and replace
                              dict:update(Key, fun(V) ->
                                                       Type:merge(V, Value) end,
                                          Value, Acc) end,
                      dict:new(),
                      Remaining),
    [{K, Type:value(V)} || {{_Name, Type}=K, V} <- dict:to_list(Res)].

value(_, Map) ->
    value(Map).

update({update, Ops}, Dot, {Clock, Values}) when is_tuple(Dot) ->
    NewClock = riak_dt_vclock:merge([[Dot], Clock]),
    apply_ops(Ops, Dot, NewClock, Values);
update({update, [{remove, _F}]=Ops}, Actor, {Clock, Values}) ->
    NewClock = riak_dt_vclock:increment(Actor, Clock),
    Dot = {Actor, riak_dt_vclock:get_counter(Actor, NewClock)},
    apply_ops(Ops, Dot, NewClock, Values);
update({update, Ops}, Actor, {Clock, Values}) ->
    NewClock = riak_dt_vclock:increment(Actor, Clock),
    Dot = {Actor, riak_dt_vclock:get_counter(Actor, NewClock)},
    apply_ops(Ops, Dot, NewClock, Values).

%% @private
apply_ops([], _Dot, Clock, Values) ->
    {ok, {Clock, Values}};
apply_ops([{update, {_Name, Type}=Field, Op} | Rest], Dot, Clock, Values) ->
    FieldInMap = [{F, CRDT, Tag} || {F, CRDT, Tag} <- ordsets:to_list(Values), F == Field],
    {CRDT, TrimmedValues} = lists:foldl(fun({_F, Value, _T}=E, {Acc, ValuesAcc}) ->
                                                %% remove the tagged
                                                %% value, as it will
                                                %% be superseded by
                                                %% the new update
                                                {Type:merge(Acc, Value),
                                                 ordsets:del_element(E, ValuesAcc)};
                                           (_, Acc) -> Acc
                                        end,
                                        {Type:new(), Values},
                                        FieldInMap),
    case Type:update(Op, Dot, CRDT) of
        {ok, Updated} ->
            %% ¿¿Remove? all the values you merged with?
            NewValues = ordsets:add_element({Field, Updated, Dot}, TrimmedValues),
            apply_ops(Rest, Dot, Clock, NewValues);
        Error ->
            Error
    end;
apply_ops([{remove, Field} | Rest], Dot, Clock, Values) ->
    {Removed, NewValues} = ordsets:fold(fun({F, _Val, _Token}, {_B, AccIn}) when F == Field ->
                                                {true, AccIn};
                                           (Elem, {B, AccIn}) ->
                                                {B, ordsets:add_element(Elem, AccIn)}
                                        end,
                                        {false, ordsets:new()},
                                        Values),
    case Removed of
        false ->
            {error, {precondition, {not_present, Field}}};
        _ ->
            apply_ops(Rest, Dot, Clock, NewValues)
    end;
apply_ops([{add, {_Name, Mod}=Field} | Rest], Dot, Clock, Values) ->
    %% @TODO ¿Should an add read and replace, or stand alone?
    %% InMap = [{F, CRDT} || {F, CRDT, _Tag, InMap} <- ordsets:to_list(Values), InMap == true],
    %% CRDT = lists:foldl(fun({{FName, FType}, Value}, Acc) when FName == Name,
    %%                                                               FType == Mod ->
    %%                            Mod:merge(Acc, Value);
    %%                       (_, Acc) -> Acc
    %%                    end,
    %%                    Mod:new(),
    %%                    InMap),
    ToAdd = {Field, Mod:new(), Dot},
    NewValues = ordsets:add_element(ToAdd, Values),
    apply_ops(Rest, Dot, Clock, NewValues).

merge({LHSClock, LHSEntries}, {RHSClock, RHSEntries}) ->
    Clock = riak_dt_vclock:merge([LHSClock, RHSClock]),

    RHS0 = ordsets:to_list(RHSEntries),

    {Entries0, RHSUnique} = lists:foldl(fun({_F, _CRDT, Tag}=E, {Acc, RHS}) ->
                                                case lists:keytake(Tag, 3, RHS) of
                                                    {value, E, RHS1} ->
                                                        %% same in bolth
                                                        {ordsets:add_element(E, Acc), RHS1};
                                                    false ->
                                                        %% RHS does not have this field, should be dropped, or kept?
                                                        case riak_dt_vclock:descends(RHSClock, [Tag]) of
                                                            true ->
                                                                %% RHS has seen it, and removed it
                                                                {Acc, RHS};
                                                            false ->
                                                                %% RHS not seen it yet, keep it
                                                                {ordsets:add_element(E, Acc), RHS}
                                                        end
                                                end
                                        end,
                                        {ordsets:new(), RHS0},
                                        LHSEntries),
    %% What about the things left in RHS, should they be kept?
    Entries1 = lists:foldl(fun({_F, _CRDT, Tag}=E, Acc) ->
                                   case riak_dt_vclock:descends(LHSClock, [Tag]) of
                                       true ->
                                           %% LHS has seen, and removed this
                                           Acc;
                                       false ->
                                           %% Not in LHS, should be kept
                                           ordsets:add_element(E, Acc)
                                   end
                           end,
                           ordsets:new(),
                           RHSUnique),

    Entries = ordsets:union(Entries0, Entries1),
    {Clock, Entries}.

equal({Clock1, Values1}, {Clock2, Values2}) ->
    riak_dt_vclock:equal(Clock1, Clock2) andalso
        pairwise_equals(ordsets:to_list(Values1), ordsets:to_list(Values2)).

pairwise_equals([], []) ->
    true;
pairwise_equals([{{_Name, Type}, CRDT1, Tag}| Rest1], [{{_Name, Type}, CRDT2, Tag}|Rest2]) ->
    case Type:equal(CRDT1, CRDT2) of
        true ->
            pairwise_equals(Rest1, Rest2);
        false ->
            false
    end;
pairwise_equals(_, _) ->
    false.

%% @Doc a "fragment" of the Map that can be used for precondition
%% operations. The schema is just the active Key Set The values are
%% just those values that are present We use either the values
%% precondition_context or the whole CRDT
-spec precondition_context(map()) -> map().
precondition_context(Map) ->
    Map.

stats(_) ->
    [].

stat(_,_) -> undefined.

-define(TAG, 101).
-define(V1_VERS, 1).

%% @doc returns a binary representation of the provided `map()'. The
%% resulting binary is tagged and versioned for ease of future
%% upgrade. Calling `from_binary/1' with the result of this function
%% will return the original map.  Use the application env var
%% `binary_compression' to turn t2b compression on (`true') and off
%% (`false')
%%
%% @see `from_binary/1'
to_binary(Map) ->
    Opts = case application:get_env(riak_dt, binary_compression, 1) of
               true -> [compressed];
               N when N >= 0, N =< 9 -> [{compressed, N}];
               _ -> []
           end,
    <<?TAG:8/integer, ?V1_VERS:8/integer, (term_to_binary(Map, Opts))/binary>>.

%% @doc When the argument is a `binary_map()' produced by
%% `to_binary/1' will return the original `map()'.
%%
%% @see `to_binary/1'
from_binary(<<?TAG:8/integer, ?V1_VERS:8/integer, B/binary>>) ->
    binary_to_term(B).


%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

%% This fails on riak_dt_map
assoc_test() ->
    Field = {'X', riak_dt_orswot},
    {ok, A} = update({update, [{update, Field, {add, 0}}]}, a, new()),
    {ok, B} = update({update, [{update, Field, {add, 0}}]}, b, new()),
    {ok, B2} = update({update, [{update, Field, {remove, 0}}]}, b, B),
    C = A,
    {ok, C3} = update({update, [{remove, Field}]}, c, C),
    ?assertEqual(merge(A, merge(B2, C3)), merge(merge(A, B2), C3)),
    ?assertEqual(value(merge(merge(A, C3), B2)), value(merge(merge(A, B2), C3))),
    ?assertEqual(merge(merge(A, C3), B2),  merge(merge(A, B2), C3)),
    ?debugFmt("Map::::~p~n~n-----~nVal:::~p~n", [merge(merge(A, C3), B2), value(merge(merge(A, C3), B2))]).

clock_test() ->
    Field = {'X', riak_dt_orswot},
    {ok, A} = update({update, [{update, Field, {add, 0}}]}, a, new()),
    B = A,
    {ok, B2} = update({update, [{update, Field, {add, 1}}]}, b, B),
    {ok, A2} = update({update, [{update, Field, {remove, 0}}]}, a, A),
    {ok, A3} = update({update, [{remove, Field}]}, a, A2),
    {ok, A4} = update({update, [{update, Field, {add, 2}}]}, a, A3),
    AB = merge(A4, B2),
    ?assertEqual([{Field, [1, 2]}], value(AB)).

remfield_test() ->
    Field = {'X', riak_dt_orswot},
    {ok, A} = update({update, [{update, Field, {add, 0}}]}, a, new()),
    B = A,
    {ok, A2} = update({update, [{update, Field, {remove, 0}}]}, a, A),
    {ok, A3} = update({update, [{remove, Field}]}, a, A2),
    {ok, A4} = update({update, [{update, Field, {add, 2}}]}, a, A3),
    AB = merge(A4, B),
    ?assertEqual([{Field, [2]}], value(AB)).

%% Bug found by EQC, not dropping dots in merge when an element is
%% present in both Sets leads to removed items remaining after merge.
present_but_removed_test() ->
    %% Add Z to A
    {ok, A} = update({update, [{add, {'Z', riak_dt_lwwreg}}]}, a, new()),
    %% Replicate it to C so A has 'Z'->{e, 1}
    C = A,
    %% Remove Z from A
    {ok, A2} = update({update, [{remove, {'Z', riak_dt_lwwreg}}]}, a, A),
    %% Add Z to B, a new replica
    {ok, B} = update({update, [{add, {'Z', riak_dt_lwwreg}}]}, b, new()),
    %%  Replicate B to A, so now A has a Z, the one with a Dot of
    %%  {b,1} and clock of [{a, 1}, {b, 1}]
    A3 = merge(B, A2),
    %% Remove the 'Z' from B replica
    {ok, B2} = update({update, [{remove, {'Z', riak_dt_lwwreg}}]}, b, B),
    %% Both C and A have a 'Z', but when they merge, there should be
    %% no 'Z' as C's has been removed by A and A's has been removed by
    %% C.
    Merged = lists:foldl(fun(Set, Acc) ->
                                 merge(Set, Acc) end,
                         %% the order matters, the two replicas that
                         %% have 'Z' need to merge first to provoke
                         %% the bug. You end up with 'Z' with two
                         %% dots, when really it should be removed.
                         A3,
                         [C, B2]),
    ?assertEqual([], value(Merged)).


%% A bug EQC found where dropping the dots in merge was not enough if
%% you then store the value with an empty clock (derp).
no_dots_left_test() ->
    {ok, A} =  update({update, [{add, {'Z', riak_dt_lwwreg}}]}, a, new()),
    {ok, B} =  update({update, [{add, {'Z', riak_dt_lwwreg}}]}, b, new()),
    C = A, %% replicate A to empty C
    {ok, A2} = update({update, [{remove, {'Z', riak_dt_lwwreg}}]}, a, A),
    %% replicate B to A, now A has B's 'Z'
    A3 = merge(A2, B),
    %% Remove B's 'Z'
    {ok, B2} = update({update, [{remove, {'Z', riak_dt_lwwreg}}]}, b, B),
    %% Replicate C to B, now B has A's old 'Z'
    B3 = merge(B2, C),
    %% Merge everytyhing, without the fix You end up with 'Z' present,
    %% with no dots
    Merged = lists:foldl(fun(Set, Acc) ->
                                 merge(Set, Acc) end,
                         A3,
                         [B3, C]),
    ?assertEqual([], value(Merged)).


-ifdef(EQC).
-define(NUMTESTS, 1000).

bin_roundtrip_test_() ->
    crdt_statem_eqc:run_binary_rt(?MODULE, ?NUMTESTS).

eqc_value_test_() ->
    crdt_statem_eqc:run(?MODULE, ?NUMTESTS).

%% ===================================
%% crdt_statem_eqc callbacks
%% ===================================
size(Map) ->
    %% How big is a Map? Maybe number of fields and depth matter? But then the number of fields in sub maps too?
    byte_size(term_to_binary(Map)) div 10.

generate() ->
        ?LET({Ops, Actors}, {non_empty(list(gen_op())), non_empty(list(bitstring(16*8)))},
         lists:foldl(fun(Op, Map) ->
                             Actor = case length(Actors) of
                                         1 -> hd(Actors);
                                         _ -> lists:nth(crypto:rand_uniform(1, length(Actors)), Actors)
                                     end,
                             case riak_dt_tsmap:update(Op, Actor, Map) of
                                 {ok, M} -> M;
                                 _ -> Map
                             end
                     end,
                     riak_dt_map:new(),
                     Ops)).

gen_op() ->
    ?LET(Ops, non_empty(list(gen_update())), {update, Ops}).

gen_update() ->
    ?LET(Field, gen_field(),
         oneof([{add, Field}, {remove, Field},
                {update, Field, gen_field_op(Field)}])).

gen_field() ->
    {non_empty(binary()), oneof([riak_dt_pncounter,
                                 riak_dt_orswot,
                                 riak_dt_lwwreg,
                                 riak_dt_tsmap,
                                 riak_dt_od_flag])}.

gen_field_op({_Name, Type}) ->
    Type:gen_op().

init_state() ->
    {0, dict:new()}.

update_expected(ID, {update, Ops}, State) ->
    %% Ops are atomic, all pass or all fail
    %% return original state if any op failed
    update_all(ID, Ops, State);
update_expected(ID, {merge, SourceID}, {Cnt, Dict}) ->
    {FA, FR} = dict:fetch(ID, Dict),
    {TA, TR} = dict:fetch(SourceID, Dict),
    MA = sets:union(FA, TA),
    MR = sets:union(FR, TR),
    {Cnt, dict:store(ID, {MA, MR}, Dict)};
update_expected(ID, create, {Cnt, Dict}) ->
    {Cnt, dict:store(ID, {sets:new(), sets:new()}, Dict)}.

eqc_state_value({_Cnt, Dict}) ->
    {A, R} = dict:fold(fun(_K, {Add, Rem}, {AAcc, RAcc}) ->
                               {sets:union(Add, AAcc), sets:union(Rem, RAcc)} end,
                       {sets:new(), sets:new()},
                       Dict),
    Remaining = sets:subtract(A, R),
    Res = lists:foldl(fun({{_Name, Type}=Key, Value, _X}, Acc) ->
                        %% if key is in Acc merge with it and replace
                        dict:update(Key, fun(V) ->
                                                 Type:merge(V, Value) end,
                                    Value, Acc) end,
                dict:new(),
                sets:to_list(Remaining)),
    [{K, Type:value(V)} || {{_Name, Type}=K, V} <- dict:to_list(Res)].

%% @private
%% @doc Apply the list of update operations to the model
update_all(ID, Ops, OriginalState) ->
    update_all(ID, Ops, OriginalState, OriginalState).

update_all(_ID, [], _OriginalState, NewState) ->
    NewState;
update_all(ID, [{update, {_Name, Type}=Key, Op} | Rest], OriginalState, {Cnt0, Dict}) ->
    CurrentValue = get_for_key(Key, ID, Dict),
    %% handle precondition errors any precondition error means the
    %% state is not changed at all
    case Type:update(Op, ID, CurrentValue) of
        {ok, Updated} ->
            Cnt = Cnt0+1,
            ToAdd = {Key, Updated, Cnt},
            {A, R} = dict:fetch(ID, Dict),
            update_all(ID, Rest, OriginalState, {Cnt, dict:store(ID, {sets:add_element(ToAdd, A), R}, Dict)});
        _Error ->
            OriginalState
    end;
update_all(ID, [{remove, Field} | Rest], OriginalState, {Cnt, Dict}) ->
    {A, R} = dict:fetch(ID, Dict),
    In = sets:subtract(A, R),
    PresentFields = [E ||  {E, _, _X} <- sets:to_list(In)],
    case lists:member(Field, PresentFields) of
        true ->
            ToRem = [{E, V, X} || {E, V, X} <- sets:to_list(A), E == Field],
            NewState2 = {Cnt, dict:store(ID, {A, sets:union(R, sets:from_list(ToRem))}, Dict)},
            update_all(ID, Rest, OriginalState, NewState2);
        false ->
            OriginalState
    end;
update_all(ID, [{add, {_Name, Type}=Field} | Rest], OriginalState, {Cnt0, Dict}) ->
    Cnt = Cnt0+1,
    ToAdd = {Field, Type:new(), Cnt},
    {A, R} = dict:fetch(ID, Dict),
    NewState = {Cnt, dict:store(ID, {sets:add_element(ToAdd, A), R}, Dict)},
    update_all(ID, Rest, OriginalState, NewState).


get_for_key({_N, T}=K, ID, Dict) ->
    {A, R} = dict:fetch(ID, Dict),
    Remaining = sets:subtract(A, R),
    Res = lists:foldl(fun({{_Name, Type}=Key, Value, _X}, Acc) ->
                        %% if key is in Acc merge with it and replace
                        dict:update(Key, fun(V) ->
                                                 Type:merge(V, Value) end,
                                    Value, Acc) end,
                dict:new(),
                sets:to_list(Remaining)),
    proplists:get_value(K, dict:to_list(Res), T:new()).

-endif.

stat_test() ->
    Map = new(),
    {ok, Map1} = update({update, [{add, {c, riak_dt_pncounter}},
                                  {add, {s, riak_dt_orswot}},
                                  {add, {m, riak_dt_map}},
                                  {add, {l, riak_dt_lwwreg}},
                                  {add, {l2, riak_dt_lwwreg}}]}, a1, Map),
    {ok, Map2} = update({update, [{update, {l, riak_dt_lwwreg}, {assign, <<"foo">>, 1}}]}, a2, Map1),
    {ok, Map3} = update({update, [{update, {l, riak_dt_lwwreg}, {assign, <<"bar">>, 2}}]}, a3, Map1),
    Map4 = merge(Map2, Map3),
    ?assertEqual([{actor_count, 0}, {field_count, 0}, {max_dot_length, 0}], stats(Map)),
    ?assertEqual(3, stat(actor_count, Map4)),
    ?assertEqual(5, stat(field_count, Map4)),
    ?assertEqual(2, stat(max_dot_length, Map4)),
    ?assertEqual(undefined, stat(waste_pct, Map4)).

-endif.
