-module(elementary).

-behaviour(application).

% Application Callbacks
-export([start/2]).
-export([stop/1]).

% API
-export([open/2]).
-export([get/2]).
-export([get/3]).
-export([put/3]).
-export([close/1]).

-record(bucket, {
    access_key,
    secret_access_key,
    endpoint,
    host,
    path,
    region,
    pool
}).

-type etag() :: {etag, iodata()}.
-type expires() :: {expires, {Name::iodata(), DateTime::calendar:datetime()}}.

-type option() ::
    {access_key, binary()} |
    {secret_access_key, binary()} |
    {region, binary()} |
    {host, binary()} |
    {connection_timeout, pos_integer()} |
    {max_connections, pos_integer()}.

-type get_option() :: etag().
-type property() :: etag() | expires().

%--- Application Callbacks ----------------------------------------------------

% @hidden
start(_StartType, _StartArgs) ->
    ets:new(?MODULE, [named_table, public]),
    {ok, self()}.

% @hidden
stop(_State) ->
    ets:delete(?MODULE).

%--- API ----------------------------------------------------------------------

% @doc Open a bucket.
%
% Valid options are:
% <ul>
%     <li>`access_key': Amazon AWS access key (mandatory)</li>
%     <li>`secret_access_key': Amazon AWS secret access key (mandatory)</li>
%     <li>`region': Amazon AWS S3 region (mandatory)</li>
%     <li>
%         `host': Host to send requests to (defaults to
%         `s3-REGION.amazonaws.com')
%     </li>
%     <li>
%         `endpoint': Endpoint to use in `Host' header (defaults to
%         `s3.amazonaws.com')
%     </li>
%     <li>
%         `connection_timeout': The connection timeout for requests in
%          milliseconds (defaults to `5000')
%     </li>
%     <li>
%         `max_connections': Max simultaneous connections to S3 (defaults
%         to `20')
%     </li>
% </ul>
-spec open(Bucket::iodata(), Options::[option()]) -> ok.
open(Bucket, Options) ->
    AccessKey = option(access_key, Options),
    SecretAccessKey = option(secret_access_key, Options),

    {Endpoint, Path} = address(Bucket, Options),

    PoolName = pool_name(Bucket),
    Config = #bucket{
        access_key = AccessKey,
        secret_access_key = SecretAccessKey,
        endpoint = Endpoint,
        host = option(host, Options, Endpoint),
        path = Path,
        region = option(region, Options, <<"us-standard">>),
        pool = PoolName
    },
    case ets:insert_new(?MODULE, {Bucket, Config}) of
        true  -> ok;
        false -> error({bucket_already_exists, Bucket})
    end,

    ok = hackney_pool:start_pool(PoolName, [
        {timeout, option(connection_timeout, Options, 5000)},
        {max_connections, option(max_connections, Options, 20)}
    ]),

    case request(get, Bucket, [], #{query => [{"max-keys", 0}]}) of
        {200, _Headers, _Body} ->
            ok;
        {301, _Headers, _Body} ->
            close_error(Bucket, {wrong_region, Bucket});
        {404, _Headers, _Body} ->
            close_error(Bucket, {no_such_bucket, Bucket});
        {Other, Headers, Body} ->
            close_error(Bucket, {unknown_response, Other, Headers, Body})
    end.

address(Bucket, Options) ->
    address(
        Bucket,
        proplists:get_value(endpoint, Options),
        proplists:get_value(region, Options),
        proplists:get_value(style, Options, virtual)
    ).

address(Bucket, undefined, undefined, virtual) ->
    {[Bucket, <<".s3.amazonaws.com">>], []};
address(Bucket, undefined, _Region, virtual) ->
    {[Bucket, <<".s3.amazonaws.com">>], []};
    % {[Bucket, <<".s3-">>, Region, <<".amazonaws.com">>], [<<>>]};
address(Bucket, undefined, undefined, path) ->
    {<<"s3.amazonaws.com">>, [Bucket]};
address(Bucket, undefined, Region, path) ->
    {[<<"s3-">>, Region, <<".amazonaws.com">>], [Bucket]};
address(Bucket, Endpoint, _, virtual) ->
    {[Bucket, $., Endpoint], []};
address(Bucket, Endpoint, _, path) ->
    {Endpoint, [Bucket]}.

% @doc Equivalent to `get(Bucket, Key, [])'.
% @see get/3
get(Bucket, Key) -> get(Bucket, Key, []).

% @doc Get an object from a bucket.
%
% Returns the data for a key in an open bucket (must have been opened with
% {@link open/2}). If available, the properties will contain the ETag value
% and the expiration information associated with the key.
%
% If an ETag is supplied (with the option `{etag, ETag}'), it is possible that
% the key has not been modified since the last time. In this case,
% `not_modified' is then returned instead of the data.
-spec get(Bucket::iodata(), Key::iodata(), Options::[get_option()]) ->
    {Data::iodata() | not_mofified | not_found, Properties::[property()]}.
get(Bucket, Key, Options) ->
    case request(get, Bucket, [Key], #{headers => to_headers(Options)}) of
        {200, Headers, Body}  ->
            {Body, headers(
                [{etag, <<"ETag">>}, {expires, <<"x-amz-expiration">>}],
                Headers
            )};
        {304, Headers, _Body} ->
            {not_modified, headers(
                [{etag, <<"ETag">>}, {expires, <<"x-amz-expiration">>}],
                Headers
            )};
        {404, _Headers, _Body} ->
            {not_found, []};
        {Code, Headers, Body} ->
            error({unknown_response, {Code, Headers, Body}})
    end.

put(Bucket, Key, Data) ->
    case request(put, Bucket, [Key], #{body => Data}) of
        {200, Headers, _Body} ->
            headers(
                [{etag, <<"ETag">>}, {expires, <<"x-amz-expiration">>}],
                Headers
            );
        Response ->
            error({unknown_response, Response})
    end.

close(Bucket) ->
    Config = get_bucket(Bucket),
    ok = hackney_pool:stop_pool(Config#bucket.pool),
    ets:delete(?MODULE, Bucket),
    ok.

%--- Internal Functions -------------------------------------------------------

request(Method, Bucket, Path, Options) ->
    Headers = maps:get(headers, Options, []),
    Body = maps:get(body, Options, <<>>),
    Query = maps:get(query, Options, []),

    Config = get_bucket(Bucket),
    Endpoint = Config#bucket.endpoint,

    FullPath = path(Config#bucket.path ++ Path),

    AllHeaders = [
        {<<"Host">>, Config#bucket.host},
        {<<"Content-Length">>, integer_to_binary(byte_size(Body))}
    |Headers],
    {Auth, QueryString} = elementary_signature:headers(
        Method,
        FullPath,
        Query,
        AllHeaders,
        Body,
        Config#bucket.access_key,
        Config#bucket.secret_access_key,
        Config#bucket.region,
        <<"s3">>
    ),
    URI = hackney_url:make_url(Endpoint, FullPath, QueryString),
    HackneyOptions = [{pool, Config#bucket.pool}, with_body],
    {ok, StatusCode, RespHeaders, RespBody} =
        hackney:request(Method, URI, AllHeaders ++ Auth, Body, HackneyOptions),
    {StatusCode, RespHeaders, RespBody}.

path([])          -> "";
path([Head|Path]) -> iolist_to_binary([Head|[[<<"/">>, P] || P <- Path]]).

option(Key, Options) ->
    case proplists:lookup(Key, Options) of
        none         -> error({missing_option, Key});
        {Key, Value} -> Value
    end.

option(Key, Options, Default) ->
    proplists:get_value(Key, Options, Default).

get_bucket(Bucket) ->
    try
        ets:lookup_element(?MODULE, Bucket, 2)
    catch
        error:badarg -> error({bucket_not_found, Bucket})
    end.

pool_name(Bucket) ->
    binary_to_atom(iolist_to_binary([<<"elementary_">>, Bucket]), utf8).

headers([], _Headers) ->
    [];
headers([{Key, Header}|Keys], Headers) ->
    case lists:keyfind(Header, 1, Headers) of
        {Header, Value} ->
            [{Key, header(Key, Value)}|headers(Keys, Headers)];
        false ->
            headers(Keys, Headers)
    end.

header(etag, Value) ->
    Value;
header(expires, Value) ->
    {match, [Day, Month, Year, Hour, Minute, Second, Name]} = re:run(
        Value,
        <<"
            .*?,\\s
            (\\d+)\\s                      # Day
            (\\w{3})\\s                   # Month
            (\\d+)\\s                     # Year
            (\\d{2}):(\\d{2}):(\\d{2})\\s # Time
            GMT \\\",\\s
            rule-id=\\\"(.*?)\\\"         # Rule name
        ">>,
        [{capture, all_but_first, binary}, extended]
    ),
    {Name, {
        {
            binary_to_integer(Year),
            binary_to_month(Month),
            binary_to_integer(Day)},
        {
            binary_to_integer(Hour),
            binary_to_integer(Minute),
            binary_to_integer(Second)
        }}
    }.

to_headers([]) ->
    [];
to_headers([{etag, Value}|Options]) ->
    [{<<"If-None-Match">>, Value}|to_headers(Options)].

binary_to_month(<<"Jan">>) -> 1;
binary_to_month(<<"Feb">>) -> 2;
binary_to_month(<<"Mar">>) -> 3;
binary_to_month(<<"Apr">>) -> 4;
binary_to_month(<<"May">>) -> 5;
binary_to_month(<<"Jun">>) -> 6;
binary_to_month(<<"Jul">>) -> 7;
binary_to_month(<<"Aug">>) -> 8;
binary_to_month(<<"Sep">>) -> 9;
binary_to_month(<<"Oct">>) -> 10;
binary_to_month(<<"Nov">>) -> 11;
binary_to_month(<<"Dec">>) -> 12.

close_error(Bucket, Error) ->
    close(Bucket),
    error(Error).
