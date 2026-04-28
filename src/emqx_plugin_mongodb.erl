-module(emqx_plugin_mongodb).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_hooks.hrl").
-include_lib("emqx/include/logger.hrl").
-include("emqx_plugin_mongodb.hrl").

-export([
  load/0
  , unload/0
  , reload/0
]).

-export([on_message_publish/1]).

-export([eventmsg_publish/1]).

load() ->
  ensure_ets_table(),
  load(read_config()).

load(#{connection := Connection, topics := Topics}) ->
  {ok, _} = start_resource(Connection),
  topic_parse(Topics),
  hook('message.publish', {?MODULE, on_message_publish, []});
load(_) ->
  {error, "config_error"}.

%% 修改on_message_publish函数
on_message_publish(Message = #message{topic = Topic}) ->
  case select(Message) of
    {true, Querys} when Querys =/= [] ->
      ?SLOG(debug, #{
        msg => "Matched queries",
        topic => Topic,
        queries => Querys
      }),
      spawn(fun() ->
        try
          handle_matched_message(Message, Topic, Querys)
        catch
          Error:Reason ->
            ?SLOG(error, #{
              msg => "async_mongodb_query_failed",
              error => Error,
              reason => Reason,
              message => Message
            })
        end
      end);
    {true, []} ->
      %% 匹配到了规则但没有查询（可能是空列表），不执行任何操作
      ok;
    false ->
      %% 没有匹配到任何规则，不执行任何操作
      ok
  end,
  {ok, Message}.

%% 根据topic前缀处理消息
handle_matched_message(Message, Topic, Querys) ->
  case binary:match(Topic, <<"device/telemetry/">>) of
    {0, _} ->
      TelemetryData = eventmsg_publish_telemetry(Message),
      DeviceName = extract_device_name_from_topic(Topic),
      DynamicQuerys = update_collection_names(Querys, DeviceName),
      query(TelemetryData, DynamicQuerys);
    _ ->
      %% device/status/ 主题已禁用，不再处理设备状态数据
      %% case binary:match(Topic, <<"device/status/">>) of
      %%   {0, _} ->
      %%     StatusData = eventmsg_publish_device_status(Message),
      %%     DynamicQuerys = update_collection_names(Querys, <<"status">>),
      %%     query(StatusData, DynamicQuerys);
      %%   _ ->
      %%     ok
      %% end
      ok
  end.


%% 新增函数：从topic中提取设备名
extract_device_name_from_topic(Topic) ->
  %% 假设topic格式为: "hygro/deviceTelemetry/设备名"
  Parts = binary:split(Topic, <<"/">>, [global]),
  case length(Parts) of
    Length when Length >= 3 ->
      %% 取第三部分作为设备名
      lists:nth(3, Parts);
    _ ->
      <<"unknown">>
  end.

%% 确保这些辅助函数存在
update_collection_names(Querys, CollectionName) ->
  lists:map(fun({Name, _Collection}) ->
    {Name, CollectionName}
            end, Querys).


unload() ->
  unhook('message.publish', {?MODULE, on_message_publish}),
  catch ets:delete(?PLUGIN_MONGODB_TAB),
  emqx_resource:remove_local(?PLUGIN_MONGODB_RESOURCE_ID).

hook(HookPoint, MFA) ->
  emqx_hooks:add(HookPoint, MFA, _Property = ?HP_HIGHEST).

unhook(HookPoint, MFA) ->
  emqx_hooks:del(HookPoint, MFA).

ensure_ets_table() ->
  case ets:info(?PLUGIN_MONGODB_TAB) of
    undefined ->
      ets:new(?PLUGIN_MONGODB_TAB, [named_table, public, set, {keypos, 1}, {read_concurrency, true}]);
    _ ->
      ets:delete_all_objects(?PLUGIN_MONGODB_TAB)
  end.

reload() ->
  ets:delete_all_objects(?PLUGIN_MONGODB_TAB),
  emqx_resource:stop(?PLUGIN_MONGODB_RESOURCE_ID),
  emqx_resource:remove_local(?PLUGIN_MONGODB_RESOURCE_ID),
  load(read_config()).

