%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 18. Feb 2016 2:56 AM
%%%-------------------------------------------------------------------
-module(mesos_state_client).
-author("sdhillon").

-include("mesos_state.hrl").
-include("mesos_state_internal.hrl").
-define(WHITESPACE, [<<" ">>, <<"\n">>, <<"\t">>, <<"\r">>]).
-opaque mesos_agent_state() :: map().


-export_type([mesos_agent_state/0]).


%% API
-export([poll/0, poll/1, parse_response/1, flags/1, pid/1, tasks/1, id/1, slaves/1, frameworks/1]).

-spec(proto() -> string()).
proto() ->
  case application:get_env(?APP, ssl, false) of
    true ->
      "https";
    false ->
      "http"
  end.

-spec(maybe_enable_ssl(list()) -> list()).
maybe_enable_ssl(Options) ->
  case application:get_env(?APP, ssl, false) of
    true ->
      [{ssl, [{verify, verify_none}]}|Options];
    false ->
      Options
  end.

-spec(maybe_use_token(list()) -> list()).
maybe_use_token(Headers) ->
  FileToken = try_token_from_file(),
  EnvToken = application:get_env(?APP, token),
  case {FileToken, EnvToken} of
    {{ok, Token}, _} ->
      [{"Authorization", Token}|Headers];
    {_, {ok, Token}} ->
      [{"Authorization", Token}|Headers];
    _ ->
      Headers
  end.

-spec(try_token_from_file() -> {ok, string()} | undefined).
try_token_from_file() ->
  case application:get_env(?APP, ssl_token_file) of
    undefined ->
      undefined;
    {ok, Path} ->
      try_read_token_file(Path)
  end.

-spec(try_read_token_file(string()) -> {ok, string()} | undefined).
try_read_token_file(Path) ->
  case file:read_file(Path) of
    {ok, Binary} ->
      {ok, strip_token_binary(Binary)};
    {error, Error} ->
      lager:warning("unable to open configured token file ~p: ~p", [Path, Error]),
      undefined
  end.

-spec(strip_token_binary(binary()) -> string()).
strip_token_binary(Binary) ->
  Stripped = binary:replace(Binary, ?WHITESPACE, <<>>, [global]),
  binary_to_list(Stripped).

-spec(poll() -> {ok, mesos_agent_state()} | {error, Reason :: term()}).
poll() ->
  Proto = proto(),
  poll(Proto ++ "://localhost:5051/state").

-spec(poll(URI :: string()) -> {ok, mesos_agent_state()} | {error, Reason :: term()}).
poll(URI) ->
  Options = [
    {timeout, application:get_env(?APP, timeout, ?DEFAULT_TIMEOUT)},
    {connect_timeout, application:get_env(?APP, connect_timeout, ?DEFAULT_CONNECT_TIMEOUT)}
  ],
  Options1 = maybe_enable_ssl(Options),
  {ok, Hostname} = inet:gethostname(),
  UserAgent = lists:flatten(io_lib:format("Mesos-State / Host: ~s, Pid: ~s", [Hostname, os:getpid()])),
  Headers = [{"Accept", "application/json"}, {"User-Agent", UserAgent}],
  Headers1 = maybe_use_token(Headers),
  Response = httpc:request(get, {URI, Headers1}, Options1, [{body_format, binary}]),
  handle_response(Response).

handle_response({error, Reason}) ->
  {error, Reason};
handle_response({ok, {_StatusLine = {_HTTPVersion, 200 = _StatusCode, _ReasonPhrase}, _Headers, Body}}) ->
  parse_response(Body);
handle_response({ok, {StatusLine, _Headers, _Body}}) ->
  {error, StatusLine}.

-spec(parse_response(Body :: binary()) -> {ok, mesos_agent_state()}).
parse_response(Body) ->
  %% The labels should be relatively tiny -- just let them be atoms
  ParsedBody = jsx:decode(Body, [return_maps, {labels, atom}]),
  parse_response2(ParsedBody).

parse_response2(ParsedBody) ->
  {ok, ParsedBody}.

