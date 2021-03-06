%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2014-2016, Feng Lee <feng@emqtt.io>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------

-module(emqtt_benchmark).

-export([pub_http/0, prepare/0,main/2, start/2, run/3, connect/4, loop/4, print_quality_stats/0, print_list/1, time_diff/1]).

-define(TAB, eb_stats).

get_timestamp() ->
    {A, B, C} = erlang:now(),
    SentTime = ((A*1000000+B)*1000000+C),
    iolist_to_binary(lists:flatten(io_lib:format("~p", [SentTime]))).

main(sub, Opts) ->
    start(sub, Opts);

main(pub, Opts) ->
    Size    = proplists:get_value(size, Opts),
    Payload = iolist_to_binary([O || O <- lists:duplicate(Size, 0)]),
    start(pub, [{payload, Payload} | Opts]).

start(PubSub, Opts) ->
    prepare(), 
    %timer:sleep(5000),
    init(),
    spawn(?MODULE, run, [self(), PubSub, Opts]),
    timer:send_interval(1000, stats),
    main_loop(os:timestamp(), 1+proplists:get_value(startnumber, Opts), proplists:get_value(topic,Opts)).

prepare() ->
    %application:ensure_all_started(restc),
    ssl:start(),
    inets:start(),
    %timer:sleep(1000),
    %pub_http(),
    %restc:request(get, "https://api.github.com"),
    httpc:request(get, {"http://www.erlang.org", []}, [], []).
    %application:ensure_all_started(emqtt_benchmark).

get_list(0) ->
        [];
get_list(N) ->
        [{N, 0} | get_list(N-1)].

ets_init() ->
   ets:new(ingredients, [set, named_table, public]),
   ets:insert(ingredients, get_list(10000)).

print_quality_stats() ->
   io:fwrite("~s ~n",[get_timestamp()]),
   timer:sleep(1000),
   print_list(ets:match_object(ingredients, {'$0', '$1'})),
   %timer:sleep(10000),
   print_quality_stats().

print_list([]) ->
   [];

print_list([{A,B} | T]) ->
   % io:fwrite("~B~25.B~n",[A,B]),
   print_list(T).

add_timestamp(Payload) ->
   {SentTime, _ } = string:to_integer(Payload),
   {A, B, C} = erlang:now(),
   TimeTaken = ((A*1000000+B)*1000000+C - SentTime) div 1000,
   io:fwrite("~B~n",[TimeTaken]).

init() ->
    ets_init(),
    timer:sleep(1000),
    spawn(?MODULE,print_quality_stats,[]),
    ets:new(?TAB, [public, named_table, {write_concurrency, true}]),
    put({stats, recv}, 0),
    ets:insert(?TAB, {recv, 0}),
    put({stats, sent}, 0),
    ets:insert(?TAB, {sent, 0}).

time_diff(Payload) ->
   %{SentTime, K } = string:to_integer(Payload),
   SentTime =  list_to_integer(binary_to_list(Payload)),
   {A, B, C} = erlang:now(),
   TimeTaken = ((A*1000000+B)*1000000+C - SentTime) div 1000,
   % Write it in ets
   % add_timestamp(Payload).
   [{E,D}] = ets:lookup(ingredients, TimeTaken),
   F = D+1,
   % ets:delete(ingredients, TimeTaken),
   ets:insert(ingredients, {TimeTaken, F}),
   ok.
   %io:fwrite("~B~n",[ets:lookup(ingredients, TimeTaken)]). %ets.

main_loop(Uptime, Count, Topic) ->
	receive
		{connected, _N, _Client} ->
			io:format("conneted: ~w~n", [Count]),
			main_loop(Uptime, Count+1, Topic);
        stats ->
            print_stats(Uptime, Topic),
			main_loop(Uptime, Count, Topic);
        Msg ->
            io:format("~p~n", [Msg]),
            main_loop(Uptime, Count, Topic)
	end.

print_stats(Uptime, Topic) ->
    print_stats(Uptime, recv, Topic),
    print_stats(Uptime, sent, Topic).

print_stats(Uptime, Key, Topic) ->
    [{Key, Val}] = ets:lookup(?TAB, Key),
    LastVal = get({stats, Key}),
    case Val == LastVal of
        false ->
            Tdiff = timer:now_diff(os:timestamp(), Uptime) div 1000,
            io:format("~s(~w): total=~w, rate=~w(msg/sec), ~s   ~n",
                        [Key, Tdiff, Val, Val - LastVal, Topic]),
            put({stats, Key}, Val);
        true  ->
            ok
    end.

