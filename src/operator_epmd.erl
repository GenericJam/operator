%% operator_epmd.erl — the cluster's port mapper: there is none.
%%
%% Every cluster node listens on the same fixed port (`Operator.Cluster`'s
%% 9370, kernel env `operator_dist_port`), so a peer's port is known without
%% asking an epmd. A phone runs no epmd (in development its 4369 is the
%% Mac's epmd through `adb reverse`, which a cluster node must not register
%% with). `Operator.Cluster` sets this module as kernel's `epmd_module` while
%% the cluster runs and unsets it for the development link.
%%
%% A node that isn't a phone gets the same behaviour from stock OTP with
%% `-start_epmd false -erl_epmd_port 9370` (docs/CLUSTER.md).
-module(operator_epmd).

-export([start_link/0, register_node/2, register_node/3, listen_port_please/2,
         port_please/2, port_please/3, address_please/3, names/1]).

%% The lowest distribution version, as erl_epmd answers without an epmd.
-define(DIST_VERSION, 6).

start_link() -> ignore.

%% -1: no epmd to hand out a creation; net_kernel picks one.
register_node(_Name, _Port) -> {ok, -1}.
register_node(_Name, _Port, _Family) -> {ok, -1}.

listen_port_please(_Name, _Host) -> {ok, port()}.

port_please(Name, Host) -> port_please(Name, Host, infinity).
port_please(_Name, _Host, _Timeout) -> {port, port(), ?DIST_VERSION}.

address_please(_Name, Host, Family) -> inet:getaddr(Host, Family).

names(_Host) -> {error, address}.

port() ->
    {ok, Port} = application:get_env(kernel, operator_dist_port),
    Port.