flags(_ParsedBody = #{flags := Flags}) ->
  Flags.

pid(_ParsedBody = #{pid := Pid}) ->
  [NameBin, IPPort] = binary:split(Pid, <<"@">>),
  [IPBin, PortBin] = binary:split(IPPort, <<":">>),
  Port = binary_to_integer(PortBin),
  IPString = binary_to_list(IPBin),
  {ok, IP} = inet:parse_ipv4_address(IPString),
  #libprocess_pid{name = NameBin, port = Port, ip = IP}.

is_slave(ParsedBody) ->
  #libprocess_pid{name = NameBin} = pid(ParsedBody),
  case binary:match(NameBin, [<<"slave">>]) of
    nomatch ->
      false;
    _ ->
      true
  end.


slave(Slave) ->
  #slave{
    slave_id = maps:get(id, Slave),
    hostname = maps:get(hostname, Slave),
    pid = pid(Slave)
  }.

-spec(slaves(mesos_agent_state()) -> [slave()]).
slaves(ParsedBody) ->
  case is_slave(ParsedBody) of
    false ->
      Slaves = maps:get(slaves, ParsedBody),
      lists:map(fun slave/1, Slaves);
    true ->
      [slave(ParsedBody)]
  end.

find_slave(Id, Slaves) ->
  case lists:filter(fun(#slave{slave_id = SlaveId}) -> SlaveId == Id end, Slaves) of
    [Slave] ->
      {ok, Slave};
    _ ->
      error
  end.


%rg.listenerRecord(listener, ns)
%rg.masterRecord(domain, masters, sj.Leader)
-spec(frameworks(mesos_agent_state()) -> [framework()]).
frameworks(_ParsedBody = #{frameworks := Frameworks}) ->
  lists:map(fun framework/1, Frameworks).
-spec(framework(map()) -> framework()).
framework(Framework) ->
  Pid =
    case Framework of
      #{pid := _} ->
        pid(Framework);
      _ ->
        undefined
    end,
  #framework{
    id =  maps:get(id, Framework),
    name = maps:get(name, Framework),
    pid = Pid,
    hostname = maps:get(hostname, Framework),
    webui_url = maps:get(webui_url, Framework, undefined)
  }.


-spec(tasks(mesos_agent_state()) -> [task()]).
tasks(ParsedBody = #{frameworks := Frameworks, completed_frameworks := CompletedFrameworks}) ->
  Slaves = slaves(ParsedBody),
  Tasks1 = frameworks(Frameworks, Slaves, ParsedBody, []),
  frameworks(CompletedFrameworks, Slaves, ParsedBody, Tasks1).


frameworks([], _Slaves, _ParsedBody, TasksAcc) ->
  TasksAcc;

frameworks([Framework = #{executors := Executors, tasks := Tasks}|Frameworks], Slaves, ParsedBody, TasksAcc) ->
  TasksAcc1 = executors(Executors, Framework, Slaves, ParsedBody, TasksAcc),
  TasksAcc2 = tasks(Tasks, Framework, Slaves, ParsedBody, TasksAcc1),
  frameworks(Frameworks, Slaves, ParsedBody, TasksAcc2);
frameworks([Framework = #{executors := Executors}|Frameworks], Slaves, ParsedBody, TasksAcc) ->
  TasksAcc1 = executors(Executors, Framework, Slaves, ParsedBody, TasksAcc),
  frameworks(Frameworks, Slaves, ParsedBody, TasksAcc1);
frameworks([Framework = #{tasks := Tasks}|Frameworks], Slaves, ParsedBody, TasksAcc) ->
  TaskAcc1 = tasks(Tasks, Framework, Slaves, ParsedBody, TasksAcc),
  frameworks(Frameworks, Slaves, ParsedBody, TaskAcc1).


executors([], _Framework, _Slaves, _ParsedBody, Tasks) ->
  Tasks;
executors([_Executor = #{tasks := Tasks, completed_tasks := CompletedTasks}|Executors], Framework, Slaves, ParsedBody, TasksAcc) ->
  TasksAcc1 = tasks(Tasks, Framework, Slaves, ParsedBody, TasksAcc),
  TasksAcc2 = tasks(CompletedTasks, Framework, Slaves, ParsedBody, TasksAcc1),
  executors(Executors, Framework, Slaves, ParsedBody, TasksAcc2);
executors([_Executor = #{tasks := Tasks}|Executors], Framework, Slaves, ParsedBody, TasksAcc) ->
  TasksAcc1 = tasks(Tasks, Framework, Slaves, ParsedBody, TasksAcc),
  executors(Executors, Framework, Slaves, ParsedBody, TasksAcc1);
executors([_Executor|Executors], Framework, Slaves, ParsedBody, TasksAcc) ->
  executors(Executors, Framework, Slaves, ParsedBody, TasksAcc).

-ifdef(TEST).

tasks([], _Framework, _Slave, _ParsedBody, TasksAcc) ->
  TasksAcc;
tasks([Task | Tasks], Framework, Slave, ParsedBody, TasksAcc) ->
  TaskRecord = task(Task, Framework, Slave),
  tasks(Tasks, Framework, Slave, ParsedBody, [TaskRecord | TasksAcc]).
-else.
tasks([], _Framework, _Slave, _ParsedBody, TasksAcc) ->
  TasksAcc;
tasks([Task | Tasks], Framework, Slave, ParsedBody, TasksAcc) ->
  case catch task(Task, Framework, Slave) of
    %% Don't bail on failed tasks
    {'EXIT', Reason} ->
      lager:error("Failed to parse task: ~p", [Reason]),
      tasks(Tasks, Framework, Slave, ParsedBody, TasksAcc);
    TaskRecord ->
      tasks(Tasks, Framework, Slave, ParsedBody, [TaskRecord | TasksAcc])
  end.
-endif.

task(Task, Framework, Slaves) ->
  SlaveID = maps:get(slave_id, Task),
  {ok, Slave} = find_slave(SlaveID, Slaves),
  #task{
    id = maps:get(id, Task),
    labels = task_labels(maps:get(labels, Task, [])),
    name = maps:get(name, Task),
    executor_id = maps:get(executor_id, Task),
    state = task_state(maps:get(state, Task)),
    statuses = task_statuses(maps:get(statuses, Task, []), []),
    resources = resources(maps:get(resources, Task)),
    container = container(maps:get(container, Task, undefined)),
    discovery = discovery(maps:get(discovery, Task, undefined)),
    slave = Slave,
    framework = framework(Framework)
  }.

task_labels(Labels) ->
  Proplist = [{Key, Value} || #{key := Key, value := Value} <- Labels],
  maps:from_list(Proplist).


task_state(<<"TASK_RUNNING">>) ->
  running;
task_state(<<"TASK_STAGING">>) ->
  staging;
task_state(<<"TASK_STARTING">>) ->
  starting;
task_state(<<"TASK_FINISHED">>) ->
  finished;
task_state(<<"TASK_FAILED">>) ->
  failed;
task_state(<<"TASK_KILLED">>) ->
  killed;
task_state(<<"TASK_KILLING">>) ->
  killing;
task_state(<<"TASK_LOST">>) ->
  lost;
task_state(<<"TASK_ERROR">>) ->
  error.

resources(Resources) ->
  maps:map(fun resource/2, Resources).

resource(cpus, Value) ->
  Value;
resource(gpus, Value) ->
  Value;
resource(mem, Value) ->
  Value;
resource(disk, Value) ->
  Value;
resource(ports, PortsBin) ->
  PortsStr = binary_to_list(PortsBin),
  range_to_resource(PortsStr);
resource(_, Value) when is_number(Value) ->
  Value.


range_to_resource(String) ->
  String1 = string:strip(String, left, $[),
  String2 = string:strip(String1, right, $]),
  Ranges = [range_to_resource2(Range) || Range <- string:tokens(String2, ", ")],
  lists:flatten(Ranges).

range_to_resource2(Range) ->
  [StartStr, EndStr] = string:tokens(Range, "-"),
  Start = list_to_integer(StartStr),
  End = list_to_integer(EndStr),
  lists:seq(Start, End).

container(undefined) ->
  undefined;
container(#{docker := Docker, type := <<"DOCKER">>}) ->
  #container{type = docker, docker = docker(Docker)}.

port_mapping(#{container_port := ContainerPort, host_port := HostPort, protocol := Protocol}) ->
  #port_mapping{
    protocol = protocol(Protocol),
    host_port = HostPort,
    container_port = ContainerPort
  }.

docker(Docker = #{image := Image, network := NetworkType0})
    when NetworkType0 == <<"BRIDGE">> orelse NetworkType0 == <<"USER">>->
  PortMappings1 =
    case Docker of
      #{port_mappings := PortMappings0} ->
        lists:map(fun port_mapping/1, PortMappings0);
      _ ->
        []
    end,
  NetworkType1 =
    case NetworkType0 of
      <<"USER">> ->
        user;
      <<"BRIDGE">> ->
        bridge
    end,
  ForcePullImage =
    case Docker of
      #{force_pull_image := FPI} ->
        FPI;
      _ ->
        false
    end,
  #docker{force_pull_image = ForcePullImage, image = Image, network = NetworkType1, port_mappings = PortMappings1};
docker(_Docker =
  #{force_pull_image := ForcePullImage, image := Image, network := <<"USER">>, port_mappings := PortMappings0}) ->
  PortMappings1 = lists:map(fun port_mapping/1, PortMappings0),
  #docker{force_pull_image = ForcePullImage, image = Image, network = user, port_mappings = PortMappings1};
docker(_Docker = #{force_pull_image := ForcePullImage, image := Image, network := <<"HOST">>}) ->
  #docker{force_pull_image = ForcePullImage, image = Image, network = host, port_mappings = []}.

task_statuses([], Acc) ->
  Acc1 = lists:keysort(#task_status.timestamp, Acc),
  lists:reverse(Acc1);
task_statuses([TaskStatus|Rest], Acc) ->
  task_statuses(Rest, [task_status(TaskStatus)|Acc]).

task_status(_TaskStatus = #{timestamp := Timestamp, state := State, container_status := ContainerStatus, healthy := Healthy}) ->
  #task_status{
    timestamp = Timestamp,
    container_status = container_status(ContainerStatus),
    state = task_state(State),
    healthy = Healthy
  };
task_status(_TaskStatus = #{timestamp := Timestamp, state := State, container_status := ContainerStatus}) ->
  #task_status{
    timestamp = Timestamp,
    container_status = container_status(ContainerStatus),
    state = task_state(State),
    healthy = undefined
  };
task_status(_TaskStatus = #{timestamp := Timestamp, state := State}) ->
  #task_status{
    timestamp = Timestamp,
    container_status = undefined,
    state = task_state(State),
    healthy = undefined
  }.


container_status(_ContainerStatus = #{cgroup_info := CGroupInfo, network_infos := NetworkInfos}) ->
  #container_status{
    cgroup_info = cgroup_info(CGroupInfo),
    network_infos = network_infos(NetworkInfos, [])
  };
container_status(_ContainerStatus = #{network_infos := NetworkInfos}) ->
  #container_status{
    cgroup_info = undefined,
    network_infos = network_infos(NetworkInfos, [])
  }.

cgroup_info(#{net_cls := #{classid := ClassID}}) ->
  #cgroup_info{net_cls = #net_cls{classid = ClassID}}.


network_infos([], Acc) ->
  Acc;
network_infos([#{ip_addresses := IPAddresses}|Rest], Acc) ->
  NetworkInfo1 = #network_info{ip_addresses = ip_addresses(IPAddresses, [])},
  network_infos(Rest, [NetworkInfo1|Acc]);
%% We have no ip_addresses
network_infos(IPAddresses = [#{ip_address := _IPAddress}], []) ->
  NetworkInfo = #network_info{ip_addresses = ip_addresses(IPAddresses, [])},
  [NetworkInfo].

ip_addresses([], Acc) ->
  Acc;
ip_addresses([#{ip_address := IPAddressBin}|Rest], Acc) ->
  IPAddressStr = binary_to_list(IPAddressBin),
  case inet:parse_ipv4_address(IPAddressStr) of
    {ok, IP} ->
      ip_addresses(Rest, [#ip_address{ip_address = IP}|Acc]);
    %% Raise this error somehow?
    _Else ->
      ip_addresses(Rest, Acc)
   end.


-spec(id(mesos_agent_state()) -> binary()).
id(_ParsedBody = #{id := ID}) ->
  ID.

discovery(undefined) ->
  undefined;
discovery(Discovery) ->
  #discovery{
    name = maps:get(name, Discovery),
    ports = discovery_ports(ports_from_discovery(Discovery), [])
  }.


discovery_ports([], Acc) ->
  Acc;
discovery_ports([Port = #{number := Number, protocol := Protocol}|RestPorts],
    Acc) ->
  PortRecord =
  #mesos_port{
    name = maps:get(name, Port, undefined),
    number = Number,
    protocol = protocol(Protocol),
    labels = port_labels(Port)
  },
  discovery_ports(RestPorts, [PortRecord|Acc]).

port_labels(_Port = #{labels := #{labels := Labels}}) ->
  Proplist = [{Key, Value} || #{key := Key, value := Value} <- Labels],
  maps:from_list(Proplist);
port_labels(_) ->
  #{}.

ports_from_discovery(#{ports := #{ports := Ports}}) ->
  Ports;
ports_from_discovery(_) ->
  [].

protocol(<<"tcp">>) -> tcp;
protocol(<<"udp">>) -> udp.












