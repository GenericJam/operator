%% operator_epmd.erl — the port mapper of Operator's two LAN modes.
%%
%% Every node of the paired cluster listens on the same fixed port
%% (`Operator.Cluster`'s 9370, kernel env `operator_dist_port`), so a peer's
%% port is known without asking an epmd. A phone runs no epmd binary (in
%% development its 4369 is the Mac's epmd through `adb reverse`, which a LAN
%% node must not register with). `Operator.Cluster` sets this module as
%% kernel's `epmd_module` while it runs and unsets it for the development
%% link.
%%
%% The mode (`set_mode/1`, only while distribution is stopped):
%%
%%   * `fixed` (the paired TLS cluster): every peer is on the fixed port.
%%   * `open` (plain Erlang distribution with any node): a peer's port is
%%     asked of the epmd on its host, like stock `erl_epmd` does. This node
%%     still listens on the fixed port and registers nowhere:
%%     `Operator.Cluster.Epmd` answers other nodes' lookups for it.
%%
%% Either way a `.local` host is resolved over multicast DNS
%% (`operator_mdns`), which the phone's resolver doesn't do.
%%
%% A node that isn't a phone gets the `fixed` behaviour from stock OTP with
%% `-start_epmd false -erl_epmd_port 9370` (docs/CLUSTER.md).
-module(operator_epmd).

-export([set_mode/1, mode/0]).
-export([start_link/0, register_node/2, register_node/3, listen_port_please/2,
         port_please/2, port_please/3, address_please/3, names/1]).

-define(MDNS_TIMEOUT, 3000).

%% The lowest distribution version, as erl_epmd answers without an epmd.
-define(DIST_VERSION, 6).
-define(KEY, {?MODULE, mode}).

-spec set_mode(fixed | open) -> ok.
set_mode(fixed) ->
    persistent_term:erase(?KEY),
    ok;
set_mode(open) ->
    persistent_term:put(?KEY, open).

-spec mode() -> fixed | open.
mode() -> persistent_term:get(?KEY, fixed).

start_link() -> ignore.

%% -1: no epmd to hand out a creation; net_kernel picks one.
register_node(_Name, _Port) -> {ok, -1}.
register_node(_Name, _Port, _Family) -> {ok, -1}.

listen_port_please(_Name, _Host) -> {ok, port()}.

port_please(Name, Host) -> port_please(Name, Host, infinity).

port_please(Name, Host, Timeout) ->
    case mode() of
        fixed -> {port, port(), ?DIST_VERSION};
        open -> erl_epmd:port_please(Name, Host, Timeout)
    end.

address_please(_Name, Host, inet) ->
    case operator_mdns:local(Host) of
        true -> operator_mdns:getaddr(Host, ?MDNS_TIMEOUT);
        false -> inet:getaddr(Host, inet)
    end;
address_please(_Name, Host, Family) -> inet:getaddr(Host, Family).

names(Host) ->
    case mode() of
        fixed ->
            {error, address};
        open ->
            case address_please(undefined, Host, inet) of
                {ok, Ip} -> erl_epmd:names(Ip);
                {error, _} -> {error, address}
            end
    end.

port() ->
    {ok, Port} = application:get_env(kernel, operator_dist_port),
    Port.
