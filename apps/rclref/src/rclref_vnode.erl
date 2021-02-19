-module(rclref_vnode).

-behaviour(riak_core_vnode).

-include_lib("stdlib/include/assert.hrl").

-export([start_vnode/1, init/1, terminate/2, handle_command/3, is_empty/1, delete/1,
         handle_handoff_command/3, handoff_starting/2, handoff_cancelled/1, handoff_finished/2,
         handle_handoff_data/2, encode_handoff_item/2, handle_overload_command/3,
         handle_overload_info/2, handle_coverage/4, handle_exit/3]).

-ignore_xref([{start_vnode, 1}]).

-record(state, {partition, mod, modstate}).
-record(riak_core_fold_req_v2,
        {foldfun :: fun(), acc0 :: term(), forwardable :: boolean(), opts = [] :: list()}).

%% API
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Partition]) ->
    Mod =
        case rclref_config:storage_backend() of
          ets ->
              rclref_ets_backend;
          dets ->
              rclref_dets_backend;
          _ ->
              ?assert(false)
        end,
    {ok, ModState} = Mod:start(Partition, []),
    logger:debug("Successfully started ~p backend for partition ~p", [Mod, Partition]),
    State = #state{partition = Partition, mod = Mod, modstate = ModState},
    {ok, State}.