read_config() ->
  case hocon:load(mongodb_config_file()) of
    {ok, RawConf} ->
      case emqx_config:check_config(emqx_plugin_mongodb_schema, RawConf) of
        {_, #{plugin_mongodb := Conf}} ->
          ?SLOG(info, #{
            msg => "emqx_plugin_mongodb config",
            config => Conf
          }),
          Conf;
        _ ->
          ?SLOG(error, #{
            msg => "bad_hocon_file",
            file => mongodb_config_file()
          }),
          {error, bad_hocon_file}

      end;
    {error, Error} ->
      ?SLOG(error, #{
        msg => "bad_hocon_file",
        file => mongodb_config_file(),
        reason => Error
      }),
      {error, bad_hocon_file}
  end.

mongodb_config_file() ->
  Env = os:getenv("EMQX_PLUGIN_MONGODB_CONF"),
  case Env =:= "" orelse Env =:= false of
    true -> "etc/emqx_plugin_mongodb.hocon";
    false -> Env
  end.

start_resource(Connection = #{health_check_interval := HealthCheckInterval}) ->
  ResId = ?PLUGIN_MONGODB_RESOURCE_ID,
  ok = emqx_resource:create_metrics(ResId),
  Result = emqx_resource:create_local(
    ResId,
    ?PLUGIN_MONGODB_RESOURCE_GROUP,
    emqx_plugin_mongodb_connector,
    Connection,
    #{health_check_interval => HealthCheckInterval}),
  start_resource_if_enabled(Result).

start_resource_if_enabled({ok, _Result = #{error := undefined, id := ResId}}) ->
  {ok, ResId};
start_resource_if_enabled({ok, #{error := Error, id := ResId}}) ->
  ?SLOG(error, #{
    msg => "start resource error",
    error => Error,
    resource_id => ResId
  }),
  emqx_resource:stop(ResId),
  error.

query(EvtMsg, Querys) ->
  query_ret(
    emqx_resource:query(?PLUGIN_MONGODB_RESOURCE_ID, {Querys, EvtMsg}),
    EvtMsg,
    Querys
  ).

query_ret({_, ok}, _, _) ->
  ok;
query_ret(Ret, EvtMsg, Querys) ->
  ?SLOG(error,
    #{
      msg => "failed_to_query_mongodb_resource",
      ret => Ret,
      evt_msg => EvtMsg,
      querys => Querys
    }).

eventmsg_publish(
    Message = #message{
      id = Id,
      from = ClientId,
      qos = QoS,
      flags = Flags,
      topic = Topic,
      payload = Payload,
      timestamp = Timestamp
    }
) ->
  with_basic_columns(
    'message.publish',
    #{
      id => emqx_guid:to_hexstr(Id),
      clientid => ClientId,
      username => emqx_message:get_header(username, Message, undefined),
      payload => Payload,
      peerhost => ntoa(emqx_message:get_header(peerhost, Message, undefined)),
      topic => Topic,
      qos => QoS,
      flags => Flags,
      pub_props => printable_maps(emqx_message:get_header(properties, Message, #{})),
      publish_received_at => Timestamp
    }
  ).

%% 修改with_basic_columns函数，避免重复的时间戳
with_basic_columns(EventName, Columns) when is_map(Columns) ->
  %% 移除timestamp字段，因为我们在telemetry数据中已经有了_id
  FilteredColumns = maps:remove(timestamp, Columns),
  FilteredColumns#{
    event => EventName,
    node => node()
  }.

ntoa(undefined) -> <<"unknown">>;
ntoa({IpAddr, Port}) -> iolist_to_binary([inet:ntoa(IpAddr), ":", integer_to_list(Port)]);
ntoa(IpAddr) -> iolist_to_binary(inet:ntoa(IpAddr)).

printable_maps(undefined) ->
  #{};
printable_maps(Headers) ->
  maps:fold(
    fun
      (K, V0, AccIn) when K =:= peerhost; K =:= peername; K =:= sockname ->
        AccIn#{K => ntoa(V0)};
      ('User-Property', V0, AccIn) when is_list(V0) ->
        AccIn#{
          %% The 'User-Property' field is for the convenience of querying properties
          %% using the '.' syntax, e.g. "SELECT 'User-Property'.foo as foo"
          %% However, this does not allow duplicate property keys. To allow
          %% duplicate keys, we have to use the 'User-Property-Pairs' field instead.
          'User-Property' => maps:from_list(V0),
          'User-Property-Pairs' => [
            #{
              key => Key,
              value => Value
            }
            || {Key, Value} <- V0
          ]
        };
      (_K, V, AccIn) when is_tuple(V) ->
        %% internal headers
        AccIn;
      (K, V, AccIn) ->
        AccIn#{K => V}
    end,
    #{'User-Property' => #{}},
    Headers
  ).

topic_parse([]) ->
  ok;
topic_parse([#{filter := Filter, name := Name, collection := Collection} | T]) ->
  Item = {Name, Filter, Collection},
  ets:insert(?PLUGIN_MONGODB_TAB, Item),
  topic_parse(T);
topic_parse([_ | T]) ->
  topic_parse(T).

select(Message) ->
  select(ets:tab2list(?PLUGIN_MONGODB_TAB), Message, []).

select([], _, Acc) ->
  {true, Acc};
select([{Name, Filter, Collection} | T], Message, Acc) ->
  case match_topic(Message, Filter) of
    true ->
      select(T, Message, [{Name, Collection} | Acc]);
    false ->
      select(T, Message, Acc)
  end.

match_topic(_, <<$#, _/binary>>) ->
  false;
match_topic(_, <<$+, _/binary>>) ->
  false;
match_topic(#message{topic = <<"$SYS/", _/binary>>}, _) ->
  false;
match_topic(#message{topic = Topic}, Filter) ->
  emqx_topic:match(Topic, Filter);
match_topic(_, _) ->
  false.


%% 修改parse_payload_to_telemetry函数，移除name字段（如果需要）
parse_payload_to_telemetry(Payload, Timestamp) ->
  try
    JsonData = jsx:decode(Payload, [return_maps]),

    %% 提取需要的字段，如果没有则使用默认值
    Time = maps:get(<<"time">>, JsonData, Timestamp div 1000),
    Ct = maps:get(<<"ct">>, JsonData, 0.0),
    Ch = maps:get(<<"ch">>, JsonData, 0.0),
    Ctc = maps:get(<<"ctc">>, JsonData, 0.0),
    Chc = maps:get(<<"chc">>, JsonData, 0.0),

    %% 构建telemetry格式的数据
    #{
      <<"_id">> => Timestamp div 1000,
      <<"time">> => Time,
      <<"ct">> => Ct,
      <<"ch">> => Ch,
      <<"ctc">> => Ctc,
      <<"chc">> => Chc
    }
  catch
    _:_ ->
      %% 如果解析失败，返回默认值
      #{
        <<"_id">> => Timestamp div 1000,
        <<"time">> => Timestamp div 1000,
        <<"ct">> => 0.0,
        <<"ch">> => 0.0,
        <<"ctc">> => 0.0,
        <<"chc">> => 0.0
      }
  end.



%% 修改eventmsg_publish_telemetry函数，只返回telemetry数据
eventmsg_publish_telemetry(
    Message = #message{
      payload = Payload,
      timestamp = Timestamp
    }
) ->
  %% 直接返回telemetry数据，去掉所有EMQX元数据
  parse_payload_to_telemetry(Payload, Timestamp).

eventmsg_publish_device_status(
    Message = #message{
      topic = Topic,
      payload = Payload,
      timestamp = Timestamp
    }
) ->
  %% 从topic中提取设备名作为_id
  DeviceName = extract_device_name_from_status_topic(Topic),

  %% 解析payload获取其他字段
  {Version, Time} = extract_fields_from_payload(Payload, Timestamp),

  %% 构建状态数据格式，确保包含_id字段
  #{
    <<"_id">> => DeviceName,      %% 使用设备名作为_id
    <<"name">> => DeviceName,     %% 使用设备名作为name
    <<"version">> => Version,     %% 从payload中提取version
    <<"time">> => Time            %% 从payload中提取time或使用时间戳
  }.

%% 新增函数：从status topic中提取设备名
extract_device_name_from_status_topic(Topic) ->
  Parts = binary:split(Topic, <<"/">>, [global]),
  case length(Parts) of
    Length when Length >= 3 ->
      lists:nth(3, Parts);
    _ ->
      <<"unknown">>
  end.

%% 新增函数：从payload中提取version和time字段
extract_fields_from_payload(Payload, Timestamp) ->
  try
    JsonData = jsx:decode(Payload, [return_maps]),
    Version = maps:get(<<"version">>, JsonData, <<"unknown">>),
    Time = maps:get(<<"time">>, JsonData, Timestamp div 1000),
    {Version, Time}
  catch
    _:_ ->
      {<<"unknown">>, Timestamp div 1000}
  end.


%%%% 备份代码，当需要接收系统的信息的时候
%% 修改eventmsg_publish_status函数，使用指定的格式
%%eventmsg_publish_status(
%%    Message = #message{
%%      id = Id,
%%      from = ClientId,
%%      qos = QoS,
%%      flags = Flags,
%%      topic = Topic,
%%      payload = Payload,
%%      timestamp = Timestamp
%%    }
%%) ->
%%  %% 从topic中提取设备ID作为_id
%%  DeviceId = extract_device_id_from_topic(Topic),
%%
%%  %% 将flags转换为map格式
%%  FlagsMap = flags_to_map(Flags),
%%
%%  %% 构建指定格式的系统数据
%%  #{
%%    <<"_id">> => DeviceId,
%%    <<"username">> => emqx_message:get_header(username, Message, <<"unknown">>),
%%    <<"flags">> => FlagsMap,
%%    <<"qos">> => QoS,
%%    <<"topic">> => Topic,
%%    <<"peerhost">> => ntoa(emqx_message:get_header(peerhost, Message, <<"unknown">>)),
%%    <<"publish_received_at">> => Timestamp,
%%    <<"payload">> => Payload,
%%    <<"clientid">> => ClientId,
%%    <<"message_id">> => emqx_guid:to_hexstr(Id),
%%    <<"node">> => atom_to_binary(node(), utf8),
%%    <<"processed_at">> => erlang:system_time(millisecond)
%%  }.