run(Parent, PubSub, Opts) ->
    run(Parent, proplists:get_value(count, Opts), PubSub, Opts).

run(_Parent, 0, _PubSub, _Opts) ->
    done;
run(Parent, N, PubSub, Opts) ->
    spawn(?MODULE, connect, [Parent, N+proplists:get_value(startnumber, Opts), PubSub, Opts]),
	timer:sleep(proplists:get_value(interval, Opts)),
	run(Parent, N-1, PubSub, Opts).
    
connect(Parent, N, PubSub, Opts) ->
    process_flag(trap_exit, true),
    random:seed(os:timestamp()),
    % HTTP Added
    Interval = proplists:get_value(interval_of_msg, Opts),
    timer:send_interval(Interval, publish),
    loop(N, 1, PubSub, []).
    %
    % ClientId = client_id(PubSub, N, Opts),
    % MqttOpts = [{client_id, ClientId} | mqtt_opts(Opts)],
    % TcpOpts  = tcp_opts(Opts),
    % AllOpts  = [{seq, N}, {client_id, ClientId} | Opts],
    %	case emqttc:start_link(MqttOpts, TcpOpts) of
    % {ok, Client} ->
    %    Parent ! {connected, N, Client},
    %    case PubSub of
    %        sub ->
    %            subscribe(Client, AllOpts);
    %        pub ->
    %           Interval = proplists:get_value(interval_of_msg, Opts),
    %           timer:send_interval(Interval, publish)
    %    end,
    %    loop(N, Client, PubSub, AllOpts);
    % {error, Error} ->
    %     io:format("client ~p connect error: ~p~n", [N, Error])
    % end.

pub_http() ->
    %io:format("client-361 "),
    % timer:sleep(1000),
    httpc:request(get, {"https://pubsub1.mlkcca.com/api/send/rkk_d5fDQ/c9hjLY04CGAVn350QcEjMDWwhN2ismsSNdfa1q44?c=demo&v=361", []}, [], []),
    % restc:request(get, "https://pubsub1.mlkcca.com/api/push/rkk_d5fDQ/c9hjLY04CGAVn350QcEjMDWwhN2ismsSNdfa1q44?c=demo&v=10").
    ets:update_counter(?TAB, recv, {2, 1}).

loop(N, Client, PubSub, Opts) ->
    receive
        publish ->
            spawn(?MODULE,pub_http, []),
            % pub_http(),
	    % io:fwrite("~s ~n",[get_timestamp()]),
            ets:update_counter(?TAB, sent, {2, 1}),
            loop(N, Client, PubSub, Opts);
        {publish, _Topic, _Payload} ->
	    spawn(?MODULE, time_diff, [_Payload]),
            ets:update_counter(?TAB, recv, {2, 1}),
            loop(N, Client, PubSub, Opts);
        {'EXIT', Client, Reason} ->
            io:format("client ~p EXIT: ~p~n", [N, Reason])
	end.

subscribe(Client, Opts) ->
    Qos = proplists:get_value(qos, Opts),
    emqttc:subscribe(Client, [{Topic, Qos} || Topic <- topics_opt(Opts)]).

publish(Client, Opts) ->
    Flags   = [{qos, proplists:get_value(qos, Opts)},
               {retain, proplists:get_value(retain, Opts)}],
    Payload = get_timestamp(), % proplists:get_value(payload, Opts),
    emqttc:publish(Client, topic_opt(Opts), Payload, Flags).

mqtt_opts(Opts) ->
    SslOpts = ssl_opts(Opts),
    [{logger, error}|mqtt_opts([SslOpts|Opts], [])].
mqtt_opts([], Acc) ->
    Acc;
mqtt_opts([{host, Host}|Opts], Acc) ->
    mqtt_opts(Opts, [{host, Host}|Acc]);
mqtt_opts([{port, Port}|Opts], Acc) ->
    mqtt_opts(Opts, [{port, Port}|Acc]);
mqtt_opts([{username, Username}|Opts], Acc) ->
    mqtt_opts(Opts, [{username, list_to_binary(Username)}|Acc]);
mqtt_opts([{password, Password}|Opts], Acc) ->
    mqtt_opts(Opts, [{password, list_to_binary(Password)}|Acc]);
mqtt_opts([{keepalive, I}|Opts], Acc) ->
    mqtt_opts(Opts, [{keepalive, I}|Acc]);
mqtt_opts([{clean, Bool}|Opts], Acc) ->
    mqtt_opts(Opts, [{clean_sess, Bool}|Acc]);