%% Sample command: respond to a ping
handle_command(ping, _Sender, State) ->
    {reply, {pong, node(), State#state.partition}, State};
handle_command({kv_put_request, RObj, Pid, Node},
               _Sender,
               State0 = #state{partition = Partition, mod = Mod, modstate = ModState0}) ->
    Key = rclref_object:key(RObj),
    Value = rclref_object:value(RObj),

    % get will be issued before put
    % If a key is new to backend, store it with a new vector clock
    % If a key is not new to backend, store it with an updated vector clock
    % If get returns an error, put will be ignored
    case Mod:get(Key, ModState0) of
      {ok, not_found, ModState1} ->
          % Create content with a new vector clock
          VClock = rclref_object:new_vclock(),
          NewVClock = rclref_object:increment_vclock(Node, VClock),
          NewContent = rclref_object:new_content(Value, NewVClock),

          case Mod:put(Key, NewContent, ModState1) of
            {ok, ModState2} ->
                NewRObj = rclref_object:new(Key, NewContent, Partition, node()),
                rclref_put_statem:result_of_put(Pid, {ok, NewRObj}),
                State1 = State0#state{modstate = ModState2},
                {noreply, State1};
            {error, Reason, ModState2} ->
                logger:error("Failed to put kv with key: ~p, content: ~p for partition: ~p, "
                             "error: ~p",
                             [Key, NewContent, Partition, Reason]),
                VnodeError = rclref_object:new_error(Reason, Partition, node()),
                rclref_put_statem:result_of_put(Pid, {error, VnodeError}),
                State1 = State0#state{modstate = ModState2},
                {noreply, State1}
          end;
      {ok, Content, ModState1} ->
          % Create content with an updated vector clock
          VClock = rclref_object:vclock(Content),
          NewVClock = rclref_object:increment_vclock(Node, VClock),
          NewContent = rclref_object:new_content(Value, NewVClock),

          case Mod:put(Key, NewContent, ModState1) of
            {ok, ModState2} ->
                NewRObj = rclref_object:new(Key, NewContent, Partition, node()),
                rclref_put_statem:result_of_put(Pid, {ok, NewRObj}),
                State1 = State0#state{modstate = ModState2},
                {noreply, State1};
            {error, Reason, ModState2} ->
                logger:error("Failed to put kv with key: ~p, content: ~p for partition: ~p, "
                             "error: ~p",
                             [Key, NewContent, Partition, Reason]),
                VnodeError = rclref_object:new_error(Reason, Partition, node()),
                rclref_put_statem:result_of_put(Pid, {error, VnodeError}),
                State1 = State0#state{modstate = ModState2},
                {noreply, State1}
          end;
      {error, Reason, ModState1} ->
          logger:error("Failed to get kv (before put) with key: ~p for partition: ~p, "
                       "error: ~p",
                       [Key, Partition, Reason]),
          VnodeError = rclref_object:new_error(Reason, Partition, node()),
          rclref_put_statem:result_of_put(Pid, {error, VnodeError}),
          State1 = State0#state{modstate = ModState1},
          {noreply, State1}
    end;
handle_command({kv_get_request, Key, Pid},
               _Sender,
               State0 = #state{partition = Partition, mod = Mod, modstate = ModState0}) ->
    case Mod:get(Key, ModState0) of
      {ok, not_found, ModState1} ->
          VnodeError = rclref_object:new_error(not_found, Partition, node()),
          ok = rclref_get_statem:result_of_get(Pid, {error, VnodeError}),
          State1 = State0#state{modstate = ModState1},
          {noreply, State1};
      {ok, Content, ModState1} ->
          RObj = rclref_object:new(Key, Content, Partition, node()),
          ok = rclref_get_statem:result_of_get(Pid, {ok, RObj}),
          State1 = State0#state{modstate = ModState1},
          {noreply, State1};
      {error, Reason, ModState1} ->
          logger:error("Failed to get kv with key: ~p for partition: ~p, error: ~p",
                       [Key, Partition, Reason]),
          VnodeError = rclref_object:new_error(Reason, Partition, node()),
          rclref_get_statem:result_of_get(Pid, {error, VnodeError}),
          State1 = State0#state{modstate = ModState1},
          {noreply, State1}
    end;
handle_command({repair_request, RObj},
               _Sender,
               State0 = #state{partition = Partition, mod = Mod, modstate = ModState0}) ->
    Key = rclref_object:key(RObj),
    Content = rclref_object:content(RObj),

    case Mod:put(Key, Content, ModState0) of
      {ok, ModState1} ->
          State1 = State0#state{modstate = ModState1},
          {noreply, State1};
      {error, Reason, ModState1} ->
          logger:error("Failed to put kv with key: ~p, content: ~p for partition: ~p, "
                       "error: ~p",
                       [Key, Content, Partition, Reason]),
          State1 = State0#state{modstate = ModState1},
          {noreply, State1}
    end;
handle_command({reap_tombs_request, Key},
               _Sender,
               State0 = #state{partition = Partition, mod = Mod, modstate = ModState0}) ->
    case Mod:get(Key, ModState0) of
      {ok, not_found, ModState1} ->
          State1 = State0#state{modstate = ModState1},
          {noreply, State1};
      {ok, Content, ModState1} ->
          case rclref_object:value(Content) of
            undefined ->
                {ok, ModState2} = Mod:delete(Key, ModState1);
            _ ->
                ModState2 = ModState1
          end,
          State1 = State0#state{modstate = ModState2},
          {noreply, State1};
      {error, Reason, ModState1} ->
          logger:error("Failed to get kv with key: ~p for partition: ~p, error: ~p",
                       [Key, Partition, Reason]),
          State1 = State0#state{modstate = ModState1},
          {noreply, State1}
    end;
handle_command(Message, _Sender, State) ->
    logger:warning("unhandled_command ~p", [Message]),
    {noreply, State}.

handle_handoff_command(#riak_core_fold_req_v2{foldfun = FoldFun, acc0 = Acc0},
                       _Sender,
                       State = #state{mod = Mod, modstate = ModState}) ->
    % FoldFun
    % -type fold_objects_fun() :: fun((term(), term(), any()) -> any() | no_return()).
    Acc = Mod:fold_objects(FoldFun, Acc0, [], ModState),
    {reply, Acc, State};
handle_handoff_command(Message, _Sender, State) ->
    logger:warning("handoff command ~p, ignoring", [Message]),
    {noreply, State}.

handoff_starting(TargetNode, State = #state{partition = Partition}) ->
    logger:debug("handoff starting ~p: ~p", [Partition, TargetNode]),
    {true, State}.

handoff_cancelled(State = #state{partition = Partition}) ->
    logger:debug("handoff cancelled ~p", [Partition]),
    {ok, State}.

handoff_finished(TargetNode, State = #state{partition = Partition}) ->
    logger:debug("handoff finished ~p: ~p", [Partition, TargetNode]),
    {ok, State}.

handle_handoff_data(BinData,
                    State0 = #state{partition = Partition, mod = Mod, modstate = ModState0}) ->
    {Key, Content} = binary_to_term(BinData),
    logger:debug("handoff data received ~p: ~p", [Partition, Key]),
    {ok, ModState1} = Mod:put(Key, Content, ModState0),
    State1 = State0#state{modstate = ModState1},
    {reply, ok, State1}.

encode_handoff_item(Key, Content) ->
    term_to_binary({Key, Content}).

handle_overload_command(_, _, _) ->
    ok.

handle_overload_info(_, _Idx) ->
    ok.

is_empty(State = #state{mod = Mod, modstate = ModState}) ->
    case Mod:is_empty(ModState) of
      true ->
          logger:debug("is_empty: ~p", [true]),
          {true, State};
      false ->
          logger:debug("is_empty: ~p", [false]),
          {false, State};
      Other ->
          logger:error("is_empty error reason :~p", [Other]),
          {false, State}
    end.

delete(State0 = #state{partition = Partition, mod = Mod, modstate = ModState0}) ->
    logger:debug("delete partition: ~p", [Partition]),
    {ok, ModState1} = Mod:drop(ModState0),
    ok = Mod:stop(ModState1),
    State1 = State0#state{modstate = ModState1},
    {ok, State1}.

handle_coverage({_, keys},
                _KeySpaces,
                {_, ReqId, _},
                State0 = #state{partition = _Partition, mod = Mod, modstate = ModState0}) ->
    Acc0 = [],
    Fun =
        fun (Key, Accum) ->
                [Key] ++ Accum
        end,
    Acc1 = Mod:fold_keys(Fun, Acc0, ModState0),
    {reply, {ReqId, Acc1}, State0};
handle_coverage({_, objects},
                _KeySpaces,
                {_, ReqId, _},
                State0 = #state{partition = Partition, mod = Mod, modstate = ModState0}) ->
    Acc0 = [],
    Fun =
        fun (Key, Content, Accum) ->
                [rclref_object:new(Key, Content, Partition, node())] ++ Accum
        end,
    Acc1 = Mod:fold_objects(Fun, Acc0, ModState0),
    {reply, {ReqId, Acc1}, State0}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
