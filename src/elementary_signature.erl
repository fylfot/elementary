-module(elementary_signature).

% API
-export([headers/9]).

-ifdef(TEST).
-export([headers/10]).
-export([canonical_request/5]).
-export([string_to_sign/3]).
-export([signature/5]).
-endif.

%--- API ----------------------------------------------------------------------

headers(Method, URI, QueryString, Headers, Payload, AccessKey,
        SecretAccessKey, Region, Service) ->
    DateTime = calendar:universal_time(),
    headers(Method, URI, QueryString, Headers, Payload, AccessKey,
        SecretAccessKey, Region, Service, DateTime).

%--- Internal Functions -------------------------------------------------------

headers(Method, URI, QueryString, Headers, Payload, AccessKey,
        SecretAccessKey, Region, Service, {D, T}) ->
    HashedPayload = hash(Payload),
    Date = date(D),
    TimeStamp = timestamp(Date, T),
    AMZHeaders = [
        {<<"x-amz-content-sha256">>, HashedPayload},
        {<<"x-amz-date">>, TimeStamp}
    ],
    AllHeaders = AMZHeaders ++ Headers,
    {CanonicalRequest, SignedHeaders, QueryString} =
        canonical_request(Method, URI, QueryString, AllHeaders,
            HashedPayload),
    Scope = scope(Date, Region, Service),
    StringToSign = string_to_sign(TimeStamp, Scope, CanonicalRequest),
    Signature =
        signature(SecretAccessKey, Date, Region, Service, StringToSign),
    SignatureHeaders = [
        {
            <<"Authorization">>, [
                <<"AWS4-HMAC-SHA256 Credential=">>,
                AccessKey, $/, Scope, $,,
                <<"SignedHeaders=">>, SignedHeaders, $,,
                <<"Signature=">>, Signature
            ]
        }
        | AMZHeaders
    ],
    {SignatureHeaders, QueryString}.

canonical_request(Method, URI, QueryString, Headers, HashedPayload) ->
    {CanonicalHeaders, SignedHeaders} = canonical_headers(Headers),
    CanonicalQueryString = hackney_url:qs(lists:sort(QueryString)),
    {
        [
            method(Method), $\n,
            canonical_uri(URI), $\n,
            CanonicalQueryString, $\n,
            CanonicalHeaders, $\n,
            SignedHeaders, $\n,
            HashedPayload
        ],
        SignedHeaders,
        QueryString
    }.

string_to_sign(TimeStamp, Scope, CanonicalRequest) ->
    [
        <<"AWS4-HMAC-SHA256">>, $\n,
        TimeStamp, $\n,
        Scope, $\n,
        hash(CanonicalRequest)
    ].

signature(SecretAccessKey, Date, Region, Service, StringToSign) ->
    DateKey = hmac:hmac256([<<"AWS4">>, SecretAccessKey], Date),
    DateRegionKey = hmac:hmac256(DateKey, Region),
    DateRegionServiceKey = hmac:hmac256(DateRegionKey, Service),
    SigningKey = hmac:hmac256(DateRegionServiceKey, "aws4_request"),
    hmac:hexlify(hmac:hmac256(SigningKey, StringToSign), [lower]).

%--- Parts --------------------------------------------------------------------

method(get) -> <<"GET">>;
method(put) -> <<"PUT">>.

canonical_uri(URI) -> [$/, URI].

canonical_headers(Headers) ->
    canonical_headers(Headers, [], []).

canonical_headers([], CanonicalHeaders, SignedHeaders) ->
    {lists:sort(CanonicalHeaders), join(lists:sort(SignedHeaders), $;)};
canonical_headers([Header|Headers], CanonicalHeaders, SignedHeaders) ->
    {C, S} = canonical_header(Header),
    canonical_headers(Headers, [C|CanonicalHeaders], [S|SignedHeaders]).

canonical_header({H, V}) ->
    Lower = lowercase(H),
    {[Lower, $:, trim(V), $\n], Lower}.

scope(Date, Region, Service) ->
    [Date, $/, Region, $/, Service, $/, <<"aws4_request">>].

%--- Utility Functions --------------------------------------------------------

timestamp(Date, {Hour, Minute, Second}) ->
    [Date, $T, pad(Hour), pad(Minute), pad(Second), $Z].

date({Year, Month, Day}) ->
    [integer_to_list(Year), pad(Month), pad(Day)].

pad(Number) when Number < 10 -> [$0|integer_to_list(Number)];
pad(Number)                  -> integer_to_list(Number).

lowercase(Binary) when is_binary(Binary) -> lowercase(binary_to_list(Binary));
lowercase(String) when is_list(String)   -> string:to_lower(String).

trim(IOData) ->
    re:replace(IOData, <<"^\\s+|\\s+$">>, [], [dotall, multiline]).

hash(<<>>) ->
    <<"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855">>;
hash(Payload) ->
    hmac:hexlify(erlsha2:sha256(Payload), [lower]).

join([], _Separator)          -> [];
join([First|List], Separator) -> [First, [[Separator, I] || I <- List]].
