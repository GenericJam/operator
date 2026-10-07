%% operator_dist.erl — Operator's distribution carrier (`-proto_dist operator`).
%%
%% The proto is fixed when the BEAM boots (`Operator.Cluster` writes the
%% init args for the next launch with `Mob.InitArgs`), but which carrier the
%% node uses is chosen each time distribution starts:
%%
%%   * `inet_tcp_dist` (the default): the development link, plain TCP on
%%     loopback only, reached from the Mac through `adb forward`
%%     (`Mob.Dist`, `mix mob.connect`, scripts/rpc.sh);
%%   * `inet_tls_dist`: the cluster, mutually authenticated TLS on the
%%     phone's Wi-Fi address, peers pinned by certificate fingerprint
%%     (`Operator.Cluster.Tls`).
%%
%% `Operator.Cluster` sets the mode (`set_mode/1`) only while distribution
%% is stopped, so every callback of one distribution run goes to the same
%% carrier.
-module(operator_dist).

-export([set_mode/1, mode/0]).
-export([childspecs/0, select/1, address/0, is_node_name/1, listen/2, accept/1,
         accept_connection/5, setup/5, close/1, setopts/2, getopts/2]).

-define(KEY, {?MODULE, mode}).

-spec set_mode(tcp | tls) -> ok.
set_mode(tcp) ->
    persistent_term:erase(?KEY),
    ok;
set_mode(tls) ->
    persistent_term:put(?KEY, inet_tls_dist).

-spec mode() -> tcp | tls.
mode() ->
    case carrier() of
        inet_tls_dist -> tls;
        inet_tcp_dist -> tcp
    end.

carrier() ->
    persistent_term:get(?KEY, inet_tcp_dist).

childspecs() ->
    case carrier() of
        inet_tls_dist -> inet_tls_dist:childspecs();
        inet_tcp_dist -> {ok, []}
    end.

select(Node) -> (carrier()):select(Node).

address() -> (carrier()):address().

is_node_name(Node) -> (carrier()):is_node_name(Node).

listen(Name, Host) -> (carrier()):listen(Name, Host).

accept(Listen) -> (carrier()):accept(Listen).

accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    (carrier()):accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime).

setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    (carrier()):setup(Node, Type, MyNode, LongOrShortNames, SetupTime).

close(Listen) -> (carrier()):close(Listen).

setopts(Listen, Opts) -> optional(setopts, [Listen, Opts]).

getopts(Socket, Opts) -> optional(getopts, [Socket, Opts]).

%% inet_tls_dist has neither; net_kernel reads `undef` as "not supported".
optional(Fun, Args) ->
    Mod = carrier(),
    case erlang:function_exported(Mod, Fun, length(Args)) of
        true -> apply(Mod, Fun, Args);
        false -> {error, enotsup}
    end.
