-module(hackto_ffi).
-export([send/1]).

send({hackney_request, Method, Url, Body, Headers, Timeout}) ->
  Options = [
    {binary, true},
    {with_body, true},
    {max_body, infinity},
    {async, false},
    {recv_timeout, Timeout},
    {follow_redirect, true}
  ],
  case hackney:request(Method, Url, Headers, Body, Options) of
    {ok, Status, ResponseHeaders, ResponseBody} ->
      {ok, {hackney_response, Status, ResponseHeaders, {some, ResponseBody}}};
    {ok, Status, ResponseHeaders} ->
      {ok, {hackney_response, Status, ResponseHeaders, none}};
    {error, Error} ->
      case Error of
        timeout -> {error, {hackney_error, timeout}};
        _ -> {error, {hackney_error, {other, Error}}}
      end
  end.

