%% operator_mdns.erl — `.local` host names for the open cluster.
%%
%% Nerves devices (mdns_lite) and Macs name themselves `<host>.local` over
%% multicast DNS (RFC 6762), which the pure-BEAM resolver a phone runs
%% (`Mob.DNS.configure_pure_beam/0`) doesn't speak, so a node like
%% `pi_zero@nerves-7ef3.local` would be unreachable by name. `operator_epmd`
%% resolves those here: one query to 224.0.0.251:5353 from an ordinary port,
%% with the unicast-response (QU) bit set. Sent from a port other than 5353
%% it is also a "legacy unicast" query (RFC 6762 §6.7): either way the
%% answer comes straight back to this socket, without joining the multicast
%% group (which Android only lets an app do under a WifiManager lock).
-module(operator_mdns).

-export([local/1, getaddr/2, getaddr/3]).

-define(GROUP, {224, 0, 0, 251}).
-define(PORT, 5353).
%% The QU bit over class IN.
-define(CLASS_IN_QU, 16#8001).
-define(TYPE_A, 1).

%% Is `Host` an mDNS name?
-spec local(term()) -> boolean().
local(Host) when is_list(Host); is_atom(Host) -> lists:suffix(".local", normalize(Host));
local(_Address) -> false.

%% The IPv4 address of `Host` (`x.local`), or `{error, nxdomain}` when no
%% answer comes within `Timeout` ms.
-spec getaddr(string() | atom(), non_neg_integer()) ->
    {ok, inet:ip4_address()} | {error, term()}.
getaddr(Host, Timeout) -> getaddr(Host, Timeout, {?GROUP, ?PORT}).

%% The same, asking `{Address, Port}` instead of the mDNS group (tests).
-spec getaddr(string() | atom(), non_neg_integer(), {inet:ip4_address(), inet:port_number()}) ->
    {ok, inet:ip4_address()} | {error, term()}.
getaddr(Host0, Timeout, {Address, Port}) ->
    Host = normalize(Host0),
    case gen_udp:open(0, [binary, {active, false}, {multicast_ttl, 255} | interface()]) of
        {ok, Socket} ->
            try
                Deadline = erlang:monotonic_time(millisecond) + Timeout,
                ok = gen_udp:send(Socket, Address, Port, query(rand:uniform(16#ffff), Host)),
                await(Socket, Host, Deadline)
            after
                gen_udp:close(Socket)
            end;
        {error, _} = Error ->
            Error
    end.

%% Leave through the interface distribution listens on (Wi-Fi, not a
%% phone's cellular one), as `Operator.Cluster` sets it.
interface() ->
    case application:get_env(kernel, inet_dist_use_interface) of
        {ok, Ip} -> [{ip, Ip}, {multicast_if, Ip}];
        undefined -> []
    end.

query(Id, Host) ->
    Labels = [begin B = list_to_binary(L), <<(byte_size(B)), B/binary>> end
              || L <- string:split(Host, ".", all)],
    iolist_to_binary([<<Id:16, 0:16, 1:16, 0:16, 0:16, 0:16>>, Labels,
                      <<0, ?TYPE_A:16, ?CLASS_IN_QU:16>>]).

await(Socket, Host, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case gen_udp:recv(Socket, 0, Left) of
        {ok, {_Addr, _Port, Packet}} ->
            case address(Packet, Host) of
                {ok, _} = Found -> Found;
                error -> await(Socket, Host, Deadline)
            end;
        {error, timeout} ->
            {error, nxdomain};
        {error, _} = Error ->
            Error
    end.

%% Any responder may also answer for other names: only an A record for
%% `Host`, in the answers or the additional records.
address(Packet, Host) ->
    case inet_dns:decode(Packet) of
        {ok, Msg} ->
            Records = inet_dns:msg(Msg, anlist) ++ inet_dns:msg(Msg, arlist),
            case [inet_dns:rr(RR, data) || RR <- Records,
                                           inet_dns:rr(RR, type) =:= a,
                                           normalize(inet_dns:rr(RR, domain)) =:= Host] of
                [Ip | _] -> {ok, Ip};
                [] -> error
            end;
        _ ->
            error
    end.

normalize(Host) when is_atom(Host) -> normalize(atom_to_list(Host));
normalize(Host) -> string:lowercase(string:trim(Host, trailing, ".")).