mqtt_opts([{ssl, true} | Opts], Acc) ->
    mqtt_opts(Opts, [ssl|Acc]);
mqtt_opts([{ssl, false} | Opts], Acc) ->
    mqtt_opts(Opts, Acc);
mqtt_opts([{ssl, []} | Opts], Acc) ->
    mqtt_opts(Opts, Acc);
mqtt_opts([{ssl, SslOpts} | Opts], Acc) ->
    mqtt_opts(Opts, [{ssl, SslOpts}|Acc]);
mqtt_opts([_|Opts], Acc) ->
    mqtt_opts(Opts, Acc).

tcp_opts(Opts) ->
    tcp_opts(Opts, []).
tcp_opts([], Acc) ->
    Acc;
tcp_opts([{ifaddr, IfAddr} | Opts], Acc) ->
    {ok, IpAddr} = inet_parse:address(IfAddr),
    tcp_opts(Opts, [{ip, IpAddr}|Acc]);
tcp_opts([_|Opts], Acc) ->
    tcp_opts(Opts, Acc).

ssl_opts(Opts) ->
    ssl_opts(Opts, []).
ssl_opts([], Acc) ->
    {ssl, Acc};
ssl_opts([{keyfile, KeyFile} | Opts], Acc) ->
    ssl_opts(Opts, [{keyfile, KeyFile}|Acc]);
ssl_opts([{certfile, CertFile} | Opts], Acc) ->
    ssl_opts(Opts, [{certfile, CertFile}|Acc]);
ssl_opts([_|Opts], Acc) ->
    ssl_opts(Opts, Acc).

client_id(PubSub, N, Opts) ->
    Prefix =
    case proplists:get_value(ifaddr, Opts) of
        undefined ->
            {ok, Host} = inet:gethostname(), Host;
        IfAddr    ->
            IfAddr
    end,
    list_to_binary(lists:concat([Prefix, "_bench_", atom_to_list(PubSub),
                                    "_", N, "_", random:uniform(16#FFFFFFFF)])).

topics_opt(Opts) ->
    Topics = topics_opt(Opts, []),
    io:format("Topics: ~p~n", [Topics]),
    [feed_var(bin(Topic), Opts) || Topic <- Topics].

topics_opt([], Acc) ->
    Acc;
topics_opt([{topic, Topic}|Topics], Acc) ->
    topics_opt(Topics, [Topic | Acc]);
topics_opt([_Opt|Topics], Acc) ->
    topics_opt(Topics, Acc).

topic_opt(Opts) ->
    feed_var(bin(proplists:get_value(topic, Opts)), Opts).

feed_var(Topic, Opts) when is_binary(Topic) ->
    Props = [{Var, bin(proplists:get_value(Key, Opts))} || {Key, Var} <-
                [{seq, <<"%i">>}, {client_id, <<"%c">>}, {username, <<"%u">>}]],
    lists:foldl(fun({_Var, undefined}, Acc) -> Acc;
                   ({Var, Val}, Acc) -> feed_var(Var, Val, Acc)
        end, Topic, Props).

feed_var(Var, Val, Topic) ->
    feed_var(Var, Val, words(Topic), []).
feed_var(_Var, _Val, [], Acc) ->
    join(lists:reverse(Acc));
feed_var(Var, Val, [Var|Words], Acc) ->
    feed_var(Var, Val, Words, [Val|Acc]);
feed_var(Var, Val, [W|Words], Acc) ->
    feed_var(Var, Val, Words, [W|Acc]).

words(Topic) when is_binary(Topic) ->
    [word(W) || W <- binary:split(Topic, <<"/">>, [global])].

word(<<>>)    -> '';
word(<<"+">>) -> '+';
word(<<"#">>) -> '#';
word(Bin)     -> Bin.

join([]) ->
    <<>>;
join([W]) ->
    bin(W);
join(Words) ->
    {_, Bin} =
    lists:foldr(fun(W, {true, Tail}) ->
                        {false, <<W/binary, Tail/binary>>};
                   (W, {false, Tail}) ->
                        {false, <<W/binary, "/", Tail/binary>>}
                end, {true, <<>>}, [bin(W) || W <- Words]),
    Bin.

bin(A) when is_atom(A)   -> bin(atom_to_list(A));
bin(I) when is_integer(I)-> bin(integer_to_list(I));
bin(S) when is_list(S)   -> list_to_binary(S);
bin(B) when is_binary(B) -> B;
bin(undefined)           -> undefined.