%% 新增函数：从topic中提取设备ID
%%extract_device_id_from_topic(Topic) ->
%%  %% 尝试从各种可能的topic格式中提取设备ID
%%  case binary:split(Topic, <<"/">>, [global]) of
%%    [<<"$SYS">>, <<"brokers">>, Broker, <<"clients">>, ClientId, _] ->
%%      %% 格式: $SYS/brokers/emqx@127.0.0.1/clients/Re465b8aff30a/...
%%      ClientId;
%%    [<<"$SYS">>, <<"brokers">>, Broker, <<"nodes">>, Node, _] ->
%%      %% 格式: $SYS/brokers/emqx@127.0.0.1/nodes/emqx@127.0.0.1/...
%%      Node;
%%    [<<"$SYS">>, <<"brokers">>, Broker, _] ->
%%      %% 格式: $SYS/brokers/emqx@127.0.0.1/version
%%      Broker;
%%    Parts when length(Parts) >= 2 ->
%%      %% 取最后一个有意义的part作为设备ID
%%      lists:last(Parts);
%%    _ ->
%%      %% 如果无法提取，使用默认值
%%      <<"unknown">>
%%  end.


%% 新增：将flags转换为map的函数
%%flags_to_map(Flags) when is_tuple(Flags) ->
%%  %% 假设Flags是{dup, retain}格式的元组
%%  case tuple_size(Flags) of
%%    2 ->
%%      #{<<"dup">> => element(1, Flags), <<"retain">> => element(2, Flags)};
%%    _ ->
%%      #{<<"dup">> => false, <<"retain">> => false}
%%  end;
%%flags_to_map(_) ->
%%  #{<<"dup">> => false, <<"retain">> => false}.
